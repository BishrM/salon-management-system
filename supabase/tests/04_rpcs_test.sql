begin;
\ir helpers.psql

select plan(33);

-- set_outlet_cutoff (owner only) ------------------------------------------------------------------
select tests.login_as('manager');
select throws_ok($$ select public.set_outlet_cutoff(tests.outlet('A'), '04:00', 'setup') $$,
  '42501', null, 'owner''s son cannot set the cutoff');
reset role;
select tests.login_as('owner');
select throws_ok($$ select public.set_outlet_cutoff(tests.outlet('A'), '04:00', '   ') $$,
  '22023', null, 'cutoff change needs a reason');
select throws_ok($$ select public.set_outlet_cutoff(tests.outlet('B'), '04:00', 'setup') $$,
  '42501', null, 'owner of A cannot set B''s cutoff');
select lives_ok($$ select public.set_outlet_cutoff(tests.outlet('A'), '03:30', 'latest trading ends 01:00') $$,
  'owner sets the cutoff');
reset role;
select is((select day_cutoff from public.outlets where id = tests.outlet('A')), '03:30'::time, 'cutoff stored');
select is(
  (select row(actor, reason, old_data ->> 'day_cutoff', new_data ->> 'day_cutoff')::text
   from public.audit_logs where table_name = 'outlets' and row_id = tests.outlet('A') and action = 'UPDATE'
   order by server_seq desc limit 1),
  row(tests.uid('owner'), 'latest trading ends 01:00', null::text, '03:30:00')::text,
  'cutoff change audited with actor, reason, old and new value');

-- set_outlet_denominations (owner, manager) --------------------------------------------------------
select tests.login_as('head');
select throws_ok($$ select public.set_outlet_denominations(tests.outlet('A'), '{1000}', 'x') $$,
  '42501', null, 'head cannot change denominations');
reset role;
select tests.login_as('manager');
select is(public.set_outlet_denominations(tests.outlet('A'), '{50000,1000,1000,200}', 'add coins'),
  array[200,1000,50000], 'denominations stored sorted and de-duplicated');
select throws_ok($$ select public.set_outlet_denominations(tests.outlet('A'), '{1050}', 'x') $$,
  '22023', null, 'denominations must be whole rupees');
select throws_ok($$ select public.set_outlet_denominations(tests.outlet('A'), '{}', 'x') $$,
  '22023', null, 'at least one denomination is required');
reset role;

-- Staff ------------------------------------------------------------------------------------------
select tests.login_as('head');
select lives_ok($$ select public.create_staff(tests.outlet('A'), 'Shop Hire', '2026-11-01') $$,
  'Shop/Staff adds an employee to its outlet');
select throws_ok($$ select public.create_staff(tests.outlet('B'), 'Spy', '2026-11-01') $$,
  '42501', null, 'Shop/Staff cannot add an employee to another outlet');
reset role;
select tests.login_as('manager');
select throws_ok($$ select public.create_staff(tests.outlet('B'), 'Spy', '2026-11-01') $$,
  '42501', null, 'manager cannot create staff in another outlet');
select throws_ok($$ select public.create_staff(tests.outlet('A'), '  ', '2026-11-01') $$,
  '22023', null, 'staff name is required');
select throws_ok($$ select public.create_staff(tests.outlet('A'), 'Linked', '2026-11-01', tests.uid('outsider')) $$,
  '22023', null, 'linked login must belong to the outlet');
create temp table s as select public.create_staff(tests.outlet('A'), 'New Stylist', '2026-11-01') as id;
select is((select count(*)::int from public.staff_assignments a join s on a.staff_id = s.id
           where a.outlet_id = tests.outlet('A') and a.end_date is null), 1, 'create_staff opens an assignment');
select throws_ok($$ select public.end_staff_assignment((select a.id from public.staff_assignments a join s on a.staff_id = s.id),
                   '2026-11-30', '') $$, '22023', null, 'ending an assignment needs a reason');
select lives_ok($$ select public.end_staff_assignment((select a.id from public.staff_assignments a join s on a.staff_id = s.id),
                   '2026-11-30', 'moved') $$, 'manager ends an assignment');
select throws_ok($$ select public.end_staff_assignment((select a.id from public.staff_assignments a join s on a.staff_id = s.id),
                   '2026-12-31', 'again') $$, 'P0001', null, 'an ended assignment cannot be changed');
select lives_ok($$ select public.assign_staff((select id from s), tests.outlet('A'), '2026-12-01', 'returned') $$,
  'staff can be re-assigned after the previous assignment ended');
select throws_ok($$ select public.end_staff_assignment('00000000-0000-4000-8000-000000000000', '2026-12-31', 'x') $$,
  '42501', null, 'unknown assignment is denied, not leaked');
reset role;

-- Memberships ------------------------------------------------------------------------------------
select tests.login_as('manager');
select throws_ok($$ select public.add_membership(tests.outlet('A'), tests.uid('nobody'), 'counter', 'hire') $$,
  '42501', null, 'owner''s son cannot add users (users.manage is owner only)');
reset role;
select tests.login_as('owner');
select throws_ok($$ select public.add_membership(tests.outlet('A'), tests.uid('nobody'), 'counter', 'hired') $$,
  '22023', null, 'retired roles (counter, head) cannot be granted');
select lives_ok($$ select public.add_membership(tests.outlet('A'), tests.uid('nobody'), 'manager', 'hired') $$,
  'owner adds a management login');
select throws_ok($$ select public.add_membership(tests.outlet('A'), tests.uid('nobody'), 'shop', 'again') $$,
  '23505', null, 'duplicate permanent membership is rejected');
select throws_ok($$ select public.add_membership(tests.outlet('A'), tests.uid('owner2'), 'shop', 'second shop') $$,
  '23505', null, 'an outlet has one Shop/Staff login');
select throws_ok($$ select public.add_membership(tests.outlet('A'), tests.uid('head'), 'owner', 'promote shop') $$,
  '23505', null, 'the Shop/Staff login cannot also hold a management role');
select throws_ok($$ select public.revoke_membership(
                     (select id from public.outlet_memberships where profile_id = tests.uid('owner') and outlet_id = tests.outlet('A')),
                     'leaving') $$,
  '22023', null, 'the last owner cannot be revoked');
select lives_ok($$ select public.revoke_membership(
                     (select id from public.outlet_memberships where profile_id = tests.uid('nobody') and revoked_at is null),
                     'left') $$, 'owner revokes a membership');
select throws_ok($$ select public.revoke_membership(
                     (select id from public.outlet_memberships where profile_id = tests.uid('nobody')), 'again') $$,
  '22023', null, 'a revoked membership cannot be revoked again');
reset role;

-- Acting-head delegation was retired (001700): nobody can grant one. ---------------------------------
select tests.login_as('owner');
select throws_ok($$ select public.grant_acting_head(tests.outlet('A'), tests.uid('counter2'), now() + interval '8 hours', 'cover') $$,
  '42501', null, 'owner cannot grant an acting-head delegation');
reset role;
select tests.login_as('manager');
select throws_ok($$ select public.grant_acting_head(tests.outlet('A'), tests.uid('counter2'), now() + interval '8 hours', 'cover') $$,
  '42501', null, 'manager cannot grant an acting-head delegation');
reset role;
select tests.login_as('head');
select throws_ok($$ select public.grant_acting_head(tests.outlet('A'), tests.uid('counter2'), now() + interval '8 hours', 'cover') $$,
  '42501', null, 'Shop/Staff cannot grant an acting-head delegation');
reset role;

select * from finish();
rollback;
