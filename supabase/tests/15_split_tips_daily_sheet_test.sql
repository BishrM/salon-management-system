begin;
\ir helpers.psql
select tests.ops_fixture();

-- Migration …002200 (2026-11-24): split payments, explicit tips, the Paytm statement reconciliation,
-- Daily Sheet opening and the owner's sheet-change feed.
select plan(56);

create temp table ids (k text primary key, v uuid);
grant select, insert on ids to authenticated;
insert into ids select k, gen_random_uuid()
  from unnest(array['dev', 'cash', 'paytm', 'split', 'tipd', 'splittip', 'prod', 'bad1', 'bad2', 'bad3', 'bad4',
                    'bad5', 'off', 'late1', 'dev2']) k;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
grant execute on function pg_temp.id(text) to authenticated;
create temp table d (today date);
insert into d select app.business_date(tests.outlet('A'), now());
grant select on d to authenticated;
create function pg_temp.today() returns date language sql as $$ select today from d $$;
grant execute on function pg_temp.today() to authenticated;

create function pg_temp.svc(p_staff text, p_rupees int, p_extra jsonb) returns jsonb language sql as $$
  select jsonb_build_object('kind', 'service', 'staff_id', tests.staff(p_staff), 'amount', p_rupees * 100) || p_extra $$;
grant execute on function pg_temp.svc(text, int, jsonb) to authenticated;
create temp table ops (k text primary key, v jsonb);
grant select on ops to authenticated;
insert into ops values
  ('cash',     tests.op('create_entry', (select v from ids where k = 'cash'), 1, pg_temp.svc('A', 150, '{"payment_method":"cash"}'))),
  ('paytm',    tests.op('create_entry', (select v from ids where k = 'paytm'), 2, pg_temp.svc('B', 200, '{"payment_method":"paytm"}'))),
  ('split',    tests.op('create_entry', (select v from ids where k = 'split'), 3,
                 pg_temp.svc('A', 150, '{"payment_method":"split","split_cash":10000,"split_paytm":5000}'))),
  -- ₹150 service paid ₹200 digitally; the operator marks ₹50 as a tip.
  ('tipd',     tests.op('create_entry', (select v from ids where k = 'tipd'), 4,
                 pg_temp.svc('C', 150, '{"payment_method":"paytm","tip_paytm":5000}'))),
  ('splittip', tests.op('create_entry', (select v from ids where k = 'splittip'), 5,
                 pg_temp.svc('B', 300, '{"payment_method":"split","split_cash":20000,"split_paytm":10000,"tip_cash":2000}'))),
  ('prod',     tests.op('create_entry', (select v from ids where k = 'prod'), 6,
                 jsonb_build_object('kind', 'product', 'product_id', '9a000000-0000-4000-8000-000000000001', 'quantity', 1,
                                    'unit_price', 25000, 'payment_method', 'paytm'))),
  ('bad1',     tests.op('create_entry', (select v from ids where k = 'bad1'), 7,
                 pg_temp.svc('A', 150, '{"payment_method":"split","split_cash":10000,"split_paytm":4000}'))),
  ('bad2',     tests.op('create_entry', (select v from ids where k = 'bad2'), 8,
                 pg_temp.svc('A', 150, '{"payment_method":"split","split_cash":15000}'))),
  ('bad3',     tests.op('create_entry', (select v from ids where k = 'bad3'), 9,
                 pg_temp.svc('A', 150, '{"payment_method":"split","split_cash":"-5000","split_paytm":20000}'))),
  ('bad4',     tests.op('create_entry', (select v from ids where k = 'bad4'), 10,
                 jsonb_build_object('kind', 'product', 'product_id', '9a000000-0000-4000-8000-000000000001', 'quantity', 1,
                                    'unit_price', 25000, 'payment_method', 'split'))),
  ('bad5',     tests.op('create_entry', (select v from ids where k = 'bad5'), 11,
                 jsonb_build_object('kind', 'expense', 'amount', 5000, 'description', 'Tea', 'tip_cash', 1000))),
  -- Recorded offline 20 minutes ago, synced now.
  ('off',      tests.op('create_entry', (select v from ids where k = 'off'), 12,
                 pg_temp.svc('C', 100, '{"payment_method":"split","split_cash":6000,"split_paytm":4000}'),
                 jsonb_build_object('device_time', now() - interval '20 minutes', 'device_last_sync_at', now() - interval '25 minutes')));
create function pg_temp.op(p text) returns jsonb language sql as $$ select v from ops where k = p $$;
grant execute on function pg_temp.op(text) to authenticated;
create function pg_temp.send(p_op jsonb, p_dev text default 'dev') returns jsonb language sql as $$
  select public.sync_ops(tests.outlet('A'), pg_temp.id(p_dev), 'Tablet', jsonb_build_array(p_op)) -> 'results' -> 0 $$;
grant execute on function pg_temp.send(jsonb, text) to authenticated;
create function pg_temp.sum() returns jsonb language sql as $$ select public.day_summary(tests.outlet('A'), pg_temp.today()) $$;
grant execute on function pg_temp.sum() to authenticated;

-- 1–4. Payment methods, split and tips ----------------------------------------------------------------------
select tests.login_as('head');
select is(pg_temp.send(pg_temp.op('cash')) ->> 'status', 'applied', '1. cash-only service sale is applied');
select is(pg_temp.send(pg_temp.op('paytm')) ->> 'status', 'applied', '2. Paytm-only service sale is applied');
select is(pg_temp.send(pg_temp.op('split')) ->> 'status', 'applied', '3. split cash + Paytm service sale is applied');
select is((select row(kind, amount, payment_method::text, split_cash, split_paytm, tip_cash, tip_paytm)::text
           from public.entries where id = pg_temp.id('split')),
  row('service', 15000::bigint, 'split', 10000::bigint, 5000::bigint, 0::bigint, 0::bigint)::text,
  '3. one service entry with two payment allocations (not two entries)');
select is((select count(*)::int from public.entries where op_id = (pg_temp.op('split') ->> 'op_id')::uuid), 1,
  '3. the split sale is a single entry');
select is(pg_temp.send(pg_temp.op('tipd')) ->> 'status', 'applied', '4. Paytm sale with an explicit digital tip is applied');
select is(pg_temp.send(pg_temp.op('splittip')) ->> 'status', 'applied', '4. split sale with an explicit cash tip is applied');
select is((select row(amount, split_cash, split_paytm, tip_cash)::text from public.entries where id = pg_temp.id('splittip')),
  row(30000::bigint, 20000::bigint, 10000::bigint, 2000::bigint)::text, '4. the tip is stored apart from the service amount');
select is(pg_temp.send(pg_temp.op('prod')) ->> 'status', 'applied', '5. digital product sale is applied');

select is(pg_temp.send(pg_temp.op('bad1')) ->> 'status', 'failed', 'split parts that do not add up are refused');
select ok(pg_temp.send(pg_temp.op('bad1')) ->> 'error' like '%must equal the service amount%', 'the mismatch error says why');
select is(pg_temp.send(pg_temp.op('bad2')) ->> 'status', 'failed', 'a split needs both parts');
select is(pg_temp.send(pg_temp.op('bad3')) ->> 'status', 'failed', 'a negative split part is refused');
select is(pg_temp.send(pg_temp.op('bad4')) ->> 'status', 'failed', 'a product cannot be split');
select is(pg_temp.send(pg_temp.op('bad5')) ->> 'status', 'failed', 'a tip can only be recorded on a service sale');
select is((select count(*)::int from public.entries where id in (pg_temp.id('bad1'), pg_temp.id('bad2'), pg_temp.id('bad3'),
           pg_temp.id('bad4'), pg_temp.id('bad5'))), 0, 'refused sales leave no entry');
select ok((select (r ->> 'duplicate')::boolean and r ->> 'status' = 'applied' from pg_temp.send(pg_temp.op('split')) r),
  '8. re-sending the same split op is an idempotent success');
select is((select count(*)::int from public.entries where id = pg_temp.id('split')), 1, '8. the retry created no second sale');
reset role;
select throws_ok($$ update public.entries set split_paytm = 6000 where id = pg_temp.id('split') $$, '23514', null,
  'the database refuses split parts that do not add up to the amount');

-- 9. Offline split sale, synced later
select tests.login_as('head');
-- (A second tablet: its first op, made 20 minutes ago while offline.)
select is(pg_temp.send(pg_temp.op('off'), 'dev2') ->> 'status', 'applied', '9. offline split sale syncs');
select is((select row(business_date, split_cash, split_paytm)::text from public.entries where id = pg_temp.id('off')),
  row(pg_temp.today(), 6000::bigint, 4000::bigint)::text, '9. offline split keeps its date and both parts');

-- 5–8. Day figures ------------------------------------------------------------------------------------------
-- Services 150 + 200 + 150 + 150 + 300 + 100 = ₹1,050; products ₹250 (Paytm).
-- Recorded service cash 150 + 100 + 200 + 60 = ₹510, service Paytm 200 + 50 + 150 + 100 + 40 = ₹540.
select is((select row(s ->> 'service_total', s ->> 'commission_pool', s ->> 'product_total')::text from pg_temp.sum() s),
  row('105000', '10000', '25000')::text,
  '7. service sales exclude tips; commission FLOOR(₹1,050 × 10% / 10) × 10 = ₹100; products separate');
select is((select row(s ->> 'service_cash_recorded', s ->> 'service_paytm_recorded')::text from pg_temp.sum() s),
  row('51000', '54000')::text, '8. split parts land once in cash and once in Paytm');
select is((select ((s ->> 'service_cash_recorded')::bigint + (s ->> 'service_paytm_recorded')::bigint)::text from pg_temp.sum() s),
  '105000', '8. recorded cash + Paytm = service sales (no double counting)');
select is((select row(s ->> 'tips_cash', s ->> 'tips_paytm')::text from pg_temp.sum() s), row('2000', '5000')::text,
  '4. tips are reported separately');
select is((select s ->> 'paytm_recorded_total' from pg_temp.sum() s), '84000',
  '5. counter Paytm = service Paytm ₹540 + product Paytm ₹250 + digital tip ₹50');
select is((select (s -> 'allocations')::text from pg_temp.sum() s) is not null and
          (select sum((a ->> 'service_total')::bigint) from jsonb_array_elements((select s -> 'allocations' from pg_temp.sum() s)) a) = 105000,
  true, '7. commission allocations use service amounts only');

-- 6, 10. Paytm statement entered at closing ------------------------------------------------------------------
insert into ids select 'closing', (public.prepare_closing(tests.outlet('A'), pg_temp.today()) ->> 'closing_id')::uuid;
select ok((pg_temp.sum() -> 'blockers') ? 'paytm_missing', 'closing cannot be submitted before the Paytm statement total is entered');
select is((pg_temp.sum() ->> 'paytm_difference'), null, 'no difference is shown before the total is entered');
select throws_ok($$ select public.update_draft(pg_temp.id('closing'), -100, null, null, '{}', null, null) $$, '22023', null,
  'a negative Paytm total is refused');
select public.update_draft(pg_temp.id('closing'), 84000, null, null, '{"50000": 1}', null, null);
select ok(not ((pg_temp.sum() -> 'warnings') ? 'paytm_recorded_mismatch') and (pg_temp.sum() ->> 'paytm_difference') = '0',
  'matching statement: no warning, difference ₹0');
select is((select s ->> 'cash_sales' from pg_temp.sum() s), '46000',
  'cash sales = services ₹1,050 + products ₹250 − Paytm statement ₹840 = ₹460');
select public.update_draft(pg_temp.id('closing'), 82000, null, null, '{"50000": 1}', null, null);
select ok((pg_temp.sum() -> 'warnings') ? 'paytm_recorded_mismatch', '6. statement differs from the Register: warning');
select is((select row(s ->> 'paytm_total', s ->> 'paytm_difference', s ->> 'cash_sales')::text from pg_temp.sum() s),
  row('82000', '-2000', '48000')::text,
  '6. the entered statement total stays authoritative for cash sales; the −₹20 difference is visible');
select is((select paytm_total from public.closing_drafts where closing_id = pg_temp.id('closing')), 82000::bigint,
  '10. the entered Paytm total is saved in the draft');
select public.update_draft(pg_temp.id('closing'), 82000, null, null, '{"50000": 2}', null, null);
select is((pg_temp.sum() ->> 'paytm_total'), '82000', '10. saving the draft again keeps the entered total');

-- Corrections of split sales
select is(pg_temp.send(tests.op('correct_entry', pg_temp.id('split'), 20, '{"amount": 20000}',
  '{"base_version": 1, "reason": "price typo"}'), 'dev2') ->> 'error' like '%must equal the service amount%', true,
  'changing a split sale''s amount without new parts is refused');
select is(pg_temp.send(tests.op('correct_entry', pg_temp.id('split'), 21, '{"amount": 20000, "split_cash": 15000, "split_paytm": 5000}',
  '{"base_version": 1, "reason": "price typo"}')) ->> 'status', 'applied', 'a split correction with matching parts is applied');
select is(pg_temp.send(tests.op('correct_entry', pg_temp.id('split'), 22, '{"payment_method": "cash"}',
  '{"base_version": 2, "reason": "was all cash"}')) ->> 'status', 'applied', 'a split sale can be corrected to cash only');
select is((select row(payment_method::text, split_cash, split_paytm)::text from public.entries where id = pg_temp.id('split')),
  row('cash', null::bigint, null::bigint)::text, 'switching away from split clears the parts');

-- Daily Sheet opening -------------------------------------------------------------------------------------------
select throws_ok($$ select public.open_daily_sheet(tests.outlet('A'), pg_temp.today() + 1) $$, '22023', null,
  'a future business date cannot be opened');
reset role;
create temp table before_open as
  select (select count(*) from public.daily_closings) c, (select count(*) from public.closing_revisions) r,
         (select count(*) from public.closing_events) e;
select tests.login_as('head');
select ok(public.open_daily_sheet(tests.outlet('A'), pg_temp.today() - 1) is not null, 'Shop/Staff opens an earlier day''s sheet');
select ok(public.open_daily_sheet(tests.outlet('A'), pg_temp.today()) is not null, 'Shop/Staff opens today''s sheet');
reset role;
select is((select row((select count(*) from public.daily_closings), (select count(*) from public.closing_revisions),
                      (select count(*) from public.closing_events))::text),
  (select row(c, r, e)::text from before_open), 'opening a sheet creates no closing, revision or event');
select tests.login_as('owner');
select is(public.sheet_changes(), '[]'::jsonb, 'changes made before the sheet was opened are not listed');

-- Owner sheet changes: addition, correction, removal after opening --------------------------------------------
select tests.login_as('head');
select pg_temp.send(tests.op('create_entry', pg_temp.id('late1'), 30, pg_temp.svc('A', 150, '{"payment_method":"cash"}')));
select pg_temp.send(tests.op('correct_entry', pg_temp.id('prod'), 31, '{"quantity": 2}', '{"base_version": 1, "reason": "two bottles"}'));
select pg_temp.send(tests.op('void_entry', pg_temp.id('cash'), 32, '{}', '{"base_version": 1, "reason": "double entry"}'));
select tests.login_as('owner');
create temp table feed as select x.* from jsonb_array_elements(public.sheet_changes()) x;
select is((select count(*)::int from feed), 3, 'one item per change (no duplicates)');
select is((select row(x ->> 'action', x ->> 'section', x ->> 'employee_new', x -> 'new' ->> 'amount',
                      x -> 'totals' -> 0 ->> 'before', x -> 'totals' -> 0 ->> 'after', x ->> 'actor', x ->> 'outlet',
                      x ->> 'business_date')::text
           from feed f(x) where x ->> 'action' = 'added'),
  row('added', 'service', 'Asha', '15000', '35000', '50000', 'Head', 'Outlet A', pg_temp.today()::text)::text,
  'addition: employee, amount, employee total ₹350 → ₹500, actor, outlet, business date');
select is((select row(x -> 'old' ->> 'quantity', x -> 'new' ->> 'quantity', x -> 'new' ->> 'unit_price',
                      x -> 'totals' -> 0 ->> 'before', x -> 'totals' -> 0 ->> 'after', x ->> 'reason')::text
           from feed f(x) where x ->> 'action' = 'corrected'),
  row('1', '2', '25000', '25000', '50000', 'two bottles')::text,
  'correction: product quantity 1 → 2, section total ₹250 → ₹500, reason');
select is((select row(x ->> 'employee_old', x -> 'old' ->> 'amount', x -> 'totals' -> 0 ->> 'before', x -> 'totals' -> 0 ->> 'after')::text
           from feed f(x) where x ->> 'action' = 'removed'),
  row('Asha', '15000', '50000', '35000')::text, 'removal: amount removed, employee total ₹500 → ₹350');
select tests.login_as('manager');
select is(public.sheet_changes(), '[]'::jsonb, 'the feed is for the owner (audit.read) only');

-- 10. Submit, then reopen: the entered Paytm total is kept for the new revision
reset role;
select tests.initial_float(500, pg_temp.today());
select tests.login_as('head');
select public.update_draft(pg_temp.id('closing'), 82000, null, null, '{"50000": 2}', 'test difference', 'Owner');
select public.set_closing_employee(pg_temp.id('closing'), tests.staff('A'));
select is(pg_temp.sum() -> 'blockers', '[]'::jsonb, 'nothing blocks submission once the Paytm total is entered');
select lives_ok($$ select public.submit_closing(pg_temp.id('closing')) $$, 'closing submitted');
select tests.login_as('owner');
select lives_ok($$ select public.reopen_closing(pg_temp.id('closing'), 'recount') $$, 'owner reopens the closing');
select is((select row(s ->> 'state', s ->> 'paytm_total', s ->> 'paytm_entered')::text from pg_temp.sum() s),
  row('reopened', '82000', 'true')::text, '10. after reopening, the draft still holds the entered Paytm total');
select is((select paytm_total from public.closing_revisions where closing_id = pg_temp.id('closing')), 82000::bigint,
  'the submitted revision kept the entered Paytm total');
select tests.login_as('outsider');
select is(public.sheet_changes(), '[]'::jsonb, 'an owner of another outlet sees nothing from this outlet');

select * from finish();
rollback;
