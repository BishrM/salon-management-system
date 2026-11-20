begin;
\ir helpers.psql
select tests.ops_fixture();

-- Client features 4 and 5 (2026-11-20, migration …001500):
--   F4 every service sale records Cash or UPI / Paytm / Card (payment_method cash | paytm);
--   F5 corrected entries are identifiable (version − 1 − voided > 0) and every correction is in the audit log.
select plan(53);

create temp table ids (k text primary key, v uuid);
grant select on ids to authenticated;
insert into ids select k, gen_random_uuid()
  from unnest(array['dev', 'dev2', 'cash', 'upi', 'nomethod', 'badmethod', 'off', 'prod', 'exp', 'legacy', 'b1']) k;
insert into ids values ('today', null);
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
grant execute on function pg_temp.id(text) to authenticated;
create temp table d (today date);
insert into d select app.business_date(tests.outlet('A'), now());
grant select on d to authenticated;

create temp table ops (k text primary key, v jsonb);
grant select on ops to authenticated;
insert into ops values
  ('cash',      tests.op('create_entry', (select v from ids where k = 'cash'), 1,
                  jsonb_build_object('kind', 'service', 'staff_id', tests.staff('A'), 'amount', 55000, 'payment_method', 'cash'))),
  ('upi',       tests.op('create_entry', (select v from ids where k = 'upi'), 2,
                  jsonb_build_object('kind', 'service', 'staff_id', tests.staff('B'), 'amount', 45000, 'payment_method', 'paytm'))),
  ('nomethod',  tests.op('create_entry', (select v from ids where k = 'nomethod'), 3,
                  jsonb_build_object('kind', 'service', 'staff_id', tests.staff('A'), 'amount', 10000))),
  ('badmethod', tests.op('create_entry', (select v from ids where k = 'badmethod'), 4,
                  jsonb_build_object('kind', 'service', 'staff_id', tests.staff('A'), 'amount', 10000, 'payment_method', 'card'))),
  -- Made offline 20 minutes ago (older device time and last-sync time), sent now.
  ('off',       tests.op('create_entry', (select v from ids where k = 'off'), 5,
                  jsonb_build_object('kind', 'service', 'staff_id', tests.staff('C'), 'amount', 30000, 'payment_method', 'paytm'),
                  jsonb_build_object('device_time', now() - interval '20 minutes', 'device_last_sync_at', now() - interval '25 minutes'))),
  ('prod',      tests.op('create_entry', (select v from ids where k = 'prod'), 6,
                  jsonb_build_object('kind', 'product', 'product_id', '9a000000-0000-4000-8000-000000000001', 'quantity', 1,
                                     'unit_price', 25000, 'payment_method', 'cash'))),
  ('exp',       tests.op('create_entry', (select v from ids where k = 'exp'), 7,
                  jsonb_build_object('kind', 'expense', 'amount', 5000, 'description', 'Tea'))),
  ('b1',        tests.op('create_entry', (select v from ids where k = 'b1'), 1,
                  jsonb_build_object('kind', 'service', 'staff_id', tests.staff('A'), 'amount', 10000, 'payment_method', 'cash')));
create function pg_temp.op(p text) returns jsonb language sql as $$ select v from ops where k = p $$;
grant execute on function pg_temp.op(text) to authenticated;
create function pg_temp.send(p_op jsonb, p_outlet text default 'A', p_dev text default 'dev') returns jsonb language sql as $$
  select public.sync_ops(tests.outlet(p_outlet), pg_temp.id(p_dev), 'Tablet', jsonb_build_array(p_op)) -> 'results' -> 0 $$;
grant execute on function pg_temp.send(jsonb, text, text) to authenticated;
create function pg_temp.fix(p_rec text, p_seq int, p_ver int, p_data jsonb, p_extra jsonb default '{}') returns jsonb language sql as $$
  select tests.op('correct_entry', pg_temp.id(p_rec), p_seq, p_data,
    jsonb_build_object('base_version', p_ver, 'reason', 'counter typo') || p_extra) $$;
grant execute on function pg_temp.fix(text, int, int, jsonb, jsonb) to authenticated;
create function pg_temp.audits(p_rec text) returns int language sql as $$
  select count(*)::int from public.audit_logs where table_name = 'entries' and row_id = pg_temp.id(p_rec) $$;
grant execute on function pg_temp.audits(text) to authenticated;

-- F4: payment method on service sales ----------------------------------------------------------------------
select tests.login_as('counter');
select is(pg_temp.send(pg_temp.op('cash')) ->> 'status', 'applied', 'cash service sale is applied');
select is(pg_temp.send(pg_temp.op('upi')) ->> 'status', 'applied', 'UPI / Paytm / Card service sale is applied');
select is((select payment_method::text from public.entries where id = pg_temp.id('cash')), 'cash', 'cash is stored on the entry');
select is((select payment_method::text from public.entries where id = pg_temp.id('upi')), 'paytm', 'UPI / Paytm / Card is stored as paytm');
select ok((select r ->> 'status' = 'failed' and r ->> 'error' like 'choose how it was paid%' from pg_temp.send(pg_temp.op('nomethod')) r),
  'a service sale without a payment method is refused by the server');
select ok((select r ->> 'status' = 'failed' and r ->> 'error' like 'choose how it was paid%' from pg_temp.send(pg_temp.op('badmethod')) r),
  'an unknown payment method is refused (UPI and card stay combined under paytm)');
select is((select count(*)::int from public.entries where id in (pg_temp.id('nomethod'), pg_temp.id('badmethod'))), 0,
  'refused sales create no entry');
select is(pg_temp.send(pg_temp.op('off')) ->> 'status', 'applied', 'a sale made offline syncs later');
select ok((select payment_method = 'paytm' and device_time < received_at - interval '19 minutes' and recorded_by = tests.uid('counter')
           from public.entries where id = pg_temp.id('off')),
  'offline sale keeps its payment method, original device time and the person who recorded it');
-- Its device time is earlier than this device's previous ops, so (existing rule) it waits for a management date.
select ok((select business_date is null and 'seq_order' = any (timestamp_flags) from public.entries where id = pg_temp.id('off')),
  'existing offline dating rules still apply (out-of-order device time → undated until management assigns it)');
select ok((select (r ->> 'duplicate')::boolean and r ->> 'status' = 'applied' from pg_temp.send(pg_temp.op('off')) r),
  'retrying the same op is answered as a duplicate');
select is((select count(*)::int from public.entries where id = pg_temp.id('off')), 1, 'the retry created no second sale');
reset role;

select tests.login_as('outsider');
select throws_ok($$ select pg_temp.send(pg_temp.op('b1'), 'A', 'dev2') $$, '42501', null,
  'the owner of another outlet cannot record a sale in this outlet');
reset role;
select tests.login_as('nobody');
select throws_ok($$ select pg_temp.send(pg_temp.op('b1'), 'A', 'dev2') $$, '42501', null, 'a user with no membership cannot record a sale');
reset role;
select tests.login_as('counter');
select throws_ok($$ select pg_temp.send(pg_temp.op('b1'), 'B', 'dev2') $$, '42501', null,
  'a counter operator cannot record a sale in an outlet they do not work at');
reset role;

-- Accounting: the recorded split is reported; commission and the cash formula are unchanged.
select tests.login_as('counter');
select is((select row((s ->> 'service_total')::bigint, (s ->> 'service_cash_recorded')::bigint, (s ->> 'service_paytm_recorded')::bigint,
                      (s ->> 'service_method_unrecorded')::bigint, (s ->> 'commission_pool')::bigint)::text
           from public.day_summary(tests.outlet('A'), (select today from d)) s),
  row(100000::bigint, 55000::bigint, 45000::bigint, 0::bigint, 10000::bigint)::text,
  'services ₹1,000 = cash ₹550 + UPI/Paytm/Card ₹450; commission is 10% rounded down to ₹10 of all services (₹100)');
reset role;
select is((select (app.compute_day(tests.outlet('A'), (select today from d)) ->> 'commission_pool')::bigint), 10000::bigint,
  'the closing engine computes the same commission (payment method does not change it)');
select ok((select not (s ? 'service_cash_recorded') from app.compute_day(tests.outlet('A'), (select today from d)) s),
  'closing revisions are computed exactly as before (the split is reported by day_summary only)');

-- A service row from before the feature has no method: still valid, still voidable; a correction must state it.
insert into public.entries (id, outlet_id, kind, amount, staff_id, recorded_by, op_id, business_date, date_basis)
  select pg_temp.id('legacy'), tests.outlet('A'), 'service', 20000, tests.staff('A'), tests.uid('counter'), gen_random_uuid(), today, 'online' from d;
select tests.login_as('counter');
select is((select (s ->> 'service_method_unrecorded')::bigint from public.day_summary(tests.outlet('A'), (select today from d)) s),
  20000::bigint, 'an older sale without a method is shown as not recorded');
select ok((select r ->> 'status' = 'failed' and r ->> 'error' like 'choose how it was paid%'
           from pg_temp.send(pg_temp.fix('legacy', 8, 1, '{"amount":25000}')) r),
  'correcting an older sale requires saying how it was paid');
select is(pg_temp.send(pg_temp.fix('legacy', 2, 1, '{"payment_method":"cash"}'), 'A', 'dev2') ->> 'status', 'applied',
  'the correction that records its payment method is applied');

-- F5: edited entries and their audit trail -----------------------------------------------------------------
select is(pg_temp.send(pg_temp.op('prod')) ->> 'status', 'applied', 'product sale created');
select is(pg_temp.send(pg_temp.op('exp')) ->> 'status', 'applied', 'expense created');
select is((select count(*)::int from public.entries where id in (pg_temp.id('cash'), pg_temp.id('prod'), pg_temp.id('exp')) and version = 1),
  3, 'new entries are version 1 (not edited)');

select is(pg_temp.send(pg_temp.fix('cash', 10, 1, '{"amount":60000,"payment_method":"paytm"}')) ->> 'status', 'applied',
  'service sale corrected (amount and payment method)');
select is(pg_temp.send(pg_temp.fix('prod', 11, 1, '{"quantity":2}')) ->> 'status', 'applied', 'product sale corrected');
select is(pg_temp.send(pg_temp.fix('exp', 12, 1, '{"amount":7000}')) ->> 'status', 'applied', 'expense corrected');
select is((select count(*)::int from public.entries where id in (pg_temp.id('cash'), pg_temp.id('prod'), pg_temp.id('exp'))
             and version - case when status = 'voided' then 2 else 1 end > 0), 3,
  'corrected service, product and expense entries are edited');
select ok((select amount = 60000 and payment_method = 'paytm' and updated_by = tests.uid('counter') from public.entries where id = pg_temp.id('cash')),
  'the entry holds the corrected values and who corrected it');
reset role;

select ok((select table_name = 'entries' and action = 'UPDATE' and outlet_id = tests.outlet('A') and actor = tests.uid('counter')
             and reason = 'counter typo' and (old_data ->> 'amount')::bigint = 55000 and old_data ->> 'payment_method' = 'cash'
             and (new_data ->> 'amount')::bigint = 60000 and new_data ->> 'payment_method' = 'paytm'
             and new_data ->> 'kind' = 'service' and at is not null
             and op_id = (select op_id from public.sync_ops where record_id = pg_temp.id('cash') and op_type = 'correct_entry')
           from public.audit_logs where row_id = pg_temp.id('cash') and action = 'UPDATE'),
  'audit keeps original and new values, record, type, outlet, editor, time, reason and the op');
select ok((select (old_data ->> 'quantity')::int = 1 and (new_data ->> 'quantity')::int = 2 and (new_data ->> 'amount')::bigint = 50000
           from public.audit_logs where row_id = pg_temp.id('prod') and action = 'UPDATE'),
  'product correction: original and corrected quantity and total are kept');
select ok((select (old_data ->> 'amount')::bigint = 5000 and (new_data ->> 'amount')::bigint = 7000
           from public.audit_logs where row_id = pg_temp.id('exp') and action = 'UPDATE'),
  'expense correction: original and corrected amount are kept');
select ok((select (new_data ->> 'amount')::bigint = 55000 from public.audit_logs where row_id = pg_temp.id('cash') and action = 'INSERT'),
  'the original entry (as created) stays in the audit log');

-- Retries and offline corrections.
create temp table retry as select pg_temp.fix('upi', 13, 1, '{"amount":50000}',
  jsonb_build_object('device_time', now() - interval '15 minutes', 'device_last_sync_at', now() - interval '16 minutes')) v;
grant select on retry to authenticated;
select tests.login_as('counter');
select is(pg_temp.send((select v from retry)) ->> 'status', 'applied', 'a correction made offline is applied when it syncs');
select ok((select (r ->> 'duplicate')::boolean from pg_temp.send((select v from retry)) r), 'retrying the correction is a duplicate');
select is((select version from public.entries where id = pg_temp.id('upi')), 2, 'the retry did not correct the entry twice');
reset role;
select is(pg_temp.audits('upi'), 2, 'the retry added no audit event (create + one correction)');
select ok((select s.device_time < a.at - interval '14 minutes' and a.actor = tests.uid('counter')
           from public.audit_logs a join public.sync_ops s on s.op_id = a.op_id
           where a.row_id = pg_temp.id('upi') and a.action = 'UPDATE'),
  'the offline correction keeps its device time (via its op) and the person who made it');
select tests.login_as('counter');
select ok((select r ->> 'status' = 'conflict' from pg_temp.send(pg_temp.fix('upi', 14, 1, '{"amount":40000}')) r),
  'a correction based on an old version is a conflict, never applied');
select is((select amount from public.entries where id = pg_temp.id('upi')), 50000::bigint, 'the conflicting correction changed nothing');
reset role;

-- Permissions: only members with entries.record can correct; audit history is owner-only and per outlet.
select tests.login_as('outsider');
select throws_ok($$ select pg_temp.send(pg_temp.fix('exp', 1, 2, '{"amount":9000}'), 'A', 'dev2') $$, '42501', null,
  'the owner of another outlet cannot correct this outlet''s entries');
select is((select count(*)::int from public.audit_logs where row_id = pg_temp.id('cash')), 0,
  'the owner of another outlet cannot read this outlet''s audit history');
reset role;
select tests.login_as('owner');
select is(pg_temp.audits('cash'), 2, 'the owner can inspect the audit history of an edited entry');
reset role;
select tests.login_as('head');
select is(pg_temp.audits('cash'), 0, 'audit history is owner-only (head employee cannot read it)');
reset role;
select tests.login_as('counter');
select is(pg_temp.audits('cash'), 0, 'counter operators cannot read audit history');
reset role;

-- Submitted / approved days: corrections are refused until management reopens the closing.
select tests.initial_float(2000, (select today - 30 from d));
create temp table cl (id uuid);
grant select, insert on cl to authenticated;
select tests.login_as('head');
insert into cl select (public.prepare_closing(tests.outlet('A'), (select today from d)) ->> 'closing_id')::uuid;
select ok((public.update_draft((select id from cl), 100000, null, null, '{"50000":4}', 'test', 'Owner') -> 'warnings') ? 'paytm_recorded_mismatch'
  = false, 'update_draft (closing engine) is unchanged by the recorded split');
select ok((select (s -> 'warnings') ? 'paytm_recorded_mismatch' from public.day_summary(tests.outlet('A'), (select today from d)) s),
  'Paytm total ₹1,000 ≠ recorded UPI/Paytm/Card ₹1,100 → mismatch warning');
select lives_ok($$ select public.update_draft((select id from cl), 110000, null, null, '{"50000":4}', 'test', 'Owner') $$, 'Paytm total corrected');
select ok((select not (s -> 'warnings') ? 'paytm_recorded_mismatch' from public.day_summary(tests.outlet('A'), (select today from d)) s),
  'Paytm total equal to the recorded UPI/Paytm/Card sales → no warning');
select lives_ok($$ select public.submit_closing((select id from cl)) $$, 'closing submitted');
reset role;
select tests.login_as('counter');
select ok((select r ->> 'status' = 'failed' and r ->> 'error_code' = 'SO423' from pg_temp.send(pg_temp.fix('exp', 15, 2, '{"amount":9000}')) r),
  'correcting an entry of a submitted day is refused (management must reopen it)');
reset role;
select is((select row(version, amount)::text from public.entries where id = pg_temp.id('exp')), row(2, 7000::bigint)::text,
  'the refused correction left the entry and its version untouched');
select is(pg_temp.audits('exp'), 2, 'and added no audit event');

select * from finish();
rollback;
