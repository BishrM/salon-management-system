-- M1 completion (Rev 6 §3.1, §4.1, §11 M1 row) and gaps found in review:
--   * product_catalog (M1 scope; the earlier migration had deferred it).
--   * Temporary cross-outlet staff assignments (business requirement): the old exclusion constraint
--     forbade any overlap, so a loan to another outlet meant ending the home assignment.
--     Now at most one home and one temporary assignment may overlap per person.
--   * update_staff, set_offline_thresholds (G4), set_outlet_details, server_time.
--   * Membership validity for an arbitrary profile (needed to validate handover recipients).

-- Membership validity for any profile (same rules as app.my_valid_memberships) ------------------
create function app.valid_memberships_of(p_profile uuid)
returns table (outlet_id uuid, role public.app_role, is_acting boolean, membership_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select m.outlet_id, m.role, m.is_acting, m.id
  from public.outlet_memberships m
  join public.profiles p on p.id = m.profile_id and p.active
  where m.profile_id = p_profile
    and m.revoked_at is null
    and m.valid_from <= now()
    and (m.valid_to is null or now() < m.valid_to)
    and (
      not m.is_acting
      or exists (
        select 1
        from public.outlet_memberships g
        join public.profiles gp on gp.id = g.profile_id and gp.active
        where g.outlet_id = m.outlet_id
          and g.profile_id = m.granted_by
          and not g.is_acting
          and g.role in ('owner', 'manager')
          and g.revoked_at is null
          and g.valid_from <= now()
          and (g.valid_to is null or now() < g.valid_to)
      )
    )
$$;

create or replace function app.my_valid_memberships()
returns table (outlet_id uuid, role public.app_role, is_acting boolean, membership_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.valid_memberships_of(auth.uid())
$$;

-- Permission matrix: adds catalogue and reporting permissions. ---------------------------------
create or replace function app.permission_matrix()
returns table (permission text, roles public.app_role[])
language sql
immutable
set search_path = ''
as $$
  values
    ('outlet.read',           array['owner','manager','head','counter']::public.app_role[]),
    ('entries.record',        array['owner','manager','head','counter']::public.app_role[]),
    ('closing.prepare',       array['owner','manager','head']::public.app_role[]),
    ('closing.submit',        array['owner','manager','head']::public.app_role[]),
    ('paytm.enter',           array['owner','manager','head']::public.app_role[]),
    ('commission.handover',   array['owner','manager','head']::public.app_role[]),
    ('closing.approve',       array['owner','manager']::public.app_role[]),
    ('closing.reopen',        array['owner','manager']::public.app_role[]),
    ('review.acknowledge',    array['owner','manager']::public.app_role[]),
    ('late_entry.review',     array['owner','manager']::public.app_role[]),
    ('food_excess.allocate',  array['owner','manager']::public.app_role[]),
    ('commission.adjust',     array['owner','manager']::public.app_role[]),
    ('float.manage',          array['owner','manager']::public.app_role[]),
    ('date.assign',           array['owner','manager']::public.app_role[]),
    ('sync.manage',           array['owner','manager']::public.app_role[]),
    ('staff.manage',          array['owner','manager']::public.app_role[]),
    ('catalog.manage',        array['owner','manager']::public.app_role[]),
    ('reports.read',          array['owner','manager']::public.app_role[]),
    ('members.read',          array['owner','manager']::public.app_role[]),
    ('delegation.manage',     array['owner','manager']::public.app_role[]),
    ('outlet.denominations',  array['owner','manager']::public.app_role[]),
    ('outlet.cutoff',         array['owner']::public.app_role[]),
    ('outlet.thresholds',     array['owner']::public.app_role[]),
    ('outlet.details',        array['owner']::public.app_role[]),
    ('float.initial',         array['owner']::public.app_role[]),
    ('users.manage',          array['owner']::public.app_role[]),
    ('audit.read',            array['owner']::public.app_role[])
$$;

-- Temporary assignments --------------------------------------------------------------------------
alter table public.staff_assignments add column is_temporary boolean not null default false;
alter table public.staff_assignments drop constraint staff_assignments_no_overlap;
alter table public.staff_assignments add constraint staff_assignments_no_overlap exclude using gist (
  staff_id with =,
  is_temporary with =,
  daterange(start_date, end_date, '[]') with &&
);
-- A temporary assignment always has an end date (it is a loan, not a transfer).
alter table public.staff_assignments add constraint staff_assignments_temporary_ends
  check (not is_temporary or end_date is not null);

create or replace function app.guard_assignment_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
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

-- Staff assigned to an outlet on a date (home or temporary).
create function app.staff_assigned(p_staff uuid, p_outlet uuid, p_date date)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.staff s
    join public.staff_assignments a on a.staff_id = s.id
    where s.id = p_staff and s.active and a.outlet_id = p_outlet
      and a.start_date <= p_date and (a.end_date is null or a.end_date >= p_date)
  )
$$;

create function public.assign_staff_temporary(
  p_staff uuid, p_outlet uuid, p_start_date date, p_end_date date, p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text;
  v_id     uuid;
begin
  perform app.require_permission(p_outlet, 'staff.manage');
  v_reason := app.require_reason(p_reason);
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    raise exception 'a temporary assignment needs a start date and an end date on or after it' using errcode = '22023';
  end if;
  if not exists (select 1 from public.staff where id = p_staff and active) then
    raise exception 'staff member not found or inactive' using errcode = '22023';
  end if;
  perform app.set_audit_context(v_reason);
  -- end_reason must accompany end_date (table CHECK); for a loan the reason is the loan reason.
  insert into public.staff_assignments (staff_id, outlet_id, start_date, end_date, end_reason, is_temporary)
  values (p_staff, p_outlet, p_start_date, p_end_date, v_reason, true)
  returning id into v_id;
  return v_id;
end;
$$;

-- Staff edits: rename / deactivate / reactivate. Caller must manage staff in an outlet the person
-- is (or was) assigned to.
create function public.update_staff(p_staff uuid, p_full_name text, p_active boolean, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text;
begin
  if not exists (
    select 1 from public.staff_assignments a
    where a.staff_id = p_staff and app.has_permission(a.outlet_id, 'staff.manage')
  ) then
    raise exception 'permission staff.manage denied' using errcode = '42501';
  end if;
  v_reason := app.require_reason(p_reason);
  if p_full_name is null or length(btrim(p_full_name)) = 0 or length(p_full_name) > 120 then
    raise exception 'staff name must be 1-120 characters' using errcode = '22023';
  end if;
  if p_active is null then
    raise exception 'active flag is required' using errcode = '22023';
  end if;
  perform app.set_audit_context(v_reason);
  update public.staff set full_name = btrim(p_full_name), active = p_active where id = p_staff;
end;
$$;

-- Outlet settings ----------------------------------------------------------------------------------
create function public.set_offline_thresholds(
  p_outlet uuid, p_online_window_s integer, p_clock_warn_s integer, p_gap_flag_h integer, p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text;
begin
  perform app.require_permission(p_outlet, 'outlet.thresholds');
  v_reason := app.require_reason(p_reason);
  if p_online_window_s is null or p_clock_warn_s is null or p_gap_flag_h is null
     or p_online_window_s <= 0 or p_clock_warn_s <= 0 or p_gap_flag_h <= 0 then
    raise exception 'thresholds must be positive whole numbers' using errcode = '22023';
  end if;
  perform app.set_audit_context(v_reason);
  update public.outlets
     set online_window_s = p_online_window_s, clock_warn_s = p_clock_warn_s, gap_flag_h = p_gap_flag_h
   where id = p_outlet;
end;
$$;

create function public.set_outlet_details(
  p_outlet uuid, p_name text, p_address text, p_go_live_date date, p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text;
begin
  perform app.require_permission(p_outlet, 'outlet.details');
  v_reason := app.require_reason(p_reason);
  if p_name is null or length(btrim(p_name)) = 0 or length(p_name) > 120 then
    raise exception 'outlet name must be 1-120 characters' using errcode = '22023';
  end if;
  perform app.set_audit_context(v_reason);
  update public.outlets
     set name = btrim(p_name), address = nullif(btrim(coalesce(p_address, '')), ''), go_live_date = p_go_live_date
   where id = p_outlet;
end;
$$;

-- Server clock for device offset tracking (Rev 6 §6.3). Any signed-in user.
create function public.server_time()
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select now()
$$;

-- Product catalogue (Rev 6 §3.1, O10) ---------------------------------------------------------------
create table public.product_catalog (
  id             uuid primary key default gen_random_uuid(),
  outlet_id      uuid not null references public.outlets (id),
  name           text not null check (length(btrim(name)) between 1 and 120),
  -- Paise, whole rupees (D-07 in docs/DECISIONS.md).
  default_price  bigint not null check (default_price > 0 and default_price % 100 = 0 and default_price <= 10000000),
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index product_catalog_name_uidx on public.product_catalog (outlet_id, lower(name));
create trigger product_catalog_touch before update on public.product_catalog
  for each row execute function app.touch_updated_at();
create trigger product_catalog_no_delete before delete on public.product_catalog
  for each row execute function app.forbid_mutation();
create trigger product_catalog_audit after insert or update on public.product_catalog
  for each row execute function app.audit_row();

alter table public.product_catalog enable row level security;
create policy product_catalog_select on public.product_catalog
  for select to authenticated using (app.is_member(outlet_id));
grant select on public.product_catalog to authenticated;

-- Create (p_product null) or update a catalogue item.
create function public.upsert_product(
  p_outlet uuid, p_product uuid, p_name text, p_default_price bigint, p_active boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.require_permission(p_outlet, 'catalog.manage');
  if p_name is null or length(btrim(p_name)) = 0 or length(p_name) > 120 then
    raise exception 'product name must be 1-120 characters' using errcode = '22023';
  end if;
  if p_default_price is null or p_default_price <= 0 or p_default_price % 100 <> 0 or p_default_price > 10000000 then
    raise exception 'price must be a whole-rupee amount between ₹1 and ₹1,00,000' using errcode = '22023';
  end if;
  perform app.set_audit_context('catalogue change');
  if p_product is null then
    insert into public.product_catalog (outlet_id, name, default_price, active)
    values (p_outlet, btrim(p_name), p_default_price, coalesce(p_active, true))
    returning id into v_id;
  else
    update public.product_catalog
       set name = btrim(p_name), default_price = p_default_price, active = coalesce(p_active, active)
     where id = p_product and outlet_id = p_outlet
    returning id into v_id;
    if v_id is null then
      raise exception 'product not found in this outlet' using errcode = '22023';
    end if;
  end if;
  return v_id;
end;
$$;
