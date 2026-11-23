-- Revised account structure, employee deactivation, closing attribution and food (migrations 001600-001800).
begin;
\ir helpers.psql

select plan(63);

select tests.ops_fixture();
-- 'head' (= 'counter') is the outlet's Shop/Staff login. The revised food rule starts on 1 Mar 2026 here.
update public.outlets set food_rule_v2_from = '2026-03-01' where id = tests.outlet('A');
select tests.initial_float(2000, '2026-03-01');
create temp table k (name text primary key, v uuid);
grant select, insert, update on k to authenticated;
create function pg_temp.k(p text) returns uuid language sql as $$ select v from k where name = p $$;
create temp table today_ist as select (now() at time zone 'Asia/Kolkata')::date as d;
grant select on today_ist to authenticated;

-- 1. Employee management by the Shop/Staff login ---------------------------------------------------
select tests.login_as('head');
insert into k select 'divya', public.create_staff(tests.outlet('A'), 'Divya', '2026-03-01');
select ok(pg_temp.k('divya') is not null, 'Shop/Staff adds an employee');
select lives_ok($$ select public.update_staff(pg_temp.k('divya'), 'Divya R', true, 'spelling') $$,
  'Shop/Staff edits an employee');
select lives_ok($$ select public.update_staff(tests.staff('C'), 'Chetan', false, 'left the salon') $$,
  'Shop/Staff deactivates an employee');
reset role;
select is((select row(active, inactive_from)::text from public.staff where id = tests.staff('C')),
  row(false, (select d + 1 from today_ist))::text, 'deactivation is dated: inactive from tomorrow (India time)');
select ok(app.staff_assigned(tests.staff('C'), tests.outlet('A'), '2026-03-04'),
  'a deactivated employee stays valid for dates before deactivation');
select ok(not app.staff_assigned(tests.staff('C'), tests.outlet('A'), (select d + 1 from today_ist)),
  'and is not valid from the deactivation date');
select is((select count(*)::int from public.staff where id = tests.staff('C')), 1, 'the employee record is kept');
select throws_ok($$ delete from public.staff where id = '5aaa0000-0000-4000-8000-00000000000c' $$, 'P0001', null,
  'employees can never be deleted, even by the database owner');
select is((select array_agg(a.actor = tests.uid('head') order by a.id)::text from public.audit_logs a
           where a.table_name = 'staff' and (a.row_id = pg_temp.k('divya') or (a.row_id = tests.staff('C') and a.action = 'UPDATE'))),
  '{t,t,t}', 'employee added, edited and deactivated are audited with the Shop/Staff login as actor');
select is((select old_data ->> 'full_name' || ' → ' || (new_data ->> 'full_name') from public.audit_logs
           where table_name = 'staff' and row_id = pg_temp.k('divya') and action = 'UPDATE'),
  'Divya → Divya R', 'the edit keeps before and after values');
select is((select new_data ->> 'inactive_from' from public.audit_logs
           where table_name = 'staff' and row_id = tests.staff('C') and action = 'UPDATE'),
  (select (d + 1)::text from today_ist), 'the deactivation date is in the audit log');
update public.staff set active = true where id = tests.staff('A');   -- no-op update keeps a NULL date
select is((select inactive_from from public.staff where id = tests.staff('A')), null::date, 'active rows have no date');

-- 2. Food days (revised rule) ---------------------------------------------------------------------------
-- D1: commission above lunch/dinner.  S ₹20,000 → C ₹2,000; breakfast ₹300, lunch ₹1,500.
select tests.entry('service', 20000, '2026-03-02', jsonb_build_object('staff_id', tests.staff('A')));
select tests.entry('food', 300, '2026-03-02', '{"meal":"breakfast"}');
select tests.entry('food', 1500, '2026-03-02', '{"meal":"lunch"}');
-- D2: commission exactly equal (client example).  S ₹15,000 → C ₹1,500; breakfast ₹300, lunch ₹1,000, dinner ₹500.
select tests.entry('service', 15000, '2026-03-03', jsonb_build_object('staff_id', tests.staff('B')));
select tests.entry('food', 300, '2026-03-03', '{"meal":"breakfast"}');
select tests.entry('food', 1000, '2026-03-03', '{"meal":"lunch"}');
select tests.entry('food', 500, '2026-03-03', '{"meal":"dinner"}');
-- D3: lunch/dinner above commission.  S ₹15,000 → C ₹1,500; lunch ₹1,000, dinner ₹800 → ₹300 owed.
select tests.entry('service', 15000, '2026-03-04', jsonb_build_object('staff_id', tests.staff('C')));
select tests.entry('food', 1000, '2026-03-04', '{"meal":"lunch"}');
select tests.entry('food', 800, '2026-03-04', '{"meal":"dinner"}');

select is((select row(s ->> 'food_cost', s ->> 'food_breakfast_salon', s ->> 'food_shop_funded',
                      s ->> 'food_commission_funded', s ->> 'food_employee_owed', s ->> 'remaining_payable')::text
           from app.compute_day(tests.outlet('A'), '2026-03-02') s),
  row('180000', '30000', '30000', '150000', '0', '50000')::text,
  'commission > lunch/dinner: breakfast salon-funded, ₹1,500 from commission, ₹500 commission left');
select is((select row(s ->> 'food_shop_funded', s ->> 'food_commission_funded', s ->> 'food_employee_owed',
                      s ->> 'remaining_payable')::text from app.compute_day(tests.outlet('A'), '2026-03-03') s),
  row('30000', '150000', '0', '0')::text, 'commission = lunch/dinner: fully consumed, nothing owed');
select is((select row(s ->> 'food_shop_funded', s ->> 'food_commission_funded', s ->> 'food_employee_owed',
                      s ->> 'remaining_payable')::text from app.compute_day(tests.outlet('A'), '2026-03-04') s),
  row('0', '150000', '30000', '0')::text, 'lunch/dinner > commission: ₹1,500 deducted, ₹300 owed to the salon');
select ok(not ((app.compute_day(tests.outlet('A'), '2026-03-04') -> 'blockers') ? 'food_excess_unallocated'),
  'the revised rule needs no food-excess approval');
select is((select row(s ->> 'net_cash', s ->> 'food_not_paid_drawer', s ->> 'food_paid_drawer', s ->> 'commission_retained')::text
           from app.compute_day(tests.outlet('A'), '2026-03-04') s),
  row('1350000', '180000', '0', '0')::text,
  'SRS net cash = S − C (food not deducted again); unpaid food not taken from the drawer');
-- Old rule before the start date: all meals from commission, excess needs approval (shop pays).
select tests.entry('service', 1000, '2026-02-27', jsonb_build_object('staff_id', tests.staff('A')));
select tests.entry('food', 300, '2026-02-27', '{"meal":"breakfast"}');
select is((select row(s ->> 'food_commission_funded', s ->> 'food_shop_funded', s ->> 'food_employee_owed',
                      (s -> 'blockers') ? 'food_excess_unallocated')::text
           from app.compute_day(tests.outlet('A'), '2026-02-27') s),
  row('10000', '20000', '0', true)::text, 'days before the start date keep the old rule unchanged (D2/B6)');

-- 3. Closing attribution ------------------------------------------------------------------------------
create function pg_temp.draft(p_c uuid, p_notes int) returns jsonb language sql as $$
  select public.update_draft(p_c, 0, null, null, jsonb_build_object('50000', p_notes), null, 'Owner')
$$;
select tests.login_as('head');
insert into k select 'c1', (public.prepare_closing(tests.outlet('A'), '2026-03-02') ->> 'closing_id')::uuid;
select is(pg_temp.draft(pg_temp.k('c1'), 44) -> 'blockers', '["closing_employee_missing"]'::jsonb,
  'the closing employee is required');
select throws_ok($$ select public.submit_closing(pg_temp.k('c1')) $$, '22023', null,
  'a closing cannot be submitted without the employee who performed it');
select throws_ok($$ select public.set_closing_employee(pg_temp.k('c1'), tests.staff('Bstaff')) $$, '22023', null,
  'an employee of another outlet cannot be selected');
insert into k select 'esha', public.create_staff(tests.outlet('A'), 'Esha', '2026-03-10');
select throws_ok($$ select public.set_closing_employee(pg_temp.k('c1'), pg_temp.k('esha')) $$, '22023', null,
  'an employee not yet assigned on the closing date cannot be selected');
select is((select array_agg(full_name order by full_name) from public.closing_employees(tests.outlet('A'), '2026-03-02')),
  array['Asha','Bilal','Chetan','Counter Two','Divya R','Head Hari'],
  'dropdown: employees assigned and active on that date (incl. one deactivated later; not other outlets)');
select ok(not exists (select 1 from public.closing_employees(tests.outlet('A'), (select d + 1 from today_ist))
                      where id = tests.staff('C')), 'a deactivated employee is not offered for later dates');
select ok((public.set_closing_employee(pg_temp.k('c1'), tests.staff('A')) -> 'blockers') = '[]'::jsonb,
  'Shop/Staff selects who performed the closing');
insert into k select 'r1', public.submit_closing(pg_temp.k('c1'));
reset role;
select is((select row(closed_by_staff_id, submitted_by, food_employee_owed, food_breakfast_salon)::text
           from public.closing_revisions where id = pg_temp.k('r1')),
  row(tests.staff('A'), tests.uid('head'), 0::bigint, 30000::bigint)::text,
  'revision stores the closing employee separately from the authenticated submitter (Shop/Staff login)');
select is((select actor from public.closing_events where revision_id = pg_temp.k('r1') and type = 'submitted'),
  tests.uid('head'), 'the submission event names the login, not the employee');
select is((select new_data ->> 'closed_by_staff_id' from public.audit_logs
           where table_name = 'closing_drafts' and action = 'UPDATE' and new_data ->> 'closing_id' = pg_temp.k('c1')::text
             and old_data ->> 'closed_by_staff_id' is null and new_data ->> 'closed_by_staff_id' is not null),
  tests.staff('A')::text, 'the selection is in the audit log');

select tests.login_as('head');
insert into k select 'c2', (public.prepare_closing(tests.outlet('A'), '2026-03-03') ->> 'closing_id')::uuid;
select pg_temp.draft(pg_temp.k('c2'), 34);
select public.set_closing_employee(pg_temp.k('c2'), tests.staff('B'));
insert into k select 'r2', public.submit_closing(pg_temp.k('c2'));
insert into k select 'c3', (public.prepare_closing(tests.outlet('A'), '2026-03-04') ->> 'closing_id')::uuid;
select pg_temp.draft(pg_temp.k('c3'), 34);
select lives_ok($$ select public.set_closing_employee(pg_temp.k('c3'), tests.staff('C')) $$,
  'an employee deactivated after the closing date can still be named for it');
insert into k select 'r3', public.submit_closing(pg_temp.k('c3'));
select throws_ok($$ select public.set_closing_employee(pg_temp.k('c3'), tests.staff('A')) $$, 'SO423', null,
  'attribution of a submitted closing cannot be changed without reopening');
select throws_ok($$ select public.approve_closing(pg_temp.k('r3'), '{}') $$, '42501', null,
  'Shop/Staff cannot approve its own closing');
select throws_ok($$ select public.reopen_closing(pg_temp.k('c3'), 'x') $$, '42501', null, 'Shop/Staff cannot reopen');
reset role;

-- Revision snapshots (D2 exact, D3 owed) and drawer unchanged.
select is((select row(food_cost, food_shop_funded, food_commission_funded, food_employee_owed, remaining_payable,
                      expected_drawer, counted_cash, variance)::text from public.closing_revisions where id = pg_temp.k('r3')),
  row(180000, 0, 150000, 30000, 0, 1700000, 1700000, 0)::text,
  'D3 revision: ₹300 owed is stored; expected drawer = opening + cash sales (not reduced by the debt)');
select is((select row(food_breakfast_salon, food_commission_funded, food_employee_owed, remaining_payable)::text
           from public.closing_revisions where id = pg_temp.k('r2')),
  row(30000, 150000, 0, 0)::text, 'D2 revision: breakfast salon expense, commission fully used, nothing owed');
select is((select closed_by_staff_id from public.closing_revisions where id = pg_temp.k('r3')), tests.staff('C'),
  'the historical closing keeps the (now deactivated) employee');

-- 4. Food debt and repayments ---------------------------------------------------------------------------
select tests.login_as('head');
select is((select row(s ->> 'owed_approved', s ->> 'owed_pending_approval', s ->> 'outstanding')::text
           from public.food_debt_summary(tests.outlet('A')) s),
  row('0', '30000', '0')::text, 'before approval the ₹300 is pending, not outstanding');
select throws_ok($$ select public.record_food_repayment(tests.outlet('A'), 10000, 'cash', '2026-03-05', '{}', null) $$,
  '42501', null, 'Shop/Staff cannot record a repayment (received by the owner)');
reset role;
select tests.login_as('owner');
select throws_ok($$ select public.record_food_repayment(tests.outlet('A'), 10000, 'cash', '2026-03-05', '{}', null) $$,
  '22023', null, 'nothing can be repaid before the closing is approved');
select lives_ok($$ select public.approve_closing(pg_temp.k('r1'), '{}') $$, 'owner approves D1');
select lives_ok($$ select public.approve_closing(pg_temp.k('r2'), '{}') $$, 'owner approves D2');
select lives_ok($$ select public.approve_closing(pg_temp.k('r3'), '{}') $$, 'owner approves D3');
select is((select row(s ->> 'owed_approved', s ->> 'repaid', s ->> 'outstanding', s -> 'days' -> 0 ->> 'business_date')::text
           from public.food_debt_summary(tests.outlet('A')) s),
  row('30000', '0', '30000', '2026-03-04')::text, 'after approval ₹300 is outstanding, listed against 4 Mar');
select is((select count(*)::int from public.food_repayments), 0, 'appearing in a closing does not mark it repaid');
insert into k select 'rep1', public.record_food_repayment(tests.outlet('A'), 20000, 'cash', '2026-03-05',
  array[tests.staff('A'), tests.staff('C')], 'handed to owner');
select is((select row(amount, payment_method, received_on, recorded_by, staff_ids)::text from public.food_repayments
           where id = pg_temp.k('rep1')),
  row(20000::bigint, 'cash'::public.payment_method, date '2026-03-05', tests.uid('owner'),
      array[tests.staff('A'), tests.staff('C')])::text, 'repayment stored with amount, method, date, actor, employees');
select is((select (s ->> 'outstanding')::bigint from public.food_debt_summary(tests.outlet('A')) s), 10000::bigint,
  'outstanding drops to ₹100');
select throws_ok($$ select public.record_food_repayment(tests.outlet('A'), 20000, 'paytm', '2026-03-05', '{}', null) $$,
  '22023', null, 'cannot repay more than is outstanding');
select throws_ok($$ select public.record_food_repayment(tests.outlet('A'), 5000, 'cash', '2026-03-05',
                    array['5bbb0000-0000-4000-8000-00000000000b']::uuid[], null) $$,
  '22023', null, 'employees named must belong to the outlet');
select throws_ok($$ select public.record_food_repayment(tests.outlet('A'), 5000, 'cash', current_date + 30, '{}', null) $$,
  '22023', null, 'a repayment cannot be dated in the future');
select is((select row(expected_drawer, variance)::text from public.closing_revisions where id = pg_temp.k('r3')),
  row(1700000, 0)::text, 'the frozen closing is untouched by the repayment');
reset role;
select is((select (s ->> 'expected_drawer')::bigint from app.compute_day(tests.outlet('A'), '2026-03-05') s),
  (select retained_float from public.closing_revisions where id = pg_temp.k('r3')),
  'the repayment is not drawer cash on any day (next day opens with the retained float only)');
select tests.login_as('owner');
select throws_ok($$ update public.food_repayments set amount = 1 $$, '42501', null, 'clients cannot write repayments directly');
reset role;
select throws_ok($$ update public.food_repayments set amount = 1 $$, 'P0001', null, 'repayments are immutable even for the database owner');
select tests.login_as('owner');
select throws_ok($$ select public.reverse_food_repayment(pg_temp.k('rep1'), '') $$, '22023', null, 'a reversal needs a reason');
select lives_ok($$ select public.reverse_food_repayment(pg_temp.k('rep1'), 'typed the wrong amount') $$, 'owner reverses a repayment');
select throws_ok($$ select public.reverse_food_repayment(pg_temp.k('rep1'), 'again') $$, '23505', null,
  'a repayment can be reversed only once');
select is((select (s ->> 'outstanding')::bigint from public.food_debt_summary(tests.outlet('A')) s), 30000::bigint,
  'after the reversal ₹300 is outstanding again');
select ok((select count(*) from public.audit_logs where table_name = 'food_repayments') = 2,
  'repayment and reversal are audited');
reset role;
select tests.login_as('outsider');
select throws_ok($$ select public.food_debt_summary(tests.outlet('A')) $$, '42501', null,
  'another outlet''s owner cannot read the food debt');
select is((select count(*)::int from public.food_repayments), 0, 'nor see its repayments');
reset role;

-- 5. Reopen and change the attribution: the original stays in revision 1 and the audit log. ----------
select tests.login_as('owner');
select lives_ok($$ select public.reopen_closing(pg_temp.k('c3'), 'wrong employee named') $$, 'owner reopens D3');
reset role;
select tests.login_as('head');
select public.set_closing_employee(pg_temp.k('c3'), tests.staff('B'));
insert into k select 'r3b', public.submit_closing(pg_temp.k('c3'));
reset role;
select is((select array_agg(closed_by_staff_id order by revision_no)::text from public.closing_revisions
           where closing_id = pg_temp.k('c3')),
  array[tests.staff('C'), tests.staff('B')]::text, 'revision 1 keeps the original employee; revision 2 the new one');
select is((select (old_data ->> 'closed_by_staff_id') || '>' || (new_data ->> 'closed_by_staff_id') from public.audit_logs
           where table_name = 'closing_drafts' and new_data ->> 'closing_id' = pg_temp.k('c3')::text
             and old_data ->> 'closed_by_staff_id' = tests.staff('C')::text),
  tests.staff('C')::text || '>' || tests.staff('B')::text, 'the change is audited with old and new values');
select is((select row(s ->> 'owed_approved', s ->> 'owed_pending_approval')::text from public.food_debt_summary(tests.outlet('A')) s),
  row('0', '30000')::text, 'a reopened day''s debt counts again only once re-approved');

select * from finish();
rollback;
