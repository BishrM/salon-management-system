#!/usr/bin/env bash
# Concurrency tests that need two real database sessions (Rev 6 §9 "sync races", G2, §5.8).
# Uses the same local harness as scripts/test-db-local.sh (plain PostgreSQL 17 + auth stub).
set -euo pipefail
cd "$(dirname "$0")/.."
export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-54399}" PGUSER="${PGUSER:-postgres}" LC_ALL="${LC_ALL:-en_US.UTF-8}"
PSQL="${PSQL:-$(command -v psql || echo /opt/homebrew/opt/postgresql@17/bin/psql)}"
DB="salonops_conc_$$"
"$PSQL" -qX -d postgres -c "create database $DB" >/dev/null
trap '"$PSQL" -qX -d postgres -c "drop database if exists $DB with (force)" >/dev/null' EXIT
q() { PGOPTIONS='-c search_path=public,extensions' "$PSQL" -qXtA -v ON_ERROR_STOP=1 -d "$DB" "$@"; }

q -f supabase/tests/local/auth_stub.psql >/dev/null 2>&1
for m in supabase/migrations/*.sql; do q -f "$m" >/dev/null 2>&1; done

O=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
q >/dev/null <<SQL
insert into auth.users (id, email, raw_user_meta_data) values
  ('a0000000-0000-4000-8000-000000000001','owner@t','{"full_name":"Owner"}'),
  ('a0000000-0000-4000-8000-000000000003','shop@t','{"full_name":"Shop/Staff"}');
insert into public.outlets (id, name, day_cutoff) values ('$O', 'A', '04:00');
insert into public.outlet_memberships (outlet_id, profile_id, role, reason) values
  ('$O','a0000000-0000-4000-8000-000000000001','owner','t'),
  ('$O','a0000000-0000-4000-8000-000000000003','shop','t');
insert into public.staff (id, full_name, profile_id) values
  ('5aaa0000-0000-4000-8000-00000000000a','Asha',null),
  ('5aaa0000-0000-4000-8000-0000000000aa','Hari',null);
insert into public.staff_assignments (staff_id, outlet_id, start_date)
  select id, '$O', '2020-01-01' from public.staff;
SQL

as() { echo "select set_config('request.jwt.claims', '{\"sub\":\"a0000000-0000-4000-8000-00000000000$1\",\"role\":\"authenticated\"}', false); set role authenticated;"; }
op() { # seq record op_id
  echo "jsonb_build_array(jsonb_build_object('op_id','$3','device_seq',$1,'type','create_entry','record_id','$2','device_time',now(),'device_offset_ms',0,'device_last_sync_at',now(),'data',jsonb_build_object('kind','service','payment_method','cash','staff_id','5aaa0000-0000-4000-8000-00000000000a','amount',10000)))"
}
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1 (got '$2', want '$3')"; fail=1; fi; }

DEV=dddddddd-0000-4000-8000-000000000001
R1=e0000000-0000-4000-8000-000000000001; R2=e0000000-0000-4000-8000-000000000002
OP1=f0000000-0000-4000-8000-000000000001; OP2=f0000000-0000-4000-8000-000000000002

# 1. Two sync batches for one device are serialised by the device row lock; the second sees the first's
#    last_contact_at as its lower bound (§6.4).
q -c "$(as 3) begin; select public.sync_ops('$O','$DEV','Tablet',$(op 1 $R1 $OP1)); select pg_sleep(2); commit;" >/dev/null &
sleep 0.5
start=$(date +%s)
q -c "$(as 3) select public.sync_ops('$O','$DEV','Tablet',$(op 2 $R2 $OP2));" >/dev/null
waited=$(( $(date +%s) - start )); wait
check "second batch waited for the first (device lock)" "$([[ $waited -ge 1 ]] && echo yes || echo no)" yes
check "second batch lower bound = first batch receipt time" \
  "$(q -c "select (select bound_lower from entries where id='$R2') = (select received_at from entries where id='$R1')")" t

# 2. Two tabs send the same op at the same time: exactly one entry, the other is an idempotent duplicate.
R3=e0000000-0000-4000-8000-000000000003; OP3=f0000000-0000-4000-8000-000000000003
for _ in 1 2; do q -c "$(as 3) select public.sync_ops('$O','$DEV','Tablet',$(op 3 $R3 $OP3))" >/dev/null & done; wait
check "concurrent duplicate op creates one entry" "$(q -c "select count(*) from entries where id='$R3'")" 1
check "…and one applied sync record" "$(q -c "select count(*) from sync_ops where op_id='$OP3' and status='applied'")" 1

# 3. Concurrent initial-float establishment: exactly one succeeds (G2 unique index).
for _ in 1 2; do
  q -c "$(as 1) select public.establish_initial_float('$O', current_date - 30, '{\"50000\":4}', 200000)" >/dev/null 2>&1 &
done; wait || true
check "only one initial float under concurrency" "$(q -c "select count(*) from float_movements where type='initial_float'")" 1

# 4. Concurrent drawer handovers for the full payable: the closing row lock lets only one through (§5.8).
D=$(q -c "select current_date - 30")
q -c "insert into entries (id, outlet_id, kind, amount, staff_id, recorded_by, op_id, business_date, date_basis)
      values (gen_random_uuid(),'$O','service',1000000,'5aaa0000-0000-4000-8000-00000000000a','a0000000-0000-4000-8000-000000000003',gen_random_uuid(),'$D','online')" >/dev/null
C=$(q -c "$(as 3) select public.prepare_closing('$O','$D') ->> 'closing_id'" | tail -1)
for _ in 1 2; do
  q -c "$(as 3) begin; select public.record_handover('$C','5aaa0000-0000-4000-8000-0000000000aa',100000,'drawer'); select pg_sleep(1); commit;" >/dev/null 2>&1 &
done; wait || true
check "concurrent handovers cannot exceed the payable" "$(q -c "select coalesce(sum(amount),0) from commission_handovers where closing_id='$C'")" 100000

# 5. Committed end-to-end flow, one transaction per RPC exactly as in production (exercises the
#    commit-time constraint triggers that rolled-back pgTAP tests cannot reach).
q -c "$(as 3) select public.update_draft('$C', 0, null, null, '{\"50000\":22}', null, 'Owner')" >/dev/null
q -c "$(as 3) select public.set_closing_employee('$C', '5aaa0000-0000-4000-8000-00000000000a')" >/dev/null
q -c "$(as 3) select public.submit_closing('$C')" >/dev/null
REV=$(q -c "select current_revision_id from closing_state where closing_id='$C'")
q -c "$(as 1) select public.approve_closing('$REV', '{}')" >/dev/null
check "first day approved (committed)" "$(q -c "select state from closing_state where closing_id='$C'")" approved
F1=e0000000-0000-4000-8000-0000000000f1; OPF=f0000000-0000-4000-8000-0000000000f1
q -c "$(as 3) select public.sync_ops('$O','$DEV','Tablet',jsonb_build_array(jsonb_build_object('op_id','$OPF','device_seq',4,'type','create_entry','record_id','$F1','device_time',now(),'device_offset_ms',0,'device_last_sync_at',now(),'data','{\"kind\":\"food\",\"meal\":\"lunch\",\"amount\":5000,\"pay_now\":true}'::jsonb)))" >/dev/null
check "food paid now committed (deferred paid<=cost check passed)" "$(q -c "select count(*) from food_payments where food_id='$F1'")" 1
T=$(q -c "select app.business_date('$O', now())")
C2=$(q -c "$(as 3) select public.prepare_closing('$O','$T') ->> 'closing_id'" | tail -1)
q -c "$(as 3) select public.set_closing_employee('$C2', '5aaa0000-0000-4000-8000-0000000000aa')" >/dev/null
q -c "$(as 3) select public.update_draft('$C2', 0, null, null, '{\"50000\":4,\"10000\":2,\"5000\":1}', null, 'Owner')" >/dev/null
q -c "$(as 3) select public.submit_closing('$C2')" >/dev/null
check "today's revision (revised food rule): S 300, C 30, lunch 50 → FC 30, owed 20, Fd 50, ED 2250, V 0" \
  "$(q -c "select row(service_total, commission_pool, food_commission_funded, food_shop_funded, food_employee_owed, food_paid_drawer, expected_drawer, variance)::text from closing_revisions where closing_id='$C2'")" \
  "(30000,3000,3000,0,2000,5000,225000,0)"
REV2=$(q -c "select current_revision_id from closing_state where closing_id='$C2'")
q -c "$(as 1) select public.approve_closing('$REV2', '{}')" >/dev/null
check "today approved (committed)" "$(q -c "select state from closing_state where closing_id='$C2'")" approved
check "audit trail has the approval" "$(q -c "select count(*) from audit_logs where table_name='closing_events' and new_data->>'type'='approved'")" 2

exit $fail
