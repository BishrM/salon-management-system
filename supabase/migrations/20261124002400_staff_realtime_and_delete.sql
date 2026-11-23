-- Employee changes in real time, and Owner-only permanent deletion of an employee with no history (2026-11-24).
--
-- 1. Realtime: staff, staff_assignments and staff_day_visibility join the supabase_realtime publication, so an
--    employee added, renamed, deactivated, reassigned or removed from the Service tab in one session refreshes
--    every other session of that outlet. Realtime applies each subscriber's RLS (staff_select, ...), so nobody
--    hears about an employee they cannot already read.
-- 2. Permanent delete: public.delete_staff_permanently. Only for an employee with NO history anywhere: no sale,
--    commission, closing, handover, Service tab change, food repayment, sync record, login link, and no audit row
--    of any other table naming them. Anyone else is deactivated instead (unchanged). The employee row and their
--    own assignment rows are removed; their audit rows are kept and the deletion itself is audited.
--    Database-enforced: a delete outside that RPC is refused by trigger, the trigger re-checks the history, and
--    the foreign keys (never cascading) still refuse a delete of anyone with sales, commission or closings.
-- Forward-only. No existing row changes.

-- 1. Realtime ---------------------------------------------------------------------------------------------------
alter publication supabase_realtime add table public.staff, public.staff_assignments, public.staff_day_visibility;

-- 2. What stops a permanent delete ------------------------------------------------------------------------------
create function app.staff_delete_blockers(p_staff uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_out text[] := '{}';
  v_id  text := p_staff::text;
  v_n   bigint;
  r     record;
begin
  if exists (select 1 from public.staff where id = p_staff and profile_id is not null) then
    v_out := v_out || 'a linked login account'::text;
  end if;
  -- Every foreign key to staff except the employee's own assignments, including any table added later.
  for r in
    select c.conrelid::regclass::text as tbl, a.attname::text as col
      from pg_constraint c
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
     where c.contype = 'f' and c.confrelid = 'public.staff'::regclass
       and c.conrelid <> 'public.staff_assignments'::regclass
     order by 1, 2
  loop
    execute format('select count(*) from %s where %I = $1', r.tbl, r.col) into v_n using p_staff;
    if v_n > 0 then
      v_out := v_out || format('%s %s', v_n, case r.tbl
        when 'public.entries' then 'sale or register record(s)'
        when 'public.revision_commission_allocations' then 'commission record(s)'
        when 'public.closing_drafts' then 'closing draft(s)'
        when 'public.closing_revisions' then 'closing(s)'
        when 'public.commission_handovers' then 'commission handover(s)'
        when 'public.staff_day_visibility' then 'Service tab change(s)'
        else replace(r.tbl, 'public.', '') || ' row(s)' end);
    end if;
  end loop;
  if exists (select 1 from public.food_repayments where p_staff = any (staff_ids)) then
    v_out := v_out || 'food repayments'::text;
  end if;
  if exists (select 1 from public.sync_ops where payload::text like '%' || v_id || '%') then
    v_out := v_out || 'offline sync records'::text;
  end if;
  -- ponytail: text scan of audit_logs; fine at salon scale, add an index on the staff ids if it grows large.
  if exists (select 1 from public.audit_logs
              where table_name not in ('staff', 'staff_assignments')
                and (coalesce(old_data::text, '') || coalesce(new_data::text, '')) like '%' || v_id || '%') then
    v_out := v_out || 'audit history of sales, closings or other records'::text;
  end if;
  return v_out;
end;
$$;
revoke execute on function app.staff_delete_blockers(uuid) from public, anon, authenticated;

-- The caller is an Owner of every outlet the employee was ever assigned to.
create function app.owns_staff(p_staff uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.staff_assignments a where a.staff_id = p_staff)
     and not exists (
       select 1 from public.staff_assignments a
        where a.staff_id = p_staff
          and not exists (select 1 from app.my_valid_memberships() v where v.outlet_id = a.outlet_id and v.role = 'owner'))
$$;
revoke execute on function app.owns_staff(uuid) from public, anon, authenticated;

-- For the Owner's Employees page: why each employee the Owner may delete cannot be (empty = can be deleted).
create function public.staff_delete_blockers()
returns table (staff_id uuid, blockers text[])
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not app.is_owner_anywhere() then
    raise exception 'permission denied: only Owners can delete employees permanently' using errcode = '42501';
  end if;
  return query
    select s.id, app.staff_delete_blockers(s.id) from public.staff s where app.owns_staff(s.id);
end;
$$;
revoke execute on function public.staff_delete_blockers() from public, anon;
grant execute on function public.staff_delete_blockers() to authenticated;

-- 3. The delete -----------------------------------------------------------------------------------------------
create function public.delete_staff_permanently(p_outlet uuid, p_staff uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name     text;
  v_blockers text[];
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.staff_assignments a where a.staff_id = p_staff and a.outlet_id = p_outlet) then
    raise exception 'this employee does not belong to this outlet' using errcode = '42501';
  end if;
  if not app.owns_staff(p_staff) then
    raise exception 'permission denied: only the Owner of every outlet this employee worked at can delete them permanently'
      using errcode = '42501';
  end if;
  -- Lock the row: a sale being recorded for this employee (foreign key share lock) waits, or makes this fail.
  select full_name into v_name from public.staff where id = p_staff for update;
  v_blockers := app.staff_delete_blockers(p_staff);
  if cardinality(v_blockers) > 0 then
    raise exception '% cannot be deleted permanently. History found: %. Deactivate them instead: history is kept.',
      v_name, array_to_string(v_blockers, ', ') using errcode = '22023';
  end if;
  perform app.set_audit_context('Permanently deleted employee ' || v_name || ' (no history) from the Employees page of '
    || (select name from public.outlets where id = p_outlet));
  perform set_config('app.staff_purge', p_staff::text, true);
  delete from public.staff_assignments where staff_id = p_staff;
  delete from public.staff where id = p_staff;
  perform set_config('app.staff_purge', '', true);
end;
$$;
revoke execute on function public.delete_staff_permanently(uuid, uuid) from public, anon;
grant execute on function public.delete_staff_permanently(uuid, uuid) to authenticated;

-- 4. Database guards: deletes only through the RPC, and never of an employee with history -----------------------
create function app.guard_staff_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_setting('app.staff_purge', true) is distinct from old.id::text then
    raise exception 'employees cannot be deleted; deactivate them instead' using errcode = 'P0001';
  end if;
  if cardinality(app.staff_delete_blockers(old.id)) > 0 then
    raise exception 'an employee with history cannot be deleted' using errcode = 'P0001';
  end if;
  return old;
end;
$$;
revoke execute on function app.guard_staff_delete() from public, anon, authenticated;
drop trigger staff_no_delete on public.staff;
create trigger staff_delete_guard before delete on public.staff
  for each row execute function app.guard_staff_delete();

-- Same as …000500, except an assignment may be deleted together with its employee by delete_staff_permanently.
create or replace function app.guard_assignment_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if current_setting('app.staff_purge', true) is not distinct from old.staff_id::text then
      return old;
    end if;
    raise exception 'staff_assignments cannot be deleted; end the assignment instead' using errcode = 'P0001';
  end if;
  if old.end_date is not null then
    raise exception 'assignment % is already ended', old.id using errcode = 'P0001';
  end if;
  if (new.id, new.staff_id, new.outlet_id, new.start_date, new.created_at, new.is_temporary)
     is distinct from (old.id, old.staff_id, old.outlet_id, old.start_date, old.created_at, old.is_temporary) then
    raise exception 'only end_date and end_reason of an assignment may change' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

-- Audit the deletion (the employee's earlier audit rows stay).
drop trigger staff_audit on public.staff;
create trigger staff_audit after insert or update or delete on public.staff
  for each row execute function app.audit_row();
drop trigger staff_assignments_audit on public.staff_assignments;
create trigger staff_assignments_audit after insert or update or delete on public.staff_assignments
  for each row execute function app.audit_row();
