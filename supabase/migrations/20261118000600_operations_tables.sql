-- M2/M4 tables: register entries, food payments, sync op log (Rev 6 §3.2, §6).
--
-- D-01 (docs/DECISIONS.md): the five entry kinds of Rev 6 §3.2 (service_sales, product_sales,
-- expenses, zakat_entries, food_deductions) share one `entries` table with a `kind` column and
-- per-kind CHECKs. Every common column, evidence rule and lifecycle rule in §3.2 is identical, so
-- one table means one correction / void / sync / late-entry path. Read-only views with the
-- original names are provided for reporting.

create type public.entry_kind as enum ('service', 'product', 'expense', 'zakat', 'food');
create type public.meal as enum ('breakfast', 'lunch', 'dinner');
create type public.payment_method as enum ('cash', 'paytm');
create type public.expense_source as enum ('cash_drawer', 'outside_drawer');
create type public.date_basis as enum ('online', 'offline_bounded', 'management_assigned');

-- audit_row: tolerate tables whose id is not a uuid (sync_ops) or that key on closing_id.
create or replace function app.audit_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old    jsonb;
  v_new    jsonb;
  v_row    uuid;
  v_outlet uuid;
begin
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;

  -- Row id: uuid `id`, else `closing_id` (closing_drafts); non-uuid ids are kept only in the jsonb.
  v_row := case when coalesce(v_new, v_old) ->> 'id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                then (coalesce(v_new, v_old) ->> 'id')::uuid
                else nullif(coalesce(v_new, v_old) ->> 'closing_id', '')::uuid end;
  if tg_table_name = 'outlets' then
    v_outlet := v_row;
  else
    v_outlet := nullif(coalesce(v_new, v_old) ->> 'outlet_id', '')::uuid;
  end if;

  insert into public.audit_logs (outlet_id, table_name, row_id, op_id, action, old_data, new_data, reason, actor)
  values (
    v_outlet, tg_table_name, v_row,
    nullif(current_setting('app.op_id', true), '')::uuid,
    tg_op, v_old, v_new,
    nullif(current_setting('app.reason', true), ''),
    auth.uid()
  );
  return null;
end;
$$;

alter table public.devices add column registered_by uuid references public.profiles (id);

-- Entries --------------------------------------------------------------------------------------------
create table public.entries (
  id                        uuid primary key,              -- client-generated UUID
  outlet_id                 uuid not null references public.outlets (id),
  kind                      public.entry_kind not null,
  -- Paise, whole rupees (D-07). For products: quantity × unit_price (server-computed).
  -- For food: the food COST, not a cash movement (J2).
  amount                    bigint not null check (amount > 0 and amount % 100 = 0 and amount <= 100000000),
  staff_id                  uuid references public.staff (id),  -- service: performer; zakat: optional donor (O9)
  product_id                uuid references public.product_catalog (id),
  product_name              text,                          -- snapshot (O10)
  quantity                  integer,
  unit_price                bigint,
  payment_method            public.payment_method,         -- product only
  expense_source            public.expense_source,         -- expense only (O2)
  meal                      public.meal,                   -- food only
  description               text check (description is null or length(description) <= 300),
  notes                     text check (notes is null or length(notes) <= 500),
  status                    text not null default 'active' check (status in ('active', 'voided')),
  void_reason               text,
  version                   integer not null default 1 check (version >= 1),
  recorded_by               uuid not null references public.profiles (id),
  device_id                 uuid references public.devices (id),
  op_id                     uuid not null unique,
  -- Timestamp evidence (F3) — immutable after insert.
  device_time               timestamptz,
  device_offset_ms          bigint,
  device_last_sync_at       timestamptz,
  received_at               timestamptz not null default now(),
  server_seq                bigint not null default nextval('app.server_seq'),
  bound_lower               timestamptz,
  bound_upper               timestamptz,
  -- Business-date assignment (§6.3).
  business_date             date,
  date_basis                public.date_basis,
  timestamp_flags           text[] not null default '{}',
  late                      boolean not null default false,
  late_against_revision_id  uuid,                          -- FK added with closing_revisions
  updated_at                timestamptz,
  updated_by                uuid references public.profiles (id),
  constraint entries_date_basis check ((business_date is null) = (date_basis is null)),
  constraint entries_void check ((status = 'voided') = (void_reason is not null)),
  constraint entries_late check (late = (late_against_revision_id is not null)),
  constraint entries_kind_columns check (
    case kind
      when 'service' then
        staff_id is not null and product_id is null and product_name is null and quantity is null
        and unit_price is null and payment_method is null and expense_source is null and meal is null
      when 'product' then
        product_name is not null and length(btrim(product_name)) > 0 and quantity > 0 and quantity <= 1000
        and unit_price > 0 and unit_price % 100 = 0 and amount = quantity::bigint * unit_price
        and payment_method is not null and staff_id is null and expense_source is null and meal is null
      when 'expense' then
        description is not null and length(btrim(description)) > 0 and expense_source is not null
        and staff_id is null and product_id is null and product_name is null and quantity is null
        and unit_price is null and payment_method is null and meal is null
      when 'zakat' then
        product_id is null and product_name is null and quantity is null and unit_price is null
        and payment_method is null and expense_source is null and meal is null
      when 'food' then
        meal is not null and staff_id is null and product_id is null and product_name is null
        and quantity is null and unit_price is null and payment_method is null and expense_source is null
    end
  )
);
create index entries_day_idx on public.entries (outlet_id, business_date, kind) where status = 'active';
create index entries_unassigned_idx on public.entries (outlet_id) where business_date is null;
create index entries_late_idx on public.entries (outlet_id, business_date) where late;
create index entries_staff_idx on public.entries (staff_id) where staff_id is not null;
create index entries_seq_idx on public.entries (outlet_id, server_seq);

-- Guard for offline-capable rows (entries, food_payments):
--   * never deleted;
--   * only the columns named in TG_ARGV may change;
--   * business_date / date_basis / late may change only while business_date is still NULL
--     (management assignment of an Unassigned row).
create function app.guard_operational_row()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_allowed text[] := tg_argv;
  v_old jsonb;
  v_new jsonb;
begin
  if tg_op = 'DELETE' then
    raise exception '%.% rows cannot be deleted; void or reverse instead', tg_table_schema, tg_table_name
      using errcode = 'P0001';
  end if;
  v_old := to_jsonb(old) - v_allowed
           - array['business_date', 'date_basis', 'timestamp_flags', 'late', 'late_against_revision_id'];
  v_new := to_jsonb(new) - v_allowed
           - array['business_date', 'date_basis', 'timestamp_flags', 'late', 'late_against_revision_id'];
  if v_old is distinct from v_new then
    raise exception 'immutable columns of %.% cannot change (evidence and identity are fixed)', tg_table_schema, tg_table_name
      using errcode = 'P0001';
  end if;
  if old.business_date is not null
     and (new.business_date, new.date_basis, new.late, new.late_against_revision_id, new.timestamp_flags)
         is distinct from (old.business_date, old.date_basis, old.late, old.late_against_revision_id, old.timestamp_flags) then
    raise exception 'business date of an assigned row cannot change' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger entries_guard before update or delete on public.entries
  for each row execute function app.guard_operational_row(
    'amount', 'staff_id', 'product_id', 'product_name', 'quantity', 'unit_price', 'payment_method',
    'expense_source', 'meal', 'description', 'notes', 'status', 'void_reason', 'version',
    'updated_at', 'updated_by');
create trigger entries_audit after insert or update on public.entries
  for each row execute function app.audit_row();

-- Food payments (J2): insert-only cash evidence for food cost entries. --------------------------------
create table public.food_payments (
  id                        uuid primary key,
  outlet_id                 uuid not null references public.outlets (id),
  food_id                   uuid not null references public.entries (id),
  amount                    bigint not null check (amount > 0 and amount % 100 = 0),
  paid_from                 text not null check (paid_from in ('drawer', 'outside_drawer')),
  reverses_payment_id       uuid unique references public.food_payments (id),
  reason                    text,
  recorded_by               uuid not null references public.profiles (id),
  device_id                 uuid references public.devices (id),
  op_id                     uuid not null unique,
  device_time               timestamptz,
  device_offset_ms          bigint,
  device_last_sync_at       timestamptz,
  received_at               timestamptz not null default now(),
  server_seq                bigint not null default nextval('app.server_seq'),
  bound_lower               timestamptz,
  bound_upper               timestamptz,
  business_date             date,
  date_basis                public.date_basis,
  timestamp_flags           text[] not null default '{}',
  late                      boolean not null default false,
  late_against_revision_id  uuid,
  constraint food_payments_date_basis check ((business_date is null) = (date_basis is null)),
  constraint food_payments_late check (late = (late_against_revision_id is not null)),
  constraint food_payments_reversal_reason check (
    reverses_payment_id is null or (reason is not null and length(btrim(reason)) > 0)
  )
);
create index food_payments_food_idx on public.food_payments (food_id);
create index food_payments_day_idx on public.food_payments (outlet_id, business_date);

create trigger food_payments_guard before update or delete on public.food_payments
  for each row execute function app.guard_operational_row();
create trigger food_payments_audit after insert or update on public.food_payments
  for each row execute function app.audit_row();

-- Net paid per food entry never exceeds its cost; a voided food entry has nothing paid.
-- Deferred so it is evaluated at commit, after every row of the transaction (concurrency backstop
-- for the row lock taken by the RPCs).
create function app.check_food_paid()
returns trigger
language plpgsql
security definer   -- deferred: fires at COMMIT, outside the definer RPC that queued it
set search_path = ''
as $$
declare
  v_food  uuid := case when tg_table_name = 'entries' then new.id else (to_jsonb(new) ->> 'food_id')::uuid end;
  v_cost  bigint;
  v_stat  text;
  v_kind  public.entry_kind;
  v_paid  bigint;
begin
  select amount, status, kind into v_cost, v_stat, v_kind from public.entries where id = v_food;
  if v_kind is distinct from 'food' then
    if tg_table_name = 'food_payments' then
      raise exception 'food payments must reference a food entry' using errcode = '23514';
    end if;
    return null;
  end if;
  select coalesce(sum(case when reverses_payment_id is null then amount else -amount end), 0)
    into v_paid from public.food_payments where food_id = v_food;
  if v_paid > v_cost then
    raise exception 'food payments (₹%) would exceed the food cost (₹%)', v_paid / 100, v_cost / 100
      using errcode = '23514';
  end if;
  if v_stat = 'voided' and v_paid > 0 then
    raise exception 'reverse the food payments before voiding the food entry' using errcode = '23514';
  end if;
  return null;
end;
$$;
create constraint trigger food_payments_within_cost
  after insert on public.food_payments
  deferrable initially deferred
  for each row execute function app.check_food_paid();
create constraint trigger entries_food_cost_covers_paid
  after update of amount, status on public.entries
  deferrable initially deferred
  for each row execute function app.check_food_paid();

-- Sync op log (Rev 6 §6.1, §6.4): idempotency keys + evidence for every op a device sent. -------
create table public.sync_ops (
  id               bigint generated always as identity primary key,
  op_id            uuid not null,
  device_id        uuid not null references public.devices (id),
  device_seq       bigint not null check (device_seq > 0),
  outlet_id        uuid not null references public.outlets (id),
  op_type          text not null,
  record_id        uuid,
  payload          jsonb not null,
  payload_hash     text not null,
  device_time      timestamptz,
  status           text not null check (status in ('applied', 'failed', 'conflict')),
  result           jsonb,
  error_code       text,
  error_message    text,
  submitted_by     uuid not null references public.profiles (id),
  received_at      timestamptz not null default now(),
  server_seq       bigint not null default nextval('app.server_seq'),
  resolved_at      timestamptz,
  resolved_by      uuid references public.profiles (id),
  resolution_note  text,
  constraint sync_ops_resolution check (
    (resolved_at is null) = (resolved_by is null) and (resolved_at is null) = (resolution_note is null)
  )
);
-- One accepted op per (device, seq) and per op_id; conflicting duplicates are stored separately.
create unique index sync_ops_device_seq_uidx on public.sync_ops (device_id, device_seq) where status <> 'conflict';
create unique index sync_ops_op_uidx on public.sync_ops (op_id) where status <> 'conflict';
create index sync_ops_issues_idx on public.sync_ops (outlet_id) where status <> 'applied' and resolved_at is null;
create index sync_ops_record_idx on public.sync_ops (device_id, record_id);

-- Only the one-time resolution fields may change.
create function app.guard_sync_op()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'sync_ops rows cannot be deleted' using errcode = 'P0001';
  end if;
  if old.resolved_at is not null
     or (to_jsonb(new) - array['resolved_at', 'resolved_by', 'resolution_note'])
        is distinct from (to_jsonb(old) - array['resolved_at', 'resolved_by', 'resolution_note']) then
    raise exception 'sync_ops rows are immutable except for a one-time resolution' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger sync_ops_guard before update or delete on public.sync_ops
  for each row execute function app.guard_sync_op();
create trigger sync_ops_audit after update on public.sync_ops
  for each row execute function app.audit_row();
