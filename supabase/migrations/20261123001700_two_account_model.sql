-- Revised account structure (client, 2026-11-23; DECISIONS D-28..D-30):
--   * Two account types: Owner (owner; manager kept as the owner-side login of the owner's son) and one
--     shared Shop/Staff login per outlet (role 'shop').
--   * 'head' and 'counter' memberships stay stored (history) but grant nothing; acting-head delegation
--     is switched off (delegation.manage is held by nobody, so grant_acting_head is always denied).
--   * Shop/Staff manages employees (add, edit, deactivate); employees are records, not logins.
--   * Deactivation is dated (staff.inactive_from): the person stays valid for every business date before
--     it, so historical corrections, late entries and closing attribution keep working.
--   * Commission handover recipient: any employee working at the outlet that day (there is no head).
-- Nothing is deleted or rewritten: no membership, staff, assignment or financial row changes.

-- Permission matrix ---------------------------------------------------------------------------------
create or replace function app.permission_matrix()
returns table (permission text, roles public.app_role[])
language sql
immutable
set search_path = ''
as $$
  values
    ('outlet.read',           array['owner','manager','shop']::public.app_role[]),
    ('entries.record',        array['owner','manager','shop']::public.app_role[]),
    ('closing.prepare',       array['owner','manager','shop']::public.app_role[]),
    ('closing.submit',        array['owner','manager','shop']::public.app_role[]),
    ('paytm.enter',           array['owner','manager','shop']::public.app_role[]),
    ('commission.handover',   array['owner','manager','shop']::public.app_role[]),
    ('staff.manage',          array['owner','manager','shop']::public.app_role[]),
    ('closing.approve',       array['owner','manager']::public.app_role[]),
    ('closing.reopen',        array['owner','manager']::public.app_role[]),
    ('review.acknowledge',    array['owner','manager']::public.app_role[]),
    ('late_entry.review',     array['owner','manager']::public.app_role[]),
    ('food_excess.allocate',  array['owner','manager']::public.app_role[]),
    ('food_repayment.record', array['owner','manager']::public.app_role[]),
    ('commission.adjust',     array['owner','manager']::public.app_role[]),
    ('float.manage',          array['owner','manager']::public.app_role[]),
    ('date.assign',           array['owner','manager']::public.app_role[]),
    ('sync.manage',           array['owner','manager']::public.app_role[]),
    ('catalog.manage',        array['owner','manager']::public.app_role[]),
    ('reports.read',          array['owner','manager']::public.app_role[]),
    ('members.read',          array['owner','manager']::public.app_role[]),
    ('delegation.manage',     array[]::public.app_role[]),
    ('outlet.denominations',  array['owner','manager']::public.app_role[]),
    ('outlet.cutoff',         array['owner']::public.app_role[]),
    ('outlet.thresholds',     array['owner']::public.app_role[]),
    ('outlet.details',        array['owner']::public.app_role[]),
    ('float.initial',         array['owner']::public.app_role[]),
    ('users.manage',          array['owner']::public.app_role[]),
    ('audit.read',            array['owner']::public.app_role[])
$$;

-- One shared Shop/Staff login per outlet, and that login belongs to exactly one outlet. ---------------
create unique index memberships_one_shop_per_outlet_uidx
  on public.outlet_memberships (outlet_id) where role = 'shop' and revoked_at is null;
create unique index memberships_shop_single_outlet_uidx
  on public.outlet_memberships (profile_id) where role = 'shop' and revoked_at is null;

create or replace function public.add_membership(p_outlet uuid, p_profile uuid, p_role public.app_role, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text;
  v_id     uuid;
begin
  perform app.require_permission(p_outlet, 'users.manage');
  v_reason := app.require_reason(p_reason);
  if p_role is null or p_role not in ('owner', 'manager', 'shop') then
    raise exception 'role must be owner, manager or shop (head and counter accounts were retired)' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where id = p_profile and active) then
    raise exception 'user not found or inactive' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.outlet_memberships
    where outlet_id = p_outlet and profile_id = p_profile and not is_acting and revoked_at is null
  ) then
    raise exception 'user already has a role in this outlet; revoke it first' using errcode = '23505';
  end if;
  -- The Shop/Staff login is outlet-specific and never doubles as a management login (or vice versa).
  if exists (
    select 1 from public.outlet_memberships
    where profile_id = p_profile and revoked_at is null and (p_role = 'shop' or role = 'shop')
  ) then
    raise exception 'a Shop/Staff login belongs to one outlet only and cannot hold another role' using errcode = '23505';
  end if;
  if p_role = 'shop' and exists (
    select 1 from public.outlet_memberships where outlet_id = p_outlet and role = 'shop' and revoked_at is null
  ) then
    raise exception 'this outlet already has a Shop/Staff login' using errcode = '23505';
  end if;
  perform app.set_audit_context(v_reason);
  insert into public.outlet_memberships (outlet_id, profile_id, role, granted_by, reason)
  values (p_outlet, p_profile, p_role, auth.uid(), v_reason)
  returning id into v_id;
  return v_id;
end;
$$;

-- Dated deactivation ----------------------------------------------------------------------------------
alter table public.staff add column inactive_from date;
comment on column public.staff.inactive_from is
  'First business date the employee no longer works (set when deactivated, cleared when reactivated). '
  'NULL on an inactive row = deactivated before 2026-11-23 (treated as inactive on every date, as before).';
alter table public.staff add constraint staff_inactive_from_only_inactive
  check (inactive_from is null or not active);

-- Deactivating keeps the person valid up to and including today (India time); reactivating clears it.
-- ponytail: one timezone for all outlets (all are in India); use the outlet's timezone if that changes.
create function app.staff_set_inactive_from()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.active then
    new.inactive_from := null;
  elsif old.active then
    new.inactive_from := (now() at time zone 'Asia/Kolkata')::date + 1;
  else
    new.inactive_from := old.inactive_from;
  end if;
  return new;
end;
$$;
create trigger staff_inactive_from before update on public.staff
  for each row execute function app.staff_set_inactive_from();

-- Assigned to the outlet on the date and not yet deactivated on that date.
create or replace function app.staff_assigned(p_staff uuid, p_outlet uuid, p_date date)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.staff s
    join public.staff_assignments a on a.staff_id = s.id
    where s.id = p_staff and (s.active or p_date < s.inactive_from) and a.outlet_id = p_outlet
      and a.start_date <= p_date and (a.end_date is null or a.end_date >= p_date)
  )
$$;

-- Commission handover: recipient is an employee working at the outlet that day. -----------------------
create or replace function public.record_handover(p_closing uuid, p_recipient_staff uuid, p_amount bigint, p_source text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  c      public.daily_closings;
  v_rev  uuid;
  v_set  jsonb;
  v_id   uuid;
begin
  c := app.lock_closing(p_closing, 'commission.handover');
  select revision_id into v_rev from app.state_of(p_closing);
  if p_source not in ('drawer', 'outside_drawer') or p_source is null then
    raise exception 'source must be drawer or outside_drawer' using errcode = '22023';
  end if;
  if p_source = 'drawer' and v_rev is not null then
    raise exception 'the drawer is closed once the day is submitted; record an outside-drawer handover'
      using errcode = 'SO423';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount % 100 <> 0 then
    raise exception 'amount must be a positive whole-rupee amount' using errcode = '22023';
  end if;
  if p_recipient_staff is null or not app.staff_assigned(p_recipient_staff, c.outlet_id, c.business_date) then
    raise exception 'recipient must be an employee working at this outlet on that day' using errcode = '22023';
  end if;
  v_set := app.settlement(p_closing, app.allowed_payable(p_closing));
  if (v_set ->> 'net_transferred')::bigint + p_amount > (v_set ->> 'allowed')::bigint then
    raise exception 'handover exceeds the commission payable (₹% still payable)',
      greatest(0, (v_set ->> 'allowed')::bigint - (v_set ->> 'net_transferred')::bigint) / 100 using errcode = '22023';
  end if;
  insert into public.commission_handovers (closing_id, outlet_id, revision_id, kind, source, amount,
    recipient_staff_id, recorded_by)
  values (p_closing, c.outlet_id, v_rev, 'handover', p_source, p_amount, p_recipient_staff, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

revoke execute on function app.staff_set_inactive_from() from public, anon, authenticated;
