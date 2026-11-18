-- M1 identity & configuration tables (Rev 6 §3.1).
-- product_catalog is deliberately NOT created here: the M1 authorisation excludes products.

-- Outlets ---------------------------------------------------------------------------------
create table public.outlets (
  id               uuid primary key default gen_random_uuid(),
  name             text not null check (length(btrim(name)) > 0),
  address          text,
  timezone         text not null default 'Asia/Kolkata',
  -- B1/F5: no default. Production setup must set it; 04:00 is only a suggestion in the UI.
  day_cutoff       time,
  -- Paise. Default = SRS §3.7 notes (₹10, 20, 50, 100, 200, 500).
  denominations    integer[] not null default '{1000,2000,5000,10000,20000,50000}',
  go_live_date     date,
  -- G4: configurable offline thresholds (used from M4).
  online_window_s  integer not null default 120 check (online_window_s > 0),
  clock_warn_s     integer not null default 300 check (clock_warn_s > 0),
  gap_flag_h       integer not null default 48  check (gap_flag_h > 0),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint outlets_denominations_valid check (
    cardinality(denominations) between 1 and 20
    and 0 < all (denominations)
    and array_position(denominations, null) is null
  )
);
create trigger outlets_touch before update on public.outlets
  for each row execute function app.touch_updated_at();
create trigger outlets_no_delete before delete on public.outlets
  for each row execute function app.forbid_mutation();
create trigger outlets_audit after insert or update on public.outlets
  for each row execute function app.audit_row();

-- Profiles (1:1 with auth.users) ------------------------------------------------------------
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete restrict,
  full_name   text not null check (length(btrim(full_name)) > 0),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create trigger profiles_touch before update on public.profiles
  for each row execute function app.touch_updated_at();
create trigger profiles_no_delete before delete on public.profiles
  for each row execute function app.forbid_mutation();
create trigger profiles_audit after insert or update on public.profiles
  for each row execute function app.audit_row();

create function app.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''), new.email, new.id::text));
  return new;
end;
$$;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app.handle_new_auth_user();

-- Outlet memberships (roles, incl. acting-head delegation; Rev 6 §3.1, §4.1) -----------------
create table public.outlet_memberships (
  id             uuid primary key default gen_random_uuid(),
  outlet_id      uuid not null references public.outlets (id),
  profile_id     uuid not null references public.profiles (id),
  role           public.app_role not null,
  is_acting      boolean not null default false,
  valid_from     timestamptz not null default now(),
  valid_to       timestamptz,
  granted_by     uuid references public.profiles (id),
  reason         text,
  revoked_at     timestamptz,
  revoked_by     uuid references public.profiles (id),
  revoke_reason  text,
  created_at     timestamptz not null default now(),
  constraint memberships_window check (valid_to is null or valid_to > valid_from),
  -- Acting head: always head, always ends, always granted by someone else, always has a reason.
  constraint memberships_acting_rules check (
    not is_acting or (
      role = 'head'
      and valid_to is not null
      and granted_by is not null
      and granted_by <> profile_id
      and reason is not null and length(btrim(reason)) > 0
    )
  ),
  constraint memberships_revoke_pair check ((revoked_at is null) = (revoked_by is null)),
  constraint memberships_revoke_reason check (
    revoked_at is null or (revoke_reason is not null and length(btrim(revoke_reason)) > 0)
  )
);
create unique index memberships_one_permanent_uidx
  on public.outlet_memberships (outlet_id, profile_id)
  where not is_acting and revoked_at is null;
create index memberships_profile_idx on public.outlet_memberships (profile_id);
create index memberships_outlet_idx on public.outlet_memberships (outlet_id);

-- Memberships are never deleted; the only permitted update is a one-time revocation.
create function app.guard_membership_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'outlet_memberships cannot be deleted; revoke instead' using errcode = 'P0001';
  end if;
  if old.revoked_at is not null then
    raise exception 'membership % is already revoked', old.id using errcode = 'P0001';
  end if;
  if (new.id, new.outlet_id, new.profile_id, new.role, new.is_acting, new.valid_from, new.valid_to,
      new.granted_by, new.reason, new.created_at)
     is distinct from
     (old.id, old.outlet_id, old.profile_id, old.role, old.is_acting, old.valid_from, old.valid_to,
      old.granted_by, old.reason, old.created_at) then
    raise exception 'only revocation fields of a membership may change' using errcode = 'P0001';
  end if;
  if new.revoked_at is null then
    raise exception 'a membership update must revoke it' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger memberships_guard before update or delete on public.outlet_memberships
  for each row execute function app.guard_membership_change();
create trigger memberships_audit after insert or update on public.outlet_memberships
  for each row execute function app.audit_row();

-- Staff (people who earn commission; may or may not have a login) ----------------------------
create table public.staff (
  id          uuid primary key default gen_random_uuid(),
  full_name   text not null check (length(btrim(full_name)) > 0),
  profile_id  uuid unique references public.profiles (id),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create trigger staff_touch before update on public.staff
  for each row execute function app.touch_updated_at();
create trigger staff_no_delete before delete on public.staff
  for each row execute function app.forbid_mutation();
create trigger staff_audit after insert or update on public.staff
  for each row execute function app.audit_row();

create table public.staff_assignments (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references public.staff (id),
  outlet_id   uuid not null references public.outlets (id),
  start_date  date not null,
  end_date    date,
  end_reason  text,
  created_at  timestamptz not null default now(),
  constraint staff_assignments_dates check (end_date is null or end_date >= start_date),
  constraint staff_assignments_end_reason check (
    (end_date is null) = (end_reason is null)
    and (end_reason is null or length(btrim(end_reason)) > 0)
  ),
  -- Preserves history (SRS §13) and forbids overlapping assignments for the same person.
  constraint staff_assignments_no_overlap exclude using gist (
    staff_id with =,
    daterange(start_date, end_date, '[]') with &&
  )
);
create index staff_assignments_outlet_idx on public.staff_assignments (outlet_id);

-- Assignments are never deleted; only an open assignment may be ended (once).
create function app.guard_assignment_change()
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
  if (new.id, new.staff_id, new.outlet_id, new.start_date, new.created_at)
     is distinct from (old.id, old.staff_id, old.outlet_id, old.start_date, old.created_at) then
    raise exception 'only end_date and end_reason of an assignment may change' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger staff_assignments_guard before update or delete on public.staff_assignments
  for each row execute function app.guard_assignment_change();
create trigger staff_assignments_audit after insert or update on public.staff_assignments
  for each row execute function app.audit_row();

-- Devices (client devices for offline sync; written from M4) ---------------------------------
create table public.devices (
  id               uuid primary key,
  outlet_id        uuid not null references public.outlets (id),
  label            text,
  first_seen_at    timestamptz not null default now(),
  last_contact_at  timestamptz,
  last_synced_seq  bigint not null default 0 check (last_synced_seq >= 0)
);
create index devices_outlet_idx on public.devices (outlet_id);
create trigger devices_no_delete before delete on public.devices
  for each row execute function app.forbid_mutation();
