-- M2/M4 engine: business dates, untrusted-timestamp classification, register ops, sync_ops
-- (Rev 6 §3.2, §6.3, §6.4). Error codes:
--   42501 permission denied · 22023 invalid input · SO409 version conflict · SO423 day locked

-- Business date of an instant: local wall time minus the outlet's cutoff (O6/F5).
create function app.business_date(p_outlet uuid, p_at timestamptz)
returns date
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz  text;
  v_cut time;
begin
  select timezone, day_cutoff into v_tz, v_cut from public.outlets where id = p_outlet;
  if v_cut is null then
    raise exception 'setup incomplete: the business-day cutoff has not been set for this outlet'
      using errcode = '22023';
  end if;
  return ((p_at at time zone v_tz) - v_cut::interval)::date;
end;
$$;

create function app.closing_of(p_outlet uuid, p_date date)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.daily_closings where outlet_id = p_outlet and business_date = p_date
$$;

-- Lifecycle state + current revision of a closing (F1).
create function app.state_of(p_closing uuid, out state text, out revision_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select
    coalesce((select e.type from public.closing_events e
              where e.closing_id = p_closing and e.type in ('submitted', 'approved', 'rejected', 'reopened')
              order by e.server_seq desc limit 1), 'draft'),
    (select r.id from public.closing_revisions r where r.closing_id = p_closing order by r.revision_no desc limit 1)
$$;

-- Current revision of the day when it is frozen (submitted or approved), else NULL (§5.6).
create function app.frozen_revision(p_outlet uuid, p_date date)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_closing uuid := app.closing_of(p_outlet, p_date);
  s record;
begin
  if v_closing is null then return null; end if;
  select * into s from app.state_of(v_closing);
  if s.state in ('submitted', 'approved') then return s.revision_id; end if;
  return null;
end;
$$;

create function app.late_decision(p_kind text, p_id uuid, out decision text, out at timestamptz, out seq bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select r.decision, r.at, r.server_seq from public.late_entry_reviews r
  where r.entry_kind = p_kind and r.entry_id = p_id
  order by r.server_seq desc limit 1
$$;

-- §6.3 classification. Thresholds come from the outlet (G4); comparisons are inclusive.
--   estimate = device_time + device_offset_ms;  Δ = received_at − estimate (signed)
--   |Δ| ≤ online_window_s                      → online, date from received_at
--   Δ < −online_window_s                       → future_time + timestamp_suspect (Unassigned)
--   bounds [lower, upper] inside one day       → offline_bounded
--   bounds span days, estimate inside bounds   → estimate's day, flag estimated_date
--   otherwise                                  → timestamp_suspect, business_date NULL (Unassigned)
-- lower = least(server last contact before this batch, device's own last-sync time); upper = received_at.
create function app.classify_time(
  p_outlet uuid, p_device uuid, p_device_seq bigint,
  p_device_time timestamptz, p_offset_ms bigint, p_last_sync timestamptz,
  p_lower timestamptz, p_received timestamptz,
  out business_date date, out basis public.date_basis, out flags text[],
  out bound_lower timestamptz, out bound_upper timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  o         public.outlets;
  v_est     timestamptz;
  v_delta   numeric;
  v_suspect boolean := false;
begin
  select * into o from public.outlets where id = p_outlet;
  flags := '{}';
  bound_upper := p_received;
  bound_lower := case
    when p_lower is null then p_last_sync
    when p_last_sync is null then p_lower
    else least(p_lower, p_last_sync) end;

  if p_offset_ms is not null and abs(p_offset_ms) > o.clock_warn_s::bigint * 1000 then
    flags := flags || 'clock_offset'::text;
  end if;

  if p_device_time is not null and p_offset_ms is not null then
    v_est := p_device_time + make_interval(secs => p_offset_ms / 1000.0);
    v_delta := extract(epoch from (p_received - v_est));
    if abs(v_delta) <= o.online_window_s then
      business_date := app.business_date(p_outlet, p_received);
      basis := 'online';
      return;
    end if;
    if v_delta < -o.online_window_s then
      flags := flags || 'future_time'::text;
      v_suspect := true;
    end if;
    if v_delta > o.gap_flag_h::numeric * 3600 then
      flags := flags || 'long_gap'::text;
    end if;
  end if;

  -- Within one device, device_seq gives a trustworthy order: a clock that runs backwards relative to an
  -- earlier op of the same device (beyond the online window) is suspect.
  if p_device is not null and p_device_time is not null and exists (
    select 1 from public.sync_ops s
    where s.device_id = p_device and s.device_seq < p_device_seq and s.status = 'applied'
      and s.device_time > p_device_time + make_interval(secs => o.online_window_s)
  ) then
    flags := flags || 'seq_order'::text;
    v_suspect := true;
  end if;

  if not v_suspect and bound_lower is not null
     and app.business_date(p_outlet, bound_lower) = app.business_date(p_outlet, bound_upper) then
    business_date := app.business_date(p_outlet, bound_upper);
    basis := 'offline_bounded';
    return;
  end if;

  if not v_suspect and v_est is not null and bound_lower is not null
     and v_est between bound_lower and bound_upper then
    business_date := app.business_date(p_outlet, v_est);
    basis := 'offline_bounded';
    flags := flags || 'estimated_date'::text;
    return;
  end if;

  flags := flags || 'timestamp_suspect'::text;
  business_date := null;
  basis := null;
end;
$$;

-- Register ops ------------------------------------------------------------------------------------------
create function app.money(p jsonb, p_key text, p_label text)
returns bigint
language plpgsql
immutable
set search_path = ''
as $$
declare
  v bigint;
begin
  if p ->> p_key is null or (p ->> p_key) !~ '^[0-9]+$' then
    raise exception '% must be a whole number of paise', p_label using errcode = '22023';
  end if;
  v := (p ->> p_key)::bigint;
  if v <= 0 or v % 100 <> 0 or v > 100000000 then
    raise exception '% must be a whole-rupee amount between ₹1 and ₹10,00,000', p_label using errcode = '22023';
  end if;
  return v;
end;
$$;

create function app.require_keys(p jsonb, p_allowed text[])
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_bad text;
begin
  select string_agg(k, ', ') into v_bad from jsonb_object_keys(coalesce(p, '{}')) k where k <> all (p_allowed);
  if v_bad is not null then
    raise exception 'unexpected field(s): %', v_bad using errcode = '22023';
  end if;
end;
$$;

-- Validated, server-normalised entry values for a kind (used by create and correct).
create function app.entry_values(p_outlet uuid, p_kind public.entry_kind, p jsonb, p_date date)
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
begin
  case p_kind
    when 'service' then
      v_staff := nullif(p ->> 'staff_id', '')::uuid;
      if v_staff is null or not app.staff_assigned(v_staff, p_outlet, v_date) then
        raise exception 'choose an employee working at this outlet on %', v_date using errcode = '22023';
      end if;
      return jsonb_build_object('amount', app.money(p, 'amount', 'Amount'), 'staff_id', v_staff);
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
      if (p ->> 'payment_method') not in ('cash', 'paytm') or p ->> 'payment_method' is null then
        raise exception 'payment method must be cash or paytm' using errcode = '22023';
      end if;
      return jsonb_build_object(
        'product_id', v_prod.id, 'product_name', v_prod.name, 'quantity', v_qty, 'unit_price', v_price,
        'amount', v_qty::bigint * v_price, 'payment_method', p ->> 'payment_method');
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

create function app.op_create_entry(p_outlet uuid, p_device uuid, p_op jsonb, p_lower timestamptz)
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
  v_plate uuid;
begin
  -- product_name is accepted for the device's own display but ignored: the name is snapshotted from the catalogue.
  perform app.require_keys(v_data, array['kind', 'amount', 'staff_id', 'product_id', 'product_name', 'quantity',
    'unit_price', 'payment_method', 'description', 'notes', 'expense_source', 'meal', 'pay_now', 'payment_id']);
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
    business_date, date_basis, timestamp_flags, late, late_against_revision_id
  ) values (
    v_id, p_outlet, v_kind, (v_vals ->> 'amount')::bigint, (v_vals ->> 'staff_id')::uuid,
    (v_vals ->> 'product_id')::uuid, v_vals ->> 'product_name', (v_vals ->> 'quantity')::int,
    (v_vals ->> 'unit_price')::bigint, (v_vals ->> 'payment_method')::public.payment_method,
    (v_vals ->> 'expense_source')::public.expense_source, (v_vals ->> 'meal')::public.meal,
    v_vals ->> 'description', v_vals ->> 'notes', auth.uid(), p_device, (p_op ->> 'op_id')::uuid,
    (p_op ->> 'device_time')::timestamptz, (p_op ->> 'device_offset_ms')::bigint,
    (p_op ->> 'device_last_sync_at')::timestamptz, v_cls.bound_lower, v_cls.bound_upper,
    v_cls.business_date, v_cls.basis, v_cls.flags, v_late is not null, v_late
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

-- Lock an entry for change: same outlet, active, expected version, day not frozen.
create function app.lock_entry_for_change(p_outlet uuid, p_op jsonb)
returns public.entries
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.entries;
begin
  select * into e from public.entries where id = (p_op ->> 'record_id')::uuid for update;
  if e.id is null or e.outlet_id <> p_outlet then
    raise exception 'entry not found in this outlet' using errcode = '22023';
  end if;
  if e.status <> 'active' then
    raise exception 'entry is already voided' using errcode = 'SO409';
  end if;
  if (p_op ->> 'base_version') is null or (p_op ->> 'base_version')::int <> e.version then
    raise exception 'entry was changed elsewhere (now version %); review it before changing again', e.version
      using errcode = 'SO409';
  end if;
  if e.business_date is not null and app.frozen_revision(p_outlet, e.business_date) is not null then
    raise exception 'the closing for % is submitted or approved; ask management to reopen it first', e.business_date
      using errcode = 'SO423';
  end if;
  return e;
end;
$$;

create function app.op_correct_entry(p_outlet uuid, p_op jsonb)
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
    when 'service' then array['amount', 'staff_id']
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
      'notes', e.notes, 'expense_source', e.expense_source, 'meal', e.meal)) || v_data;
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
    version = version + 1,
    updated_at = now(),
    updated_by = auth.uid()
  where id = e.id;
  return jsonb_build_object('id', e.id, 'version', e.version + 1, 'amount', (v_vals ->> 'amount')::bigint);
end;
$$;

create function app.op_void_entry(p_outlet uuid, p_op jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  e        public.entries;
  v_reason text := app.require_reason(p_op ->> 'reason');
begin
  e := app.lock_entry_for_change(p_outlet, p_op);
  perform app.set_audit_context(v_reason);
  update public.entries
     set status = 'voided', void_reason = v_reason, version = version + 1, updated_at = now(), updated_by = auth.uid()
   where id = e.id;
  return jsonb_build_object('id', e.id, 'version', e.version + 1, 'status', 'voided');
end;
$$;

create function app.op_food_payment(p_outlet uuid, p_device uuid, p_op jsonb, p_lower timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_data jsonb := coalesce(p_op -> 'data', '{}');
  v_food public.entries;
  v_cls  record;
  v_late uuid;
  v_amt  bigint;
  v_paid bigint;
  v_id   uuid := (p_op ->> 'record_id')::uuid;
begin
  perform app.require_keys(v_data, array['food_id', 'amount', 'paid_from']);
  if v_id is null then raise exception 'record_id is required' using errcode = '22023'; end if;
  -- Row lock serialises concurrent payments for the same food entry (J2).
  select * into v_food from public.entries
   where id = nullif(v_data ->> 'food_id', '')::uuid and outlet_id = p_outlet and kind = 'food' for update;
  if v_food.id is null or v_food.status <> 'active' then
    raise exception 'food entry not found or voided' using errcode = '22023';
  end if;
  if coalesce(v_data ->> 'paid_from', '') not in ('drawer', 'outside_drawer') then
    raise exception 'paid_from must be drawer or outside_drawer' using errcode = '22023';
  end if;
  v_amt := app.money(v_data, 'amount', 'Payment');
  select coalesce(sum(case when reverses_payment_id is null then amount else -amount end), 0) into v_paid
    from public.food_payments where food_id = v_food.id;
  if v_paid + v_amt > v_food.amount then
    raise exception 'payment ₹% exceeds the unpaid food cost ₹%', v_amt / 100, (v_food.amount - v_paid) / 100
      using errcode = '22023';
  end if;
  select * into v_cls from app.classify_time(
    p_outlet, p_device, (p_op ->> 'device_seq')::bigint,
    (p_op ->> 'device_time')::timestamptz, (p_op ->> 'device_offset_ms')::bigint,
    (p_op ->> 'device_last_sync_at')::timestamptz, p_lower, now());
  if v_cls.business_date is not null then
    v_late := app.frozen_revision(p_outlet, v_cls.business_date);
  end if;
  insert into public.food_payments (
    id, outlet_id, food_id, amount, paid_from, recorded_by, device_id, op_id,
    device_time, device_offset_ms, device_last_sync_at, bound_lower, bound_upper,
    business_date, date_basis, timestamp_flags, late, late_against_revision_id
  ) values (
    v_id, p_outlet, v_food.id, v_amt, v_data ->> 'paid_from', auth.uid(), p_device, (p_op ->> 'op_id')::uuid,
    (p_op ->> 'device_time')::timestamptz, (p_op ->> 'device_offset_ms')::bigint,
    (p_op ->> 'device_last_sync_at')::timestamptz, v_cls.bound_lower, v_cls.bound_upper,
    v_cls.business_date, v_cls.basis, v_cls.flags, v_late is not null, v_late
  );
  return jsonb_build_object('id', v_id, 'business_date', v_cls.business_date, 'late', v_late is not null,
    'flags', to_jsonb(v_cls.flags));
end;
$$;

create function app.op_reverse_food_payment(p_outlet uuid, p_device uuid, p_op jsonb, p_lower timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_data   jsonb := coalesce(p_op -> 'data', '{}');
  v_orig   public.food_payments;
  v_reason text := app.require_reason(p_op ->> 'reason');
  v_cls    record;
  v_late   uuid;
  v_id     uuid := (p_op ->> 'record_id')::uuid;
begin
  perform app.require_keys(v_data, array['payment_id']);
  if v_id is null then raise exception 'record_id is required' using errcode = '22023'; end if;
  select * into v_orig from public.food_payments
   where id = nullif(v_data ->> 'payment_id', '')::uuid and outlet_id = p_outlet;
  if v_orig.id is null or v_orig.reverses_payment_id is not null then
    raise exception 'payment not found (or it is itself a reversal)' using errcode = '22023';
  end if;
  perform 1 from public.entries where id = v_orig.food_id for update;
  if exists (select 1 from public.food_payments where reverses_payment_id = v_orig.id) then
    raise exception 'payment is already reversed' using errcode = 'SO409';
  end if;
  select * into v_cls from app.classify_time(
    p_outlet, p_device, (p_op ->> 'device_seq')::bigint,
    (p_op ->> 'device_time')::timestamptz, (p_op ->> 'device_offset_ms')::bigint,
    (p_op ->> 'device_last_sync_at')::timestamptz, p_lower, now());
  if v_cls.business_date is not null then
    v_late := app.frozen_revision(p_outlet, v_cls.business_date);
  end if;
  perform app.set_audit_context(v_reason);
  insert into public.food_payments (
    id, outlet_id, food_id, amount, paid_from, reverses_payment_id, reason, recorded_by, device_id, op_id,
    device_time, device_offset_ms, device_last_sync_at, bound_lower, bound_upper,
    business_date, date_basis, timestamp_flags, late, late_against_revision_id
  ) values (
    v_id, p_outlet, v_orig.food_id, v_orig.amount, v_orig.paid_from, v_orig.id, v_reason, auth.uid(), p_device,
    (p_op ->> 'op_id')::uuid,
    (p_op ->> 'device_time')::timestamptz, (p_op ->> 'device_offset_ms')::bigint,
    (p_op ->> 'device_last_sync_at')::timestamptz, v_cls.bound_lower, v_cls.bound_upper,
    v_cls.business_date, v_cls.basis, v_cls.flags, v_late is not null, v_late
  );
  return jsonb_build_object('id', v_id, 'business_date', v_cls.business_date, 'late', v_late is not null);
end;
$$;

-- sync_ops (§6.4): the single write path for register data, online and offline.
--   * per-device row lock serialises batches from one device (retries, several tabs);
--   * ops applied in device_seq order, each in its own subtransaction;
--   * (device, seq) or op_id seen before with the same payload → idempotent replay of the stored result;
--     with a different payload → stored as a conflict, never applied;
--   * an op whose record has an earlier unresolved failure/conflict on this device is returned as
--     'blocked' (not stored) so the device keeps it and retries after resolution.
create function public.sync_ops(p_outlet uuid, p_device uuid, p_device_label text, p_ops jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dev      public.devices;
  v_lower    timestamptz;
  v_op       jsonb;
  v_hash     text;
  v_prev     public.sync_ops;
  v_result   jsonb;
  v_results  jsonb := '[]';
  v_seq      bigint;
  v_contig   bigint;
  v_gaps     jsonb;
  v_type     text;
  v_state    text;
  v_code     text;
  v_msg      text;
begin
  perform app.require_permission(p_outlet, 'entries.record');
  if p_device is null then
    raise exception 'device id is required' using errcode = '22023';
  end if;
  if jsonb_typeof(p_ops) is distinct from 'array' or jsonb_array_length(p_ops) > 200 then
    raise exception 'ops must be an array of at most 200 operations' using errcode = '22023';
  end if;

  insert into public.devices (id, outlet_id, label, registered_by)
  values (p_device, p_outlet, left(p_device_label, 80), auth.uid())
  on conflict (id) do nothing;
  select * into v_dev from public.devices where id = p_device for update;
  v_lower := v_dev.last_contact_at;

  for v_op in select value from jsonb_array_elements(p_ops) order by (value ->> 'device_seq')::bigint loop
    v_hash := md5(v_op::text);
    v_type := v_op ->> 'type';
    v_seq := nullif(v_op ->> 'device_seq', '')::bigint;
    v_result := null;

    if v_seq is null or v_seq <= 0 or (v_op ->> 'op_id') is null
       or (v_op ->> 'op_id') !~* '^[0-9a-f-]{36}$' or (v_op ->> 'record_id') !~* '^[0-9a-f-]{36}$' then
      v_results := v_results || jsonb_build_object('op_id', v_op ->> 'op_id', 'device_seq', v_seq,
        'status', 'failed', 'error_code', '22023', 'error', 'malformed op');
      continue;
    end if;

    select * into v_prev from public.sync_ops
     where status <> 'conflict'
       and ((device_id = p_device and device_seq = v_seq) or op_id = (v_op ->> 'op_id')::uuid)
     order by id limit 1;
    if v_prev.id is not null then
      if v_prev.op_id = (v_op ->> 'op_id')::uuid and v_prev.device_id = p_device
         and v_prev.device_seq = v_seq and v_prev.payload_hash = v_hash then
        v_results := v_results || jsonb_build_object('op_id', v_prev.op_id, 'device_seq', v_seq,
          'status', v_prev.status, 'result', v_prev.result, 'error_code', v_prev.error_code,
          'error', v_prev.error_message, 'duplicate', true);
      else
        insert into public.sync_ops (op_id, device_id, device_seq, outlet_id, op_type, record_id, payload,
          payload_hash, device_time, status, error_code, error_message, submitted_by)
        values ((v_op ->> 'op_id')::uuid, p_device, v_seq, p_outlet, coalesce(v_type, '?'),
          (v_op ->> 'record_id')::uuid, v_op, v_hash, (v_op ->> 'device_time')::timestamptz, 'conflict',
          'SO409', 'device sequence or op id reused with different content', auth.uid());
        v_results := v_results || jsonb_build_object('op_id', v_op ->> 'op_id', 'device_seq', v_seq,
          'status', 'conflict', 'error_code', 'SO409',
          'error', 'device sequence or op id reused with different content');
      end if;
      continue;
    end if;

    if exists (
      select 1 from public.sync_ops s
      where s.device_id = p_device and s.record_id = (v_op ->> 'record_id')::uuid
        and s.device_seq < v_seq and s.status <> 'applied' and s.resolved_at is null
    ) or (
      -- Out-of-order arrival: a change to an entry whose create has not arrived yet waits (not stored).
      v_type in ('correct_entry', 'void_entry')
      and not exists (select 1 from public.entries where id = (v_op ->> 'record_id')::uuid)
    ) then
      v_results := v_results || jsonb_build_object('op_id', v_op ->> 'op_id', 'device_seq', v_seq,
        'status', 'blocked', 'error', 'waiting for an earlier operation on this record (missing or unresolved)');
      continue;
    end if;

    begin
      perform set_config('app.op_id', v_op ->> 'op_id', true);
      perform set_config('app.reason', '', true);
      v_result := case v_type
        when 'create_entry'         then app.op_create_entry(p_outlet, p_device, v_op, v_lower)
        when 'correct_entry'        then app.op_correct_entry(p_outlet, v_op)
        when 'void_entry'           then app.op_void_entry(p_outlet, v_op)
        when 'food_payment'         then app.op_food_payment(p_outlet, p_device, v_op, v_lower)
        when 'reverse_food_payment' then app.op_reverse_food_payment(p_outlet, p_device, v_op, v_lower)
        else null end;
      if v_result is null then
        raise exception 'unknown op type %', coalesce(v_type, '(none)') using errcode = '22023';
      end if;
      -- Surface deferred constraint violations (food paid ≤ cost) inside this op's subtransaction.
      set constraints all immediate;
      set constraints all deferred;
      insert into public.sync_ops (op_id, device_id, device_seq, outlet_id, op_type, record_id, payload,
        payload_hash, device_time, status, result, submitted_by)
      values ((v_op ->> 'op_id')::uuid, p_device, v_seq, p_outlet, v_type, (v_op ->> 'record_id')::uuid,
        v_op, v_hash, (v_op ->> 'device_time')::timestamptz, 'applied', v_result, auth.uid());
      v_results := v_results || jsonb_build_object('op_id', v_op ->> 'op_id', 'device_seq', v_seq,
        'status', 'applied', 'result', v_result);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      v_code := v_state;
      insert into public.sync_ops (op_id, device_id, device_seq, outlet_id, op_type, record_id, payload,
        payload_hash, device_time, status, error_code, error_message, submitted_by)
      values ((v_op ->> 'op_id')::uuid, p_device, v_seq, p_outlet, coalesce(v_type, '?'),
        (v_op ->> 'record_id')::uuid, v_op, v_hash, (v_op ->> 'device_time')::timestamptz,
        case when v_code = 'SO409' then 'conflict' else 'failed' end, v_code, v_msg, auth.uid());
      v_results := v_results || jsonb_build_object('op_id', v_op ->> 'op_id', 'device_seq', v_seq,
        'status', case when v_code = 'SO409' then 'conflict' else 'failed' end,
        'error_code', v_code, 'error', v_msg);
    end;
  end loop;

  perform set_config('app.op_id', '', true);
  perform set_config('app.reason', '', true);

  -- Highest contiguous seq received from this device, and the gaps below the highest seq seen.
  with s as (select distinct device_seq from public.sync_ops where device_id = p_device and status <> 'conflict'),
       r as (select device_seq, row_number() over (order by device_seq) rn from s)
  select coalesce(max(device_seq), 0) into v_contig from r where device_seq = rn;
  select coalesce(jsonb_agg(g order by g), '[]') into v_gaps
    from generate_series(v_contig + 1,
      coalesce((select max(device_seq) from public.sync_ops where device_id = p_device and status <> 'conflict'), 0)) g
   where not exists (select 1 from public.sync_ops where device_id = p_device and device_seq = g and status <> 'conflict');

  update public.devices
     set last_contact_at = now(), last_synced_seq = greatest(last_synced_seq, v_contig)
   where id = p_device;

  return jsonb_build_object('results', v_results, 'server_time', now(), 'last_synced_seq', v_contig,
    'gaps', v_gaps);
end;
$$;

-- Management resolution of a failed/conflicting op (§6.1: any resolution needs a recorded reason).
create function public.resolve_sync_issue(p_sync_op bigint, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.sync_ops;
  v_note text;
begin
  select * into s from public.sync_ops where id = p_sync_op for update;
  if s.id is null then raise exception 'permission denied' using errcode = '42501'; end if;
  perform app.require_permission(s.outlet_id, 'sync.manage');
  v_note := app.require_reason(p_note);
  if s.status = 'applied' then raise exception 'applied ops need no resolution' using errcode = '22023'; end if;
  perform app.set_audit_context(v_note);
  update public.sync_ops set resolved_at = now(), resolved_by = auth.uid(), resolution_note = v_note
   where id = p_sync_op;
end;
$$;

-- Management assigns a business date to an Unassigned row (§6.3).
create function public.assign_business_date(p_kind text, p_id uuid, p_date date, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outlet uuid;
  v_date   date;
  v_reason text;
  v_late   uuid;
begin
  if p_kind = 'entry' then
    select outlet_id, business_date into v_outlet, v_date from public.entries where id = p_id for update;
  elsif p_kind = 'food_payment' then
    select outlet_id, business_date into v_outlet, v_date from public.food_payments where id = p_id for update;
  else
    raise exception 'kind must be entry or food_payment' using errcode = '22023';
  end if;
  perform app.require_permission(v_outlet, 'date.assign');
  v_reason := app.require_reason(p_reason);
  if v_date is not null then raise exception 'row already has a business date' using errcode = '22023'; end if;
  if p_date is null then raise exception 'date is required' using errcode = '22023'; end if;
  v_late := app.frozen_revision(v_outlet, p_date);
  perform app.set_audit_context(v_reason);
  if p_kind = 'entry' then
    update public.entries set business_date = p_date, date_basis = 'management_assigned',
           late = v_late is not null, late_against_revision_id = v_late where id = p_id;
  else
    update public.food_payments set business_date = p_date, date_basis = 'management_assigned',
           late = v_late is not null, late_against_revision_id = v_late where id = p_id;
  end if;
end;
$$;
