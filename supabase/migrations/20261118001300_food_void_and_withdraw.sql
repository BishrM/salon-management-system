-- Staging 2026-11-19: removing a food entry that had been "paid now from the drawer" always failed
-- ("reverse the food payments before voiding the food entry") because the Register sent a plain
-- void and nothing offered the reversal. Every later change to that entry from the same device was
-- then held back ("blocked") until a manager resolved the failure — the person who made it had no way
-- to, so the device stayed stuck and sign-out stayed refused.
--
-- 1. void_entry for a food entry accepts data.reverse_payments = true: inside the op's own
--    subtransaction every unreversed payment is reversed (same reason, audited, dated by receipt time
--    as before — D-14) and then the food is voided. All or nothing; ids of the reversals are derived
--    from the op id so a replay can never create a second reversal. Without the flag a paid food entry
--    is refused with an actionable message and nothing changes.
-- 2. A 'blocked' result names the earlier op it waits for (blocked_by).
-- 3. public.withdraw_sync_op: the person who sent a FAILED op may withdraw it with a reason. The op is
--    not deleted and not marked applied; it is recorded as resolved by that person (visible to
--    management and in the audit log). Ops waiting behind it are then replayed through the normal
--    validation. Conflicts (reused device sequence/op id) stay management-only.

create function app.op_void_entry(p_outlet uuid, p_device uuid, p_op jsonb, p_lower timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  e         public.entries;
  v_reason  text := app.require_reason(p_op ->> 'reason');
  v_data    jsonb := coalesce(p_op -> 'data', '{}');
  v_reverse boolean;
  v_pay     record;
  v_paid    bigint := 0;
  v_rev     uuid[] := '{}';
  v_rid     uuid;
begin
  perform app.require_keys(v_data, array['reverse_payments']);
  if v_data ? 'reverse_payments' and jsonb_typeof(v_data -> 'reverse_payments') <> 'boolean' then
    raise exception 'reverse_payments must be true or false' using errcode = '22023';
  end if;
  v_reverse := coalesce((v_data ->> 'reverse_payments')::boolean, false);
  e := app.lock_entry_for_change(p_outlet, p_op);
  if e.kind = 'food' then
    for v_pay in
      select p.id, p.amount from public.food_payments p
       where p.food_id = e.id and p.reverses_payment_id is null
         and not exists (select 1 from public.food_payments r where r.reverses_payment_id = p.id)
       order by p.server_seq
    loop
      v_paid := v_paid + v_pay.amount;
      if v_reverse then
        v_rid := md5((p_op ->> 'op_id') || ':' || v_pay.id::text)::uuid;
        perform app.op_reverse_food_payment(p_outlet, p_device,
          p_op || jsonb_build_object('record_id', v_rid, 'data', jsonb_build_object('payment_id', v_pay.id)), p_lower);
        v_rev := v_rev || v_rid;
      end if;
    end loop;
    if v_paid > 0 and not v_reverse then
      raise exception 'this food has ₹% already paid; use "Remove and cancel payment" so the payment is reversed first (nothing was changed)',
        v_paid / 100 using errcode = '23514';
    end if;
  elsif v_reverse then
    raise exception 'reverse_payments applies only to food entries' using errcode = '22023';
  end if;
  perform app.set_audit_context(v_reason);
  update public.entries
     set status = 'voided', void_reason = v_reason, version = version + 1, updated_at = now(), updated_by = auth.uid()
   where id = e.id;
  return jsonb_build_object('id', e.id, 'version', e.version + 1, 'status', 'voided',
    'reversed_payment_ids', to_jsonb(v_rev));
end;
$$;
revoke execute on function app.op_void_entry(uuid, uuid, jsonb, timestamptz) from public, anon, authenticated;

-- sync_ops: identical to migration …000800 except the void dispatch above and blocked_by.
create or replace function public.sync_ops(p_outlet uuid, p_device uuid, p_device_label text, p_ops jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dev      public.devices;
  v_lower    timestamptz;
  v_op       jsonb;
  v_hash     text;
  v_prev     public.sync_ops;
  v_result   jsonb;
  v_results  jsonb := '[]';
  v_seq      bigint;
  v_contig   bigint;
  v_gaps     jsonb;
  v_type     text;
  v_state    text;
  v_code     text;
  v_msg      text;
  v_blocker  uuid;
begin
  perform app.require_permission(p_outlet, 'entries.record');
  if p_device is null then
    raise exception 'device id is required' using errcode = '22023';
  end if;
  if jsonb_typeof(p_ops) is distinct from 'array' or jsonb_array_length(p_ops) > 200 then
    raise exception 'ops must be an array of at most 200 operations' using errcode = '22023';
  end if;

  insert into public.devices (id, outlet_id, label, registered_by)
  values (p_device, p_outlet, left(p_device_label, 80), auth.uid())
  on conflict (id) do nothing;
  select * into v_dev from public.devices where id = p_device for update;
  v_lower := v_dev.last_contact_at;

  for v_op in select value from jsonb_array_elements(p_ops) order by (value ->> 'device_seq')::bigint loop
    v_hash := md5(v_op::text);
    v_type := v_op ->> 'type';
    v_seq := nullif(v_op ->> 'device_seq', '')::bigint;
    v_result := null;

    if v_seq is null or v_seq <= 0 or (v_op ->> 'op_id') is null
       or (v_op ->> 'op_id') !~* '^[0-9a-f-]{36}$' or (v_op ->> 'record_id') !~* '^[0-9a-f-]{36}$' then
      v_results := v_results || jsonb_build_object('op_id', v_op ->> 'op_id', 'device_seq', v_seq,
        'status', 'failed', 'error_code', '22023', 'error', 'malformed op');
      continue;
    end if;

    select * into v_prev from public.sync_ops
     where status <> 'conflict'
       and ((device_id = p_device and device_seq = v_seq) or op_id = (v_op ->> 'op_id')::uuid)
     order by id limit 1;
    if v_prev.id is not null then
      if v_prev.op_id = (v_op ->> 'op_id')::uuid and v_prev.device_id = p_device
         and v_prev.device_seq = v_seq and v_prev.payload_hash = v_hash then
        v_results := v_results || jsonb_build_object('op_id', v_prev.op_id, 'device_seq', v_seq,
          'status', v_prev.status, 'result', v_prev.result, 'error_code', v_prev.error_code,
          'error', v_prev.error_message, 'duplicate', true);
      else
        insert into public.sync_ops (op_id, device_id, device_seq, outlet_id, op_type, record_id, payload,
          payload_hash, device_time, status, error_code, error_message, submitted_by)
        values ((v_op ->> 'op_id')::uuid, p_device, v_seq, p_outlet, coalesce(v_type, '?'),
          (v_op ->> 'record_id')::uuid, v_op, v_hash, (v_op ->> 'device_time')::timestamptz, 'conflict',
          'SO409', 'device sequence or op id reused with different content', auth.uid());
        v_results := v_results || jsonb_build_object('op_id', v_op ->> 'op_id', 'device_seq', v_seq,
          'status', 'conflict', 'error_code', 'SO409',
          'error', 'device sequence or op id reused with different content');
      end if;
      continue;
    end if;

    select s.op_id into v_blocker from public.sync_ops s
     where s.device_id = p_device and s.record_id = (v_op ->> 'record_id')::uuid
       and s.device_seq < v_seq and s.status <> 'applied' and s.resolved_at is null
     order by s.device_seq limit 1;
    if v_blocker is not null or (
      -- Out-of-order arrival: a change to an entry whose create has not arrived yet waits (not stored).
      v_type in ('correct_entry', 'void_entry')
      and not exists (select 1 from public.entries where id = (v_op ->> 'record_id')::uuid)
    ) then
      v_results := v_results || jsonb_build_object('op_id', v_op ->> 'op_id', 'device_seq', v_seq,
        'status', 'blocked', 'error', 'waiting for an earlier operation on this record (missing or unresolved)',
        'blocked_by', v_blocker);
      continue;
    end if;

    begin
      perform set_config('app.op_id', v_op ->> 'op_id', true);
      perform set_config('app.reason', '', true);
      v_result := case v_type
        when 'create_entry'         then app.op_create_entry(p_outlet, p_device, v_op, v_lower)
        when 'correct_entry'        then app.op_correct_entry(p_outlet, v_op)
        when 'void_entry'           then app.op_void_entry(p_outlet, p_device, v_op, v_lower)
        when 'food_payment'         then app.op_food_payment(p_outlet, p_device, v_op, v_lower)
        when 'reverse_food_payment' then app.op_reverse_food_payment(p_outlet, p_device, v_op, v_lower)
        else null end;
      if v_result is null then
        raise exception 'unknown op type %', coalesce(v_type, '(none)') using errcode = '22023';
      end if;
      -- Surface deferred constraint violations (food paid ≤ cost) inside this op's subtransaction.
      set constraints all immediate;
      set constraints all deferred;
      insert into public.sync_ops (op_id, device_id, device_seq, outlet_id, op_type, record_id, payload,
        payload_hash, device_time, status, result, submitted_by)
      values ((v_op ->> 'op_id')::uuid, p_device, v_seq, p_outlet, v_type, (v_op ->> 'record_id')::uuid,
        v_op, v_hash, (v_op ->> 'device_time')::timestamptz, 'applied', v_result, auth.uid());
      v_results := v_results || jsonb_build_object('op_id', v_op ->> 'op_id', 'device_seq', v_seq,
        'status', 'applied', 'result', v_result);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      v_code := v_state;
      insert into public.sync_ops (op_id, device_id, device_seq, outlet_id, op_type, record_id, payload,
        payload_hash, device_time, status, error_code, error_message, submitted_by)
      values ((v_op ->> 'op_id')::uuid, p_device, v_seq, p_outlet, coalesce(v_type, '?'),
        (v_op ->> 'record_id')::uuid, v_op, v_hash, (v_op ->> 'device_time')::timestamptz,
        case when v_code = 'SO409' then 'conflict' else 'failed' end, v_code, v_msg, auth.uid());
      v_results := v_results || jsonb_build_object('op_id', v_op ->> 'op_id', 'device_seq', v_seq,
        'status', case when v_code = 'SO409' then 'conflict' else 'failed' end,
        'error_code', v_code, 'error', v_msg);
    end;
  end loop;

  perform set_config('app.op_id', '', true);
  perform set_config('app.reason', '', true);

  -- Highest contiguous seq received from this device, and the gaps below the highest seq seen.
  with s as (select distinct device_seq from public.sync_ops where device_id = p_device and status <> 'conflict'),
       r as (select device_seq, row_number() over (order by device_seq) rn from s)
  select coalesce(max(device_seq), 0) into v_contig from r where device_seq = rn;
  select coalesce(jsonb_agg(g order by g), '[]') into v_gaps
    from generate_series(v_contig + 1,
      coalesce((select max(device_seq) from public.sync_ops where device_id = p_device and status <> 'conflict'), 0)) g
   where not exists (select 1 from public.sync_ops where device_id = p_device and device_seq = g and status <> 'conflict');

  update public.devices
     set last_contact_at = now(), last_synced_seq = greatest(last_synced_seq, v_contig)
   where id = p_device;

  return jsonb_build_object('results', v_results, 'server_time', now(), 'last_synced_seq', v_contig,
    'gaps', v_gaps);
end;
$$;

drop function app.op_void_entry(uuid, jsonb);

create function public.withdraw_sync_op(p_op_id uuid, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  s      public.sync_ops;
  v_note text;
begin
  select * into s from public.sync_ops where op_id = p_op_id and status = 'failed' for update;
  -- Same answer for "not found" and "not yours": never reveal another user's ops.
  if s.id is null or s.submitted_by is distinct from auth.uid() then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  perform app.require_permission(s.outlet_id, 'entries.record');
  if s.resolved_at is not null then return; end if;  -- retry-safe
  v_note := app.require_reason(p_note);
  perform app.set_audit_context(v_note);
  update public.sync_ops
     set resolved_at = now(), resolved_by = auth.uid(),
         resolution_note = 'Withdrawn by the person who sent it: ' || v_note
   where id = s.id;
end;
$$;
revoke execute on function public.withdraw_sync_op(uuid, text) from public, anon;
grant execute on function public.withdraw_sync_op(uuid, text) to authenticated;
