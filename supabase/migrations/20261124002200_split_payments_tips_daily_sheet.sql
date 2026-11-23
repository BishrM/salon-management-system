-- Daily Sheet, split payments and tips (2026-11-24). Forward-only; no existing row changes.
--
--   * Split payment: one service sale paid partly in cash and partly by UPI / Paytm / Card.
--     payment_method = 'split' with split_cash + split_paytm = amount (both >= 0). One entry, one employee,
--     one amount: service revenue and commission are unchanged (they use entries.amount only).
--   * Tips: tip_cash / tip_paytm on a service sale, entered explicitly by the operator. Never revenue,
--     never commission (compute_day sums entries.amount only and is not changed here).
--     Cash handling (U5, docs/DECISIONS.md): a tip goes to the employee at the time. A cash tip never stays in
--     the drawer; a digital tip arrives in the salon's Paytm account and is paid to the employee in cash from the
--     drawer. The Paytm statement total (entered at closing) therefore includes digital tips and the existing
--     cash model (cash sales = services + products − Paytm statement total) stays exactly right.
--   * day_summary: counter-recorded Paytm now = Paytm-only sales + split Paytm parts + product Paytm + digital
--     tips, compared with the Paytm statement total entered at closing (paytm_difference).
--   * Daily Sheet: sheet_opens records the first time a day's sheet was opened (no closing, revision or
--     notification is created). sheet_changes() lists, from the audit log, every Register change to a day after
--     its sheet was opened — for the owner (audit.read).

-- 1. Columns and constraints ------------------------------------------------------------------------------
alter table public.entries
  add column split_cash  bigint,
  add column split_paytm bigint,
  add column tip_cash    bigint not null default 0,
  add column tip_paytm   bigint not null default 0;

comment on column public.entries.split_cash is 'service with payment_method = split: part paid in cash (paise). split_cash + split_paytm = amount.';
comment on column public.entries.split_paytm is 'service with payment_method = split: part paid by UPI / Paytm / Card (paise).';
comment on column public.entries.tip_cash is 'service only: tip received in cash, explicitly entered. Not revenue, not commission.';
comment on column public.entries.tip_paytm is 'service only: tip received by UPI / Paytm / Card. Included in the Paytm statement total.';
comment on column public.entries.payment_method is
  'product: cash | paytm. service: cash | paytm | split. NULL only on service rows recorded before 2026-11-20.';

alter table public.entries add constraint entries_split_payment check (
  ((payment_method is not null and payment_method::text = 'split') = (split_cash is not null))
  and ((split_cash is null) = (split_paytm is null))
  and (split_cash is null or (
    kind = 'service' and split_cash >= 0 and split_paytm >= 0
    and split_cash % 100 = 0 and split_paytm % 100 = 0 and split_cash + split_paytm = amount))
);
alter table public.entries add constraint entries_tips check (
  tip_cash >= 0 and tip_paytm >= 0 and tip_cash % 100 = 0 and tip_paytm % 100 = 0
  and tip_cash <= 100000000 and tip_paytm <= 100000000
  and (kind = 'service' or (tip_cash = 0 and tip_paytm = 0))
);
alter table public.food_repayments add constraint food_repayments_no_split check (payment_method::text <> 'split');

-- The new payment columns may change through a correction (same rule as the other value columns).
drop trigger entries_guard on public.entries;
create trigger entries_guard before update or delete on public.entries
  for each row execute function app.guard_operational_row(
    'amount', 'staff_id', 'product_id', 'product_name', 'quantity', 'unit_price', 'payment_method',
    'expense_source', 'meal', 'description', 'notes', 'status', 'void_reason', 'version',
    'updated_at', 'updated_by', 'split_cash', 'split_paytm', 'tip_cash', 'tip_paytm');

-- 2. Validation ---------------------------------------------------------------------------------------------
-- Optional non-negative whole-rupee amount; absent or empty = 0.
create function app.money_or_zero(p jsonb, p_key text, p_label text)
returns bigint
language plpgsql
immutable
set search_path = ''
as $$
declare
  v bigint;
begin
  if coalesce(p ->> p_key, '') = '' then
    return 0;
  end if;
  if (p ->> p_key) !~ '^[0-9]+$' then
    raise exception '% must be a whole number of paise', p_label using errcode = '22023';
  end if;
  v := (p ->> p_key)::bigint;
  if v % 100 <> 0 or v > 100000000 then
    raise exception '% must be a whole-rupee amount up to ₹10,00,000', p_label using errcode = '22023';
  end if;
  return v;
end;
$$;
revoke execute on function app.money_or_zero(jsonb, text, text) from public, anon, authenticated;

-- Same as …001500 except the service branch: split payment and tips.
create or replace function app.entry_values(p_outlet uuid, p_kind public.entry_kind, p jsonb, p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_date    date := coalesce(p_date, app.business_date(p_outlet, now()));
  v_staff   uuid;
  v_prod    public.product_catalog;
  v_qty     integer;
  v_price   bigint;
  v_text    text;
  v_amt     bigint;
  v_sc      bigint;
  v_sp      bigint;
  v_tips    jsonb;
begin
  -- Split parts and tips exist only on service sales; refuse them elsewhere instead of dropping them.
  if p_kind <> 'service' and (coalesce(p ->> 'tip_cash', '0') <> '0' or coalesce(p ->> 'tip_paytm', '0') <> '0'
     or p ->> 'split_cash' is not null or p ->> 'split_paytm' is not null) then
    raise exception 'tips and split payments can only be recorded on a service sale' using errcode = '22023';
  end if;
  case p_kind
    when 'service' then
      v_staff := nullif(p ->> 'staff_id', '')::uuid;
      if v_staff is null or not app.staff_assigned(v_staff, p_outlet, v_date) then
        raise exception 'choose an employee working at this outlet on %', v_date using errcode = '22023';
      end if;
      v_amt := app.money(p, 'amount', 'Amount');
      v_tips := jsonb_build_object('tip_cash', app.money_or_zero(p, 'tip_cash', 'Cash tip'),
                                   'tip_paytm', app.money_or_zero(p, 'tip_paytm', 'UPI / Paytm / Card tip'));
      if p ->> 'payment_method' = 'split' then
        if coalesce(p ->> 'split_cash', '') = '' or coalesce(p ->> 'split_paytm', '') = '' then
          raise exception 'a split payment needs both the cash part and the UPI / Paytm / Card part' using errcode = '22023';
        end if;
        v_sc := app.money_or_zero(p, 'split_cash', 'Cash part');
        v_sp := app.money_or_zero(p, 'split_paytm', 'UPI / Paytm / Card part');
        if v_sc + v_sp <> v_amt then
          raise exception 'cash ₹% + UPI / Paytm / Card ₹% must equal the service amount ₹% (enter any tip separately)',
            v_sc / 100, v_sp / 100, v_amt / 100 using errcode = '22023';
        end if;
        return jsonb_build_object('amount', v_amt, 'staff_id', v_staff, 'payment_method', 'split',
          'split_cash', v_sc, 'split_paytm', v_sp) || v_tips;
      end if;
      return jsonb_build_object('amount', v_amt, 'staff_id', v_staff, 'payment_method', app.payment_method(p)) || v_tips;
    when 'product' then
      select * into v_prod from public.product_catalog
       where id = nullif(p ->> 'product_id', '')::uuid and outlet_id = p_outlet;
      if v_prod.id is null then
        raise exception 'choose a product from this outlet''s catalogue' using errcode = '22023';
      end if;
      if (p ->> 'quantity') is null or (p ->> 'quantity') !~ '^[0-9]+$'
         or (p ->> 'quantity')::int not between 1 and 1000 then
        raise exception 'quantity must be between 1 and 1000' using errcode = '22023';
      end if;
      v_qty := (p ->> 'quantity')::int;
      v_price := app.money(p, 'unit_price', 'Price per unit');
      return jsonb_build_object(
        'product_id', v_prod.id, 'product_name', v_prod.name, 'quantity', v_qty, 'unit_price', v_price,
        'amount', v_qty::bigint * v_price, 'payment_method', app.payment_method(p));
    when 'expense' then
      v_text := btrim(coalesce(p ->> 'description', ''));
      if length(v_text) = 0 or length(v_text) > 300 then
        raise exception 'expense description is required (max 300 characters)' using errcode = '22023';
      end if;
      if coalesce(p ->> 'expense_source', 'cash_drawer') not in ('cash_drawer', 'outside_drawer') then
        raise exception 'payment source must be cash_drawer or outside_drawer' using errcode = '22023';
      end if;
      return jsonb_build_object(
        'amount', app.money(p, 'amount', 'Amount'), 'description', v_text,
        'notes', nullif(btrim(coalesce(p ->> 'notes', '')), ''),
        'expense_source', coalesce(p ->> 'expense_source', 'cash_drawer'));
    when 'zakat' then
      v_staff := nullif(p ->> 'staff_id', '')::uuid;
      if v_staff is not null and not app.staff_assigned(v_staff, p_outlet, v_date) then
        raise exception 'donor must be an employee working at this outlet' using errcode = '22023';
      end if;
      return jsonb_build_object(
        'amount', app.money(p, 'amount', 'Amount'), 'staff_id', v_staff,
        'description', nullif(btrim(coalesce(p ->> 'description', '')), ''));
    when 'food' then
      if coalesce(p ->> 'meal', '') not in ('breakfast', 'lunch', 'dinner') then
        raise exception 'meal must be breakfast, lunch or dinner' using errcode = '22023';
      end if;
      return jsonb_build_object(
        'amount', app.money(p, 'amount', 'Food cost'), 'meal', p ->> 'meal',
        'description', nullif(btrim(coalesce(p ->> 'description', '')), ''));
  end case;
end;
$$;

-- Same as …000800 except: accepts split_cash / split_paytm / tip_cash / tip_paytm and stores them.
create or replace function app.op_create_entry(p_outlet uuid, p_device uuid, p_op jsonb, p_lower timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_data  jsonb := coalesce(p_op -> 'data', '{}');
  v_kind  public.entry_kind;
  v_id    uuid := (p_op ->> 'record_id')::uuid;
  v_cls   record;
  v_vals  jsonb;
  v_late  uuid;
  v_pay   uuid;
begin
  -- product_name is accepted for the device's own display but ignored: the name is snapshotted from the catalogue.
  perform app.require_keys(v_data, array['kind', 'amount', 'staff_id', 'product_id', 'product_name', 'quantity',
    'unit_price', 'payment_method', 'description', 'notes', 'expense_source', 'meal', 'pay_now', 'payment_id',
    'split_cash', 'split_paytm', 'tip_cash', 'tip_paytm']);
  if coalesce(v_data ->> 'kind', '') not in ('service', 'product', 'expense', 'zakat', 'food') then
    raise exception 'unknown entry kind' using errcode = '22023';
  end if;
  v_kind := (v_data ->> 'kind')::public.entry_kind;
  if v_id is null then
    raise exception 'record_id is required' using errcode = '22023';
  end if;
  if exists (select 1 from public.entries where id = v_id) then
    raise exception 'record id % is already used by another entry', v_id using errcode = 'SO409';
  end if;

  select * into v_cls from app.classify_time(
    p_outlet, p_device, (p_op ->> 'device_seq')::bigint,
    (p_op ->> 'device_time')::timestamptz, (p_op ->> 'device_offset_ms')::bigint,
    (p_op ->> 'device_last_sync_at')::timestamptz, p_lower, now());
  v_vals := app.entry_values(p_outlet, v_kind, v_data, v_cls.business_date);
  if v_cls.business_date is not null then
    v_late := app.frozen_revision(p_outlet, v_cls.business_date);
  end if;

  insert into public.entries (
    id, outlet_id, kind, amount, staff_id, product_id, product_name, quantity, unit_price, payment_method,
    expense_source, meal, description, notes, recorded_by, device_id, op_id,
    device_time, device_offset_ms, device_last_sync_at, bound_lower, bound_upper,
    business_date, date_basis, timestamp_flags, late, late_against_revision_id,
    split_cash, split_paytm, tip_cash, tip_paytm
  ) values (
    v_id, p_outlet, v_kind, (v_vals ->> 'amount')::bigint, (v_vals ->> 'staff_id')::uuid,
    (v_vals ->> 'product_id')::uuid, v_vals ->> 'product_name', (v_vals ->> 'quantity')::int,
    (v_vals ->> 'unit_price')::bigint, (v_vals ->> 'payment_method')::public.payment_method,
    (v_vals ->> 'expense_source')::public.expense_source, (v_vals ->> 'meal')::public.meal,
    v_vals ->> 'description', v_vals ->> 'notes', auth.uid(), p_device, (p_op ->> 'op_id')::uuid,
    (p_op ->> 'device_time')::timestamptz, (p_op ->> 'device_offset_ms')::bigint,
    (p_op ->> 'device_last_sync_at')::timestamptz, v_cls.bound_lower, v_cls.bound_upper,
    v_cls.business_date, v_cls.basis, v_cls.flags, v_late is not null, v_late,
    (v_vals ->> 'split_cash')::bigint, (v_vals ->> 'split_paytm')::bigint,
    coalesce((v_vals ->> 'tip_cash')::bigint, 0), coalesce((v_vals ->> 'tip_paytm')::bigint, 0)
  );

  -- Food "paid now from drawer" (B15): cost and payment in one op.
  if v_kind = 'food' and coalesce((v_data ->> 'pay_now')::boolean, false) then
    v_pay := coalesce(nullif(v_data ->> 'payment_id', '')::uuid, gen_random_uuid());
    insert into public.food_payments (
      id, outlet_id, food_id, amount, paid_from, recorded_by, device_id, op_id,
      device_time, device_offset_ms, device_last_sync_at, bound_lower, bound_upper,
      business_date, date_basis, timestamp_flags, late, late_against_revision_id
    ) values (
      v_pay, p_outlet, v_id, (v_vals ->> 'amount')::bigint, 'drawer', auth.uid(), p_device, (p_op ->> 'op_id')::uuid,
      (p_op ->> 'device_time')::timestamptz, (p_op ->> 'device_offset_ms')::bigint,
      (p_op ->> 'device_last_sync_at')::timestamptz, v_cls.bound_lower, v_cls.bound_upper,
      v_cls.business_date, v_cls.basis, v_cls.flags, v_late is not null, v_late
    );
  end if;

  return jsonb_build_object('id', v_id, 'version', 1, 'business_date', v_cls.business_date,
    'date_basis', v_cls.basis, 'flags', to_jsonb(v_cls.flags), 'late', v_late is not null,
    'amount', (v_vals ->> 'amount')::bigint, 'payment_id', v_pay);
end;
$$;

-- Same as …001500 except: a service correction may change the split parts and the tips.
create or replace function app.op_correct_entry(p_outlet uuid, p_op jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  e       public.entries;
  v_data  jsonb := coalesce(p_op -> 'data', '{}');
  v_merge jsonb;
  v_vals  jsonb;
  v_allow text[];
begin
  e := app.lock_entry_for_change(p_outlet, p_op);
  v_allow := case e.kind
    when 'service' then array['amount', 'staff_id', 'payment_method', 'split_cash', 'split_paytm', 'tip_cash', 'tip_paytm']
    when 'product' then array['product_id', 'quantity', 'unit_price', 'payment_method']
    when 'expense' then array['amount', 'description', 'notes', 'expense_source']
    when 'zakat'   then array['amount', 'staff_id', 'description']
    when 'food'    then array['amount', 'meal', 'description'] end;
  perform app.require_keys(v_data, v_allow);
  if v_data = '{}'::jsonb then
    raise exception 'nothing to correct' using errcode = '22023';
  end if;
  perform app.set_audit_context(app.require_reason(p_op ->> 'reason'));
  -- Merge new values over current ones, then re-validate the whole entry.
  v_merge := jsonb_strip_nulls(jsonb_build_object(
      'amount', e.amount, 'staff_id', e.staff_id, 'product_id', e.product_id, 'quantity', e.quantity,
      'unit_price', e.unit_price, 'payment_method', e.payment_method, 'description', e.description,
      'notes', e.notes, 'expense_source', e.expense_source, 'meal', e.meal,
      'split_cash', e.split_cash, 'split_paytm', e.split_paytm, 'tip_cash', e.tip_cash, 'tip_paytm', e.tip_paytm)) || v_data;
  v_vals := app.entry_values(p_outlet, e.kind, v_merge, e.business_date);
  update public.entries set
    amount = (v_vals ->> 'amount')::bigint,
    staff_id = (v_vals ->> 'staff_id')::uuid,
    product_id = (v_vals ->> 'product_id')::uuid,
    product_name = v_vals ->> 'product_name',
    quantity = (v_vals ->> 'quantity')::int,
    unit_price = (v_vals ->> 'unit_price')::bigint,
    payment_method = (v_vals ->> 'payment_method')::public.payment_method,
    expense_source = (v_vals ->> 'expense_source')::public.expense_source,
    meal = (v_vals ->> 'meal')::public.meal,
    description = v_vals ->> 'description',
    notes = v_vals ->> 'notes',
    split_cash = (v_vals ->> 'split_cash')::bigint,
    split_paytm = (v_vals ->> 'split_paytm')::bigint,
    tip_cash = coalesce((v_vals ->> 'tip_cash')::bigint, 0),
    tip_paytm = coalesce((v_vals ->> 'tip_paytm')::bigint, 0),
    version = version + 1,
    updated_at = now(),
    updated_by = auth.uid()
  where id = e.id;
  return jsonb_build_object('id', e.id, 'version', e.version + 1, 'amount', (v_vals ->> 'amount')::bigint);
end;
$$;

-- 3. day_summary: recorded payment split, tips and the Paytm statement difference ---------------------------
-- Same as …001500 plus split parts and tips. compute_day, revisions and submission rules are unchanged.
create or replace function public.day_summary(p_outlet uuid, p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v      jsonb;
  v_sc   bigint;
  v_sp   bigint;
  v_su   bigint;
  v_tc   bigint;
  v_tp   bigint;
  v_rec  bigint;
begin
  perform app.require_permission(p_outlet, 'outlet.read');
  v := app.compute_day(p_outlet, coalesce(p_date, app.business_date(p_outlet, now())));
  select coalesce(sum(case when e.payment_method::text = 'cash' then e.amount
                           when e.payment_method::text = 'split' then e.split_cash else 0 end), 0),
         coalesce(sum(case when e.payment_method::text = 'paytm' then e.amount
                           when e.payment_method::text = 'split' then e.split_paytm else 0 end), 0),
         coalesce(sum(e.amount) filter (where e.payment_method is null), 0),
         coalesce(sum(e.tip_cash), 0),
         coalesce(sum(e.tip_paytm), 0)
    into v_sc, v_sp, v_su, v_tc, v_tp
    from public.entries e
   where e.kind = 'service'
     and e.id in (select (x ->> 'id')::uuid from jsonb_array_elements(v -> 'entries_snapshot') x);
  -- Everything the counter recorded as received by UPI / Paytm / Card: services (whole and split parts),
  -- products and digital tips. Compared with the Paytm statement total entered at closing, which stays the
  -- authority for the cash check. Only when every service sale has a recorded method, so old rows never raise it.
  v_rec := v_sp + (v ->> 'product_paytm')::bigint + v_tp;
  if (v ->> 'paytm_entered')::boolean and v_su = 0 and v_rec <> (v ->> 'paytm_total')::bigint then
    v := jsonb_set(v, '{warnings}', (v -> 'warnings') || '"paytm_recorded_mismatch"'::jsonb);
  end if;
  return v || jsonb_build_object(
    'service_cash_recorded', v_sc, 'service_paytm_recorded', v_sp, 'service_method_unrecorded', v_su,
    'tips_cash', v_tc, 'tips_paytm', v_tp,
    'paytm_recorded_total', v_rec,
    'paytm_difference', case when (v ->> 'paytm_entered')::boolean then (v ->> 'paytm_total')::bigint - v_rec end);
end;
$$;

-- 4. Daily Sheet opens ---------------------------------------------------------------------------------------
create table public.sheet_opens (
  outlet_id      uuid not null references public.outlets (id),
  business_date  date not null,
  opened_at      timestamptz not null default now(),
  opened_by      uuid not null references public.profiles (id),
  -- Ordering key shared with audit_logs.server_seq: changes with a higher seq came after the opening.
  opened_seq     bigint not null default nextval('app.server_seq'),
  primary key (outlet_id, business_date)
);
comment on table public.sheet_opens is
  'First time each day''s Daily Sheet was opened. Changes to that day after this moment are listed for the owner (sheet_changes). Holds no money.';
create trigger sheet_opens_immutable before update or delete on public.sheet_opens
  for each row execute function app.forbid_mutation();
alter table public.sheet_opens enable row level security;
create policy sheet_opens_select on public.sheet_opens for select to authenticated using (app.is_member(outlet_id));
grant select on public.sheet_opens to authenticated;

-- Records the first opening of a day's sheet (idempotent). Creates no closing, revision, event or notification.
create function public.open_daily_sheet(p_outlet uuid, p_date date)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date;
  v_at    timestamptz;
begin
  perform app.require_permission(p_outlet, 'outlet.read');
  v_today := app.business_date(p_outlet, now());
  if p_date is null or v_today is null or p_date > v_today then
    raise exception 'choose a business date up to %', v_today using errcode = '22023';
  end if;
  insert into public.sheet_opens (outlet_id, business_date, opened_by)
  values (p_outlet, p_date, auth.uid())
  on conflict (outlet_id, business_date) do nothing;
  select opened_at into v_at from public.sheet_opens where outlet_id = p_outlet and business_date = p_date;
  return v_at;
end;
$$;
revoke execute on function public.open_daily_sheet(uuid, date) from public, anon;
grant execute on function public.open_daily_sheet(uuid, date) to authenticated;

-- 5. Sheet changes for the owner (read from the audit log; nothing is copied) -------------------------------
-- Section total (paise) of one day's active entries as the audit log stood at p_seq.
-- p_key narrows it: service → staff_id, food → meal; NULL = whole section.
create function app.sheet_total_at(p_outlet uuid, p_date date, p_kind text, p_key text, p_seq bigint)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum((x.n ->> 'amount')::bigint), 0)
  from (
    select distinct on (a.row_id) a.new_data n
    from public.audit_logs a
    where a.table_name = 'entries' and a.outlet_id = p_outlet and a.server_seq <= p_seq
      and a.row_id in (select id from public.entries where outlet_id = p_outlet and business_date = p_date and kind::text = p_kind)
    order by a.row_id, a.server_seq desc
  ) x
  where x.n ->> 'status' = 'active' and x.n ->> 'business_date' = p_date::text
    and (p_key is null or x.n ->> (case p_kind when 'service' then 'staff_id' else 'meal' end) = p_key)
$$;
revoke execute on function app.sheet_total_at(uuid, date, text, text, bigint) from public, anon, authenticated;

-- Every Register addition, correction or removal to a day made after that day's sheet was opened, newest
-- first, one item per audit row (so never duplicated), in every outlet where the caller holds audit.read.
create function public.sheet_changes(p_limit integer default 200)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v jsonb;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  with ch as (
    select a.id, a.server_seq, a.at, a.actor, a.reason, a.outlet_id, a.old_data o, a.new_data n,
           (a.new_data ->> 'business_date')::date bdate, a.new_data ->> 'kind' kind,
           case when a.action = 'INSERT' or a.old_data ->> 'business_date' is null then 'added'
                when a.old_data ->> 'status' = 'active' and a.new_data ->> 'status' = 'voided' then 'removed'
                else 'corrected' end act
    from public.audit_logs a
    join public.sheet_opens s on s.outlet_id = a.outlet_id and s.business_date = (a.new_data ->> 'business_date')::date
    where a.table_name = 'entries' and a.server_seq > s.opened_seq and app.has_permission(a.outlet_id, 'audit.read')
    order by a.server_seq desc
    limit greatest(1, least(coalesce(p_limit, 200), 1000))
  ), keyed as (
    select ch.*,
           case ch.kind when 'service' then ch.o ->> 'staff_id' when 'food' then ch.o ->> 'meal' end k_old,
           case ch.kind when 'service' then ch.n ->> 'staff_id' when 'food' then ch.n ->> 'meal' end k_new
    from ch
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', k.id, 'at', k.at, 'business_date', k.bdate, 'outlet', ou.name, 'section', k.kind, 'action', k.act,
      'actor', pr.full_name, 'reason', k.reason, 'late', (k.n ->> 'late')::boolean,
      'employee_old', so.full_name, 'employee_new', sn.full_name,
      'old', case when k.act = 'added' then null else k.o end,
      'new', k.n,
      'totals', (
        select jsonb_agg(jsonb_build_object(
          'label', case when k.kind = 'service' then st.full_name when k.kind = 'food' then g.key else null end,
          'before', app.sheet_total_at(k.outlet_id, k.bdate, k.kind, g.key, k.server_seq - 1),
          'after', app.sheet_total_at(k.outlet_id, k.bdate, k.kind, g.key, k.server_seq)))
        from (select distinct x.key from unnest(array[coalesce(k.k_old, k.k_new), k.k_new]) x(key)) g
        left join public.staff st on k.kind = 'service' and st.id::text = g.key)
    ) order by k.server_seq desc), '[]'::jsonb)
  into v
  from keyed k
  join public.outlets ou on ou.id = k.outlet_id
  left join public.profiles pr on pr.id = k.actor
  left join public.staff so on k.kind = 'service' and so.id = (k.o ->> 'staff_id')::uuid
  left join public.staff sn on k.kind = 'service' and sn.id = (k.n ->> 'staff_id')::uuid;
  return v;
end;
$$;
revoke execute on function public.sheet_changes(integer) from public, anon;
grant execute on function public.sheet_changes(integer) to authenticated;
