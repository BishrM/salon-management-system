begin;
\ir helpers.psql
select tests.ops_fixture();

select plan(68);

-- §5.1 / D1 commission pool and largest-remainder allocation -------------------------------------------------
create function pg_temp.alloc(p_date date) returns jsonb language sql as $$
  select app.compute_day(tests.outlet('A'), p_date)
$$;
create function pg_temp.svc(p_staff text, p_rupees bigint, p_date date) returns uuid language sql as $$
  select tests.entry('service', p_rupees, p_date, jsonb_build_object('staff_id', tests.staff(p_staff)))
$$;

-- SRS §3.1 example: S = 15,550 → C = 1,550.
select pg_temp.svc('A', 15550, '2025-01-01');
select is((pg_temp.alloc('2025-01-01') ->> 'commission_pool')::bigint, 155000::bigint, 'S ₹15,550 → pool ₹1,550 (rounded down to ₹10)');
-- Rev 6 §5.1 statement example: 3,090 / 4,090 / 2,880 → 310 / 410 / 280, Σ adj = −6.
select pg_temp.svc('A', 3090, '2025-01-02'), pg_temp.svc('B', 4090, '2025-01-02'), pg_temp.svc('C', 2880, '2025-01-02');
select is((pg_temp.alloc('2025-01-02') ->> 'commission_pool')::bigint, 100000::bigint, 'S ₹10,060 → pool ₹1,000');
select results_eq(
  $$ select (a ->> 'staff_name'), (a ->> 'exact_share')::bigint, (a ->> 'allocated')::bigint, (a ->> 'rounding_adj')::bigint
     from jsonb_array_elements(app.compute_day(tests.outlet('A'), '2025-01-02') -> 'allocations') a order by 1 $$,
  $$ values ('Asha', 30900::bigint, 31000::bigint, 100::bigint), ('Bilal', 40900, 41000, 100), ('Chetan', 28800, 28000, -800) $$,
  'statement: exact 10%, allocated ₹10 shares and rounding adjustment per employee (J3)');
select is((select sum((a ->> 'rounding_adj')::bigint) from jsonb_array_elements(pg_temp.alloc('2025-01-02') -> 'allocations') a),
  -600::numeric, 'Σ rounding adjustments = C − Σ exact = −₹6');
-- S = 0, S < ₹100, one employee.
select is((pg_temp.alloc('2025-01-03') ->> 'commission_pool')::bigint, 0::bigint, 'no sales → pool 0');
select is(pg_temp.alloc('2025-01-03') -> 'allocations', '[]'::jsonb, 'no sales → no allocations');
select pg_temp.svc('A', 90, '2025-01-04');
select is((pg_temp.alloc('2025-01-04') -> 'allocations' -> 0 ->> 'allocated')::bigint, 0::bigint, 'S ₹90 → pool 0, share 0');
select pg_temp.svc('A', 199, '2025-01-05');
select is((pg_temp.alloc('2025-01-05') -> 'allocations' -> 0 ->> 'allocated')::bigint, 1000::bigint, 'one employee gets the whole pool');
-- Ties: equal remainders → higher sales first, then staff id.
select pg_temp.svc('A', 1050, '2025-01-06'), pg_temp.svc('B', 1050, '2025-01-06'), pg_temp.svc('C', 1950, '2025-01-06');
select results_eq(
  $$ select (a ->> 'staff_name'), (a ->> 'allocated')::bigint
     from jsonb_array_elements(app.compute_day(tests.outlet('A'), '2025-01-06') -> 'allocations') a order by 1 $$,
  $$ values ('Asha', 10000::bigint), ('Bilal', 10000), ('Chetan', 20000) $$,
  'remainder ties: 1050/1050/1950 → pool ₹400 → 100/100/200');
select pg_temp.svc('A', 1150, '2025-01-07'), pg_temp.svc('B', 1150, '2025-01-07'), pg_temp.svc('C', 1000, '2025-01-07');
select is((select sum((a ->> 'allocated')::bigint) from jsonb_array_elements(pg_temp.alloc('2025-01-07') -> 'allocations') a),
  (pg_temp.alloc('2025-01-07') ->> 'commission_pool')::numeric, 'shares always sum to the pool');
select is((select a ->> 'staff_name' from jsonb_array_elements(pg_temp.alloc('2025-01-07') -> 'allocations') a
           where (a ->> 'allocated')::bigint = 12000), 'Asha',
  'equal remainder and equal sales → lower staff id wins the extra ₹10');
-- Product sales are excluded from commission.
select tests.entry('product', 5000, '2025-01-07');
select is((pg_temp.alloc('2025-01-07') ->> 'commission_pool')::bigint, 33000::bigint, 'product sales never change the pool');

-- §5.3 cash model: worked examples A–M (pure function, integer paise) -------------------------------------
create function pg_temp.m(p jsonb) returns jsonb language sql as $$ select app.cash_model(p) $$;
create temp table base as select jsonb_build_object(
  'R', 200000, 'PF', 0, 'I', 0, 'S', 1555000, 'P', 120000, 'paytm', 640000, 'E', 50000, 'Z', 5000,
  'F', 70000, 'f_today', 70000, 'f_prior', 0, 'H', 85000, 'RF', 200000) b;
create function pg_temp.case_(p jsonb) returns jsonb language sql as $$ select app.cash_model((select b from base) || p) $$;
select is(pg_temp.case_('{"CC":1025000}') - array['C','FC','FX','payable','O','CS','Fd','U'],
  '{"N":825000,"Rc":0,"ED":1025000,"V":0,"AF":200000,"FS":0,"TH":825000}'::jsonb, 'A normal: ED 10,250, TH 8,250');
select is(pg_temp.case_('{"CC":1025000}') ->> 'CS', '1035000', 'base CS = S + P − Paytm = 10,350');
select is((select (r ->> 'O')::bigint + (r ->> 'I')::bigint + (r ->> 'N')::bigint + (r ->> 'Rc')::bigint + (r ->> 'U')::bigint
                  - 0 - (r ->> 'FX')::bigint from (select pg_temp.case_('{"CC":1025000}') || '{"I":0}' r) x),
  1025000::bigint, 'bridge: O + I + N + Rc + U − Fprior − FX = ED');
select is(pg_temp.case_('{"CC":1010000}') -> 'V', '-15000', 'B shortage: V −150');
select is(pg_temp.case_('{"CC":1030000}') -> 'V', '5000', 'C surplus: V +50');
select is(pg_temp.case_('{"paytm":1500000,"CC":165000}') - array['C','FC','FX','payable','O','CS','Fd','U','Rc'],
  '{"N":-35000,"ED":165000,"V":0,"AF":165000,"FS":35000,"TH":0}'::jsonb, 'D shortfall: N −350, AF 1,650, FS 350');
select is(pg_temp.case_('{"RF":300000,"CC":1025000}') -> 'TH', '725000', 'E RF 3,000: AF 3,000, TH 7,250');
select is(pg_temp.case_('{"paytm":1500000,"CC":160000}') - array['C','FC','FX','payable','O','CS','Fd','U','Rc','N','ED'],
  '{"V":-5000,"AF":160000,"FS":40000,"TH":0}'::jsonb, 'F shortage + shortfall: V −50, FS 400');
select is(pg_temp.case_('{"I":50000,"CC":1075000}') - array['C','FC','FX','payable','CS','Fd','U','Rc','N'],
  '{"O":200000,"ED":1075000,"V":0,"AF":200000,"FS":0,"TH":875000}'::jsonb, 'G intraday top-up: O stays 2,000, ED 10,750');
select is(pg_temp.case_('{"PF":100000,"RF":300000,"CC":1125000}') - array['C','FC','FX','payable','CS','Fd','U','Rc','N'],
  '{"O":300000,"ED":1125000,"V":0,"AF":300000,"FS":0,"TH":825000}'::jsonb, 'H pre-opening funding: O 3,000, ED 11,250');
select is(pg_temp.case_('{"H":50000,"CC":1060000}') - array['C','FC','FX','payable','O','CS','Fd','U','N','FS','AF'],
  '{"Rc":35000,"ED":1060000,"V":0,"TH":860000}'::jsonb, 'J partial handover: Rc 350, ED 10,600, no variance');
select is(pg_temp.case_('{"f_today":0,"CC":1095000}') - array['C','FC','FX','payable','O','CS','N','FS','AF','Rc'],
  '{"Fd":0,"U":70000,"ED":1095000,"V":0,"TH":895000}'::jsonb, 'K unpaid food: never reduces ED (10,950)');
select is(pg_temp.case_('{"f_prior":70000,"CC":955000}') - array['C','FC','FX','payable','O','CS','N','FS','AF','Rc','U'],
  '{"Fd":140000,"ED":955000,"V":0,"TH":755000}'::jsonb, 'L next day pays yesterday''s food: Fd 1,400, ED 9,550');
select is(pg_temp.case_('{"S":1545000,"CC":1015000}') - array['FC','FX','O','CS','N','FS','AF','U','Fd','TH'],
  '{"C":154000,"payable":84000,"Rc":-1000,"ED":1015000,"V":0}'::jsonb,
  'M correction after count: C 1,540, payable 840, H fixed 850 → Rc −10, V 0');
select is(pg_temp.m('{"S":1000000,"F":150000}') - array['O','CS','N','Fd','U','Rc','ED','V','AF','FS','TH'],
  '{"C":100000,"FC":100000,"FX":50000,"payable":0}'::jsonb, 'F > C: FC = C, FX = F − C, payable 0');
select is(pg_temp.m('{"S":1000000,"F":100000}') ->> 'FX', '0', 'F = C: nothing shop-funded');

-- End-to-end: four days through the real RPCs ---------------------------------------------------------------
-- D1 base (case A), D2 unpaid food (K), D3 pays D2's food (L), D4 correction after count (M).
select tests.initial_float(2000, '2026-01-05');
create function pg_temp.day(p_date date, p_pay_food boolean, p_dup boolean) returns void language plpgsql as $$
declare v_food uuid;
begin
  perform pg_temp.svc('A', case when p_dup then 5450 else 5550 end, p_date);
  perform pg_temp.svc('B', 6000, p_date);
  perform pg_temp.svc('C', 4000, p_date);
  if p_dup then perform pg_temp.svc('A', 100, p_date); end if;
  perform tests.entry('product', 800, p_date);
  perform tests.entry('product', 400, p_date, '{"payment_method":"paytm"}');
  perform tests.entry('expense', 500, p_date);
  perform tests.entry('expense', 300, p_date, '{"expense_source":"outside_drawer"}');
  perform tests.entry('zakat', 50, p_date);
  v_food := tests.entry('food', 700, p_date);
  if p_pay_food then perform tests.food_pay(v_food, 700, p_date); end if;
end $$;
select pg_temp.day('2026-01-05', true, false);
select pg_temp.day('2026-01-06', false, false);
select pg_temp.day('2026-01-07', true, false);
select tests.food_pay((select id from public.entries where kind = 'food' and business_date = '2026-01-06'), 700, '2026-01-07');
select pg_temp.day('2026-01-08', true, true);

create temp table c (d date primary key, closing uuid, rev uuid);
grant select, insert, update on c to authenticated;
create function pg_temp.close_day(p_date date, p_den jsonb, p_handover bigint) returns uuid language plpgsql as $$
declare v_c uuid; v_r uuid;
begin
  v_c := (public.prepare_closing(tests.outlet('A'), p_date) ->> 'closing_id')::uuid;
  perform public.update_draft(v_c, 640000, 400000, 240000, p_den, null, 'Owner (take-home)');
  if p_handover > 0 then perform public.record_handover(v_c, tests.staff('headstaff'), p_handover, 'drawer'); end if;
  v_r := public.submit_closing(v_c);
  insert into c values (p_date, v_c, v_r) on conflict (d) do update set closing = excluded.closing, rev = excluded.rev;
  return v_r;
end $$;

select tests.login_as('head');
select lives_ok($$ select pg_temp.close_day('2026-01-05', '{"50000":20,"20000":1,"5000":1}', 85000) $$,
  'head prepares, records the drawer handover and submits D1');
reset role;
select is((select row(service_total, commission_pool, product_total, product_paytm, cash_sales, expenses_total,
                      expenses_outside_total, zakat_total, food_cost, food_paid_drawer, drawer_handover_total,
                      net_cash, expected_drawer, counted_cash, variance, retained_float, take_home)::text
           from public.closing_revisions where id = (select rev from c where d = '2026-01-05')),
  row(1555000, 155000, 120000, 40000, 1035000, 50000, 30000, 5000, 70000, 70000, 85000,
      825000, 1025000, 1025000, 0, 200000, 825000)::text,
  'D1 revision snapshot matches case A (outside-drawer expense not deducted, O2)');
select is((select row(opening_float, retained_float_carried, initial_float_movement_id is not null)::text
           from public.closing_revisions where id = (select rev from c where d = '2026-01-05')),
  row(200000, 200000, true)::text, 'D1 opens with the initial float');
select is((select count(*)::int from public.revision_denominations where revision_id = (select rev from c where d = '2026-01-05')), 3,
  'denomination counts stored with the revision');
select is((select sum(allocated) from public.revision_commission_allocations where revision_id = (select rev from c where d = '2026-01-05')),
  155000::numeric, 'allocations stored and sum to the pool');
select is((select state from public.closing_state where closing_id = (select closing from c where d = '2026-01-05')),
  'submitted', 'closing state derived as submitted');

select tests.login_as('head');
select lives_ok($$ select pg_temp.close_day('2026-01-06', '{"50000":21,"20000":2,"5000":1}', 85000) $$,
  'D2 submitted while D1 awaits approval (D4)');
reset role;
select is((select row(retained_float_carried, food_paid_drawer, food_not_paid_drawer, expected_drawer, variance)::text
           from public.closing_revisions where id = (select rev from c where d = '2026-01-06')),
  row(200000, 0, 70000, 1095000, 0)::text, 'D2 (case K): unpaid food leaves ED at 10,950');
select is((select opening_float_source_revision_id from public.closing_revisions where id = (select rev from c where d = '2026-01-06')),
  (select rev from c where d = '2026-01-05'), 'D2 opening float sourced from D1''s revision');

select tests.login_as('manager');
select throws_ok($$ select public.approve_closing((select rev from c where d = '2026-01-06'), '{}') $$, '22023', null,
  'D2 cannot be approved before D1');
select lives_ok($$ select public.approve_closing((select rev from c where d = '2026-01-05'), '{}') $$, 'manager approves D1');
select lives_ok($$ select public.approve_closing((select rev from c where d = '2026-01-06'), '{}') $$, 'then D2');
reset role;

select tests.login_as('head');
select lives_ok($$ select pg_temp.close_day('2026-01-07', '{"50000":19,"5000":1}', 85000) $$, 'D3 submitted');
reset role;
select is((select row(food_paid_drawer_today, food_paid_drawer_prior, expected_drawer, take_home)::text
           from public.closing_revisions where id = (select rev from c where d = '2026-01-07')),
  row(70000, 70000, 955000, 755000)::text, 'D3 (case L): yesterday''s food paid today counts as Fprior; ED 9,550');
select tests.login_as('manager');
select lives_ok($$ select public.approve_closing((select rev from c where d = '2026-01-07'), '{}') $$, 'D3 approved');
reset role;

-- D4 (case M): duplicate ₹100 sale; counted cash is ₹100 short.
select tests.login_as('head');
select throws_ok($$ select pg_temp.close_day('2026-01-08', '{"50000":20,"10000":1,"5000":1}', 85000) $$, '22023', null,
  'a variance needs a reason before submission');
reset role;
select tests.login_as('head');
select lives_ok($$ select public.update_draft((select (public.prepare_closing(tests.outlet('A'), '2026-01-08') ->> 'closing_id')::uuid),
   640000, null, null, '{"50000":20,"10000":1,"5000":1}', 'drawer ₹100 short, cause unknown', 'Owner') $$, 'reason recorded');
select lives_ok($$ select public.record_handover((select id from public.daily_closings where business_date = '2026-01-08'),
   tests.staff('headstaff'), 85000, 'drawer') $$, 'full commission handed over from the drawer');
select lives_ok($$ insert into c select '2026-01-08', id, public.submit_closing(id) from public.daily_closings
                  where business_date = '2026-01-08' $$, 'D4 revision 1 submitted with V −100');
reset role;
select is((select variance from public.closing_revisions where id = (select rev from c where d = '2026-01-08')), -10000::bigint,
  'revision 1 shows V −100');
select tests.login_as('manager');
select throws_ok($$ select public.approve_closing((select rev from c where d = '2026-01-08'), '{}') $$, '22023',
  'acknowledge before approving: variance', 'variance must be acknowledged at approval');
select lives_ok($$ select public.reopen_closing((select closing from c where d = '2026-01-08'), 'duplicate sale found') $$,
  'manager reopens D4');
reset role;
select tests.login_as('counter');
select is(public.sync_ops(tests.outlet('A'), gen_random_uuid(), 'Tablet', jsonb_build_array(tests.op('void_entry',
  (select id from public.entries where business_date = '2026-01-08' and kind = 'service' and amount = 10000), 1, '{}',
  '{"base_version":1,"reason":"entered twice"}'))) -> 'results' -> 0 ->> 'status', 'applied', 'duplicate voided after reopen');
reset role;
select tests.login_as('head');
select throws_ok($$ select public.record_handover((select closing from c where d = '2026-01-08'), tests.staff('headstaff'), 1000, 'drawer') $$,
  'SO423', null, 'no drawer handovers once the day has a revision (reopen does not reopen the drawer)');
select lives_ok($$ select public.update_draft((select closing from c where d = '2026-01-08'), 640000, null, null,
   '{"50000":20,"10000":1,"5000":1}', null, 'Owner') $$, 'variance reason cleared');
select lives_ok($$ update c set rev = public.submit_closing(closing) where d = '2026-01-08' $$, 'revision 2 submitted');
reset role;
select is((select row(revision_no, service_total, commission_pool, remaining_payable, drawer_handover_total,
                      commission_retained, expected_drawer, variance)::text
           from public.closing_revisions where id = (select rev from c where d = '2026-01-08')),
  row(2, 1545000, 154000, 84000, 85000, -1000, 1015000, 0)::text,
  'revision 2 (case M): C 1,540, H stays 850, Rc −10, V 0');
select is((select variance from public.closing_revisions where closing_id = (select closing from c where d = '2026-01-08') and revision_no = 1),
  -10000::bigint, 'revision 1 is unchanged');
select tests.login_as('manager');
select throws_ok($$ select public.approve_closing((select rev from c where d = '2026-01-08'), '{}') $$, '22023', null,
  'over-handed commission (₹10) blocks approval (B10)');
select throws_ok($$ select public.accept_commission_overpayment((select closing from c where d = '2026-01-08'), 2000, 'x') $$,
  '22023', null, 'cannot accept more than the excess');
select lives_ok($$ select public.accept_commission_overpayment((select closing from c where d = '2026-01-08'), 1000, 'head keeps ₹10') $$,
  'manager accepts the ₹10 overpayment');
reset role;
select is((select app.settlement((select closing from c where d = '2026-01-08'), 84000) - array['allowed','gross_handed','handed_outside_drawer','returned','drawer_net','outstanding']),
  '{"net_transferred":85000,"excess":1000,"accepted_overpayment":1000,"unresolved_excess":0,"status":"over_handed_accepted"}'::jsonb,
  'accepted overpayment resolves the blocker without changing net transferred');
select tests.login_as('manager');
select throws_ok($$ select public.record_handover((select closing from c where d = '2026-01-08'), tests.staff('headstaff'), 1000, 'outside_drawer') $$,
  '22023', null, 'accepted overpayment gives no new handover headroom');
select lives_ok($$ select public.approve_closing((select rev from c where d = '2026-01-08'), '{}') $$, 'D4 approved');
reset role;

-- Revisions are insert-only even for the database owner -------------------------------------------------------
select throws_ok($$ update public.closing_revisions set variance = 0 $$, 'P0001', null, 'revisions cannot be updated');
select throws_ok($$ delete from public.closing_revisions $$, 'P0001', null, 'revisions cannot be deleted');
select throws_ok($$ delete from public.closing_events $$, 'P0001', null, 'closing events cannot be deleted');
select throws_ok($$ update public.revision_commission_allocations set allocated = 0 $$, 'P0001', null, 'allocations are immutable');
select throws_ok($$ update public.commission_handovers set amount = 1 $$, 'P0001', null, 'handovers are immutable');
-- A revision violating ED = O + I + CS − E − Z − Fd − H is rejected by CHECK.
select throws_ok($$ insert into public.closing_revisions
  select (jsonb_populate_record(r, jsonb_build_object('id', gen_random_uuid(), 'revision_no', 99, 'expected_drawer', r.expected_drawer + 100))).*
  from public.closing_revisions r where id = (select rev from c where d = '2026-01-05') $$,
  '23514', null, 'a revision breaking the expected-drawer invariant cannot be inserted');

select * from finish();
rollback;
