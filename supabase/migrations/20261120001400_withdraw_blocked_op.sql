-- Withdraw a change that is blocked forever (defect D7, staging 2026-11-20).
--
-- sync_ops answers 'blocked' WITHOUT storing the op when it waits for an unresolved earlier op on the same
-- record, or when it changes an entry the server does not have. withdraw_sync_op (…001300) and
-- resolve_sync_issue only act on stored ops, so a blocked op whose entry never arrives (lost on the device,
-- or removed by a staging data reset) could not be cleared by anyone: the device retried it forever and
-- the only way out was wiping the browser's storage.
--
-- withdraw_blocked_op lets the person who made such a change withdraw it from the device that holds it.
-- The op is stored exactly as sync_ops would store it (same op_id, device, seq and payload hash), as
-- failed, then withdrawn through withdraw_sync_op (resolved by the sender, with the reason, audited).
-- Because it is stored, a later re-send of the same op is answered as a duplicate and never executes.
-- Only an op that is blocked right now can be withdrawn this way; anything the server would accept or has
-- already received is refused. Nothing is deleted, skipped or marked applied.

create function public.withdraw_blocked_op(p_outlet uuid, p_device uuid, p_device_label text, p_op jsonb, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_seq    bigint;
  v_op_id  uuid;
  v_rec    uuid;
  v_type   text;
  v_prev   public.sync_ops;
  v_note   text;
begin
  perform app.require_permission(p_outlet, 'entries.record');
  v_note := app.require_reason(p_note);
  if p_device is null or jsonb_typeof(p_op) is distinct from 'object'
     or coalesce(p_op ->> 'op_id', '') !~* '^[0-9a-f-]{36}$' or coalesce(p_op ->> 'record_id', '') !~* '^[0-9a-f-]{36}$'
     or coalesce(p_op ->> 'device_seq', '') !~ '^[0-9]+$' or (p_op ->> 'device_seq')::bigint <= 0 then
    raise exception 'malformed op' using errcode = '22023';
  end if;
  v_seq := (p_op ->> 'device_seq')::bigint;
  v_op_id := (p_op ->> 'op_id')::uuid;
  v_rec := (p_op ->> 'record_id')::uuid;
  v_type := p_op ->> 'type';

  -- Already received (same op, or the same device seq): never store a second copy.
  select * into v_prev from public.sync_ops
   where status <> 'conflict' and ((device_id = p_device and device_seq = v_seq) or op_id = v_op_id)
   order by id limit 1;
  if v_prev.id is not null then
    if v_prev.op_id = v_op_id and v_prev.device_id = p_device and v_prev.submitted_by = auth.uid()
       and v_prev.status = 'failed' and v_prev.resolved_at is not null then
      return;  -- retry-safe: already withdrawn
    end if;
    raise exception 'this change has already reached the server; it cannot be withdrawn here' using errcode = 'SO409';
  end if;

  -- Same test sync_ops uses to answer 'blocked'. Anything else would apply or fail normally: send it instead.
  if not exists (select 1 from public.sync_ops s
                  where s.device_id = p_device and s.record_id = v_rec and s.device_seq < v_seq
                    and s.status <> 'applied' and s.resolved_at is null)
     and not (v_type in ('correct_entry', 'void_entry') and not exists (select 1 from public.entries where id = v_rec)) then
    raise exception 'this change is no longer waiting; sync again instead of withdrawing it' using errcode = '22023';
  end if;

  insert into public.devices (id, outlet_id, label, registered_by)
  values (p_device, p_outlet, left(p_device_label, 80), auth.uid())
  on conflict (id) do nothing;
  insert into public.sync_ops (op_id, device_id, device_seq, outlet_id, op_type, record_id, payload,
    payload_hash, device_time, status, error_code, error_message, submitted_by)
  values (v_op_id, p_device, v_seq, p_outlet, coalesce(v_type, '?'), v_rec, p_op, md5(p_op::text),
    (p_op ->> 'device_time')::timestamptz, 'failed', 'SO410',
    'withdrawn while waiting for an earlier operation on this record (missing or unresolved)', auth.uid());
  perform public.withdraw_sync_op(v_op_id, v_note);
end;
$$;
revoke execute on function public.withdraw_blocked_op(uuid, uuid, text, jsonb, text) from public, anon;
grant execute on function public.withdraw_blocked_op(uuid, uuid, text, jsonb, text) to authenticated;
