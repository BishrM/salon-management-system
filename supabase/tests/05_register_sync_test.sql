begin;
\ir helpers.psql
select tests.ops_fixture();

select plan(57);

create temp table ids (k text primary key, v uuid);
grant select, insert on ids to authenticated;
insert into ids values ('dev', gen_random_uuid()), ('dev2', gen_random_uuid()),
  ('s1', gen_random_uuid()), ('p1', gen_random_uuid()), ('e1', gen_random_uuid()), ('z1', gen_random_uuid()),
  ('f1', gen_random_uuid()), ('f1pay', gen_random_uuid()), ('f2', gen_random_uuid()), ('fp2', gen_random_uuid()),
  ('fp3', gen_random_uuid()), ('rev2', gen_random_uuid()), ('s2', gen_random_uuid()), ('op_s2', gen_random_uuid());
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
create temp table res (k text primary key, v jsonb);
grant select, insert on res to authenticated;

-- Direct writes are impossible for every client role (RLS + privileges) ----------------------------------
select tests.login_as('owner');
select throws_ok($$ insert into public.entries (id, outlet_id, kind, amount, staff_id, recorded_by, op_id)
                    values (gen_random_uuid(), tests.outlet('A'), 'service', 10000, tests.staff('A'), auth.uid(), gen_random_uuid()) $$,
  '42501', null, 'owner cannot insert entries directly');
select throws_ok($$ update public.entries set amount = 1 $$, '42501', null, 'owner cannot update entries directly');
select throws_ok($$ insert into public.food_payments (id, outlet_id, food_id, amount, paid_from, recorded_by, op_id)
                    values (gen_random_uuid(), tests.outlet('A'), gen_random_uuid(), 100, 'drawer', auth.uid(), gen_random_uuid()) $$,
  '42501', null, 'owner cannot insert food payments directly');
reset role;

-- Setup gate (F5): no cutoff → entries refused --------------------------------------------------------------
update public.outlets set day_cutoff = null where id = tests.outlet('A');
select tests.login_as('counter');
select is(
  (public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet',
     jsonb_build_array(tests.op('create_entry', gen_random_uuid(), 1,
       jsonb_build_object('kind', 'service', 'payment_method', 'cash', 'staff_id', tests.staff('A'), 'amount', 50000)))) -> 'results' -> 0 ->> 'error'),
  'setup incomplete: the business-day cutoff has not been set for this outlet',
  'entries are refused while the outlet has no cutoff');
reset role;
update public.outlets set day_cutoff = '04:00' where id = tests.outlet('A');

-- Recording each kind -------------------------------------------------------------------------------------
select tests.login_as('counter');
insert into res select 'batch1', public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array(
  tests.op('create_entry', pg_temp.id('s1'), 2, jsonb_build_object('kind', 'service', 'payment_method', 'cash', 'staff_id', tests.staff('A'), 'amount', 50000)),
  tests.op('create_entry', pg_temp.id('p1'), 3, jsonb_build_object('kind', 'product',
    'product_id', '9a000000-0000-4000-8000-000000000001', 'quantity', 2, 'unit_price', 30000, 'amount', 1, 'payment_method', 'paytm')),
  tests.op('create_entry', pg_temp.id('e1'), 4, jsonb_build_object('kind', 'expense', 'amount', 12000, 'description', 'Shampoo refill')),
  tests.op('create_entry', pg_temp.id('z1'), 5, jsonb_build_object('kind', 'zakat', 'amount', 2000, 'staff_id', tests.staff('B'))),
  tests.op('create_entry', pg_temp.id('f1'), 6, jsonb_build_object('kind', 'food', 'meal', 'lunch', 'amount', 70000,
    'pay_now', true, 'payment_id', pg_temp.id('f1pay'))),
  tests.op('create_entry', pg_temp.id('f2'), 7, jsonb_build_object('kind', 'food', 'meal', 'breakfast', 'amount', 30000))
));
select is((select count(*)::int from jsonb_array_elements((select v from res where k = 'batch1') -> 'results') r
           where r ->> 'status' = 'applied'), 6, 'six register ops applied');
reset role;

select is((select row(kind, amount, staff_id, recorded_by, date_basis, late)::text from public.entries where id = pg_temp.id('s1')),
  row('service'::public.entry_kind, 50000::bigint, tests.staff('A'), tests.uid('counter'), 'online'::public.date_basis, false)::text,
  'service sale stored with employee, recorder (from auth.uid) and online date basis');
select is((select business_date from public.entries where id = pg_temp.id('s1')),
  app.business_date(tests.outlet('A'), now()), 'online entry dated by server receipt time and cutoff');
select is((select row(amount, product_name, quantity, unit_price, payment_method)::text from public.entries where id = pg_temp.id('p1')),
  row(60000::bigint, 'Hair oil', 2, 30000::bigint, 'paytm'::public.payment_method)::text,
  'product total recomputed server-side as quantity × unit price (client amount ignored)');
select is((select expense_source from public.entries where id = pg_temp.id('e1')), 'cash_drawer'::public.expense_source,
  'expense defaults to the cash drawer');
select is((select staff_id from public.entries where id = pg_temp.id('z1')), tests.staff('B'), 'zakat keeps the optional donor');
select is((select row(amount, paid_from, food_id)::text from public.food_payments where id = pg_temp.id('f1pay')),
  row(70000::bigint, 'drawer', pg_temp.id('f1'))::text, 'food "paid now" creates cost and drawer payment in one op');
select is((select count(*)::int from public.food_payments where food_id = pg_temp.id('f2')), 0, 'unpaid food has no payment');
select is((select count(*)::int from public.audit_logs where table_name = 'entries' and row_id = pg_temp.id('s1') and action = 'INSERT'
           and actor = tests.uid('counter') and op_id is not null), 1, 'entry insert is audited with actor and op id');
select is((select count(*)::int from public.sync_ops where device_id = pg_temp.id('dev') and status = 'applied'), 6,
  'applied ops are logged for idempotency');
select is((select last_synced_seq from public.devices where id = pg_temp.id('dev')), 7::bigint,
  'device last_synced_seq is the highest contiguous seq (failed seq 1 counts as received)');

-- Validation --------------------------------------------------------------------------------------------
select tests.login_as('counter');
create function pg_temp.one(p_seq bigint, p_data jsonb) returns jsonb language sql as $$
  select public.sync_ops(tests.outlet('A'), (select v from ids where k = 'dev'), 'Tablet',
    jsonb_build_array(tests.op('create_entry', gen_random_uuid(), p_seq, p_data))) -> 'results' -> 0
$$;
select is(pg_temp.one(8, '{"kind":"service","amount":50050,"staff_id":"5aaa0000-0000-4000-8000-00000000000a"}') ->> 'error_code',
  '22023', 'amounts must be whole rupees');
select is(pg_temp.one(9, '{"kind":"service","amount":-100,"staff_id":"5aaa0000-0000-4000-8000-00000000000a"}') ->> 'error_code',
  '22023', 'negative amounts rejected');
select is(pg_temp.one(10, '{"kind":"service","amount":50000,"staff_id":"5bbb0000-0000-4000-8000-00000000000b"}') ->> 'error_code',
  '22023', 'employee from another outlet rejected');
select is(pg_temp.one(11, '{"kind":"service","amount":50000}') ->> 'error_code', '22023', 'service needs an employee');
select is(pg_temp.one(12, '{"kind":"expense","amount":5000}') ->> 'error_code', '22023', 'expense needs a description');
select is(pg_temp.one(13, '{"kind":"food","amount":5000,"meal":"snack"}') ->> 'error_code', '22023', 'unknown meal rejected');
select is(pg_temp.one(14, '{"kind":"service","amount":5000,"staff_id":"5aaa0000-0000-4000-8000-00000000000a","is_admin":true}') ->> 'error_code',
  '22023', 'unexpected fields rejected');
select is(pg_temp.one(15, '{"kind":"product","product_id":"9a000000-0000-4000-8000-000000000001","quantity":1,"unit_price":5000,"payment_method":"credit"}') ->> 'error_code',
  '22023', 'product payment method must be cash or paytm');
reset role;

-- Cross-outlet isolation --------------------------------------------------------------------------------
select tests.login_as('counter');
select throws_ok($$ select public.sync_ops(tests.outlet('B'), gen_random_uuid(), 'x', '[]'::jsonb) $$,
  '42501', null, 'counter of A cannot sync into outlet B');
reset role;
select tests.login_as('outsider');
select is((select count(*)::int from public.entries), 0, 'owner of B sees none of A''s entries');
select is((select count(*)::int from public.sync_ops), 0, 'owner of B sees none of A''s sync ops');
reset role;
select tests.login_as('nobody');
select is((select count(*)::int from public.food_payments), 0, 'a login without membership sees no food payments');
reset role;

-- Idempotency and conflicts (§6.4) ---------------------------------------------------------------------
select tests.login_as('counter');
insert into res select 's2', tests.op('create_entry', pg_temp.id('s2'), 20,
  jsonb_build_object('kind', 'service', 'payment_method', 'cash', 'staff_id', tests.staff('C'), 'amount', 40000));
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array((select v from res where k = 's2')))
          -> 'results' -> 0 ->> 'status', 'applied', 'op applied once');
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array((select v from res where k = 's2')))
          -> 'results' -> 0 ->> 'duplicate', 'true', 'retrying the same op is an idempotent success');
select is((select count(*)::int from public.entries where id = pg_temp.id('s2')), 1, 'retry did not duplicate the sale');
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array(
            (select v from res where k = 's2') || '{"data":{"kind":"service","staff_id":"5aaa0000-0000-4000-8000-00000000000c","amount":99900}}'))
          -> 'results' -> 0 ->> 'status', 'conflict', 'same seq with different content is a conflict');
select is((select amount from public.entries where id = pg_temp.id('s2')), 40000::bigint, 'conflict never overwrites');
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev2'), 'Phone', jsonb_build_array(
            (select v from res where k = 's2') || '{"device_seq":1}'))
          -> 'results' -> 0 ->> 'status', 'conflict', 'same op id from another device/seq is a conflict');
reset role;

-- Out-of-order arrival and gaps ---------------------------------------------------------------------------
select tests.login_as('counter');
insert into res select 'gapped', public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array(
  tests.op('create_entry', gen_random_uuid(), 23, jsonb_build_object('kind', 'service', 'payment_method', 'cash', 'staff_id', tests.staff('A'), 'amount', 10000))));
select is((select v from res where k = 'gapped') -> 'gaps', '[16, 17, 18, 19, 21, 22]'::jsonb,
  'gaps below the highest seq are reported');
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array(
  tests.op('create_entry', gen_random_uuid(), 16, jsonb_build_object('kind', 'service', 'payment_method', 'cash', 'staff_id', tests.staff('A'), 'amount', 10000)),
  tests.op('create_entry', gen_random_uuid(), 17, jsonb_build_object('kind', 'service', 'payment_method', 'cash', 'staff_id', tests.staff('A'), 'amount', 10000)),
  tests.op('create_entry', gen_random_uuid(), 18, jsonb_build_object('kind', 'service', 'payment_method', 'cash', 'staff_id', tests.staff('A'), 'amount', 10000)),
  tests.op('create_entry', gen_random_uuid(), 19, jsonb_build_object('kind', 'service', 'payment_method', 'cash', 'staff_id', tests.staff('A'), 'amount', 10000)),
  tests.op('create_entry', gen_random_uuid(), 21, jsonb_build_object('kind', 'service', 'payment_method', 'cash', 'staff_id', tests.staff('A'), 'amount', 10000)),
  tests.op('create_entry', gen_random_uuid(), 22, jsonb_build_object('kind', 'service', 'payment_method', 'cash', 'staff_id', tests.staff('A'), 'amount', 10000))
)) -> 'gaps', '[]'::jsonb, 'late-arriving lower seqs are accepted and close the gap');
reset role;
select is((select last_synced_seq from public.devices where id = pg_temp.id('dev')), 23::bigint, 'contiguous seq advanced to 23');
select tests.login_as('counter');
-- A correction that arrives before its create waits (not stored, returned as blocked).
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array(
  tests.op('correct_entry', gen_random_uuid(), 25, '{"amount":20000}', '{"base_version":1,"reason":"typo"}')))
  -> 'results' -> 0 ->> 'status', 'blocked', 'correction for a not-yet-synced entry is blocked, not failed');
select is((select count(*)::int from public.sync_ops where device_id = pg_temp.id('dev') and device_seq = 25), 0,
  'blocked op is not stored');
reset role;

-- Corrections and voids (§3.2, SRS §6.2) ------------------------------------------------------------------
select tests.login_as('counter');
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array(
  tests.op('correct_entry', pg_temp.id('s1'), 24, '{"amount":55000}', '{"base_version":1,"reason":"entered 500 instead of 550"}')))
  -> 'results' -> 0 -> 'result' ->> 'version', '2', 'correction bumps the version');
select is((select row(e.amount, e.version)::text from public.entries e where id = pg_temp.id('s1')),
  row(55000::bigint, 2)::text, 'corrected value stored');
reset role;
select is((select row(old_data ->> 'amount', new_data ->> 'amount', reason, actor)::text from public.audit_logs
           where table_name = 'entries' and row_id = pg_temp.id('s1') and action = 'UPDATE'),
  row('50000', '55000', 'entered 500 instead of 550', tests.uid('counter'))::text,
  'audit keeps original and new value, reason and user');
select tests.login_as('counter');
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev2'), 'Phone', jsonb_build_array(
  tests.op('correct_entry', pg_temp.id('s1'), 2, '{"amount":60000}', '{"base_version":1,"reason":"stale"}')))
  -> 'results' -> 0 ->> 'status', 'conflict', 'stale base version is a conflict (no last-write-wins)');
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev2'), 'Phone', jsonb_build_array(
  tests.op('correct_entry', pg_temp.id('s1'), 11, '{"amount":61000}', '{"base_version":2,"reason":"again"}')))
  -> 'results' -> 0 ->> 'status', 'blocked', 'later ops for a record with an unresolved conflict on that device are blocked');
select is((select amount from public.entries where id = pg_temp.id('s1')), 55000::bigint, 'stale correction did not overwrite');
select is(public.sync_ops(tests.outlet('A'), gen_random_uuid(), 'Phone', jsonb_build_array(
  tests.op('correct_entry', pg_temp.id('s1'), 1, '{"amount":60000}', '{"base_version":2}')))
  -> 'results' -> 0 ->> 'error_code', '22023', 'correction needs a reason');
select is(public.sync_ops(tests.outlet('A'), gen_random_uuid(), 'Phone', jsonb_build_array(
  tests.op('correct_entry', pg_temp.id('s1'), 1, '{"kind":"expense"}', '{"base_version":2,"reason":"x"}')))
  -> 'results' -> 0 ->> 'error_code', '22023', 'kind and identity cannot be corrected');
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev2'), 'Phone', jsonb_build_array(
  tests.op('void_entry', pg_temp.id('f1'), 5, '{}', '{"base_version":1,"reason":"duplicate"}')))
  -> 'results' -> 0 ->> 'error_code', '23514', 'paid food cannot be voided before its payment is reversed');
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev2'), 'Phone', jsonb_build_array(
  tests.op('void_entry', pg_temp.id('e1'), 6, '{}', '{"base_version":1,"reason":"entered twice"}')))
  -> 'results' -> 0 -> 'result' ->> 'status', 'voided', 'void keeps the row and marks it voided');
reset role;

-- Food payments (J2) --------------------------------------------------------------------------------------
select tests.login_as('counter');
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev2'), 'Phone', jsonb_build_array(
  tests.op('food_payment', pg_temp.id('fp2'), 7, jsonb_build_object('food_id', pg_temp.id('f2'), 'amount', 40000, 'paid_from', 'drawer'))))
  -> 'results' -> 0 ->> 'error_code', '22023', 'payment above the unpaid cost is rejected');
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev2'), 'Phone', jsonb_build_array(
  tests.op('food_payment', pg_temp.id('fp3'), 8, jsonb_build_object('food_id', pg_temp.id('f2'), 'amount', 30000, 'paid_from', 'outside_drawer'))))
  -> 'results' -> 0 ->> 'status', 'applied', 'outside-drawer payment of the full cost accepted');
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev2'), 'Phone', jsonb_build_array(
  tests.op('correct_entry', pg_temp.id('f2'), 9, '{"amount":20000}', '{"base_version":1,"reason":"cheaper"}')))
  -> 'results' -> 0 ->> 'error_code', '23514', 'food cost cannot be corrected below the amount already paid');
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev2'), 'Phone', jsonb_build_array(
  tests.op('reverse_food_payment', pg_temp.id('rev2'), 10, jsonb_build_object('payment_id', pg_temp.id('fp3')), '{"reason":"paid by owner personally"}')))
  -> 'results' -> 0 ->> 'status', 'applied', 'food payment reversed with a reason');
select is((select sum(case when reverses_payment_id is null then amount else -amount end) from public.food_payments
           where food_id = pg_temp.id('f2')), 0::numeric, 'net paid after reversal is zero');
reset role;

-- Evidence is immutable, even for the database owner (trigger) ----------------------------------------
select throws_ok($$ update public.entries set device_time = now() - interval '1 day' where id = (select v from ids where k = 's1') $$,
  'P0001', null, 'timestamp evidence cannot be rewritten');
select throws_ok($$ update public.entries set business_date = business_date - 1 where id = (select v from ids where k = 's1') $$,
  'P0001', null, 'an assigned business date cannot be moved');
select throws_ok($$ delete from public.entries where id = (select v from ids where k = 's1') $$,
  'P0001', null, 'entries are never deleted');
select throws_ok($$ delete from public.food_payments $$, 'P0001', null, 'food payments are never deleted');

select * from finish();
rollback;
