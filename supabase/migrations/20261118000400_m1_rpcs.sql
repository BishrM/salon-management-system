-- M1 RPCs: the only write paths for M1 tables (Rev 6 §4.1). Every function:
--   * is SECURITY DEFINER with an empty search_path,
--   * checks the caller's permission in the target outlet first,
--   * takes actor columns from auth.uid(), never from the client,
--   * records a reason through app.reason so the audit trigger stores it.

create function app.require_reason(p_reason text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'a reason is required' using errcode = '22023';
  end if;
  if length(p_reason) > 500 then
    raise exception 'reason is too long (max 500 characters)' using errcode = '22023';
  end if;
  return btrim(p_reason);
end;
$$;

create function app.set_audit_context(p_reason text)
returns void
language sql
set search_path = ''
as $$
  select set_config('app.reason', coalesce(p_reason, ''), true);
$$;

-- Permissions -----------------------------------------------------------------------------------
create function public.my_permissions(p_outlet uuid)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(m.permission order by m.permission), '{}')
  from app.permission_matrix() m
  where app.has_permission(p_outlet, m.permission)
$$;

-- Outlet setup (setup checklist v1) --------------------------------------------------------------
create function public.set_outlet_cutoff(p_outlet uuid, p_cutoff time, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text;
begin
  perform app.require_permission(p_outlet, 'outlet.cutoff');
  v_reason := app.require_reason(p_reason);
  if p_cutoff is null then
    raise exception 'cutoff is required' using errcode = '22023';
  end if;
  perform app.set_audit_context(v_reason);
  update public.outlets set day_cutoff = p_cutoff where id = p_outlet;
end;
$$;

-- Denominations in paise; must be whole rupees. Stored sorted and de-duplicated.
create function public.set_outlet_denominations(p_outlet uuid, p_denominations integer[], p_reason text)
returns integer[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text;
  v_clean  integer[];
begin
  perform app.require_permission(p_outlet, 'outlet.denominations');
  v_reason := app.require_reason(p_reason);
  if p_denominations is null or cardinality(p_denominations) = 0 then
    raise exception 'at least one denomination is required' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(p_denominations) d where d is null or d <= 0 or d % 100 <> 0) then
    raise exception 'denominations must be positive whole-rupee amounts in paise' using errcode = '22023';
  end if;
  select array_agg(distinct d order by d) into v_clean from unnest(p_denominations) d;
  perform app.set_audit_context(v_reason);
  update public.outlets set denominations = v_clean where id = p_outlet;
  return v_clean;
end;
$$;

-- Staff -------------------------------------------------------------------------------------------
create function public.create_staff(
  p_outlet uuid,
  p_full_name text,
  p_start_date date,
  p_profile_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff uuid;
begin
  perform app.require_permission(p_outlet, 'staff.manage');
  if p_full_name is null or length(btrim(p_full_name)) = 0 or length(p_full_name) > 120 then
    raise exception 'staff name must be 1-120 characters' using errcode = '22023';
  end if;
  if p_start_date is null then
    raise exception 'start date is required' using errcode = '22023';
  end if;
  if p_profile_id is not null and not exists (
    select 1 from public.outlet_memberships m
    join public.profiles p on p.id = m.profile_id and p.active
    where m.outlet_id = p_outlet and m.profile_id = p_profile_id and m.revoked_at is null
  ) then
    raise exception 'linked login must be an active member of this outlet' using errcode = '22023';
  end if;
  perform app.set_audit_context('staff created');
  insert into public.staff (full_name, profile_id) values (btrim(p_full_name), p_profile_id)
  returning id into v_staff;
  insert into public.staff_assignments (staff_id, outlet_id, start_date)
  values (v_staff, p_outlet, p_start_date);
  return v_staff;
end;
$$;

create function public.assign_staff(p_staff uuid, p_outlet uuid, p_start_date date, p_reason text)
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
  if p_start_date is null then
    raise exception 'start date is required' using errcode = '22023';
  end if;
  if not exists (select 1 from public.staff where id = p_staff and active) then
    raise exception 'staff member not found or inactive' using errcode = '22023';
  end if;
  perform app.set_audit_context(v_reason);
  insert into public.staff_assignments (staff_id, outlet_id, start_date)
  values (p_staff, p_outlet, p_start_date)
  returning id into v_id;
  return v_id;
end;
$$;

create function public.end_staff_assignment(p_assignment uuid, p_end_date date, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outlet uuid;
  v_reason text;
begin
  select outlet_id into v_outlet from public.staff_assignments where id = p_assignment;
  perform app.require_permission(v_outlet, 'staff.manage');  -- NULL outlet (not found) => denied
  v_reason := app.require_reason(p_reason);
  if p_end_date is null then
    raise exception 'end date is required' using errcode = '22023';
  end if;
  perform app.set_audit_context(v_reason);
  update public.staff_assignments
     set end_date = p_end_date, end_reason = v_reason
   where id = p_assignment;
end;
$$;

-- Memberships & delegation ------------------------------------------------------------------------
create function public.add_membership(p_outlet uuid, p_profile uuid, p_role public.app_role, p_reason text)
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
  if p_role is null then
    raise exception 'role is required' using errcode = '22023';
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
  perform app.set_audit_context(v_reason);
  insert into public.outlet_memberships (outlet_id, profile_id, role, granted_by, reason)
  values (p_outlet, p_profile, p_role, auth.uid(), v_reason)
  returning id into v_id;
  return v_id;
end;
$$;

-- Rev 6 §4.1: caller must be a valid owner/manager (delegation.manage), granted_by = caller,
-- no self-grant, end time required and in the future, target must be a current member.
create function public.grant_acting_head(
  p_outlet uuid,
  p_profile uuid,
  p_valid_to timestamptz,
  p_reason text,
  p_valid_from timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text;
  v_from   timestamptz := coalesce(p_valid_from, now());
  v_id     uuid;
begin
  perform app.require_permission(p_outlet, 'delegation.manage');
  v_reason := app.require_reason(p_reason);
  if p_profile is null or p_profile = auth.uid() then
    raise exception 'a delegation cannot be granted to yourself' using errcode = '42501';
  end if;
  if p_valid_to is null then
    raise exception 'an acting-head delegation must have an end time' using errcode = '22023';
  end if;
  if p_valid_to <= v_from then
    raise exception 'delegation end must be after its start' using errcode = '22023';
  end if;
  if p_valid_to <= now() then
    raise exception 'delegation end must be in the future' using errcode = '22023';
  end if;
  if not exists (
    select 1
    from public.outlet_memberships m
    join public.profiles p on p.id = m.profile_id and p.active
    where m.outlet_id = p_outlet and m.profile_id = p_profile
      and not m.is_acting and m.revoked_at is null
      and m.valid_from <= now() and (m.valid_to is null or now() < m.valid_to)
  ) then
    raise exception 'acting head must be an active member of this outlet' using errcode = '22023';
  end if;
  perform app.set_audit_context(v_reason);
  insert into public.outlet_memberships (outlet_id, profile_id, role, is_acting, valid_from, valid_to, granted_by, reason)
  values (p_outlet, p_profile, 'head', true, v_from, p_valid_to, auth.uid(), v_reason)
  returning id into v_id;
  return v_id;
end;
$$;

-- Acting delegations: delegation.manage. Permanent memberships: users.manage.
-- The last valid owner of an outlet cannot be revoked.
create function public.revoke_membership(p_membership uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_m      public.outlet_memberships;
  v_reason text;
begin
  select * into v_m from public.outlet_memberships where id = p_membership for update;
  if not found then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if v_m.is_acting then
    perform app.require_permission(v_m.outlet_id, 'delegation.manage');
  else
    perform app.require_permission(v_m.outlet_id, 'users.manage');
  end if;
  v_reason := app.require_reason(p_reason);
  if v_m.revoked_at is not null then
    raise exception 'membership is already revoked' using errcode = '22023';
  end if;
  if v_m.role = 'owner' and not v_m.is_acting and not exists (
    select 1 from public.outlet_memberships o
    where o.outlet_id = v_m.outlet_id and o.id <> v_m.id and o.role = 'owner'
      and not o.is_acting and o.revoked_at is null
      and o.valid_from <= now() and (o.valid_to is null or now() < o.valid_to)
  ) then
    raise exception 'cannot revoke the last owner of an outlet' using errcode = '22023';
  end if;
  perform app.set_audit_context(v_reason);
  update public.outlet_memberships
     set revoked_at = now(), revoked_by = auth.uid(), revoke_reason = v_reason
   where id = p_membership;
end;
$$;

-- Bootstrap (not callable by clients) -------------------------------------------------------------
-- Creates an outlet with its first owner. Run from the SQL editor / psql as postgres when setting
-- up production, and from seed.sql locally.
create function app.bootstrap_outlet(p_name text, p_address text, p_owner_profile uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outlet uuid;
begin
  perform app.set_audit_context('bootstrap outlet');
  insert into public.outlets (name, address) values (p_name, p_address) returning id into v_outlet;
  insert into public.outlet_memberships (outlet_id, profile_id, role, reason)
  values (v_outlet, p_owner_profile, 'owner', 'bootstrap owner');
  return v_outlet;
end;
$$;

-- Privileges --------------------------------------------------------------------------------------
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

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.my_permissions(uuid),
  public.set_outlet_cutoff(uuid, time, text),
  public.set_outlet_denominations(uuid, integer[], text),
  public.create_staff(uuid, text, date, uuid),
  public.assign_staff(uuid, uuid, date, text),
  public.end_staff_assignment(uuid, date, text),
  public.add_membership(uuid, uuid, public.app_role, text),
  public.grant_acting_head(uuid, uuid, timestamptz, text, timestamptz),
  public.revoke_membership(uuid, text)
to authenticated;
