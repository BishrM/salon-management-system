begin;
\ir helpers.psql

select plan(26);

insert into public.staff (id, full_name) values
  ('cccccccc-0000-4000-8000-00000000000a', 'Stylist A'),
  ('cccccccc-0000-4000-8000-00000000000b', 'Stylist B');
insert into public.staff_assignments (staff_id, outlet_id, start_date) values
  ('cccccccc-0000-4000-8000-00000000000a', tests.outlet('A'), '2026-01-01'),
  ('cccccccc-0000-4000-8000-00000000000b', tests.outlet('B'), '2026-01-01');
insert into public.devices (id, outlet_id, label) values
  ('eeeeeeee-0000-4000-8000-00000000000a', tests.outlet('A'), 'Counter tablet');

-- Outlets -----------------------------------------------------------------------------------------
select tests.login_as('counter');
select results_eq($$ select id from public.outlets $$, $$ values (tests.outlet('A')) $$,
  'counter sees only their own outlet');
select is((select count(*)::int from public.outlet_memberships), 1, 'counter sees only their own membership');
select is((select count(*)::int from public.profiles), 1, 'counter sees only their own profile');
select results_eq($$ select full_name from public.staff $$, $$ values ('Stylist A'::text) $$,
  'counter sees staff of their outlet only');
select is((select count(*)::int from public.devices), 0, 'counter cannot see devices');
select is((select count(*)::int from public.audit_logs), 0, 'counter cannot read the audit log');
reset role;

select tests.login_as('manager');
select is((select count(*)::int from public.outlet_memberships), 4, 'manager sees all memberships of outlet A');
select is((select count(*)::int from public.profiles), 4, 'manager sees profiles of outlet A members');
select is((select count(*)::int from public.devices), 1, 'manager sees outlet devices');
select is((select count(*)::int from public.audit_logs), 0, 'owner''s son cannot read the audit log (O16)');
reset role;

select tests.login_as('owner');
select ok((select count(*) from public.audit_logs where outlet_id = tests.outlet('A')) > 0, 'owner reads outlet A audit log');
select is((select count(*)::int from public.audit_logs where outlet_id = tests.outlet('B')), 0,
  'owner of A cannot read outlet B audit rows');
select is((select count(*)::int from public.staff where full_name = 'Stylist B'), 0, 'owner of A cannot see outlet B staff');
select ok(exists (select 1 from public.audit_logs where table_name = 'staff' and row_id = 'cccccccc-0000-4000-8000-00000000000a'),
  'owner of A reads audit rows of outlet A staff');
reset role;

-- Audit rows of global tables (staff, profiles) have no outlet_id: never visible across outlets (S12).
select tests.login_as('outsider');
select is((select count(*)::int from public.audit_logs where table_name = 'staff' and row_id = 'cccccccc-0000-4000-8000-00000000000a'), 0,
  'owner of B cannot read audit rows of outlet A staff');
select is((select count(*)::int from public.audit_logs where table_name = 'profiles' and row_id = tests.uid('counter')), 0,
  'owner of B cannot read audit rows of outlet A member profiles');
select ok(exists (select 1 from public.audit_logs where table_name = 'staff' and row_id = 'cccccccc-0000-4000-8000-00000000000b'),
  'owner of B reads audit rows of their own staff');
reset role;

select tests.login_as('nobody');
select is((select count(*)::int from public.outlets), 0, 'login without membership sees no outlets');
select is((select count(*)::int from public.outlet_memberships), 0, 'login without membership sees no memberships');
reset role;

select tests.login_anon();
select throws_ok($$ select * from public.outlets $$, '42501', null, 'anon has no table access at all');
reset role;

-- Direct writes are denied at the privilege layer, even for the owner ------------------------------
select tests.login_as('owner');
select throws_ok($$ update public.outlets set day_cutoff = '03:00' $$, '42501', null, 'owner cannot UPDATE outlets directly');
select throws_ok($$ insert into public.outlet_memberships (outlet_id, profile_id, role)
                   values (tests.outlet('A'), tests.uid('nobody'), 'owner') $$,
  '42501', null, 'owner cannot INSERT memberships directly');
select throws_ok($$ delete from public.staff $$, '42501', null, 'owner cannot DELETE staff directly');
select throws_ok($$ insert into public.audit_logs (table_name, action) values ('x', 'INSERT') $$,
  '42501', null, 'clients cannot forge audit rows');
reset role;

-- Role escalation attempt: counter tries to grant themselves owner ----------------------------------
select tests.login_as('counter');
select throws_ok($$ insert into public.outlet_memberships (outlet_id, profile_id, role)
                   values (tests.outlet('A'), tests.uid('counter'), 'owner') $$,
  '42501', null, 'counter cannot self-escalate by inserting a membership');
select throws_ok($$ select public.add_membership(tests.outlet('A'), tests.uid('counter'), 'owner', 'please') $$,
  '42501', null, 'counter cannot self-escalate through the RPC');
reset role;

select * from finish();
rollback;
