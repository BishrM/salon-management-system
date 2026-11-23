-- W1: an employee deactivated today stays recordable for the whole business date and is refused from the
-- next one; late (offline) entries dated to an earlier working day stay valid; history keeps the name.
begin;
\ir helpers.psql

select plan(9);

select tests.ops_fixture();
create temp table ids (k text primary key, v uuid);
grant select on ids to authenticated;
insert into ids values ('dev', gen_random_uuid()), ('dev2', gen_random_uuid()), ('b_today', gen_random_uuid()),
  ('c_today', gen_random_uuid()), ('c_late', gen_random_uuid());
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
create temp table bd as select app.business_date(tests.outlet('A'), now()) as today,
                               app.business_date(tests.outlet('A'), now() - interval '1 day') as yday;
grant select on bd to authenticated;

-- 1. Before deactivation Bilal is valid today.
select ok(app.staff_assigned(tests.staff('B'), tests.outlet('A'), (select today from bd)),
  'employee is valid before deactivation');

-- 2. Deactivated today (by the Shop/Staff login): still recordable on today's business date.
select tests.login_as('head');
select public.update_staff(tests.staff('B'), 'Bilal', false, 'left the salon');
reset role;
select ok(app.staff_assigned(tests.staff('B'), tests.outlet('A'), (select today from bd)),
  'deactivated employee stays valid for the rest of the deactivation business date');
select tests.login_as('head');
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array(
    tests.op('create_entry', pg_temp.id('b_today'), 1,
      jsonb_build_object('kind', 'service', 'payment_method', 'cash', 'staff_id', tests.staff('B'), 'amount', 50000))))
  -> 'results' -> 0 ->> 'status', 'applied',
  'a sale for the employee is accepted on the deactivation business date');
reset role;

-- 3. Next business date: simulate "the day after deactivation" by dating Chetan's deactivation to today.
alter table public.staff disable trigger staff_inactive_from;
update public.staff set active = false, inactive_from = (select today from bd) where id = tests.staff('C');
alter table public.staff enable trigger staff_inactive_from;
select ok(not app.staff_assigned(tests.staff('C'), tests.outlet('A'), (select today from bd)),
  'employee is not valid from the next business date');
select tests.login_as('head');
select is((public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array(
    tests.op('create_entry', pg_temp.id('c_today'), 2,
      jsonb_build_object('kind', 'service', 'payment_method', 'cash', 'staff_id', tests.staff('C'), 'amount', 40000))))
  -> 'results' -> 0 ->> 'error') like 'choose an employee working at this outlet on %', true,
  'a new sale for the employee is refused from the next business date');

-- 5. Late entry: made offline yesterday on another tablet (when Chetan still worked), synced today.
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev2'), 'Tablet', jsonb_build_array(
    tests.op('create_entry', pg_temp.id('c_late'), 1,
      jsonb_build_object('kind', 'service', 'payment_method', 'cash', 'staff_id', tests.staff('C'), 'amount', 30000),
      jsonb_build_object('device_time', now() - interval '1 day', 'device_last_sync_at', now() - interval '1 day 5 minutes'))))
  -> 'results' -> 0 ->> 'status', 'applied',
  'a late entry dated to an earlier working day is still accepted');
reset role;
select is((select row(business_date, staff_id)::text from public.entries where id = pg_temp.id('c_late')),
  row((select yday from bd), tests.staff('C'))::text, 'the late entry keeps its working day and employee');

-- 4. History keeps the employee's identity.
select tests.login_as('head');
select is((select a ->> 'staff_name' from jsonb_array_elements(
             public.day_summary(tests.outlet('A'), (select yday from bd)) -> 'allocations') a
           where (a ->> 'staff_id')::uuid = tests.staff('C')), 'Chetan',
  'the earlier day''s commission still names the deactivated employee');
select is((select a ->> 'staff_name' from jsonb_array_elements(
             public.day_summary(tests.outlet('A'), (select today from bd)) -> 'allocations') a
           where (a ->> 'staff_id')::uuid = tests.staff('B')), 'Bilal',
  'the deactivation day''s commission names the employee');
reset role;

select * from finish();
rollback;
