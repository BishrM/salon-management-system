-- W1 edge case: deactivation is dated by the outlet's business date (cutoff 04:00), not the calendar date.
-- Times are India local (+05:30, no daylight saving). Outlet A's cutoff is 04:00 (tests.ops_fixture).
begin;
\ir helpers.psql

select plan(16);

select tests.ops_fixture();

-- 1-6. The first unavailable business date for each deactivation instant.
select is(app.staff_inactive_from_at(tests.staff('C'), '2026-11-23 23:59+05:30'), date '2026-11-24',
  '23:59 on 23 Nov (business date 23 Nov) → unavailable from 24 Nov');
select is(app.staff_inactive_from_at(tests.staff('C'), '2026-11-24 00:01+05:30'), date '2026-11-24',
  '00:01 on 24 Nov (business date 23 Nov) → unavailable from 24 Nov');
select is(app.staff_inactive_from_at(tests.staff('C'), '2026-11-24 01:00+05:30'), date '2026-11-24',
  '01:00 on 24 Nov (business date 23 Nov) → unavailable from 24 Nov, no extra day');
select is(app.staff_inactive_from_at(tests.staff('C'), '2026-11-24 03:59:59.999+05:30'), date '2026-11-24',
  '03:59:59 on 24 Nov (business date 23 Nov) → unavailable from 24 Nov');
select is(app.staff_inactive_from_at(tests.staff('C'), '2026-11-24 04:00+05:30'), date '2026-11-25',
  'exactly 04:00 on 24 Nov starts business date 24 Nov → unavailable from 25 Nov');
select is(app.staff_inactive_from_at(tests.staff('C'), '2026-11-24 10:30+05:30'), date '2026-11-25',
  '10:30 on 24 Nov (business date 24 Nov) → unavailable from 25 Nov');
select is(app.staff_inactive_from_at(tests.staff('C'), '2026-11-23 20:30Z'), date '2026-11-24',
  'the same instant given in UTC (02:00 India time) gives the same date');

-- The outlet's own cutoff is used, not a fixed 04:00.
update public.outlets set day_cutoff = '06:00' where id = tests.outlet('A');
select is(app.staff_inactive_from_at(tests.staff('C'), '2026-11-24 05:00+05:30'), date '2026-11-24',
  'with a 06:00 cutoff, 05:00 on 24 Nov still belongs to 23 Nov');
update public.outlets set day_cutoff = '04:00' where id = tests.outlet('A');

-- The trigger uses the business date of the moment of deactivation.
select tests.login_as('head');
select public.update_staff(tests.staff('B'), 'Bilal', false, 'left the salon');
reset role;
select is((select inactive_from from public.staff where id = tests.staff('B')),
  app.business_date(tests.outlet('A'), now()) + 1, 'deactivating sets inactive_from to the business date + 1');

-- 7-8. Availability for a 01:00 deactivation on 24 Nov (dated as the trigger would at that instant).
select tests.entry('service', 5000, '2026-11-23', jsonb_build_object('staff_id', tests.staff('C')));
alter table public.staff disable trigger staff_inactive_from;
update public.staff set active = false,
  inactive_from = app.staff_inactive_from_at(id, '2026-11-24 01:00+05:30') where id = tests.staff('C');
alter table public.staff enable trigger staff_inactive_from;
select ok(app.staff_assigned(tests.staff('C'), tests.outlet('A'), '2026-11-23'),
  'available on the deactivation business date (23 Nov)');
select ok(not app.staff_assigned(tests.staff('C'), tests.outlet('A'), '2026-11-24'),
  'unavailable on the following business date (24 Nov)');

-- Deactivated exactly at 04:00: available on 24 Nov, unavailable on 25 Nov.
alter table public.staff disable trigger staff_inactive_from;
update public.staff set active = false,
  inactive_from = app.staff_inactive_from_at(id, '2026-11-24 04:00+05:30') where id = tests.staff('A');
alter table public.staff enable trigger staff_inactive_from;
select ok(app.staff_assigned(tests.staff('A'), tests.outlet('A'), '2026-11-24'),
  'deactivated at 04:00: available on that business date (24 Nov)');
select ok(not app.staff_assigned(tests.staff('A'), tests.outlet('A'), '2026-11-25'),
  'deactivated at 04:00: unavailable from 25 Nov');

-- 9. History keeps the employee's identity.
select tests.login_as('head');
select is((select a ->> 'staff_name' from jsonb_array_elements(
             public.day_summary(tests.outlet('A'), '2026-11-23') -> 'allocations') a
           where (a ->> 'staff_id')::uuid = tests.staff('C')), 'Chetan',
  'the deactivation day''s commission still names the employee');
reset role;
select is((select count(*)::int from public.entries where staff_id = tests.staff('C') and business_date = '2026-11-23'),
  1, 'the sale is kept against the employee');

-- An employee with no outlet cutoff keeps the calendar rule (no error).
update public.outlets set day_cutoff = null where id = tests.outlet('A');
select is(app.staff_inactive_from_at(tests.staff('C'), '2026-11-24 01:00+05:30'), date '2026-11-25',
  'no cutoff set: falls back to the India calendar date + 1');

select * from finish();
rollback;
