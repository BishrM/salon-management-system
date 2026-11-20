-- Client feature 4 (2026-11-20): every service sale records how it was paid — Cash or UPI / Paytm / Card.
--
-- Reuses public.payment_method ('cash' | 'paytm'): UPI and card stay combined under Paytm (Rev 6 §5.4),
-- so no new channel is introduced. The closing formulas are unchanged: physical cash still uses the Paytm
-- total entered at closing (from the Paytm statement). The recorded split is reported next to it by
-- day_summary, with a warning when the counter's record and the entered Paytm total disagree.
--
--   * entries: service rows may carry payment_method. Service rows created before this migration keep NULL
--     ("not recorded"); the RPC requires it on every new service sale and on every service correction.
--   * correct_entry may change a service sale's payment_method (audited like any correction).
--   * commission is untouched: it is computed from service amounts only, whatever the payment method.

alter table public.entries drop constraint entries_kind_columns;
alter table public.entries add constraint entries_kind_columns check (
  case kind
    when 'service' then
      staff_id is not null and product_id is null and product_name is null and quantity is null
      and unit_price is null and expense_source is null and meal is null
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
);
comment on column public.entries.payment_method is
  'product and service: cash | paytm (UPI / Paytm / card). NULL only on service rows recorded before 2026-11-20.';

create function app.payment_method(p jsonb)
returns text
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p ->> 'payment_method' is null or (p ->> 'payment_method') not in ('cash', 'paytm') then
    raise exception 'choose how it was paid: cash, or UPI / Paytm / card' using errcode = '22023';
  end if;
  return p ->> 'payment_method';
end;
$$;
revoke execute on function app.payment_method(jsonb) from public, anon, authenticated;

-- Same as …000800 except: service requires and returns payment_method; product uses the shared check.
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
begin
  case p_kind
    when 'service' then
      v_staff := nullif(p ->> 'staff_id', '')::uuid;
      if v_staff is null or not app.staff_assigned(v_staff, p_outlet, v_date) then
        raise exception 'choose an employee working at this outlet on %', v_date using errcode = '22023';
      end if;
      return jsonb_build_object('amount', app.money(p, 'amount', 'Amount'), 'staff_id', v_staff,
        'payment_method', app.payment_method(p));
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

-- Same as …000800 except: a service correction may change payment_method.
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
    when 'service' then array['amount', 'staff_id', 'payment_method']
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

-- day_summary: the same day as compute_day (same entry set, from its snapshot) plus the counter's
-- recorded service split. Read-only; compute_day, closing revisions and submission rules are unchanged.
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
begin
  perform app.require_permission(p_outlet, 'outlet.read');
  v := app.compute_day(p_outlet, coalesce(p_date, app.business_date(p_outlet, now())));
  select coalesce(sum(e.amount) filter (where e.payment_method = 'cash'), 0),
         coalesce(sum(e.amount) filter (where e.payment_method = 'paytm'), 0),
         coalesce(sum(e.amount) filter (where e.payment_method is null), 0)
    into v_sc, v_sp, v_su
    from public.entries e
   where e.kind = 'service'
     and e.id in (select (x ->> 'id')::uuid from jsonb_array_elements(v -> 'entries_snapshot') x);
  -- Digital reconciliation: counter-recorded Paytm (services + products) vs the Paytm total entered
  -- at closing. Only when every service sale has a recorded method, so old rows never raise it.
  if (v ->> 'paytm_entered')::boolean and v_su = 0
     and v_sp + (v ->> 'product_paytm')::bigint <> (v ->> 'paytm_total')::bigint then
    v := jsonb_set(v, '{warnings}', (v -> 'warnings') || '"paytm_recorded_mismatch"'::jsonb);
  end if;
  return v || jsonb_build_object(
    'service_cash_recorded', v_sc, 'service_paytm_recorded', v_sp, 'service_method_unrecorded', v_su,
    'paytm_recorded_total', v_sp + (v ->> 'product_paytm')::bigint);
end;
$$;
