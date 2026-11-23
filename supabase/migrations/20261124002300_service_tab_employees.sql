-- Service tab employee management (2026-11-24): hide an active employee from new service sales for one
-- business date, add them back, and rename an employee from the Register.
--
-- Three states, never merged:
--   active + visible        app.staff_assigned(...) and no hidden row for the date
--   active + hidden today   app.staff_assigned(...) and a hidden row for (outlet, employee, business date)
--   deactivated             not app.staff_assigned(...) (existing staff.active / inactive_from rules, unchanged)
-- A hidden row is for ONE business date, so the employee is selectable again on the next business date.
-- Hiding changes nothing else: entries, totals, commission, closings and revisions do not read this table.
-- Forward-only: one new table, one guard trigger on new service sales, two RPCs. No existing row is changed.

-- 1. Visibility per (outlet, employee, business date) -------------------------------------------------------
create table public.staff_day_visibility (
  id             uuid primary key default gen_random_uuid(),
  outlet_id      uuid not null references public.outlets (id),
  staff_id       uuid not null references public.staff (id),
  business_date  date not null,
  hidden         boolean not null,
  -- Name at the last change, so the audit row reads on its own after a later rename.
  staff_name     text not null,
  changed_by     uuid not null references public.profiles (id),
  changed_at     timestamptz not null default now(),
  constraint staff_day_visibility_one unique (outlet_id, staff_id, business_date)
);
comment on table public.staff_day_visibility is
  'Employee removed from (hidden = true) or added back to (false) the Register Service tab for one business date. '
  'Affects only choosing the employee for NEW service sales on that date. Holds no money.';
create trigger staff_day_visibility_no_delete before delete on public.staff_day_visibility
  for each row execute function app.forbid_mutation();
create trigger staff_day_visibility_audit after insert or update on public.staff_day_visibility
  for each row execute function app.audit_row();
alter table public.staff_day_visibility enable row level security;
create policy staff_day_visibility_select on public.staff_day_visibility for select to authenticated
  using (app.is_member(outlet_id));
grant select on public.staff_day_visibility to authenticated;

-- Hidden for that business date at instant p_at (a change after p_at does not count).
create function app.staff_hidden_at(p_staff uuid, p_outlet uuid, p_date date, p_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.staff_day_visibility v
    where v.outlet_id = p_outlet and v.staff_id = p_staff and v.business_date = p_date
      and v.hidden and v.changed_at <= p_at)
$$;
revoke execute on function app.staff_hidden_at(uuid, uuid, date, timestamptz) from public, anon, authenticated;

-- 2. Server-side rule: no NEW service sale for an employee hidden on that business date ---------------------
-- Checked on insert, and on a correction that moves a sale to another employee. A correction that keeps the
-- employee (amount, payment, tip) is never affected, so a hidden employee's existing sales stay correctable.
-- Offline sales are judged by when they were made (device time corrected by the clock offset), not when they
-- reached the server: a sale recorded before the employee was hidden is accepted, so no real sale is lost.
create function app.entries_hidden_staff_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_at timestamptz;
begin
  if new.kind <> 'service' or new.staff_id is null or new.business_date is null or new.status <> 'active' then
    return new;
  end if;
  if tg_op = 'UPDATE' then
    if new.staff_id is not distinct from old.staff_id then
      return new;
    end if;
    v_at := now();
  elsif new.date_basis = 'online' or new.device_time is null then
    v_at := coalesce(new.received_at, now());
  else
    v_at := new.device_time + make_interval(secs => coalesce(new.device_offset_ms, 0) / 1000.0);
  end if;
  if app.staff_hidden_at(new.staff_id, new.outlet_id, new.business_date, v_at) then
    raise exception '% is removed from the Service tab for %. Add them back (Manage employees) to record this sale.',
      (select full_name from public.staff where id = new.staff_id), to_char(new.business_date, 'DD Mon YYYY')
      using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke execute on function app.entries_hidden_staff_guard() from public, anon, authenticated;
create trigger entries_hidden_staff before insert or update of staff_id on public.entries
  for each row execute function app.entries_hidden_staff_guard();

-- 3. Hide / add back for today's business date ---------------------------------------------------------------
create function public.set_staff_hidden(p_outlet uuid, p_staff uuid, p_date date, p_hidden boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date;
  v_name  text;
  v_n     integer;
begin
  perform app.require_permission(p_outlet, 'staff.manage');
  if p_hidden is null then
    raise exception 'say whether to remove or add back the employee' using errcode = '22023';
  end if;
  v_today := app.business_date(p_outlet, now());
  -- Only today's Service tab: a page left open across the cutoff must not change the wrong day.
  if p_date is distinct from v_today then
    raise exception 'the Service tab can only be changed for today''s business date (%); reload the page',
      to_char(v_today, 'DD Mon YYYY') using errcode = '22023';
  end if;
  if p_staff is null or not app.staff_assigned(p_staff, p_outlet, p_date) then
    raise exception 'only an active employee working at this outlet today can be removed or added back; '
      'deactivated employees are managed on the Employees page' using errcode = '22023';
  end if;
  select full_name into v_name from public.staff where id = p_staff;
  perform app.set_audit_context(case when p_hidden then 'Removed from the Service tab for the day'
                                     else 'Added back to the Service tab for the day' end);
  if p_hidden then
    insert into public.staff_day_visibility (outlet_id, staff_id, business_date, hidden, staff_name, changed_by)
    values (p_outlet, p_staff, p_date, true, v_name, auth.uid())
    on conflict (outlet_id, staff_id, business_date) do update
      set hidden = true, staff_name = excluded.staff_name, changed_by = excluded.changed_by, changed_at = now()
      where not public.staff_day_visibility.hidden;
  else
    update public.staff_day_visibility
       set hidden = false, staff_name = v_name, changed_by = auth.uid(), changed_at = now()
     where outlet_id = p_outlet and staff_id = p_staff and business_date = p_date and hidden;
  end if;
  get diagnostics v_n = row_count;   -- 0 = already in that state: nothing written, nothing audited
  return jsonb_build_object('staff_id', p_staff, 'business_date', p_date, 'hidden', p_hidden, 'changed', v_n > 0);
end;
$$;
revoke execute on function public.set_staff_hidden(uuid, uuid, date, boolean) from public, anon;
grant execute on function public.set_staff_hidden(uuid, uuid, date, boolean) to authenticated;

-- 4. Rename from the Register ----------------------------------------------------------------------------------
-- Same row, same id: every screen resolves the name through staff_id. Frozen revision snapshots are not
-- rewritten. The staff audit row keeps old and new name, the login and the time; its reason names the outlet
-- (staff rows have no outlet column, and audit visibility for them is unchanged).
create function public.rename_staff(p_outlet uuid, p_staff uuid, p_full_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := btrim(coalesce(p_full_name, ''));
begin
  perform app.require_permission(p_outlet, 'staff.manage');
  if not exists (select 1 from public.staff_assignments a where a.staff_id = p_staff and a.outlet_id = p_outlet) then
    raise exception 'this employee does not belong to this outlet' using errcode = '42501';
  end if;
  -- Same rule as update_staff.
  if length(v_name) = 0 or length(v_name) > 120 then
    raise exception 'staff name must be 1-120 characters' using errcode = '22023';
  end if;
  if exists (select 1 from public.staff where id = p_staff and full_name = v_name) then
    return;   -- unchanged: no write, no audit row
  end if;
  perform app.set_audit_context('Renamed from the Register of ' || (select name from public.outlets where id = p_outlet));
  update public.staff set full_name = v_name where id = p_staff;
end;
$$;
revoke execute on function public.rename_staff(uuid, uuid, text) from public, anon;
grant execute on function public.rename_staff(uuid, uuid, text) to authenticated;
