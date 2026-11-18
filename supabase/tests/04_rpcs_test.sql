begin;
\ir helpers.psql

select plan(36);

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
select throws_ok($$ select public.create_staff(tests.outlet('A'), 'New Stylist', '2026-11-01') $$,
  '42501', null, 'head cannot create staff');
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
select lives_ok($$ select public.add_membership(tests.outlet('A'), tests.uid('nobody'), 'counter', 'hired') $$,
  'owner adds a counter operator');
select throws_ok($$ select public.add_membership(tests.outlet('A'), tests.uid('nobody'), 'head', 'promote') $$,
  '23505', null, 'duplicate permanent membership is rejected');
select throws_ok($$ select public.revoke_membership(
                     (select id from public.outlet_memberships where profile_id = tests.uid('owner') and outlet_id = tests.outlet('A')),
                     'leaving') $$,
  '22023', null, 'the last owner cannot be revoked');
reset role;

-- Acting-head delegation (Rev 6 §4.1) --------------------------------------------------------------
select tests.login_as('head');
select throws_ok($$ select public.grant_acting_head(tests.outlet('A'), tests.uid('counter2'), now() + interval '8 hours', 'cover') $$,
  '42501', null, 'head cannot grant delegations');
reset role;
select tests.login_as('manager');
select throws_ok($$ select public.grant_acting_head(tests.outlet('A'), tests.uid('manager'), now() + interval '8 hours', 'me') $$,
  '42501', null, 'manager cannot delegate to themselves');
select throws_ok($$ select public.grant_acting_head(tests.outlet('A'), tests.uid('counter2'), null, 'open ended') $$,
  '22023', null, 'delegation needs an end time');
select throws_ok($$ select public.grant_acting_head(tests.outlet('A'), tests.uid('counter2'), now() - interval '1 minute', 'past',
                   now() - interval '2 hours') $$,
  '22023', null, 'delegation ending in the past is rejected');
select throws_ok($$ select public.grant_acting_head(tests.outlet('A'), tests.uid('counter2'), now() + interval '1 hour', 'inverted',
                   now() + interval '2 hours') $$,
  '22023', null, 'delegation end before start is rejected');
select throws_ok($$ select public.grant_acting_head(tests.outlet('A'), tests.uid('outsider'), now() + interval '8 hours', 'outsider') $$,
  '22023', null, 'delegation target must be a member of the outlet');
select throws_ok($$ select public.grant_acting_head(tests.outlet('A'), tests.uid('counter2'), now() + interval '8 hours', '') $$,
  '22023', null, 'delegation needs a reason');
create temp table d as
  select public.grant_acting_head(tests.outlet('A'), tests.uid('counter2'), now() + interval '8 hours', 'head on leave') as id;
select is(
  (select row(granted_by, is_acting, role)::text from public.outlet_memberships where id = (select id from d)),
  row(tests.uid('manager'), true, 'head'::public.app_role)::text,
  'delegation recorded with the authorising manager taken from the session');
reset role;

select tests.login_as('counter2');
select ok(app.has_permission(tests.outlet('A'), 'closing.prepare'), 'acting head can prepare closings during the window');
select throws_ok($$ select public.grant_acting_head(tests.outlet('A'), tests.uid('counter'), now() + interval '1 hour', 'chain') $$,
  '42501', null, 'acting head cannot sub-delegate');
reset role;

select tests.login_as('owner');
select lives_ok($$ select public.revoke_membership((select id from d), 'head is back') $$, 'owner revokes the delegation early');
select throws_ok($$ select public.revoke_membership((select id from d), 'again') $$,
  '22023', null, 'a revoked membership cannot be revoked again');
reset role;

select * from finish();
rollback;
