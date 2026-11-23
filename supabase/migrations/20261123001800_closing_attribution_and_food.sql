-- Closing attribution and revised food accounting (client, 2026-11-23; DECISIONS D-30, D-31).
--
-- 1. "Who performed the closing?": the draft and each immutable revision store the employee
--    (closed_by_staff_id). Required to submit (blocker closing_employee_missing) and valid only if the
--    employee was assigned to the outlet and not yet deactivated on the business date
--    (closing_employee_invalid). It is an attribution field: the actor stays the authenticated login
--    (submitted_by, closing_events.actor, audit_logs.actor). Earlier revisions keep NULL.
--
-- 2. Food from outlets.food_rule_v2_from (set to the day this migration runs; earlier days unchanged):
--      B   = breakfast (salon expense)                     -> food_breakfast_salon, food_shop_funded = B
--      LD  = lunch + dinner = F − B (deducted from commission)
--      FC  = min(LD, C)                                    -> food_commission_funded
--      OW  = LD − FC (owed to the salon by the employees)  -> food_employee_owed
--      final balance = C − LD = remaining_payable − OW     (negative = owed to the salon)
--    The commission pool, rounding, payable (C − FC), drawer formula (ED) and SRS net cash are unchanged;
--    the bridge identity now also subtracts OW, so it still holds exactly. OW is outlet-level: there is
--    no rule for which employee owes it, so none is assigned to anyone. The food-excess approval step
--    no longer applies to these days.
--
-- 3. Repayments of OW are recorded separately (food_repayments): received by the owner outside the
--    drawer, never part of any closing or drawer figure. Outstanding = OW of approved closings − net
--    repayments. Insert-only; a mistake is corrected by a reversal row with a reason.

-- Columns ----------------------------------------------------------------------------------------------
alter table public.outlets
  add column food_rule_v2_from date not null default ((now() at time zone 'Asia/Kolkata')::date);
comment on column public.outlets.food_rule_v2_from is
  'First business date of the revised food rule (breakfast salon-funded; excess owed by employees). D-31.';

alter table public.closing_drafts add column closed_by_staff_id uuid references public.staff (id);

alter table public.closing_revisions
  add column closed_by_staff_id   uuid references public.staff (id),
  add column food_breakfast_salon bigint not null default 0,
  add column food_employee_owed   bigint not null default 0;

-- Every new revision names its closing employee; revisions submitted before this migration keep NULL.
alter table public.closing_revisions
  add constraint rev_closed_by check (closed_by_staff_id is not null) not valid;

-- The food split and the drawer bridge include OW (0 on every existing row, so both still hold for them).
alter table public.closing_revisions drop constraint rev_food_split;
alter table public.closing_revisions add constraint rev_food_split check (
  food_commission_funded + food_shop_funded + food_employee_owed = food_cost
  and food_commission_funded between 0 and commission_pool
  and food_shop_funded >= 0 and food_employee_owed >= 0
  and (food_employee_owed = 0 or food_commission_funded = commission_pool)
  and food_breakfast_salon between 0 and food_shop_funded
);
alter table public.closing_revisions drop constraint rev_bridge;
alter table public.closing_revisions add constraint rev_bridge check (
  expected_drawer = opening_float + intraday_top_ups + net_cash + commission_retained
                    + food_not_paid_drawer - food_paid_drawer_prior - food_shop_funded - food_employee_owed
);

-- Live day computation (only the food split, the closing employee and three output keys change). -------
-- Live computation of one business day (§5). Keys match closing_revisions columns so the snapshot
-- can be written with jsonb_populate_record. Also returns allocations, blockers, warnings, state.
create or replace function app.compute_day(p_outlet uuid, p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_closing  uuid := app.closing_of(p_outlet, p_date);
  v_state    text := 'draft';
  v_rev_id   uuid;
  v_cur      public.closing_revisions;
  d          public.closing_drafts;
  v_ids      uuid[];
  v_s bigint; v_c bigint; v_p bigint; v_pc bigint; v_pp bigint; v_e bigint; v_eo bigint; v_z bigint; v_f bigint;
  v_paytm bigint; v_spaytm bigint; v_fc bigint; v_fx bigint; v_payable bigint;
  v_ftoday bigint; v_fprior bigint; v_fp_ids uuid[];
  v_h bigint; v_h_ids uuid[];
  v_init public.float_movements;
  v_prev date; v_prev_rev public.closing_revisions;
  v_r bigint := 0; v_src uuid; v_init_id uuid;
  v_pf bigint; v_pf_ids uuid[]; v_i bigint; v_i_ids uuid[];
  v_o bigint; v_cs bigint; v_n bigint; v_ed bigint; v_cc bigint; v_v bigint;
  v_rf bigint; v_af bigint; v_fs bigint; v_th bigint;
  v_flags text[] := '{}'; v_blockers text[] := '{}'; v_warnings text[] := '{}';
  v_alloc jsonb; v_late uuid[]; v_snap jsonb; v_imported bigint; v_imported_n int;
  v_settle jsonb; v_unassigned int; v_model jsonb;
  v_fb bigint := 0; v_owed bigint := 0; v_rule2 boolean; v_closer uuid;
begin
  if v_closing is not null then
    select s.state, s.revision_id into v_state, v_rev_id from app.state_of(v_closing) s;
    select * into d from public.closing_drafts where closing_id = v_closing;
    select * into v_cur from public.closing_revisions where id = v_rev_id;
  end if;

  -- Entries in the day's totals: active, dated D, not excluded after late review (§5.6).
  select coalesce(array_agg(e.id), '{}') into v_ids
  from public.entries e
  where e.outlet_id = p_outlet and e.business_date = p_date and e.status = 'active'
    and (not e.late or (select decision from app.late_decision('entry', e.id)) is distinct from 'exclude');

  select
    coalesce(sum(amount) filter (where kind = 'service'), 0),
    coalesce(sum(amount) filter (where kind = 'product'), 0),
    coalesce(sum(amount) filter (where kind = 'product' and payment_method = 'cash'), 0),
    coalesce(sum(amount) filter (where kind = 'product' and payment_method = 'paytm'), 0),
    coalesce(sum(amount) filter (where kind = 'expense' and expense_source = 'cash_drawer'), 0),
    coalesce(sum(amount) filter (where kind = 'expense' and expense_source = 'outside_drawer'), 0),
    coalesce(sum(amount) filter (where kind = 'zakat'), 0),
    coalesce(sum(amount) filter (where kind = 'food'), 0),
    coalesce(sum(amount) filter (where kind = 'food' and meal = 'breakfast'), 0),
    coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'amount', amount, 'staff_id', staff_id,
                       'version', version) order by server_seq), '[]'),
    coalesce(array_agg(id) filter (where late), '{}')
  into v_s, v_p, v_pc, v_pp, v_e, v_eo, v_z, v_f, v_fb, v_snap, v_late
  from public.entries where id = any (v_ids);

  -- D1: pool = FLOOR(S × 10% / ₹10) × ₹10 = (S div ₹100) × ₹10, in paise.
  v_c := (v_s / 10000) * 1000;

  -- D1: largest remainder in ₹10 units; ties → higher sales, then staff id.
  with s as (
    select staff_id, sum(amount)::bigint st from public.entries
    where id = any (v_ids) and kind = 'service' group by staff_id
  ), r as (
    select s.*, st / 10000 fl, st % 10000 rem,
           row_number() over (order by st % 10000 desc, st desc, staff_id) rn
    from s
  ), lo as (select (v_c / 1000) - coalesce(sum(fl), 0) n from r)
  select coalesce(jsonb_agg(jsonb_build_object(
           'staff_id', r.staff_id, 'staff_name', st.full_name, 'service_total', r.st,
           'exact_share', r.st / 10,
           'allocated', (r.fl + case when r.rn <= lo.n then 1 else 0 end) * 1000,
           'rounding_adj', (r.fl + case when r.rn <= lo.n then 1 else 0 end) * 1000 - r.st / 10)
         order by st.full_name), '[]')
    into v_alloc
  from r cross join lo join public.staff st on st.id = r.staff_id;

  -- Paytm (§5.4).
  v_paytm := coalesce(d.paytm_total, 0);
  if d.paytm_total is null then v_flags := v_flags || 'paytm_missing'::text; end if;
  if (d.paytm_upi is not null or d.paytm_card is not null)
     and coalesce(d.paytm_upi, 0) + coalesce(d.paytm_card, 0) <> coalesce(d.paytm_total, 0) then
    v_flags := v_flags || 'split_mismatch'::text;
  end if;
  v_spaytm := v_paytm - v_pp;
  if d.paytm_total is not null and v_spaytm < 0 then v_flags := v_flags || 'service_paytm_negative'::text; end if;
  if d.paytm_total is not null and v_spaytm > v_s then v_flags := v_flags || 'service_paytm_exceeds_services'::text; end if;

  -- Food cost allocation. From the outlet's food_rule_v2_from (D-31): breakfast is a salon expense (FX);
  -- lunch and dinner are funded by the pool up to C; any rest is owed to the salon by the employees
  -- (food_employee_owed, outlet level, no approval step). Earlier days keep D2/B6 exactly as before.
  select p_date >= o.food_rule_v2_from into v_rule2 from public.outlets o where o.id = p_outlet;
  if v_rule2 then
    v_fx := v_fb;
    v_fc := least(v_f - v_fb, v_c);
    v_owed := v_f - v_fb - v_fc;
  else
    v_fb := 0;
    if v_f <= v_c then
      v_fc := v_f; v_fx := 0;
    else
      v_fc := v_c; v_fx := v_f - v_c;
      if v_closing is null or not exists (
        select 1 from public.closing_events
        where closing_id = v_closing and type = 'food_excess_allocated'
          and (payload ->> 'food_cost')::bigint = v_f and (payload ->> 'commission_pool')::bigint = v_c
      ) then
        v_blockers := v_blockers || 'food_excess_unallocated'::text;
      end if;
    end if;
  end if;
  v_payable := v_c - v_fc;

  -- Food cash (J2): drawer payments dated D, split by the food entry's day.
  select coalesce(array_agg(fp.id), '{}'),
         coalesce(sum(case when fp.reverses_payment_id is null then fp.amount else -fp.amount end)
                  filter (where fp.food_id = any (v_ids)), 0),
         coalesce(sum(case when fp.reverses_payment_id is null then fp.amount else -fp.amount end)
                  filter (where not (fp.food_id = any (v_ids))), 0)
    into v_fp_ids, v_ftoday, v_fprior
  from public.food_payments fp
  where fp.outlet_id = p_outlet and fp.business_date = p_date and fp.paid_from = 'drawer'
    and (not fp.late or (select decision from app.late_decision('food_payment', fp.id)) is distinct from 'exclude');

  -- Drawer handovers H (J1).
  select coalesce(array_agg(id), '{}'),
         coalesce(sum(case when kind = 'handover' then amount else -amount end), 0)
    into v_h_ids, v_h
  from public.commission_handovers
  where closing_id = v_closing and source = 'drawer' and kind in ('handover', 'return');

  -- Float: R from the previous day's current revision, or the initial float on the first day (§5.3).
  select * into v_init from public.float_movements where outlet_id = p_outlet and type = 'initial_float';
  if v_init.id is null or v_init.effective_business_date > p_date then
    v_blockers := v_blockers || 'initial_float_missing'::text;
  else
    select max(x.d) into v_prev from (
      select business_date d from public.daily_closings
       where outlet_id = p_outlet and business_date < p_date and business_date >= v_init.effective_business_date
      union all
      select business_date from public.entries
       where outlet_id = p_outlet and status = 'active'
         and business_date < p_date and business_date >= v_init.effective_business_date
    ) x;
    if v_prev is null then
      v_r := v_init.amount; v_init_id := v_init.id;
    else
      select r.* into v_prev_rev from public.closing_revisions r
        join public.daily_closings c on c.id = r.closing_id
       where c.outlet_id = p_outlet and c.business_date = v_prev
       order by r.revision_no desc limit 1;
      if v_prev_rev.id is null then
        v_blockers := v_blockers || 'previous_day_not_submitted'::text;
      else
        v_r := v_prev_rev.retained_float; v_src := v_prev_rev.id;
      end if;
    end if;
  end if;

  select coalesce(array_agg(id) filter (where timing = 'pre_opening'), '{}'),
         coalesce(sum(case when reverses_movement_id is null then amount else -amount end)
                  filter (where timing = 'pre_opening'), 0),
         coalesce(array_agg(id) filter (where timing = 'intraday'), '{}'),
         coalesce(sum(case when reverses_movement_id is null then amount else -amount end)
                  filter (where timing = 'intraday'), 0)
    into v_pf_ids, v_pf, v_i_ids, v_i
  from public.float_movements
  where outlet_id = p_outlet and type = 'top_up' and effective_business_date = p_date;

  select f.new_required_float into v_rf from public.float_movements f
   where f.outlet_id = p_outlet and f.type = 'required_float_change' and f.effective_business_date <= p_date
     and f.reverses_movement_id is null
     and not exists (select 1 from public.float_movements x where x.reverses_movement_id = f.id)
   order by f.effective_business_date desc, f.recorded_at desc limit 1;
  v_rf := coalesce(v_rf, v_init.amount, 0);

  -- Cash model (§5.3, J1) — the single implementation of the formulas.
  v_cc := app.denom_total(d.denominations);
  v_model := app.cash_model(jsonb_build_object(
    'R', v_r, 'PF', v_pf, 'I', v_i, 'S', v_s, 'P', v_p, 'paytm', v_paytm, 'E', v_e, 'Z', v_z, 'F', v_f,
    'f_today', v_ftoday, 'f_prior', v_fprior, 'H', v_h, 'CC', v_cc, 'RF', v_rf));
  v_o  := (v_model ->> 'O')::bigint;
  v_cs := (v_model ->> 'CS')::bigint;
  v_n  := (v_model ->> 'N')::bigint;
  v_ed := (v_model ->> 'ED')::bigint;
  v_v  := (v_model ->> 'V')::bigint;
  v_af := (v_model ->> 'AF')::bigint;
  v_fs := (v_model ->> 'FS')::bigint;
  v_th := (v_model ->> 'TH')::bigint;

  -- Blockers and warnings.
  if v_state not in ('draft', 'rejected', 'reopened') then v_blockers := v_blockers || 'closing_frozen'::text; end if;
  if 'paytm_missing' = any (v_flags) then v_blockers := v_blockers || 'paytm_missing'::text; end if;
  if 'split_mismatch' = any (v_flags) then v_blockers := v_blockers || 'split_mismatch'::text; end if;
  if d.closing_id is null or d.denominations = '{}'::jsonb then v_blockers := v_blockers || 'count_missing'::text; end if;
  if v_v <> 0 and length(btrim(coalesce(d.variance_reason, ''))) = 0 then
    v_blockers := v_blockers || 'variance_reason_missing'::text;
  end if;
  if v_th > 0 and length(btrim(coalesce(d.take_home_by, ''))) = 0 then
    v_blockers := v_blockers || 'take_home_by_missing'::text;
  end if;
  if cardinality(app.unresolved_late(p_outlet, p_date, true)) > 0 then
    v_blockers := v_blockers || 'late_entries_undecided'::text;
  end if;
  -- D-30: who physically performed the closing (an employee record, not the login).
  v_closer := d.closed_by_staff_id;
  if v_closer is null then
    v_blockers := v_blockers || 'closing_employee_missing'::text;
  elsif not app.staff_assigned(v_closer, p_outlet, p_date) then
    v_blockers := v_blockers || 'closing_employee_invalid'::text;
  end if;
  select count(*) into v_unassigned from (
    select bound_lower, bound_upper from public.entries
     where outlet_id = p_outlet and business_date is null and status = 'active'
    union all
    select bound_lower, bound_upper from public.food_payments where outlet_id = p_outlet and business_date is null
  ) u
  where p_date <= app.business_date(p_outlet, u.bound_upper)
    and (u.bound_lower is null or p_date >= app.business_date(p_outlet, u.bound_lower));
  if v_unassigned > 0 then v_warnings := v_warnings || 'unassigned_entries'::text; end if;
  if 'service_paytm_negative' = any (v_flags) then v_warnings := v_warnings || 'service_paytm_negative'::text; end if;
  if 'service_paytm_exceeds_services' = any (v_flags) then
    v_warnings := v_warnings || 'service_paytm_exceeds_services'::text;
  end if;
  select coalesce(sum(amount), 0), count(*) into v_imported, v_imported_n
    from public.paytm_transactions where outlet_id = p_outlet and business_date = p_date and status = 'success';
  if v_imported_n > 0 and v_imported <> v_paytm then v_warnings := v_warnings || 'paytm_import_mismatch'::text; end if;

  v_settle := case when v_closing is null then null
                   else app.settlement(v_closing, coalesce(v_cur.remaining_payable, v_payable)) end;

  return jsonb_build_object(
      'outlet_id', p_outlet, 'business_date', p_date, 'closing_id', v_closing,
      'state', v_state, 'current_revision_id', v_rev_id, 'current_revision_no', v_cur.revision_no,
      'needs_review', case when v_closing is null then false else app.needs_review(v_closing) end,
      'paytm_total', v_paytm, 'paytm_entered', d.paytm_total is not null,
      'paytm_upi', d.paytm_upi, 'paytm_card', d.paytm_card,
      'denominations', coalesce(d.denominations, '{}'::jsonb),
      'variance_reason', d.variance_reason, 'take_home_by', d.take_home_by,
      'paytm_imported_success_total', v_imported, 'paytm_imported_count', v_imported_n)
    || jsonb_build_object(
      'retained_float_carried', v_r, 'opening_float_source_revision_id', v_src,
      'initial_float_movement_id', v_init_id,
      'pre_opening_funding', v_pf, 'pre_opening_movement_ids', to_jsonb(v_pf_ids),
      'opening_float', v_o, 'intraday_top_ups', v_i, 'intraday_movement_ids', to_jsonb(v_i_ids),
      'included_late_entry_ids', to_jsonb(v_late), 'entries_snapshot', v_snap)
    || jsonb_build_object(
      'service_total', v_s, 'commission_pool', v_c, 'product_total', v_p, 'product_cash', v_pc,
      'product_paytm', v_pp, 'service_paytm', v_spaytm, 'cash_sales', v_cs,
      'expenses_total', v_e, 'expenses_outside_total', v_eo, 'zakat_total', v_z,
      'food_cost', v_f, 'food_commission_funded', v_fc, 'food_shop_funded', v_fx,
      'remaining_payable', v_payable)
    || jsonb_build_object(
      'food_paid_drawer_today', v_ftoday, 'food_paid_drawer_prior', v_fprior,
      'food_paid_drawer', v_ftoday + v_fprior, 'food_not_paid_drawer', v_f - v_ftoday,
      'food_payment_ids', to_jsonb(v_fp_ids),
      'drawer_handover_total', v_h, 'drawer_handover_ids', to_jsonb(v_h_ids), 'commission_retained', v_payable - v_h,
      'net_cash', v_n, 'expected_drawer', v_ed, 'counted_cash', v_cc, 'variance', v_v,
      'required_float', v_rf, 'retained_float', v_af, 'float_shortfall', v_fs, 'take_home', v_th)
    || jsonb_build_object(
      'closed_by_staff_id', v_closer, 'food_breakfast_salon', v_fb, 'food_employee_owed', v_owed)
    || jsonb_build_object(
      'paytm_flags', to_jsonb(v_flags), 'blockers', to_jsonb(v_blockers), 'warnings', to_jsonb(v_warnings),
      'allocations', v_alloc, 'settlement', v_settle);
end;
$$;


-- Employees who can be named for a closing: assigned to the outlet and active on that business date.
create function public.closing_employees(p_outlet uuid, p_date date)
returns table (id uuid, full_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select s.id, s.full_name from public.staff s
  where app.is_member(p_outlet) and p_date is not null and app.staff_assigned(s.id, p_outlet, p_date)
  order by s.full_name
$$;

create function public.set_closing_employee(p_closing uuid, p_staff uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c    public.daily_closings;
  v_st record;
begin
  c := app.lock_closing(p_closing, 'closing.prepare');
  select * into v_st from app.state_of(p_closing);
  if v_st.state not in ('draft', 'rejected', 'reopened') then
    raise exception 'the closing is % and cannot be edited', v_st.state using errcode = 'SO423';
  end if;
  if p_staff is null or not app.staff_assigned(p_staff, c.outlet_id, c.business_date) then
    raise exception 'choose an employee who worked at this outlet on %', to_char(c.business_date, 'DD Mon YYYY')
      using errcode = '22023';
  end if;
  perform app.set_audit_context('closing employee selected');
  update public.closing_drafts set closed_by_staff_id = p_staff, updated_by = auth.uid(), updated_at = now()
   where closing_id = p_closing;
  return app.compute_day(c.outlet_id, c.business_date);
end;
$$;

-- Food repayments -----------------------------------------------------------------------------------
create table public.food_repayments (
  id                     uuid primary key default gen_random_uuid(),
  outlet_id              uuid not null references public.outlets (id),
  amount                 bigint not null check (amount > 0 and amount % 100 = 0 and amount <= 10000000),
  payment_method         public.payment_method not null,
  received_on            date not null,
  staff_ids              uuid[] not null default '{}',   -- who handed it over (information only)
  note                   text check (note is null or length(note) <= 500),
  reverses_repayment_id  uuid unique references public.food_repayments (id),
  reason                 text check (reason is null or length(reason) <= 500),
  recorded_by            uuid not null references public.profiles (id),
  recorded_at            timestamptz not null default now(),
  constraint food_repayments_reversal_reason check (
    reverses_repayment_id is null or length(btrim(coalesce(reason, ''))) > 0)
);
create index food_repayments_outlet_idx on public.food_repayments (outlet_id, received_on);
create trigger food_repayments_immutable before update or delete on public.food_repayments
  for each row execute function app.forbid_mutation();
create trigger food_repayments_audit after insert on public.food_repayments
  for each row execute function app.audit_row();
alter table public.food_repayments enable row level security;
create policy food_repayments_select on public.food_repayments
  for select to authenticated using (app.is_member(outlet_id));
grant select on public.food_repayments to authenticated;

-- Outlet-level food debt: owed by approved closings minus net repayments.
create function app.food_debt(p_outlet uuid, out owed bigint, out pending bigint, out repaid bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select
    coalesce((select sum(r.food_employee_owed) from public.daily_closings c
              cross join lateral app.state_of(c.id) s
              join public.closing_revisions r on r.id = s.revision_id
              where c.outlet_id = p_outlet and s.state = 'approved'), 0)::bigint,
    coalesce((select sum(r.food_employee_owed) from public.daily_closings c
              cross join lateral app.state_of(c.id) s
              join public.closing_revisions r on r.id = s.revision_id
              where c.outlet_id = p_outlet and s.state = 'submitted'), 0)::bigint,
    coalesce((select sum(case when f.reverses_repayment_id is null then f.amount else -f.amount end)
              from public.food_repayments f where f.outlet_id = p_outlet), 0)::bigint
$$;

create function public.food_debt_summary(p_outlet uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  d record;
begin
  perform app.require_permission(p_outlet, 'outlet.read');
  select * into d from app.food_debt(p_outlet);
  return jsonb_build_object(
    'owed_approved', d.owed, 'owed_pending_approval', d.pending, 'repaid', d.repaid,
    'outstanding', d.owed - d.repaid,
    'days', coalesce((
      select jsonb_agg(jsonb_build_object('business_date', c.business_date, 'state', s.state,
                                          'owed', r.food_employee_owed) order by c.business_date desc)
      from public.daily_closings c
      cross join lateral app.state_of(c.id) s
      join public.closing_revisions r on r.id = s.revision_id
      where c.outlet_id = p_outlet and r.food_employee_owed > 0 and s.state in ('submitted', 'approved')), '[]'),
    'repayments', coalesce((
      select jsonb_agg(jsonb_build_object('id', f.id, 'amount', f.amount, 'payment_method', f.payment_method,
               'received_on', f.received_on, 'staff_ids', to_jsonb(f.staff_ids), 'note', f.note,
               'reverses_repayment_id', f.reverses_repayment_id, 'reason', f.reason,
               'reversed', exists (select 1 from public.food_repayments x where x.reverses_repayment_id = f.id),
               'recorded_at', f.recorded_at) order by f.recorded_at desc)
      from public.food_repayments f where f.outlet_id = p_outlet), '[]'));
end;
$$;

create function public.record_food_repayment(
  p_outlet uuid, p_amount bigint, p_payment_method text, p_received_on date, p_staff_ids uuid[], p_note text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  d    record;
  v_id uuid;
begin
  perform app.require_permission(p_outlet, 'food_repayment.record');
  perform 1 from public.outlets where id = p_outlet for update;   -- serialises the outstanding check
  if p_amount is null or p_amount <= 0 or p_amount % 100 <> 0 or p_amount > 10000000 then
    raise exception 'amount must be a positive whole-rupee amount' using errcode = '22023';
  end if;
  if p_payment_method is null or p_payment_method not in ('cash', 'paytm') then
    raise exception 'payment method must be cash or paytm' using errcode = '22023';
  end if;
  if p_received_on is null or p_received_on > app.business_date(p_outlet, now()) then
    raise exception 'the date received is required and cannot be in the future' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(coalesce(p_staff_ids, '{}')) sid
             where not exists (select 1 from public.staff_assignments a
                               where a.staff_id = sid and a.outlet_id = p_outlet)) then
    raise exception 'every employee named must work (or have worked) at this outlet' using errcode = '22023';
  end if;
  if p_note is not null and length(p_note) > 500 then
    raise exception 'note is too long (max 500 characters)' using errcode = '22023';
  end if;
  select * into d from app.food_debt(p_outlet);
  if p_amount > d.owed - d.repaid then
    raise exception 'repayment is more than the outstanding food amount (₹% outstanding from approved closings)',
      greatest(0, d.owed - d.repaid) / 100 using errcode = '22023';
  end if;
  perform app.set_audit_context('food repayment received');
  insert into public.food_repayments (outlet_id, amount, payment_method, received_on, staff_ids, note, recorded_by)
  values (p_outlet, p_amount, p_payment_method::public.payment_method, p_received_on,
          coalesce((select array_agg(distinct x) from unnest(p_staff_ids) x), '{}'),
          nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create function public.reverse_food_repayment(p_repayment uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  f        public.food_repayments;
  v_reason text;
  v_id     uuid;
begin
  select * into f from public.food_repayments where id = p_repayment;
  if not found then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  perform app.require_permission(f.outlet_id, 'food_repayment.record');
  v_reason := app.require_reason(p_reason);
  if f.reverses_repayment_id is not null then
    raise exception 'a reversal cannot be reversed' using errcode = '22023';
  end if;
  perform app.set_audit_context(v_reason);
  insert into public.food_repayments (outlet_id, amount, payment_method, received_on, staff_ids,
    reverses_repayment_id, reason, recorded_by)
  values (f.outlet_id, f.amount, f.payment_method, app.business_date(f.outlet_id, now()), f.staff_ids,
          f.id, v_reason, auth.uid())
  returning id into v_id;   -- unique(reverses_repayment_id) refuses a second reversal
  return v_id;
end;
$$;

revoke execute on function app.food_debt(uuid) from public, anon, authenticated;
revoke execute on function
  public.closing_employees(uuid, date), public.set_closing_employee(uuid, uuid),
  public.food_debt_summary(uuid), public.record_food_repayment(uuid, bigint, text, date, uuid[], text),
  public.reverse_food_repayment(uuid, text)
from public, anon;
grant execute on function
  public.closing_employees(uuid, date), public.set_closing_employee(uuid, uuid),
  public.food_debt_summary(uuid), public.record_food_repayment(uuid, bigint, text, date, uuid[], text),
  public.reverse_food_repayment(uuid, text)
to authenticated;
