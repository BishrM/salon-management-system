begin;
\ir helpers.psql

select plan(31);

-- Structure & privileges ------------------------------------------------------------------------
select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  0, 'every public table has RLS enabled');

select is(
  (select count(*)::int
   from pg_class c join pg_namespace n on n.oid = c.relnamespace
   cross join (values ('anon'), ('authenticated')) r(role)
   cross join (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) p(priv)
   where n.nspname = 'public' and c.relkind = 'r' and has_table_privilege(r.role, c.oid, p.priv)),
  0, 'anon/authenticated hold no write privileges on any public table');

select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and has_table_privilege('anon', c.oid, 'SELECT')),
  0, 'anon cannot SELECT any public table');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app') and has_function_privilege('anon', p.oid, 'EXECUTE')),
  0, 'anon cannot execute any public/app function');

select set_eq(
  $$ select p.proname::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'EXECUTE') $$,
  array['my_permissions','server_time','current_business_date','set_outlet_cutoff','set_outlet_denominations',
        'set_offline_thresholds','set_outlet_details','create_staff','assign_staff','assign_staff_temporary',
        'end_staff_assignment','update_staff','upsert_product','add_membership','grant_acting_head',
        'revoke_membership','sync_ops','resolve_sync_issue','withdraw_sync_op','withdraw_blocked_op','assign_business_date','day_summary',
        'prepare_closing','update_draft','allocate_food_excess','submit_closing','approve_closing',
        'reject_closing','reopen_closing','acknowledge_review','review_late_entry','establish_initial_float',
        'record_top_up','change_required_float','reverse_float_movement','record_handover',
        'record_commission_return','accept_commission_overpayment','import_paytm_transactions'],
  'authenticated can execute exactly the RPC allow-list');

select ok(not has_function_privilege('authenticated', 'app.bootstrap_outlet(text,text,uuid)', 'EXECUTE'),
  'bootstrap_outlet is not callable by clients');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public','app') and p.prosecdef
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')),
  0, 'every SECURITY DEFINER function pins search_path');

-- Profiles ----------------------------------------------------------------------------------------
select is((select full_name from public.profiles where id = tests.uid('owner')), 'Owner',
  'a profile is created for each new auth user');

-- Audit log is append-only, even for postgres ------------------------------------------------------
select ok((select count(*) from public.audit_logs where table_name = 'outlet_memberships') >= 6,
  'membership inserts are audited');
select throws_ok($$ update public.audit_logs set reason = 'x' $$, 'P0001', null, 'audit_logs: UPDATE blocked');
select throws_ok($$ delete from public.audit_logs $$, 'P0001', null, 'audit_logs: DELETE blocked');
select throws_ok($$ truncate public.audit_logs $$, 'P0001', null, 'audit_logs: TRUNCATE blocked');

-- Outlets -----------------------------------------------------------------------------------------
select is((select day_cutoff from public.outlets where id = tests.outlet('A')), null::time,
  'cutoff has no default (B1/F5)');
select is((select denominations from public.outlets where id = tests.outlet('A')),
  array[1000,2000,5000,10000,20000,50000], 'default denominations are SRS §3.7 notes, in paise');
select is((select array[online_window_s, clock_warn_s, gap_flag_h] from public.outlets where id = tests.outlet('A')),
  array[120,300,48], 'offline thresholds default to 120 s / 300 s / 48 h (G4)');
select throws_ok($$ update public.outlets set online_window_s = 0 where id = tests.outlet('A') $$,
  '23514', null, 'thresholds must be positive');
select throws_ok($$ update public.outlets set denominations = '{1000,-5}' where id = tests.outlet('A') $$,
  '23514', null, 'denominations must be positive');
select throws_ok($$ delete from public.outlets where id = tests.outlet('A') $$, 'P0001', null, 'outlets cannot be deleted');

-- Memberships: acting-head constraints (Rev 6 §4.1) ------------------------------------------------
select throws_ok($$ insert into public.outlet_memberships (outlet_id, profile_id, role, is_acting, valid_to, granted_by, reason)
                   values (tests.outlet('A'), tests.uid('counter2'), 'head', true, null, tests.uid('manager'), 'r') $$,
  '23514', null, 'acting delegation with NULL valid_to is rejected');
select throws_ok($$ insert into public.outlet_memberships (outlet_id, profile_id, role, is_acting, valid_to, granted_by, reason)
                   values (tests.outlet('A'), tests.uid('counter2'), 'head', true, now() + interval '1 day', tests.uid('counter2'), 'r') $$,
  '23514', null, 'self-authorised delegation is rejected');
select throws_ok($$ insert into public.outlet_memberships (outlet_id, profile_id, role, is_acting, valid_to, granted_by, reason)
                   values (tests.outlet('A'), tests.uid('counter2'), 'head', true, now() + interval '1 day', null, 'r') $$,
  '23514', null, 'delegation without an authorising manager is rejected');
select throws_ok($$ insert into public.outlet_memberships (outlet_id, profile_id, role, is_acting, valid_to, granted_by, reason)
                   values (tests.outlet('A'), tests.uid('counter2'), 'manager', true, now() + interval '1 day', tests.uid('owner'), 'r') $$,
  '23514', null, 'acting rows can only carry the head role');
select throws_ok($$ insert into public.outlet_memberships (outlet_id, profile_id, role, valid_from, valid_to)
                   values (tests.outlet('A'), tests.uid('nobody'), 'counter', now(), now() - interval '1 hour') $$,
  '23514', null, 'valid_to must be after valid_from');
select throws_ok($$ insert into public.outlet_memberships (outlet_id, profile_id, role)
                   values (tests.outlet('A'), tests.uid('counter'), 'head') $$,
  '23505', null, 'one active permanent membership per user per outlet');
select throws_ok($$ delete from public.outlet_memberships where profile_id = tests.uid('counter') $$,
  'P0001', null, 'memberships cannot be deleted');
select throws_ok($$ update public.outlet_memberships set role = 'owner' where profile_id = tests.uid('counter') $$,
  'P0001', null, 'membership role cannot be changed in place');
select throws_ok($$ update public.outlet_memberships set revoked_at = now(), revoked_by = tests.uid('owner')
                   where profile_id = tests.uid('counter') $$,
  '23514', null, 'revocation requires a reason');

-- Staff -------------------------------------------------------------------------------------------
insert into public.staff (id, full_name) values ('cccccccc-0000-4000-8000-000000000001', 'Stylist One');
insert into public.staff_assignments (staff_id, outlet_id, start_date)
values ('cccccccc-0000-4000-8000-000000000001', tests.outlet('A'), '2026-01-01');

select throws_ok($$ insert into public.staff_assignments (staff_id, outlet_id, start_date)
                   values ('cccccccc-0000-4000-8000-000000000001', tests.outlet('B'), '2026-06-01') $$,
  '23P01', null, 'overlapping staff assignments are rejected');
select throws_ok($$ update public.staff_assignments set start_date = '2025-01-01'
                   where staff_id = 'cccccccc-0000-4000-8000-000000000001' $$,
  'P0001', null, 'assignment start date cannot be rewritten');
select throws_ok($$ delete from public.staff where id = 'cccccccc-0000-4000-8000-000000000001' $$,
  'P0001', null, 'staff cannot be deleted');
select throws_ok($$ update public.staff_assignments set end_date = '2025-12-01', end_reason = 'x'
                   where staff_id = 'cccccccc-0000-4000-8000-000000000001' $$,
  '23514', null, 'assignment cannot end before it starts');

select * from finish();
rollback;
