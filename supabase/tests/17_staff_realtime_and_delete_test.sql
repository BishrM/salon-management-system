begin;
\ir helpers.psql
select tests.ops_fixture();

-- Migration …002400: employee tables in Realtime; Owner-only permanent delete of an employee with no history.
-- Owner = owner of A; outsider = owner of B; head = Shop/Staff of A.
select plan(27);

create temp table ids (k text primary key, v uuid);
grant select, insert on ids to authenticated;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
grant execute on function pg_temp.id(text) to authenticated;
create function pg_temp.del(p_staff uuid, p_outlet uuid default null) returns void language sql as $$
  select public.delete_staff_permanently(coalesce(p_outlet, tests.outlet('A')), p_staff) $$;
grant execute on function pg_temp.del(uuid, uuid) to authenticated;
create function pg_temp.svc(p_staff uuid, p_rupees int) returns jsonb language sql as $$
  select jsonb_build_object('kind', 'service', 'staff_id', p_staff, 'amount', p_rupees * 100, 'payment_method', 'cash') $$;
grant execute on function pg_temp.svc(uuid, int) to authenticated;
create function pg_temp.send(p_op jsonb) returns jsonb language sql as $$
  select public.sync_ops(tests.outlet('A'), 'dddddddd-0000-4000-8000-000000000017', 'Tablet', jsonb_build_array(p_op)) -> 'results' -> 0 $$;
grant execute on function pg_temp.send(jsonb) to authenticated;

-- 1. Realtime publication.
select ok((select count(*) from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public'
            and tablename in ('staff', 'staff_assignments', 'staff_day_visibility')) = 3,
  'staff, staff_assignments and staff_day_visibility are published to Realtime');

-- Fresh employees, created the normal way by Shop/Staff.
select tests.login_as('head');
insert into ids values ('fresh',  public.create_staff(tests.outlet('A'), 'Fresh Test', date '2020-01-01')),
                       ('fresh2', public.create_staff(tests.outlet('A'), 'Fresh Two', date '2020-01-01')),
                       ('sold',   public.create_staff(tests.outlet('A'), 'Has Sale', date '2020-01-01')),
                       ('moved',  public.create_staff(tests.outlet('A'), 'Sale Moved Away', date '2020-01-01')),
                       ('hidden', public.create_staff(tests.outlet('A'), 'Was Hidden', date '2020-01-01')),
                       ('both',   public.create_staff(tests.outlet('A'), 'Two Outlets', date '2020-01-01'));
insert into ids values ('e1', gen_random_uuid()), ('e2', gen_random_uuid());
select is(pg_temp.send(tests.op('create_entry', pg_temp.id('e1'), 1, pg_temp.svc(pg_temp.id('sold'), 300))) ->> 'status',
  'applied', 'sale for Has Sale');
select is(pg_temp.send(tests.op('create_entry', pg_temp.id('e2'), 2, pg_temp.svc(pg_temp.id('moved'), 300))) ->> 'status',
  'applied', 'sale for Sale Moved Away');
select is(pg_temp.send(tests.op('correct_entry', pg_temp.id('e2'), 3,
  jsonb_build_object('staff_id', tests.staff('A')), jsonb_build_object('base_version', 1, 'reason', 'wrong employee'))) ->> 'status', 'applied',
  'that sale is corrected to another employee');
select is(public.set_staff_hidden(tests.outlet('A'), pg_temp.id('hidden'),
  public.current_business_date(tests.outlet('A')), true) ->> 'changed', 'true', 'Was Hidden removed from the Service tab');
reset role;
insert into public.staff_assignments (staff_id, outlet_id, start_date, end_date, end_reason, is_temporary)
values (pg_temp.id('both'), tests.outlet('B'), date '2019-01-01', date '2019-06-01', 'visit', true);

-- 2. Only Owners.
select tests.login_as('head');
select throws_ok($$ select pg_temp.del(pg_temp.id('fresh')) $$, '42501', null, 'Shop/Staff cannot delete permanently');
select throws_ok($$ select * from public.staff_delete_blockers() $$, '42501', null, 'Shop/Staff cannot list delete blockers');
reset role;
select tests.login_as('manager');
select throws_ok($$ select pg_temp.del(pg_temp.id('fresh')) $$, '42501', null, 'Manager cannot delete permanently');
reset role;
select tests.login_as('outsider');
select throws_ok($$ select pg_temp.del(pg_temp.id('fresh'), tests.outlet('B')) $$, '42501', null,
  'Owner of another outlet cannot delete outlet A''s employee');
reset role;
select tests.login_as('owner');
select throws_ok($$ select pg_temp.del(pg_temp.id('both')) $$, '42501', null,
  'Owner of A cannot delete an employee who also worked at an outlet they do not own');

-- 3. Blockers as the Owner sees them.
select is((select blockers from public.staff_delete_blockers() where staff_id = pg_temp.id('fresh')), '{}'::text[],
  'fresh employee has no blockers');
select ok((select array_to_string(blockers, '|') from public.staff_delete_blockers() where staff_id = pg_temp.id('sold'))
  like '%sale%', 'employee with a sale is blocked by it');
select ok(not exists (select 1 from public.staff_delete_blockers() where staff_id = pg_temp.id('both')),
  'an employee the Owner does not fully own is not offered');

-- 4. History blocks the delete; the row survives.
select throws_ok($$ select pg_temp.del(pg_temp.id('sold')) $$, '22023', null, 'employee with a sale cannot be deleted');
select ok(exists (select 1 from public.staff where id = pg_temp.id('sold')), 'and is still there');
select throws_ok($$ select pg_temp.del(pg_temp.id('moved')) $$, '22023', null,
  'employee whose sale was moved away (audit history) cannot be deleted');
select throws_ok($$ select pg_temp.del(pg_temp.id('hidden')) $$, '22023', null,
  'employee with a Service tab change cannot be deleted');
select throws_ok($$ select pg_temp.del(tests.staff('headstaff')) $$, '22023', null,
  'employee linked to a login cannot be deleted');
select throws_ok($$ select pg_temp.del(pg_temp.id('sold')) $$, '22023',
  'Has Sale cannot be deleted permanently. History found: 1 sale or register record(s), offline sync records, audit history of sales, closings or other records. Deactivate them instead: history is kept.',
  'the refusal names the employee, the reason and offers Deactivate');

-- 5. Delete without history.
select lives_ok($$ select pg_temp.del(pg_temp.id('fresh')) $$, 'Owner deletes an employee with no history');
reset role;
select ok(not exists (select 1 from public.staff where id = pg_temp.id('fresh'))
      and not exists (select 1 from public.staff_assignments where staff_id = pg_temp.id('fresh')),
  'employee and their assignment are gone');
select is((select count(*)::int from public.audit_logs where row_id = pg_temp.id('fresh') and action = 'INSERT'), 1,
  'the creation audit row is kept');
select is((select count(*)::int from public.audit_logs
            where action = 'DELETE' and table_name in ('staff', 'staff_assignments')
              and (old_data ->> 'id' = pg_temp.id('fresh')::text or old_data ->> 'staff_id' = pg_temp.id('fresh')::text)
              and reason like 'Permanently deleted employee Fresh Test%' and actor = tests.uid('owner')), 2,
  'the deletion is audited (employee + assignment) with the Owner and reason');

-- 6. The database refuses every other path.
select throws_ok($$ delete from public.staff where id = '$$ || pg_temp.id('fresh2') || $$' $$, 'P0001', null,
  'direct DELETE on staff refused even for postgres');
select throws_ok($$ delete from public.staff_assignments where staff_id = '$$ || pg_temp.id('fresh2') || $$' $$, 'P0001', null,
  'direct DELETE on staff_assignments refused');
select tests.login_as('owner');
select throws_ok($$ delete from public.staff where id = '$$ || pg_temp.id('fresh2') || $$' $$, '42501', null,
  'clients have no DELETE privilege on staff');
reset role;
select throws_ok($$ select set_config('app.staff_purge', '$$ || pg_temp.id('sold') || $$', true);
                    delete from public.staff_assignments where staff_id = '$$ || pg_temp.id('sold') || $$';
                    delete from public.staff where id = '$$ || pg_temp.id('sold') || $$' $$, null, null,
  'even with the purge flag, an employee with history cannot be deleted (trigger + foreign keys)');

select * from finish();
rollback;
