-- M1 authorisation: role validity, permission matrix, RLS policies, privileges (Rev 6 §4, §4.1).

-- Memberships of the caller that are valid *now* (Rev 6 §4 acting-head rules):
--   not revoked, inside [valid_from, valid_to), profile active, and for acting rows the grantor
--   still holds a valid, non-acting owner/manager membership in the same outlet.
create function app.my_valid_memberships()
returns table (outlet_id uuid, role public.app_role, is_acting boolean, membership_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select m.outlet_id, m.role, m.is_acting, m.id
  from public.outlet_memberships m
  join public.profiles p on p.id = m.profile_id and p.active
  where m.profile_id = auth.uid()
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

-- Single source of truth for the permission matrix (Rev 6 §4).
-- Later-milestone permissions are listed so the role definitions are complete and testable now;
-- no feature uses them until its milestone.
create function app.permission_matrix()
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
    ('members.read',          array['owner','manager']::public.app_role[]),
    ('delegation.manage',     array['owner','manager']::public.app_role[]),
    ('outlet.denominations',  array['owner','manager']::public.app_role[]),
    ('outlet.cutoff',         array['owner']::public.app_role[]),
    ('outlet.thresholds',     array['owner']::public.app_role[]),
    ('float.initial',         array['owner']::public.app_role[]),
    ('users.manage',          array['owner']::public.app_role[]),
    ('audit.read',            array['owner']::public.app_role[])
$$;

create function app.has_permission(p_outlet uuid, p_permission text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_roles public.app_role[];
begin
  select roles into v_roles from app.permission_matrix() where permission = p_permission;
  if v_roles is null then
    raise exception 'unknown permission %', p_permission using errcode = '22023';
  end if;
  return exists (
    select 1 from app.my_valid_memberships() v
    where v.outlet_id = p_outlet and v.role = any (v_roles)
  );
end;
$$;

create function app.is_member(p_outlet uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app.has_permission(p_outlet, 'outlet.read')
$$;

-- Raises 42501 unless the caller holds the permission in the outlet. Used by every RPC.
create function app.require_permission(p_outlet uuid, p_permission text)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if p_outlet is null or not app.has_permission(p_outlet, p_permission) then
    raise exception 'permission % denied', p_permission using errcode = '42501';
  end if;
end;
$$;

create function app.is_owner_anywhere()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from app.my_valid_memberships() v where v.role = 'owner')
$$;

-- Caller may see a profile if it is their own, or the profile belongs to a member of an outlet
-- where the caller holds members.read.
create function app.can_view_profile(p_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_profile = auth.uid()
      or exists (
        select 1 from public.outlet_memberships m
        where m.profile_id = p_profile
          and app.has_permission(m.outlet_id, 'members.read')
      )
$$;

-- Staff visible to members of any outlet the person is (or was) assigned to.
create function app.can_view_staff(p_staff uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.staff_assignments a
    where a.staff_id = p_staff and app.is_member(a.outlet_id)
  )
$$;

-- Row Level Security ------------------------------------------------------------------------
alter table public.outlets             enable row level security;
alter table public.profiles            enable row level security;
alter table public.outlet_memberships  enable row level security;
alter table public.staff               enable row level security;
alter table public.staff_assignments   enable row level security;
alter table public.devices             enable row level security;
alter table public.audit_logs          enable row level security;

-- SELECT only. There are deliberately no INSERT/UPDATE/DELETE policies: writes go through
-- SECURITY DEFINER RPCs (and the table privileges below are revoked as a second barrier).
create policy outlets_select on public.outlets
  for select to authenticated using (app.is_member(id));

create policy profiles_select on public.profiles
  for select to authenticated using (app.can_view_profile(id));

create policy memberships_select on public.outlet_memberships
  for select to authenticated
  using (profile_id = auth.uid() or app.has_permission(outlet_id, 'members.read'));

create policy staff_select on public.staff
  for select to authenticated using (app.can_view_staff(id));

create policy staff_assignments_select on public.staff_assignments
  for select to authenticated using (app.is_member(outlet_id));

create policy devices_select on public.devices
  for select to authenticated using (app.has_permission(outlet_id, 'sync.manage'));

create policy audit_logs_select on public.audit_logs
  for select to authenticated
  using (
    (outlet_id is not null and app.has_permission(outlet_id, 'audit.read'))
    or (outlet_id is null and app.is_owner_anywhere())
  );

-- Table privileges ----------------------------------------------------------------------------
-- Supabase grants ALL on new public tables to anon/authenticated by default. Remove that and
-- grant SELECT only (RLS then filters rows). anon gets nothing.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
grant select on
  public.outlets, public.profiles, public.outlet_memberships, public.staff,
  public.staff_assignments, public.devices, public.audit_logs
to authenticated;

-- Future tables/functions created by this role start with no client privileges; each migration
-- must grant explicitly.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema app revoke execute on functions from public, anon, authenticated;

-- Helper functions: no client execution except the predicates RLS policies evaluate as the caller.
revoke execute on all functions in schema app from public, anon, authenticated;
grant execute on function
  app.my_valid_memberships(),
  app.permission_matrix(),
  app.has_permission(uuid, text),
  app.is_member(uuid),
  app.is_owner_anywhere(),
  app.can_view_profile(uuid),
  app.can_view_staff(uuid)
to authenticated;
