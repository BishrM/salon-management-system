begin;
\ir helpers.psql
select tests.ops_fixture();

-- Migration …002300 (2026-11-24): hide an employee from the Service tab for one business date, add them back,
-- rename from the Register. Shop/Staff = 'head'. Within this transaction now() is constant, so "after the hide"
-- means the same instant or later.
select plan(56);

create temp table ids (k text primary key, v uuid);
grant select on ids to authenticated;
insert into ids select k, gen_random_uuid()
  from unnest(array['dev', 'dev2', 'dev3', 'b1', 'b2', 'b3', 'a1', 'off_before', 'off_after', 'c1']) k;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
grant execute on function pg_temp.id(text) to authenticated;
create temp table d (today date);
insert into d select app.business_date(tests.outlet('A'), now());
grant select on d to authenticated;
create function pg_temp.today() returns date language sql as $$ select today from d $$;
grant execute on function pg_temp.today() to authenticated;
create function pg_temp.svc(p_staff text, p_rupees int) returns jsonb language sql as $$
  select jsonb_build_object('kind', 'service', 'staff_id', tests.staff(p_staff), 'amount', p_rupees * 100,
                            'payment_method', 'cash') $$;
grant execute on function pg_temp.svc(text, int) to authenticated;
create function pg_temp.send(p_op jsonb, p_dev text default 'dev') returns jsonb language sql as $$
  select public.sync_ops(tests.outlet('A'), pg_temp.id(p_dev), 'Tablet', jsonb_build_array(p_op)) -> 'results' -> 0 $$;
grant execute on function pg_temp.send(jsonb, text) to authenticated;
create function pg_temp.hide(p_staff text, p_hidden boolean, p_date date default null) returns jsonb language sql as $$
  select public.set_staff_hidden(tests.outlet('A'), tests.staff(p_staff), coalesce(p_date, pg_temp.today()), p_hidden) $$;
grant execute on function pg_temp.hide(text, boolean, date) to authenticated;
create function pg_temp.alloc(p_staff text) returns jsonb language sql as $$
  select a from jsonb_array_elements(public.day_summary(tests.outlet('A'), pg_temp.today()) -> 'allocations') a
   where a ->> 'staff_id' = tests.staff(p_staff)::text $$;
grant execute on function pg_temp.alloc(text) to authenticated;

-- 1. Active visible employee can be chosen for a new sale.
select tests.login_as('head');
select is(pg_temp.send(tests.op('create_entry', pg_temp.id('b1'), 1, pg_temp.svc('B', 500))) ->> 'status', 'applied',
  'visible employee: a new service sale is accepted');
select is(pg_temp.send(tests.op('create_entry', pg_temp.id('a1'), 2, pg_temp.svc('A', 300))) ->> 'status', 'applied',
  'second visible employee: sale accepted');
select is((pg_temp.alloc('B') ->> 'service_total')::bigint, 50000::bigint, 'B has ₹500 before hiding');
create temp table before_hide as select public.day_summary(tests.outlet('A'), pg_temp.today()) s;

-- 2. Shop/Staff hides B for today.
select is(pg_temp.hide('B', true) ->> 'changed', 'true', 'Shop/Staff removes B from the Service tab for today');
reset role;
select is((select hidden from public.staff_day_visibility where staff_id = tests.staff('B')), true, 'hidden row stored');
-- 3. Owner hides C.
select tests.login_as('owner');
select is(pg_temp.hide('C', true) ->> 'changed', 'true', 'Owner removes C for today');
reset role;

-- 4. Hidden employee cannot be chosen for a new sale (server-side).
select tests.login_as('head');
select is(pg_temp.send(tests.op('create_entry', pg_temp.id('b2'), 3, pg_temp.svc('B', 200)), 'dev2') ->> 'status', 'failed',
  'new online sale for hidden B refused');
select ok(pg_temp.send(tests.op('create_entry', pg_temp.id('b3'), 4, pg_temp.svc('B', 200)), 'dev2') ->> 'error'
  like '%removed from the Service tab%', 'refusal says why');
reset role;
select throws_ok($$ select tests.entry('service', 100, pg_temp.today(), jsonb_build_object('staff_id', tests.staff('B'))) $$,
  '22023', null, 'refused on every write path (direct insert too)');
select ok(app.staff_assigned(tests.staff('B'), tests.outlet('A'), pg_temp.today()),
  'hidden B is still an active, assigned employee');
select is((select active from public.staff where id = tests.staff('B')), true, 'hiding does not deactivate');
select is((select count(*) from public.staff_assignments where staff_id = tests.staff('B') and end_date is null), 1::bigint,
  'hiding keeps the outlet assignment');

-- 5. Existing sales, totals and commission are unchanged after hiding.
select is(pg_temp.alloc('B'), (select a from before_hide, jsonb_array_elements(s -> 'allocations') a
                               where a ->> 'staff_id' = tests.staff('B')::text),
  'B''s allocation (sales ₹500, commission) identical after hiding');
select is((public.day_summary(tests.outlet('A'), pg_temp.today()) ->> 'commission_pool'),
  (select s ->> 'commission_pool' from before_hide), 'commission pool unchanged');
select is((select count(*) from public.entries where staff_id = tests.staff('B') and status = 'active'), 1::bigint,
  'B''s existing sale still active');

-- 13. Existing entries stay correctable; moving a sale TO a hidden employee is refused.
select tests.login_as('head');
select is(pg_temp.send(tests.op('correct_entry', pg_temp.id('b1'), 5, '{"amount": 60000}',
  jsonb_build_object('base_version', 1, 'reason', 'price was 600'))) ->> 'status', 'applied',
  'hidden B''s existing sale can be corrected');
select is(pg_temp.send(tests.op('correct_entry', pg_temp.id('a1'), 1,
  jsonb_build_object('staff_id', tests.staff('C')), jsonb_build_object('base_version', 1, 'reason', 'wrong person')), 'dev3') ->> 'status',
  'failed', 'moving a sale to hidden C is refused');
select is(pg_temp.send(tests.op('void_entry', pg_temp.id('b1'), 6, '{}',
  jsonb_build_object('base_version', 2, 'reason', 'test removal'))) ->> 'status', 'applied',
  'hidden B''s sale can be removed');
reset role;

-- 16. Offline: a sale made before the hide (synced late) is accepted once; a sale made after it is refused.
select tests.login_as('head');
create temp table off_op as select tests.op('create_entry', pg_temp.id('off_before'), 7, pg_temp.svc('B', 250),
  jsonb_build_object('device_time', now() - interval '20 minutes', 'device_last_sync_at', now() - interval '25 minutes')) o;
select is(pg_temp.send((select o from off_op)) ->> 'status', 'applied', 'offline sale made before the hide is accepted');
select is(pg_temp.send((select o from off_op)) ->> 'status', 'applied', 'the same op resent: idempotent result');
select is((select count(*) from public.entries where id = pg_temp.id('off_before')), 1::bigint, 'resend created no duplicate');
select is(pg_temp.send(tests.op('create_entry', pg_temp.id('off_after'), 2, pg_temp.svc('B', 250),
  jsonb_build_object('device_time', now() + interval '1 second', 'device_last_sync_at', now() - interval '25 minutes')), 'dev3')
  ->> 'status', 'failed', 'offline sale made after the hide is refused');
reset role;

-- 8. No duplicate rows or audit records.
select tests.login_as('head');
select is(pg_temp.hide('B', true) ->> 'changed', 'false', 'hiding an already hidden employee changes nothing');
reset role;
select is((select count(*) from public.staff_day_visibility where staff_id = tests.staff('B')), 1::bigint, 'still one row');

-- 7. Added back the same day; then selectable.
select tests.login_as('owner');
select is(pg_temp.hide('B', false) ->> 'changed', 'true', 'Owner adds B back');
select is(pg_temp.hide('B', false) ->> 'changed', 'false', 'adding back twice changes nothing');
select is(pg_temp.hide('A', false) ->> 'changed', 'false', 'adding back a never-hidden employee writes nothing');
reset role;
select tests.login_as('head');
select is(pg_temp.send(tests.op('create_entry', pg_temp.id('c1'), 8, pg_temp.svc('B', 400))) ->> 'status', 'applied',
  'B selectable again after being added back');
reset role;
select is((select count(*) from public.staff_day_visibility where staff_id = tests.staff('B')), 1::bigint,
  'add back reuses the row (unique per outlet, employee, date)');
select is((select count(*) from public.staff where full_name in ('Bilal')), 1::bigint, 'no duplicate employee created');
select is((select count(*) from public.staff_day_visibility where staff_id = tests.staff('A')), 0::bigint,
  'no row for an employee never hidden');

-- 15. Audit: one row per real change, with employee, name at the time, outlet, date, hidden/restored, actor, time.
select is((select count(*) from public.audit_logs where table_name = 'staff_day_visibility'), 3::bigint,
  'three audit rows: hide B, hide C, add back B (no-ops wrote none)');
select is((select row(outlet_id, actor, new_data ->> 'staff_id', new_data ->> 'staff_name', new_data ->> 'business_date',
                      new_data ->> 'hidden', reason)::text
             from public.audit_logs where table_name = 'staff_day_visibility' and action = 'INSERT'
              and new_data ->> 'staff_id' = tests.staff('B')::text),
  row(tests.outlet('A'), tests.uid('head'), tests.staff('B')::text, 'Bilal', pg_temp.today()::text, 'true',
      'Removed from the Service tab for the day')::text, 'hide audit row complete');
select is((select row(action, actor, old_data ->> 'hidden', new_data ->> 'hidden')::text
             from public.audit_logs where table_name = 'staff_day_visibility' and action = 'UPDATE'),
  row('UPDATE', tests.uid('owner'), 'true', 'false')::text, 'add-back audit row (owner, hidden → shown)');

-- 6 + 18. Visibility is per business date; tomorrow B and C are selectable by default. Only today can be changed.
select ok(not app.staff_hidden_at(tests.staff('C'), tests.outlet('A'), pg_temp.today() + 1, now() + interval '1 day'),
  'C hidden today is not hidden on the next business date');
select lives_ok($$ select tests.entry('service', 100, pg_temp.today() + 1, jsonb_build_object('staff_id', tests.staff('C'))) $$,
  'a sale for C dated the next business date is accepted');
select tests.login_as('head');
select throws_ok($$ select pg_temp.hide('A', true, pg_temp.today() + 1) $$, '22023', null, 'cannot hide for another business date');
select throws_ok($$ select pg_temp.hide('A', true, pg_temp.today() - 1) $$, '22023', null, 'cannot hide for a past business date');
reset role;
select is(app.business_date(tests.outlet('A'), ((pg_temp.today() + 1) + time '03:59') at time zone 'Asia/Kolkata'),
  pg_temp.today(), '03:59 next morning is still today''s business date (cutoff 04:00): C still hidden then');

-- 9 + 17. Deactivated employees cannot be shown/hidden here; deactivation works as before.
select tests.login_as('head');
select public.update_staff(tests.staff('C'), 'Chetan', false, 'left the salon');
reset role;
select is((select inactive_from from public.staff where id = tests.staff('C')), pg_temp.today() + 1,
  'deactivation still dates inactive_from to the next business date');
select is((select hidden from public.staff_day_visibility where staff_id = tests.staff('C')), true,
  'deactivating does not touch the visibility row');
-- A: deactivated as of today (dated directly, as in 14_deactivation_cutoff_test).
alter table public.staff disable trigger staff_inactive_from;
update public.staff set active = false, inactive_from = pg_temp.today() where id = tests.staff('A');
alter table public.staff enable trigger staff_inactive_from;
select tests.login_as('owner');
select throws_ok($$ select pg_temp.hide('A', false) $$, '22023', null, 'a deactivated employee cannot be added back here');
reset role;
select is((select active from public.staff where id = tests.staff('A')), false, 'still deactivated');

-- 14. Outlet-level authorisation.
select tests.login_as('outsider');
select throws_ok($$ select pg_temp.hide('B', true) $$, '42501', null, 'owner of another outlet cannot hide here');
select throws_ok($$ select public.rename_staff(tests.outlet('A'), tests.staff('B'), 'X') $$, '42501', null,
  'owner of another outlet cannot rename here');
reset role;
select tests.login_as('head');
select throws_ok($$ select public.rename_staff(tests.outlet('A'), tests.staff('Bstaff'), 'X') $$, '42501', null,
  'Shop/Staff cannot rename another outlet''s employee');
select throws_ok($$ select public.set_staff_hidden(tests.outlet('A'), tests.staff('Bstaff'), pg_temp.today(), true) $$,
  '22023', null, 'Shop/Staff cannot hide another outlet''s employee');
reset role;
select tests.login_as('counter2');
select throws_ok($$ select pg_temp.hide('B', true) $$, '42501', null, 'a login without staff.manage cannot hide');
reset role;

-- 10-12. Rename keeps the id and history; names resolve live; money unchanged.
select tests.login_as('owner');
reset role;  -- keeps the owner's identity for day_summary; temp table owned by the test runner
create temp table pre as select public.day_summary(tests.outlet('A'), pg_temp.today()) s;
select tests.login_as('head');
select throws_ok($$ select public.rename_staff(tests.outlet('A'), tests.staff('B'), '   ') $$, '22023', null, 'empty name refused');
select lives_ok($$ select public.rename_staff(tests.outlet('A'), tests.staff('B'), '  Bilal Khan ') $$, 'Shop/Staff renames B');
select lives_ok($$ select public.rename_staff(tests.outlet('A'), tests.staff('B'), 'Bilal Khan') $$, 'same name again: no-op');
reset role;
select is((select full_name from public.staff where id = tests.staff('B')), 'Bilal Khan', 'same staff id, new name');
select is((select count(*) from public.entries where staff_id = tests.staff('B')), 3::bigint, 'sales still linked to the same id');
select is(pg_temp.alloc('B') ->> 'staff_name', 'Bilal Khan', 'day summary shows the new name');
select is((select jsonb_agg(a - 'staff_name') from jsonb_array_elements(public.day_summary(tests.outlet('A'), pg_temp.today()) -> 'allocations') a),
  (select jsonb_agg(a - 'staff_name') from pre, jsonb_array_elements(s -> 'allocations') a),
  'allocations (sales, exact share, allocated, rounding) unchanged by the rename');
select is((select row(actor, old_data ->> 'full_name', new_data ->> 'full_name', reason)::text from public.audit_logs
            where table_name = 'staff' and row_id = tests.staff('B') and new_data ->> 'full_name' = 'Bilal Khan'),
  row(tests.uid('head'), 'Bilal', 'Bilal Khan', 'Renamed from the Register of Outlet A')::text,
  'one rename audit row: login, old and new name, outlet');

select * from finish();
rollback;
