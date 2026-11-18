-- M3 engine: accounting (§5), drafts, immutable revisions, lifecycle and approval ordering (§5.5,
-- §5.6), late-entry decisions (H3), float (§3.4, §10.1), commission handovers (§5.8), Paytm CSV
-- import (§7). All amounts are bigint paise; every computation is integer arithmetic.

-- Commission settlement (§5.8, H1) for a closing given its `allowed` (remaining payable).
create function app.settlement(p_closing uuid, p_allowed bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_gross    bigint;
  v_outside  bigint;
  v_ret      bigint;
  v_h        bigint;
  v_acc      bigint;
  v_net      bigint;
  v_excess   bigint;
  v_unres    bigint;
  v_status   text;
begin
  select
    coalesce(sum(amount) filter (where kind = 'handover'), 0),
    coalesce(sum(amount) filter (where kind = 'handover' and source = 'outside_drawer'), 0),
    coalesce(sum(amount) filter (where kind = 'return'), 0),
    coalesce(sum(case when kind = 'handover' then amount else -amount end)
             filter (where kind in ('handover', 'return') and source = 'drawer'), 0),
    coalesce(sum(amount) filter (where kind = 'overpayment_accepted'), 0)
  into v_gross, v_outside, v_ret, v_h, v_acc
  from public.commission_handovers where closing_id = p_closing;
  v_net := v_gross - v_ret;
  v_excess := greatest(0, v_net - p_allowed);
  v_unres := greatest(0, v_excess - v_acc);
  v_status := case
    when v_unres > 0 then 'over_handed_unresolved'
    when v_excess > 0 then 'over_handed_accepted'
    when v_net = 0 and p_allowed > 0 then 'not_handed'
    when v_net < p_allowed then 'partial'
    else 'complete' end;
  return jsonb_build_object(
    'allowed', p_allowed, 'gross_handed', v_gross, 'handed_outside_drawer', v_outside, 'returned', v_ret,
    'drawer_net', v_h, 'net_transferred', v_net, 'excess', v_excess, 'accepted_overpayment', v_acc,
    'unresolved_excess', v_unres, 'outstanding', greatest(0, p_allowed - v_net), 'status', v_status);
end;
$$;

-- Late rows for a day that still need a management decision (H3 "unresolved").
--   p_for_submit = true: only rows with no decision (an `include` will be in the next revision).
--   p_for_submit = false: also `include` decisions not yet contained in a later submitted revision.
create function app.unresolved_late(p_outlet uuid, p_date date, p_for_submit boolean)
returns uuid[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_closing uuid := app.closing_of(p_outlet, p_date);
  v_rev     public.closing_revisions;
  v_ids     uuid[];
begin
  if v_closing is not null then
    select * into v_rev from public.closing_revisions where closing_id = v_closing order by revision_no desc limit 1;
  end if;
  select coalesce(array_agg(x.id), '{}') into v_ids
  from (
    select e.id, 'entry'::text k from public.entries e
     where e.outlet_id = p_outlet and e.business_date = p_date and e.late and e.status = 'active'
    union all
    select f.id, 'food_payment' from public.food_payments f
     where f.outlet_id = p_outlet and f.business_date = p_date and f.late
  ) x
  cross join lateral app.late_decision(x.k, x.id) d
  where d.decision is null
     or (not p_for_submit and d.decision = 'include'
         and not (v_rev.id is not null and x.id = any (v_rev.included_late_entry_ids)
                  and exists (select 1 from public.closing_events ev
                              where ev.revision_id = v_rev.id and ev.type = 'submitted' and ev.server_seq > d.seq)));
  return v_ids;
end;
$$;

create function app.needs_review(p_closing uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c public.daily_closings;
begin
  select * into c from public.daily_closings where id = p_closing;
  return exists (
    select 1 from public.closing_events e
    where e.closing_id = p_closing and e.type = 'review_flagged'
      and not exists (
        select 1 from public.closing_events a
        where a.closing_id = p_closing and a.server_seq > e.server_seq
          and (a.type = 'reopened' or (a.type = 'review_acknowledged' and a.payload ->> 'flag' = e.payload ->> 'flag'))
      )
  ) or cardinality(app.unresolved_late(c.outlet_id, c.business_date, false)) > 0;
end;
$$;

-- Pure cash model (§5.1–§5.3). Inputs and outputs in paise; integer arithmetic only. Shared with the
-- TypeScript mirror (lib/accounting.ts) through the worked examples A–M in the test suites.
--   in : R, PF, I, S, P, paytm, E, Z, F, f_today, f_prior, H, CC, RF
--   out: C, FC, FX, payable, O, CS, N, Fd, U, Rc, ED, V, AF, FS, TH
create function app.cash_model(i jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_s  bigint := coalesce((i ->> 'S')::bigint, 0);
  v_c  bigint := (v_s / 10000) * 1000;                     -- D1: FLOOR(S × 10% / ₹10) × ₹10
  v_f  bigint := coalesce((i ->> 'F')::bigint, 0);
  v_fc bigint := least(v_f, v_c);                          -- D2: food funded by the pool up to C
  v_fx bigint := v_f - least(v_f, v_c);                    -- B6: excess = F − C (shop-funded)
  v_o  bigint := coalesce((i ->> 'R')::bigint, 0) + coalesce((i ->> 'PF')::bigint, 0);
  v_i  bigint := coalesce((i ->> 'I')::bigint, 0);
  v_p  bigint := coalesce((i ->> 'P')::bigint, 0);
  v_pt bigint := coalesce((i ->> 'paytm')::bigint, 0);
  v_e  bigint := coalesce((i ->> 'E')::bigint, 0);
  v_z  bigint := coalesce((i ->> 'Z')::bigint, 0);
  v_ft bigint := coalesce((i ->> 'f_today')::bigint, 0);
  v_fp bigint := coalesce((i ->> 'f_prior')::bigint, 0);
  v_h  bigint := coalesce((i ->> 'H')::bigint, 0);
  v_cc bigint := coalesce((i ->> 'CC')::bigint, 0);
  v_rf bigint := coalesce((i ->> 'RF')::bigint, 0);
  v_cs bigint;
  v_ed bigint;
begin
  v_cs := v_s + v_p - v_pt;
  v_ed := v_o + v_i + v_cs - v_e - v_z - (v_ft + v_fp) - v_h;
  return jsonb_build_object(
    'C', v_c, 'FC', v_fc, 'FX', v_fx, 'payable', v_c - v_fc, 'O', v_o, 'CS', v_cs,
    'N', v_s - v_c + v_p - v_pt - v_e - v_z,                -- SRS §3.5 formula, verbatim
    'Fd', v_ft + v_fp, 'U', v_f - v_ft, 'Rc', v_c - v_fc - v_h, 'ED', v_ed, 'V', v_cc - v_ed,
    'AF', least(v_cc, v_rf), 'FS', greatest(0, v_rf - v_cc), 'TH', greatest(0, v_cc - v_rf));
end;
$$;

-- Live computation of one business day (§5). Keys match closing_revisions columns so the snapshot
-- can be written with jsonb_populate_record. Also returns allocations, blockers, warnings, state.
create function app.compute_day(p_outlet uuid, p_date date)
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
    coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'amount', amount, 'staff_id', staff_id,
                       'version', version) order by server_seq), '[]'),
    coalesce(array_agg(id) filter (where late), '{}')
  into v_s, v_p, v_pc, v_pp, v_e, v_eo, v_z, v_f, v_snap, v_late
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

  -- Food cost allocation (D2, B6).
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
      'paytm_flags', to_jsonb(v_flags), 'blockers', to_jsonb(v_blockers), 'warnings', to_jsonb(v_warnings),
      'allocations', v_alloc, 'settlement', v_settle);
end;
$$;

-- Read-only day summary for dashboards (every member). ----------------------------------------------
create function public.day_summary(p_outlet uuid, p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.require_permission(p_outlet, 'outlet.read');
  return app.compute_day(p_outlet, coalesce(p_date, app.business_date(p_outlet, now())));
end;
$$;

create function public.current_business_date(p_outlet uuid)
returns date
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.require_permission(p_outlet, 'outlet.read');
  return app.business_date(p_outlet, now());
end;
$$;

-- Drafts -------------------------------------------------------------------------------------------------
create function app.lock_closing(p_closing uuid, p_permission text)
returns public.daily_closings
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.daily_closings;
begin
  select * into c from public.daily_closings where id = p_closing for update;
  if c.id is null then raise exception 'permission denied' using errcode = '42501'; end if;
  perform app.require_permission(c.outlet_id, p_permission);
  return c;
end;
$$;

create function public.prepare_closing(p_outlet uuid, p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.require_permission(p_outlet, 'closing.prepare');
  if p_date is null then raise exception 'date is required' using errcode = '22023'; end if;
  if p_date > app.business_date(p_outlet, now()) then
    raise exception 'cannot prepare a closing for a future business day' using errcode = '22023';
  end if;
  v_id := app.closing_of(p_outlet, p_date);
  if v_id is null then
    insert into public.daily_closings (outlet_id, business_date, created_by)
    values (p_outlet, p_date, auth.uid())
    on conflict (outlet_id, business_date) do nothing
    returning id into v_id;
    v_id := coalesce(v_id, app.closing_of(p_outlet, p_date));
    insert into public.closing_drafts (closing_id, outlet_id, updated_by)
    values (v_id, p_outlet, auth.uid()) on conflict do nothing;
  end if;
  return app.compute_day(p_outlet, p_date);
end;
$$;

create function public.update_draft(
  p_closing uuid, p_paytm_total bigint, p_paytm_upi bigint, p_paytm_card bigint,
  p_denominations jsonb, p_variance_reason text, p_take_home_by text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c      public.daily_closings;
  v_st   record;
  v_den  integer[];
  v_bad  text;
begin
  c := app.lock_closing(p_closing, 'closing.prepare');
  select * into v_st from app.state_of(p_closing);
  if v_st.state not in ('draft', 'rejected', 'reopened') then
    raise exception 'the closing is % and cannot be edited', v_st.state using errcode = 'SO423';
  end if;
  if exists (select 1 from unnest(array[p_paytm_total, p_paytm_upi, p_paytm_card]) a
             where a is not null and (a < 0 or a % 100 <> 0 or a > 10000000000)) then
    raise exception 'Paytm amounts must be whole rupees' using errcode = '22023';
  end if;
  p_denominations := coalesce(p_denominations, '{}');
  if jsonb_typeof(p_denominations) <> 'object' then
    raise exception 'denominations must be an object of {paise: count}' using errcode = '22023';
  end if;
  select denominations into v_den from public.outlets where id = c.outlet_id;
  select string_agg(k, ', ') into v_bad from jsonb_each_text(p_denominations) t(k, v)
   where k !~ '^[0-9]+$' or not (k::int = any (v_den)) or v !~ '^[0-9]+$' or v::bigint > 100000;
  if v_bad is not null then
    raise exception 'invalid denomination count(s): %', v_bad using errcode = '22023';
  end if;
  update public.closing_drafts set
    paytm_total = p_paytm_total, paytm_upi = p_paytm_upi, paytm_card = p_paytm_card,
    denominations = p_denominations,
    variance_reason = nullif(btrim(coalesce(p_variance_reason, '')), ''),
    take_home_by = nullif(btrim(coalesce(p_take_home_by, '')), ''),
    updated_by = auth.uid(), updated_at = now()
  where closing_id = p_closing;
  return app.compute_day(c.outlet_id, c.business_date);
end;
$$;

create function public.allocate_food_excess(p_closing uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c       public.daily_closings;
  v_st    record;
  v_comp  jsonb;
  v_reason text;
begin
  c := app.lock_closing(p_closing, 'food_excess.allocate');
  v_reason := app.require_reason(p_reason);
  select * into v_st from app.state_of(p_closing);
  if v_st.state not in ('draft', 'rejected', 'reopened') then
    raise exception 'the closing is % and cannot be edited', v_st.state using errcode = 'SO423';
  end if;
  v_comp := app.compute_day(c.outlet_id, c.business_date);
  if (v_comp ->> 'food_cost')::bigint <= (v_comp ->> 'commission_pool')::bigint then
    raise exception 'food cost does not exceed the commission pool; nothing to allocate' using errcode = '22023';
  end if;
  insert into public.closing_events (closing_id, outlet_id, type, actor, reason, payload)
  values (p_closing, c.outlet_id, 'food_excess_allocated', auth.uid(), v_reason, jsonb_build_object(
    'food_cost', (v_comp ->> 'food_cost')::bigint, 'commission_pool', (v_comp ->> 'commission_pool')::bigint,
    'food_shop_funded', (v_comp ->> 'food_cost')::bigint - (v_comp ->> 'commission_pool')::bigint));
  return app.compute_day(c.outlet_id, c.business_date);
end;
$$;

-- Submit: recompute inside the transaction and write the immutable revision (F1). -------------------
create function public.submit_closing(p_closing uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  c       public.daily_closings;
  v_comp  jsonb;
  v_no    integer;
  v_rev   uuid := gen_random_uuid();
  v_row   public.closing_revisions;
begin
  c := app.lock_closing(p_closing, 'closing.submit');
  v_comp := app.compute_day(c.outlet_id, c.business_date);
  if jsonb_array_length(v_comp -> 'blockers') > 0 then
    raise exception 'closing cannot be submitted: %',
      (select string_agg(value, ', ') from jsonb_array_elements_text(v_comp -> 'blockers'))
      using errcode = '22023';
  end if;
  select coalesce(max(revision_no), 0) + 1 into v_no from public.closing_revisions where closing_id = p_closing;

  v_row := jsonb_populate_record(null::public.closing_revisions, v_comp || jsonb_build_object(
    'id', v_rev, 'closing_id', p_closing, 'revision_no', v_no,
    'paytm_upi', v_comp -> 'paytm_upi', 'paytm_card', v_comp -> 'paytm_card',
    'submitted_by', auth.uid(), 'submitted_at', now()));
  insert into public.closing_revisions select v_row.*;

  insert into public.revision_denominations (revision_id, outlet_id, denomination, qty, subtotal)
  select v_rev, c.outlet_id, k::bigint, v::int, k::bigint * v::int
    from jsonb_each_text(v_comp -> 'denominations') t(k, v);

  insert into public.revision_commission_allocations
    (revision_id, outlet_id, staff_id, staff_name, service_total, exact_share, allocated, rounding_adj)
  select v_rev, c.outlet_id, (a ->> 'staff_id')::uuid, a ->> 'staff_name', (a ->> 'service_total')::bigint,
         (a ->> 'exact_share')::bigint, (a ->> 'allocated')::bigint, (a ->> 'rounding_adj')::bigint
    from jsonb_array_elements(v_comp -> 'allocations') a;
  -- D1 invariant: shares always sum to the pool.
  if (select coalesce(sum(allocated), 0) from public.revision_commission_allocations where revision_id = v_rev)
     <> (v_comp ->> 'commission_pool')::bigint then
    raise exception 'internal error: commission allocations do not sum to the pool' using errcode = 'P0001';
  end if;

  insert into public.closing_events (closing_id, outlet_id, revision_id, type, actor, payload)
  values (p_closing, c.outlet_id, v_rev, 'submitted', auth.uid(), jsonb_build_object('revision_no', v_no));

  -- §5.5: later closings whose opening float came from a now-superseded revision are flagged.
  insert into public.closing_events (closing_id, outlet_id, revision_id, type, actor, reason, payload)
  select r.closing_id, r.outlet_id, r.id, 'review_flagged', auth.uid(), 'opening float source changed',
         jsonb_build_object('flag', 'opening_float_source_changed',
                            'old_source_revision_id', r.opening_float_source_revision_id,
                            'new_source_revision_id', v_rev)
    from public.closing_revisions r
   where r.opening_float_source_revision_id in (
           select id from public.closing_revisions where closing_id = p_closing and id <> v_rev)
     and r.revision_no = (select max(x.revision_no) from public.closing_revisions x where x.closing_id = r.closing_id);
  return v_rev;
end;
$$;

-- Approval ordering (§5.5) and gates. ------------------------------------------------------------------
create function public.approve_closing(p_revision uuid, p_acknowledgements text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r        public.closing_revisions;
  c        public.daily_closings;
  v_st     record;
  v_block  text;
  v_need   text[] := '{}';
  v_miss   text[];
  v_settle jsonb;
  v_init   date;
begin
  select * into r from public.closing_revisions where id = p_revision;
  if r.id is null then raise exception 'permission denied' using errcode = '42501'; end if;
  c := app.lock_closing(r.closing_id, 'closing.approve');
  select * into v_st from app.state_of(c.id);
  if v_st.state <> 'submitted' or v_st.revision_id <> p_revision then
    raise exception 'only the current submitted revision can be approved (closing is %)', v_st.state
      using errcode = 'SO423';
  end if;

  select effective_business_date into v_init from public.float_movements
   where outlet_id = c.outlet_id and type = 'initial_float';
  if v_init is null then
    raise exception 'the initial float has not been established' using errcode = '22023';
  end if;

  -- Every earlier closing must be approved and free of open review items.
  select string_agg(to_char(x.business_date, 'YYYY-MM-DD'), ', ' order by x.business_date) into v_block
  from public.daily_closings x
  cross join lateral app.state_of(x.id) s
  where x.outlet_id = c.outlet_id and x.business_date < c.business_date
    and (s.state <> 'approved' or app.needs_review(x.id));
  if v_block is not null then
    raise exception 'approve earlier days first (pending or under review: %)', v_block using errcode = '22023';
  end if;
  select string_agg(distinct to_char(e.business_date, 'YYYY-MM-DD'), ', ') into v_block
  from public.entries e
  where e.outlet_id = c.outlet_id and e.status = 'active' and e.business_date < c.business_date
    and e.business_date >= v_init and app.closing_of(c.outlet_id, e.business_date) is null;
  if v_block is not null then
    raise exception 'earlier days have entries but no closing: %', v_block using errcode = '22023';
  end if;

  if app.needs_review(c.id) then
    raise exception 'this closing has open review items (late entries or flags) to resolve first'
      using errcode = '22023';
  end if;

  v_settle := app.settlement(c.id, r.remaining_payable);
  if v_settle ->> 'status' = 'over_handed_unresolved' then
    raise exception 'commission was over-handed by ₹%; record a return or accept the overpayment first',
      (v_settle ->> 'unresolved_excess')::bigint / 100 using errcode = '22023';
  end if;

  -- Items the approver must explicitly acknowledge.
  select coalesce(array_agg(f), '{}') into v_need from unnest(r.paytm_flags) f
   where f in ('service_paytm_negative', 'service_paytm_exceeds_services');
  if r.variance <> 0 then v_need := v_need || 'variance'::text; end if;
  if 'unassigned_entries' = any (array(select jsonb_array_elements_text(
        app.compute_day(c.outlet_id, c.business_date) -> 'warnings'))) then
    v_need := v_need || 'unassigned_entries'::text;
  end if;
  select coalesce(array_agg(n), '{}') into v_miss from unnest(v_need) n
   where not (n = any (coalesce(p_acknowledgements, '{}')));
  if cardinality(v_miss) > 0 then
    raise exception 'acknowledge before approving: %', array_to_string(v_miss, ', ') using errcode = '22023';
  end if;

  insert into public.closing_events (closing_id, outlet_id, revision_id, type, actor, payload)
  values (c.id, c.outlet_id, p_revision, 'approved', auth.uid(), jsonb_build_object(
    'acknowledgements', to_jsonb(coalesce(p_acknowledgements, '{}')),
    'self_approved', r.submitted_by = auth.uid()));                       -- O8
end;
$$;

create function public.reject_closing(p_revision uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r        public.closing_revisions;
  c        public.daily_closings;
  v_st     record;
  v_reason text;
begin
  select * into r from public.closing_revisions where id = p_revision;
  if r.id is null then raise exception 'permission denied' using errcode = '42501'; end if;
  c := app.lock_closing(r.closing_id, 'closing.approve');
  v_reason := app.require_reason(p_reason);
  select * into v_st from app.state_of(c.id);
  if v_st.state <> 'submitted' or v_st.revision_id <> p_revision then
    raise exception 'only the current submitted revision can be rejected (closing is %)', v_st.state
      using errcode = 'SO423';
  end if;
  insert into public.closing_events (closing_id, outlet_id, revision_id, type, actor, reason)
  values (c.id, c.outlet_id, p_revision, 'rejected', auth.uid(), v_reason);
end;
$$;

create function public.reopen_closing(p_closing uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  c        public.daily_closings;
  v_st     record;
  v_reason text;
begin
  c := app.lock_closing(p_closing, 'closing.reopen');
  v_reason := app.require_reason(p_reason);
  select * into v_st from app.state_of(c.id);
  if v_st.state not in ('submitted', 'approved') then
    raise exception 'only a submitted or approved closing can be reopened (closing is %)', v_st.state
      using errcode = 'SO423';
  end if;
  insert into public.closing_events (closing_id, outlet_id, revision_id, type, actor, reason)
  values (c.id, c.outlet_id, v_st.revision_id, 'reopened', auth.uid(), v_reason);
end;
$$;

create function public.acknowledge_review(p_closing uuid, p_flag text, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  c        public.daily_closings;
  v_note   text;
  v_flag   public.closing_events;
  v_cur    public.closing_revisions;
  v_src    public.closing_revisions;
begin
  c := app.lock_closing(p_closing, 'review.acknowledge');
  v_note := app.require_reason(p_note);
  if p_flag = 'late_entries' then
    raise exception 'late entries need an include/exclude decision for each entry, not an acknowledgement'
      using errcode = '22023';
  end if;
  select e.* into v_flag from public.closing_events e
   where e.closing_id = p_closing and e.type = 'review_flagged' and e.payload ->> 'flag' = p_flag
     and not exists (select 1 from public.closing_events a where a.closing_id = p_closing and a.server_seq > e.server_seq
                     and (a.type = 'reopened' or (a.type = 'review_acknowledged' and a.payload ->> 'flag' = p_flag)))
   order by e.server_seq desc limit 1;
  if v_flag.id is null then raise exception 'no open review flag %', p_flag using errcode = '22023'; end if;
  if p_flag = 'opening_float_source_changed' then
    select * into v_cur from public.closing_revisions where closing_id = p_closing order by revision_no desc limit 1;
    select * into v_src from public.closing_revisions where id = (v_flag.payload ->> 'new_source_revision_id')::uuid;
    if v_src.retained_float is distinct from v_cur.retained_float_carried then
      raise exception 'the corrected previous day leaves ₹% in the float but this day opened with ₹%; reopen this day',
        v_src.retained_float / 100, v_cur.retained_float_carried / 100 using errcode = '22023';
    end if;
  end if;
  insert into public.closing_events (closing_id, outlet_id, revision_id, type, actor, reason, payload)
  values (p_closing, c.outlet_id, v_flag.revision_id, 'review_acknowledged', auth.uid(), v_note,
          jsonb_build_object('flag', p_flag, 'flag_event_id', v_flag.id));
end;
$$;

-- Late-entry decision (H3). ----------------------------------------------------------------------------
create function public.review_late_entry(
  p_kind text, p_id uuid, p_decision text, p_reason text, p_reopen_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_outlet  uuid;
  v_date    date;
  v_late    boolean;
  v_closing uuid;
  v_st      record;
begin
  if p_kind = 'entry' then
    select outlet_id, business_date, late into v_outlet, v_date, v_late from public.entries where id = p_id;
  elsif p_kind = 'food_payment' then
    select outlet_id, business_date, late into v_outlet, v_date, v_late from public.food_payments where id = p_id;
  else
    raise exception 'kind must be entry or food_payment' using errcode = '22023';
  end if;
  if v_outlet is null then raise exception 'permission denied' using errcode = '42501'; end if;
  perform app.require_permission(v_outlet, 'late_entry.review');
  if not coalesce(v_late, false) then raise exception 'this row is not a late entry' using errcode = '22023'; end if;
  if p_decision not in ('include', 'exclude') then
    raise exception 'decision must be include or exclude' using errcode = '22023';
  end if;
  if p_decision = 'exclude' then perform app.require_reason(p_reason); end if;
  v_closing := app.closing_of(v_outlet, v_date);
  perform 1 from public.daily_closings where id = v_closing for update;
  select * into v_st from app.state_of(v_closing);
  if p_decision = 'include' and v_st.state in ('submitted', 'approved') then
    if p_reopen_reason is null then
      raise exception 'including a late entry reopens the closing; give a reopen reason' using errcode = '22023';
    end if;
    perform public.reopen_closing(v_closing, p_reopen_reason);
  end if;
  insert into public.late_entry_reviews (entry_kind, entry_id, closing_id, outlet_id, decision, reason, decided_by)
  values (p_kind, p_id, v_closing, v_outlet, p_decision, nullif(btrim(coalesce(p_reason, '')), ''), auth.uid());
end;
$$;

-- Float (§3.4, G1, G2, J4). ------------------------------------------------------------------------------
create function app.require_open_day(p_outlet uuid, p_date date)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_date is null then raise exception 'effective date is required' using errcode = '22023'; end if;
  if app.frozen_revision(p_outlet, p_date) is not null then
    raise exception 'the closing for % is submitted or approved; use the next day or reopen', p_date
      using errcode = 'SO423';
  end if;
end;
$$;

create function public.establish_initial_float(
  p_outlet uuid, p_effective_date date, p_denominations jsonb, p_retyped_total bigint
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_total bigint;
  v_den   integer[];
  v_bad   text;
  v_id    uuid;
begin
  perform app.require_permission(p_outlet, 'float.initial');
  perform app.require_open_day(p_outlet, p_effective_date);
  if jsonb_typeof(coalesce(p_denominations, 'null')) <> 'object' then
    raise exception 'count the float by denomination' using errcode = '22023';
  end if;
  select denominations into v_den from public.outlets where id = p_outlet;
  select string_agg(k, ', ') into v_bad from jsonb_each_text(p_denominations) t(k, v)
   where k !~ '^[0-9]+$' or not (k::int = any (v_den)) or v !~ '^[0-9]+$' or v::bigint > 100000;
  if v_bad is not null then raise exception 'invalid denomination count(s): %', v_bad using errcode = '22023'; end if;
  v_total := app.denom_total(p_denominations);
  if v_total <= 0 then raise exception 'the float must be more than ₹0' using errcode = '22023'; end if;
  if p_retyped_total is distinct from v_total then
    raise exception 're-typed total ₹% does not match the counted total ₹%', coalesce(p_retyped_total, 0) / 100,
      v_total / 100 using errcode = '22023';
  end if;
  if exists (select 1 from public.float_movements where outlet_id = p_outlet and type = 'initial_float') then
    raise exception 'the initial float has already been established for this outlet' using errcode = '23505';
  end if;
  perform app.set_audit_context(
    'initial_float_established: counted, entered and self-confirmed by the owner in one action');
  insert into public.float_movements (outlet_id, type, effective_business_date, timing, amount, source,
    denominations, authorised_by, recorded_by, reason, confirmation)
  values (p_outlet, 'initial_float', p_effective_date, 'pre_opening', v_total, 'owner_funds',
    p_denominations, auth.uid(), auth.uid(), 'initial float', jsonb_build_object(
      'method', 'single_action_retyped_total', 'entered_by', auth.uid(), 'confirmed_by', auth.uid(),
      'self_confirmed', true, 'retyped_total', p_retyped_total))
  returning id into v_id;
  return v_id;
end;
$$;

create function public.record_top_up(
  p_outlet uuid, p_effective_date date, p_timing text, p_amount bigint, p_source text, p_source_note text,
  p_reason text, p_relates_to_revision uuid default null
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
  perform app.require_permission(p_outlet, 'float.manage');
  v_reason := app.require_reason(p_reason);
  perform app.require_open_day(p_outlet, p_effective_date);
  if p_timing not in ('pre_opening', 'intraday') or p_timing is null then
    raise exception 'timing must be pre_opening or intraday' using errcode = '22023';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount % 100 <> 0 then
    raise exception 'amount must be a positive whole-rupee amount' using errcode = '22023';
  end if;
  if p_source not in ('owner_funds', 'previous_take_home', 'other') or p_source is null then
    raise exception 'source must be owner_funds, previous_take_home or other' using errcode = '22023';
  end if;
  if p_relates_to_revision is not null and not exists (
    select 1 from public.closing_revisions where id = p_relates_to_revision and outlet_id = p_outlet) then
    raise exception 'linked shortfall revision not found in this outlet' using errcode = '22023';
  end if;
  perform app.set_audit_context(v_reason);
  insert into public.float_movements (outlet_id, type, effective_business_date, timing, amount, source, source_note,
    relates_to_revision_id, authorised_by, recorded_by, reason)
  values (p_outlet, 'top_up', p_effective_date, p_timing, p_amount, p_source, nullif(btrim(coalesce(p_source_note, '')), ''),
    p_relates_to_revision, auth.uid(), auth.uid(), v_reason)
  returning id into v_id;
  return v_id;
end;
$$;

create function public.change_required_float(p_outlet uuid, p_effective_date date, p_new_required_float bigint, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text;
  v_id     uuid;
begin
  perform app.require_permission(p_outlet, 'float.manage');
  v_reason := app.require_reason(p_reason);
  perform app.require_open_day(p_outlet, p_effective_date);
  if p_new_required_float is null or p_new_required_float < 0 or p_new_required_float % 100 <> 0 then
    raise exception 'required float must be a whole-rupee amount' using errcode = '22023';
  end if;
  perform app.set_audit_context(v_reason);
  insert into public.float_movements (outlet_id, type, effective_business_date, new_required_float,
    authorised_by, recorded_by, reason)
  values (p_outlet, 'required_float_change', p_effective_date, p_new_required_float, auth.uid(), auth.uid(), v_reason)
  returning id into v_id;
  return v_id;
end;
$$;

create function public.reverse_float_movement(p_movement uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  m        public.float_movements;
  v_reason text;
  v_id     uuid;
begin
  select * into m from public.float_movements where id = p_movement;
  if m.id is null then raise exception 'permission denied' using errcode = '42501'; end if;
  perform app.require_permission(m.outlet_id, 'float.manage');
  v_reason := app.require_reason(p_reason);
  if m.type = 'initial_float' then
    raise exception 'the initial float cannot be reversed; correct an under-count with a pre-opening top-up'
      using errcode = '22023';
  end if;
  if m.reverses_movement_id is not null then
    raise exception 'a reversal cannot itself be reversed' using errcode = '22023';
  end if;
  perform app.require_open_day(m.outlet_id, m.effective_business_date);
  perform app.set_audit_context(v_reason);
  insert into public.float_movements (outlet_id, type, effective_business_date, timing, amount, new_required_float,
    source, source_note, authorised_by, recorded_by, reason, reverses_movement_id)
  values (m.outlet_id, m.type, m.effective_business_date, m.timing, m.amount, m.new_required_float,
    m.source, m.source_note, auth.uid(), auth.uid(), v_reason, m.id)
  returning id into v_id;
  return v_id;
end;
$$;

-- Commission handovers (§5.8). ----------------------------------------------------------------------------
create function app.allowed_payable(p_closing uuid)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c public.daily_closings;
  v bigint;
begin
  select remaining_payable into v from public.closing_revisions where closing_id = p_closing
   order by revision_no desc limit 1;
  if v is not null then return v; end if;
  select * into c from public.daily_closings where id = p_closing;
  return (app.compute_day(c.outlet_id, c.business_date) ->> 'remaining_payable')::bigint;
end;
$$;

create function public.record_handover(p_closing uuid, p_recipient_staff uuid, p_amount bigint, p_source text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  c      public.daily_closings;
  v_rev  uuid;
  v_set  jsonb;
  v_prof uuid;
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
  select profile_id into v_prof from public.staff where id = p_recipient_staff and active;
  if v_prof is null or not exists (
    select 1 from app.valid_memberships_of(v_prof) m where m.outlet_id = c.outlet_id and m.role = 'head') then
    raise exception 'recipient must be the head employee or a valid acting head of this outlet' using errcode = '22023';
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

create function public.record_commission_return(p_closing uuid, p_amount bigint, p_source text, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  c        public.daily_closings;
  v_rev    uuid;
  v_set    jsonb;
  v_reason text;
  v_id     uuid;
begin
  c := app.lock_closing(p_closing, 'commission.handover');
  v_reason := app.require_reason(p_reason);
  select revision_id into v_rev from app.state_of(p_closing);
  if p_source not in ('drawer', 'outside_drawer') or p_source is null then
    raise exception 'source must be drawer or outside_drawer' using errcode = '22023';
  end if;
  if p_source = 'drawer' and v_rev is not null then
    raise exception 'after submission, returned commission goes to management (outside drawer)' using errcode = 'SO423';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount % 100 <> 0 then
    raise exception 'amount must be a positive whole-rupee amount' using errcode = '22023';
  end if;
  v_set := app.settlement(p_closing, app.allowed_payable(p_closing));
  if p_amount > (v_set ->> 'net_transferred')::bigint then
    raise exception 'return exceeds the commission cash held by the head (₹%)',
      (v_set ->> 'net_transferred')::bigint / 100 using errcode = '22023';
  end if;
  insert into public.commission_handovers (closing_id, outlet_id, revision_id, kind, source, amount,
    received_by, reason, recorded_by)
  values (p_closing, c.outlet_id, v_rev, 'return', p_source, p_amount, auth.uid(), v_reason, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create function public.accept_commission_overpayment(p_closing uuid, p_amount bigint, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  c        public.daily_closings;
  v_rev    uuid;
  v_set    jsonb;
  v_reason text;
  v_id     uuid;
begin
  c := app.lock_closing(p_closing, 'commission.adjust');
  v_reason := app.require_reason(p_reason);
  select revision_id into v_rev from app.state_of(p_closing);
  if p_amount is null or p_amount <= 0 or p_amount % 100 <> 0 then
    raise exception 'amount must be a positive whole-rupee amount' using errcode = '22023';
  end if;
  v_set := app.settlement(p_closing, app.allowed_payable(p_closing));
  if (v_set ->> 'accepted_overpayment')::bigint + p_amount > (v_set ->> 'excess')::bigint then
    raise exception 'only ₹% of over-handed commission is unaccepted',
      (v_set ->> 'unresolved_excess')::bigint / 100 using errcode = '22023';
  end if;
  insert into public.commission_handovers (closing_id, outlet_id, revision_id, kind, amount, reason, recorded_by)
  values (p_closing, c.outlet_id, v_rev, 'overpayment_accepted', p_amount, v_reason, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- Commit-time backstop for concurrent handover inserts (§5.8).
create function app.check_handover_limits()
returns trigger
language plpgsql
security definer   -- deferred: fires at COMMIT, outside the definer RPC that queued it
set search_path = ''
as $$
declare
  v_set jsonb := app.settlement(new.closing_id, app.allowed_payable(new.closing_id));
begin
  if (v_set ->> 'net_transferred')::bigint < 0 then
    raise exception 'commission returns exceed handovers' using errcode = '23514';
  end if;
  if new.kind = 'handover' and (v_set ->> 'net_transferred')::bigint > (v_set ->> 'allowed')::bigint then
    raise exception 'commission handovers exceed the payable amount' using errcode = '23514';
  end if;
  if new.kind = 'overpayment_accepted'
     and (v_set ->> 'accepted_overpayment')::bigint > (v_set ->> 'excess')::bigint then
    raise exception 'accepted overpayment exceeds the excess' using errcode = '23514';
  end if;
  return null;
end;
$$;
create constraint trigger commission_handovers_limits
  after insert on public.commission_handovers
  deferrable initially deferred
  for each row execute function app.check_handover_limits();

-- Paytm CSV import (§7 fallback). Duplicate references are skipped, never overwritten. ------------------
create function public.import_paytm_transactions(p_outlet uuid, p_rows jsonb, p_source_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch    uuid := gen_random_uuid();
  v_row      jsonb;
  v_inserted int := 0;
  v_dupes    int := 0;
  v_n        int;
  v_amount   numeric;
begin
  perform app.require_permission(p_outlet, 'paytm.enter');
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) > 5000 then
    raise exception 'rows must be an array of at most 5000 transactions' using errcode = '22023';
  end if;
  for v_row in select value from jsonb_array_elements(p_rows) loop
    if coalesce(btrim(v_row ->> 'txn_ref'), '') = '' or (v_row ->> 'txn_time') is null then
      raise exception 'every row needs a transaction reference and time' using errcode = '22023';
    end if;
    v_amount := (v_row ->> 'amount')::numeric;
    if v_amount is null or v_amount <= 0 or v_amount <> trunc(v_amount) then
      raise exception 'amount for % must be positive paise', v_row ->> 'txn_ref' using errcode = '22023';
    end if;
    if coalesce(v_row ->> 'status', '') not in ('success', 'pending', 'failed', 'refunded') then
      raise exception 'status for % must be success, pending, failed or refunded', v_row ->> 'txn_ref'
        using errcode = '22023';
    end if;
    insert into public.paytm_transactions (outlet_id, txn_ref, txn_time, business_date, amount, status, method,
      import_batch, source_name, imported_by)
    values (p_outlet, btrim(v_row ->> 'txn_ref'), (v_row ->> 'txn_time')::timestamptz,
      app.business_date(p_outlet, (v_row ->> 'txn_time')::timestamptz), v_amount::bigint, v_row ->> 'status',
      coalesce(nullif(v_row ->> 'method', ''), 'unknown'), v_batch, left(p_source_name, 200), auth.uid())
    on conflict (outlet_id, txn_ref) do nothing;
    get diagnostics v_n = row_count;
    v_inserted := v_inserted + v_n;
    v_dupes := v_dupes + (1 - v_n);
  end loop;
  return jsonb_build_object('batch', v_batch, 'inserted', v_inserted, 'duplicates', v_dupes);
end;
$$;
