begin;
\ir helpers.psql

select plan(23);

-- Full permission matrix per role (Rev 6 §4) -----------------------------------------------------
create temp table expected (role text, perms text[]);
insert into expected values
  ('owner', array(select permission from app.permission_matrix())),
  ('manager', array['outlet.read','entries.record','closing.prepare','closing.submit','paytm.enter',
    'commission.handover','closing.approve','closing.reopen','review.acknowledge','late_entry.review',
    'food_excess.allocate','commission.adjust','float.manage','date.assign','sync.manage','staff.manage',
    'catalog.manage','reports.read','members.read','delegation.manage','outlet.denominations']),
  ('head', array['outlet.read','entries.record','closing.prepare','closing.submit','paytm.enter','commission.handover']),
  ('counter', array['outlet.read','entries.record']);
grant select on expected to authenticated;

select tests.login_as('owner');
select set_eq($$ select unnest(public.my_permissions(tests.outlet('A'))) $$,
              $$ select unnest(perms) from expected where role = 'owner' $$, 'owner holds every permission');
reset role;
select tests.login_as('manager');
select set_eq($$ select unnest(public.my_permissions(tests.outlet('A'))) $$,
              $$ select unnest(perms) from expected where role = 'manager' $$,
              'owner''s son: everything except cutoff, thresholds, outlet details, initial float, users, audit');
reset role;
select tests.login_as('head');
select set_eq($$ select unnest(public.my_permissions(tests.outlet('A'))) $$,
              $$ select unnest(perms) from expected where role = 'head' $$, 'head employee permissions');
reset role;
select tests.login_as('counter');
select set_eq($$ select unnest(public.my_permissions(tests.outlet('A'))) $$,
              $$ select unnest(perms) from expected where role = 'counter' $$, 'counter operator permissions');
select is(public.my_permissions(tests.outlet('B')), '{}'::text[], 'no permissions in another outlet');
reset role;
select tests.login_as('nobody');
select is(public.my_permissions(tests.outlet('A')), '{}'::text[], 'a login without membership has no permissions');
reset role;

select throws_ok($$ select app.has_permission(tests.outlet('A'), 'no.such.permission') $$,
  '22023', null, 'unknown permission names raise instead of silently denying');

-- Acting head validity (Rev 6 §4.1) ---------------------------------------------------------------
-- Active delegation granted by manager.
insert into public.outlet_memberships (id, outlet_id, profile_id, role, is_acting, valid_from, valid_to, granted_by, reason)
values ('dddddddd-0000-4000-8000-000000000001', tests.outlet('A'), tests.uid('counter2'), 'head', true,
        now() - interval '1 hour', now() + interval '1 hour', tests.uid('manager'), 'head on leave');

select tests.login_as('counter2');
select ok(app.has_permission(tests.outlet('A'), 'closing.submit'), 'active acting head gets head permissions');
select ok(not app.has_permission(tests.outlet('A'), 'delegation.manage'), 'acting head cannot grant delegations');
select ok(not app.has_permission(tests.outlet('A'), 'closing.approve'), 'acting head cannot approve closings');
select ok(not app.has_permission(tests.outlet('B'), 'closing.submit'), 'delegation does not leak to other outlets');
reset role;

-- Grantor demoted -> delegation stops working.
update public.outlet_memberships set revoked_at = now(), revoked_by = tests.uid('owner'), revoke_reason = 'test'
 where outlet_id = tests.outlet('A') and profile_id = tests.uid('manager');
select tests.login_as('counter2');
select ok(not app.has_permission(tests.outlet('A'), 'closing.submit'), 'delegation ends when the grantor loses their role');
reset role;

-- Not yet started.
insert into public.outlet_memberships (outlet_id, profile_id, role, is_acting, valid_from, valid_to, granted_by, reason)
values (tests.outlet('A'), tests.uid('counter'), 'head', true, now() + interval '1 hour', now() + interval '2 hours', tests.uid('owner'), 'future');
select tests.login_as('counter');
select ok(not app.has_permission(tests.outlet('A'), 'closing.submit'), 'future delegation is not active yet');
reset role;

-- Expired. valid_to = now() is already expired (half-open window).
insert into public.outlet_memberships (outlet_id, profile_id, role, is_acting, valid_from, valid_to, granted_by, reason)
values (tests.outlet('A'), tests.uid('counter'), 'head', true, now() - interval '2 hours', now(), tests.uid('owner'), 'expired at boundary');
select tests.login_as('counter');
select ok(not app.has_permission(tests.outlet('A'), 'closing.submit'), 'delegation ending exactly now is expired');
reset role;

-- Starting exactly now is active.
insert into public.outlet_memberships (id, outlet_id, profile_id, role, is_acting, valid_from, valid_to, granted_by, reason)
values ('dddddddd-0000-4000-8000-000000000002', tests.outlet('A'), tests.uid('counter'), 'head', true, now(), now() + interval '1 hour', tests.uid('owner'), 'starts now');
select tests.login_as('counter');
select ok(app.has_permission(tests.outlet('A'), 'closing.submit'), 'delegation starting exactly now is active');
reset role;

-- Revoked.
update public.outlet_memberships set revoked_at = now(), revoked_by = tests.uid('owner'), revoke_reason = 'back early'
 where id = 'dddddddd-0000-4000-8000-000000000002';
select tests.login_as('counter');
select ok(not app.has_permission(tests.outlet('A'), 'closing.submit'), 'revoked delegation is inactive');
select ok(app.has_permission(tests.outlet('A'), 'entries.record'), 'revoking a delegation keeps the base counter role');
reset role;

-- Permanent membership with NULL valid_to stays valid; with a past valid_to it is not.
select tests.login_as('head');
select ok(app.has_permission(tests.outlet('A'), 'closing.submit'), 'permanent membership with NULL valid_to is valid');
reset role;

-- Inactive profile loses all roles.
update public.profiles set active = false where id = tests.uid('head');
select tests.login_as('head');
select ok(not app.is_member(tests.outlet('A')), 'deactivated user has no roles');
reset role;

-- Revoked permanent membership.
select tests.login_as('manager');
select ok(not app.is_member(tests.outlet('A')), 'revoked permanent membership grants nothing');
reset role;

-- Anonymous.
select tests.login_anon();
select throws_ok($$ select public.my_permissions(tests.outlet('A')) $$, '42501', null, 'anon cannot call RPCs');
reset role;

-- Owner of B is not a member of A.
select tests.login_as('outsider');
select ok(not app.is_member(tests.outlet('A')), 'owner of outlet B has no access to outlet A');
select ok(app.has_permission(tests.outlet('B'), 'audit.read'), 'owner of outlet B is owner there');
reset role;

select * from finish();
rollback;
