begin;
\ir helpers.psql

select plan(20);

-- Full permission matrix per role (two account types since 001700) ----------------------------------
create temp table expected (role text, perms text[]);
insert into expected values
  ('owner', array(select permission from app.permission_matrix() where 'owner' = any (roles))),
  ('manager', array['outlet.read','entries.record','closing.prepare','closing.submit','paytm.enter',
    'commission.handover','closing.approve','closing.reopen','review.acknowledge','late_entry.review',
    'food_excess.allocate','food_repayment.record','commission.adjust','float.manage','date.assign',
    'sync.manage','staff.manage','catalog.manage','reports.read','members.read','outlet.denominations']),
  ('shop', array['outlet.read','entries.record','closing.prepare','closing.submit','paytm.enter',
    'commission.handover','staff.manage']);
grant select on expected to authenticated;

select tests.login_as('owner');
select set_eq($$ select unnest(public.my_permissions(tests.outlet('A'))) $$,
              $$ select unnest(perms) from expected where role = 'owner' $$, 'owner holds every granted permission');
reset role;
select tests.login_as('manager');
select set_eq($$ select unnest(public.my_permissions(tests.outlet('A'))) $$,
              $$ select unnest(perms) from expected where role = 'manager' $$,
              'owner''s son: everything except cutoff, thresholds, outlet details, initial float, users, audit');
reset role;
select tests.login_as('head');
select set_eq($$ select unnest(public.my_permissions(tests.outlet('A'))) $$,
              $$ select unnest(perms) from expected where role = 'shop' $$, 'Shop/Staff permissions');
select ok(not app.has_permission(tests.outlet('A'), 'closing.approve')
          and not app.has_permission(tests.outlet('A'), 'audit.read')
          and not app.has_permission(tests.outlet('A'), 'users.manage')
          and not app.has_permission(tests.outlet('A'), 'float.manage')
          and not app.has_permission(tests.outlet('A'), 'reports.read'),
          'Shop/Staff has no owner-only management permission');
select is(public.my_permissions(tests.outlet('B')), '{}'::text[], 'no permissions in another outlet');
reset role;
select tests.login_as('nobody');
select is(public.my_permissions(tests.outlet('A')), '{}'::text[], 'a login without membership has no permissions');
reset role;

select throws_ok($$ select app.has_permission(tests.outlet('A'), 'no.such.permission') $$,
  '22023', null, 'unknown permission names raise instead of silently denying');

-- Retired roles (001700): legacy head/counter memberships and acting-head delegations grant nothing. ----
select tests.login_as('counter2');
select is(public.my_permissions(tests.outlet('A')), '{}'::text[], 'a legacy counter membership grants nothing');
reset role;
insert into public.outlet_memberships (outlet_id, profile_id, role, granted_by, reason)
values (tests.outlet('B'), tests.uid('counter2'), 'head', tests.uid('outsider'), 'legacy head');
insert into public.outlet_memberships (outlet_id, profile_id, role, is_acting, valid_from, valid_to, granted_by, reason)
values (tests.outlet('A'), tests.uid('counter2'), 'head', true,
        now() - interval '1 hour', now() + interval '1 hour', tests.uid('manager'), 'head on leave');
select tests.login_as('counter2');
select is(public.my_permissions(tests.outlet('B')), '{}'::text[], 'a legacy head membership grants nothing');
select ok(not app.has_permission(tests.outlet('A'), 'closing.submit'), 'an active acting-head delegation grants nothing');
select ok(not app.is_member(tests.outlet('A')) and not app.is_member(tests.outlet('B')), 'legacy roles see no outlet');
reset role;
select tests.login_as('owner');
select ok(not app.has_permission(tests.outlet('A'), 'delegation.manage'), 'nobody can grant delegations any more');
reset role;

-- Grantor demoted (kept: revoking a management membership still works).
update public.outlet_memberships set revoked_at = now(), revoked_by = tests.uid('owner'), revoke_reason = 'test'
 where outlet_id = tests.outlet('A') and profile_id = tests.uid('manager') and not is_acting;

-- Shop/Staff is one shared login per outlet, and a shop login belongs to one outlet.
select throws_ok($$ insert into public.outlet_memberships (outlet_id, profile_id, role, granted_by, reason)
                    values (tests.outlet('A'), tests.uid('nobody'), 'shop', tests.uid('owner'), 'second shop') $$,
  '23505', null, 'a second Shop/Staff login for the same outlet is refused');
select throws_ok($$ insert into public.outlet_memberships (outlet_id, profile_id, role, granted_by, reason)
                    values (tests.outlet('B'), tests.uid('head'), 'shop', tests.uid('outsider'), 'shop of two outlets') $$,
  '23505', null, 'one Shop/Staff login cannot serve two outlets');

-- Permanent membership with NULL valid_to stays valid; with a past valid_to it is not.
select tests.login_as('head');
select ok(app.has_permission(tests.outlet('A'), 'closing.submit'), 'permanent Shop/Staff membership with NULL valid_to is valid');
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
