-- Deactivation dated by the salon BUSINESS date (W1 edge case, 2026-11-23).
-- …001700 set staff.inactive_from to the India CALENDAR date + 1. Between midnight and the outlet's cutoff
-- (e.g. 04:00) the calendar date is one day ahead of the business day, so a deactivation at 01:00 on
-- 24 Nov (business date 23 Nov) gave inactive_from 25 Nov: one extra business day.
-- Now: inactive_from = business date of the deactivation instant (app.business_date: outlet timezone and
-- cutoff of the employee's current assignment) + 1. An employee without an outlet with a cutoff keeps the
-- old calendar rule. Function-only change: existing staff rows, sales and closings are not touched.

create function app.staff_inactive_from_at(p_staff uuid, p_at timestamptz)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  -- Assignments never overlap, so the open one (else the latest) is the outlet the person works at.
  select coalesce(
    (select app.business_date(a.outlet_id, p_at)
       from public.staff_assignments a join public.outlets o on o.id = a.outlet_id
      where a.staff_id = p_staff and o.day_cutoff is not null
      order by (a.end_date is null) desc, a.start_date desc
      limit 1),
    (p_at at time zone 'Asia/Kolkata')::date) + 1
$$;

create or replace function app.staff_set_inactive_from()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.active then
    new.inactive_from := null;
  elsif old.active then
    new.inactive_from := app.staff_inactive_from_at(new.id, now());
  else
    new.inactive_from := old.inactive_from;
  end if;
  return new;
end;
$$;

revoke execute on function app.staff_inactive_from_at(uuid, timestamptz) from public, anon, authenticated;
