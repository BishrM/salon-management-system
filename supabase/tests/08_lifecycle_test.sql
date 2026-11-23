begin;
\ir helpers.psql
select tests.ops_fixture();

select plan(71);

create temp table k (name text primary key, v uuid);
grant select, insert, update on k to authenticated;
create function pg_temp.k(p text) returns uuid language sql as $$ select v from k where name = p $$;
create temp table snap (name text primary key, v text);
grant select, insert on snap to authenticated;

-- Initial float (G2, J4, §10.1) --------------------------------------------------------------------------------
select tests.login_as('manager');
select throws_ok($$ select public.establish_initial_float(tests.outlet('A'), '2026-02-01', '{"50000":2}', 100000) $$,
  '42501', null, 'only the owner establishes the initial float');
reset role;
select tests.login_as('owner');
select throws_ok($$ select public.establish_initial_float(tests.outlet('A'), '2026-02-01', '{"50000":2}', 90000) $$,
  '22023', null, 're-typed total must equal the denomination count');
select throws_ok($$ select public.establish_initial_float(tests.outlet('A'), '2026-02-01', '{"25000":4}', 100000) $$,
  '22023', null, 'only configured denominations');
select lives_ok($$ insert into k select 'init', public.establish_initial_float(tests.outlet('A'), '2026-02-01', '{"50000":2}', 100000) $$,
  'owner counts, enters and self-confirms the float in one action');
select throws_ok($$ select public.establish_initial_float(tests.outlet('A'), '2026-02-02', '{"50000":2}', 100000) $$,
  '23505', null, 'a second initialisation is impossible');
select throws_ok($$ select public.reverse_float_movement(pg_temp.k('init'), 'miscount') $$, '22023', null,
  'the initial float cannot be reversed');
reset role;
select is((select row(recorded_by = authorised_by, confirmation ->> 'self_confirmed', confirmation ->> 'retyped_total')::text
           from public.float_movements where id = pg_temp.k('init')),
  row(true, 'true', '100000')::text, 'initial float row records owner self-confirmation');
select is((select count(*)::int from public.audit_logs where table_name = 'float_movements' and row_id = pg_temp.k('init')
           and reason like 'initial_float_established%self-confirmed%'), 1, 'initial_float_established audit entry');
select throws_ok($$ insert into public.float_movements (outlet_id, type, effective_business_date, timing, amount, source,
    denominations, authorised_by, recorded_by, reason, confirmation)
  values (tests.outlet('B'), 'initial_float', '2026-02-01', 'pre_opening', 100000, 'owner_funds', '{"50000":2}',
    tests.uid('outsider'), tests.uid('owner'), 'x', '{"method":"single_action_retyped_total","self_confirmed":true,"retyped_total":100000}') $$,
  '23514', null, 'CHECK: initial float recorder must equal authoriser');

-- Permission boundaries on closings -------------------------------------------------------------------------
select tests.entry('service', 1000, '2026-02-01', jsonb_build_object('staff_id', tests.staff('A')));
select tests.login_as('counter2');
select throws_ok($$ select public.prepare_closing(tests.outlet('A'), '2026-02-01') $$, '42501', null,
  'a retired (legacy counter) login cannot prepare a closing');
reset role;
select tests.login_as('head');
insert into k select 'c1', (public.prepare_closing(tests.outlet('A'), '2026-02-01') ->> 'closing_id')::uuid;
select public.set_closing_employee(pg_temp.k('c1'), tests.staff('A'));
select ok((select v from k where name = 'c1') is not null, 'head prepares the closing');
select ok((public.update_draft(pg_temp.k('c1'), 0, 10000, null, '{"50000":4}', null, 'Owner') -> 'blockers') ? 'split_mismatch',
  'UPI/card split that does not add up blocks submission');
select throws_ok($$ select public.submit_closing(pg_temp.k('c1')) $$, '22023', null, 'submit refused while blocked');
select ok((public.update_draft(pg_temp.k('c1'), null, null, null, '{"50000":4}', null, 'Owner') -> 'blockers') ? 'paytm_missing',
  'missing Paytm total blocks submission (enter 0 when there was none)');
select is(public.update_draft(pg_temp.k('c1'), 0, null, null, '{"50000":4}', null, 'Owner') -> 'blockers', '[]'::jsonb,
  'no blockers with Paytm 0 and an exact count');
insert into k select 'r1', public.submit_closing(pg_temp.k('c1'));
select throws_ok($$ select public.update_draft(pg_temp.k('c1'), 0, null, null, '{"50000":4}', null, 'Owner') $$, 'SO423', null,
  'a submitted closing cannot be edited');
select throws_ok($$ select public.approve_closing(pg_temp.k('r1'), '{}') $$, '42501', null, 'head cannot approve');
reset role;
select tests.login_as('counter');
select throws_ok($$ select public.approve_closing(pg_temp.k('r1'), '{}') $$, '42501', null, 'counter cannot approve');
reset role;
select tests.login_as('outsider');
select throws_ok($$ select public.approve_closing(pg_temp.k('r1'), '{}') $$, '42501', null, 'owner of another outlet cannot approve');
select is((select count(*)::int from public.closing_revisions), 0, 'and cannot read the revision');
reset role;

-- Float top-ups never touch a frozen day (F2, G1) ---------------------------------------------------------
select tests.login_as('manager');
select throws_ok($$ select public.record_top_up(tests.outlet('A'), '2026-02-01', 'intraday', 10000, 'owner_funds', null, 'change') $$,
  'SO423', null, 'top-up for a submitted day is rejected');
select throws_ok($$ select public.change_required_float(tests.outlet('A'), '2026-02-01', 200000, 'x') $$, 'SO423', null,
  'required-float change for a submitted day is rejected');
reset role;
select tests.login_as('head');
select throws_ok($$ select public.record_top_up(tests.outlet('A'), '2026-02-03', 'intraday', 10000, 'owner_funds', null, 'x') $$,
  '42501', null, 'head cannot change the float (SRS §3.6)');
reset role;

-- Unassigned entry → management date → late entry (§6.3, H3) ------------------------------------------
select tests.login_as('counter');
insert into k values ('late', gen_random_uuid());
select is(public.sync_ops(tests.outlet('A'), gen_random_uuid(), 'Tablet', jsonb_build_array(jsonb_build_object(
  'op_id', gen_random_uuid(), 'device_seq', 1, 'type', 'create_entry', 'record_id', pg_temp.k('late'),
  'device_time', '2026-02-01 18:00+05:30', 'device_offset_ms', null, 'device_last_sync_at', null,
  'data', jsonb_build_object('kind', 'service', 'payment_method', 'cash', 'staff_id', tests.staff('B'), 'amount', 50000))))
  -> 'results' -> 0 -> 'result' ->> 'business_date', null, 'offline entry with unknown clock offset lands in Unassigned');
select throws_ok($$ select public.assign_business_date('entry', pg_temp.k('late'), '2026-02-01', 'from paper register') $$,
  '42501', null, 'counter cannot assign business dates');
reset role;
select is((select row(device_time, timestamp_flags)::text from public.entries where id = pg_temp.k('late')),
  row(timestamptz '2026-02-01 18:00+05:30', array['timestamp_suspect'])::text, 'original device time kept as evidence');
select tests.login_as('manager');
select lives_ok($$ select public.assign_business_date('entry', pg_temp.k('late'), '2026-02-01', 'matches paper register') $$,
  'manager assigns the date');
reset role;
select is((select row(late, late_against_revision_id = pg_temp.k('r1'), date_basis)::text from public.entries where id = pg_temp.k('late')),
  row(true, true, 'management_assigned'::public.date_basis)::text, 'assigned into a submitted day → late entry');
select is((select row(service_total)::text from public.closing_revisions where id = pg_temp.k('r1')), row(100000::bigint)::text,
  'the frozen revision is untouched');
select tests.login_as('manager');
select throws_ok($$ select public.approve_closing(pg_temp.k('r1'), '{}') $$, '22023', null, 'undecided late entry blocks approval');
select throws_ok($$ select public.acknowledge_review(pg_temp.k('c1'), 'late_entries', 'seen') $$, '22023', null,
  'late entries cannot be cleared by a generic acknowledgement');
select throws_ok($$ select public.review_late_entry('entry', pg_temp.k('late'), 'exclude', '  ') $$, '22023', null,
  'exclude needs a reason');
reset role;
select tests.login_as('head');
select throws_ok($$ select public.review_late_entry('entry', pg_temp.k('late'), 'exclude', 'duplicate of paper') $$, '42501', null,
  'head cannot decide late entries');
reset role;
select tests.login_as('manager');
select lives_ok($$ select public.review_late_entry('entry', pg_temp.k('late'), 'exclude', 'already in the day''s paper total') $$,
  'manager excludes it with a reason');
select lives_ok($$ select public.approve_closing(pg_temp.k('r1'), '{}') $$, 'excluded late entry no longer blocks approval');
reset role;
select ok(app.compute_day(tests.outlet('A'), '2026-02-01') ->> 'service_total' = '100000', 'excluded entry stays out of totals');
select tests.login_as('manager');
select throws_ok($$ select public.review_late_entry('entry', pg_temp.k('late'), 'include', null) $$, '22023', null,
  'including into an approved day needs a reopen reason');
select lives_ok($$ select public.review_late_entry('entry', pg_temp.k('late'), 'include', 'it was real', 'late sale must count') $$,
  'exclude → include reopens the day in the same transaction');
reset role;
select is((select state from public.closing_state where closing_id = pg_temp.k('c1')), 'reopened', 'closing is reopened');
select ok(app.needs_review(pg_temp.k('c1')), 'include stays unresolved until a new revision contains it');
select tests.login_as('head');
select lives_ok($$ select public.update_draft(pg_temp.k('c1'), 0, null, null, '{"50000":5}', null, 'Owner') $$, 'recount');
select lives_ok($$ insert into k select 'r2', public.submit_closing(pg_temp.k('c1')) $$, 'revision 2 submitted');
reset role;
select ok((select pg_temp.k('late') = any (included_late_entry_ids) from public.closing_revisions where id = pg_temp.k('r2')),
  'revision 2 lists the included late entry');
select ok(not app.needs_review(pg_temp.k('c1')), 'late entry resolved by the new revision');
select is((select count(*)::int from public.late_entry_reviews where entry_id = pg_temp.k('late')), 2,
  'both decisions are kept');

-- Dependants flagged when an earlier day is re-submitted (§5.5) -----------------------------------------
select tests.entry('service', 1000, '2026-02-02', jsonb_build_object('staff_id', tests.staff('A')));
select tests.login_as('head');
insert into k select 'c2', (public.prepare_closing(tests.outlet('A'), '2026-02-02') ->> 'closing_id')::uuid;
select public.set_closing_employee(pg_temp.k('c2'), tests.staff('A'));
select public.update_draft(pg_temp.k('c2'), 0, null, null, '{"50000":4}', null, 'Owner');
insert into k select 'd2r1', public.submit_closing(pg_temp.k('c2'));
reset role;
insert into snap select 'd2', md5(r::text) from public.closing_revisions r where id = pg_temp.k('d2r1');
select tests.login_as('manager');
select lives_ok($$ select public.reopen_closing(pg_temp.k('c1'), 'check zakat') $$, 'manager reopens D1 (submitted)');
reset role;
select tests.login_as('head');
select lives_ok($$ insert into k select 'r3', public.submit_closing(pg_temp.k('c1')) $$, 'D1 revision 3 submitted unchanged');
reset role;
select ok(app.needs_review(pg_temp.k('c2')), 'D2 flagged: its opening float source was superseded');
select is((select md5(r::text) from public.closing_revisions r where id = pg_temp.k('d2r1')), (select v from snap where name = 'd2'),
  'D2''s revision is byte-identical after the flag');
select tests.login_as('manager');
select lives_ok($$ select public.acknowledge_review(pg_temp.k('c2'), 'opening_float_source_changed', 'same float carried') $$,
  'acknowledged because the new source AF equals the opening float used');
reset role;
select ok(not app.needs_review(pg_temp.k('c2')), 'flag cleared by acknowledgement');

-- Reject → edit → resubmit ----------------------------------------------------------------------------
select tests.login_as('manager');
select throws_ok($$ select public.reject_closing(pg_temp.k('d2r1'), '') $$, '22023', null, 'reject needs a reason');
select lives_ok($$ select public.reject_closing(pg_temp.k('d2r1'), 'count again') $$, 'manager rejects D2');
reset role;
select is((select state || ':' || state_reason from public.closing_state where closing_id = pg_temp.k('c2')),
  'rejected:count again', 'rejected with its reason');
select tests.login_as('head');
select lives_ok($$ select public.update_draft(pg_temp.k('c2'), 0, null, null, '{"50000":4}', null, 'Owner') $$,
  'rejected closing is editable again');
reset role;

-- Food excess (D2) ----------------------------------------------------------------------------------------
select tests.entry('food', 2000, '2026-02-03');
select tests.login_as('head');
insert into k select 'c3', (public.prepare_closing(tests.outlet('A'), '2026-02-03') ->> 'closing_id')::uuid;
select ok((public.update_draft(pg_temp.k('c3'), 0, null, null, '{"50000":2}', null, null) -> 'blockers') ? 'food_excess_unallocated',
  'food cost above the pool blocks submission');
select throws_ok($$ select public.allocate_food_excess(pg_temp.k('c3'), 'x') $$, '42501', null, 'head cannot allocate food excess');
reset role;
select tests.login_as('manager');
select ok(not ((public.allocate_food_excess(pg_temp.k('c3'), 'party food, shop pays') -> 'blockers') ? 'food_excess_unallocated'),
  'manager allocates the excess');
reset role;

-- Commission handover recipients and returns (§5.8) -----------------------------------------------------
select tests.entry('service', 5000, '2026-02-04', jsonb_build_object('staff_id', tests.staff('A')));
select tests.login_as('head');
insert into k select 'c4', (public.prepare_closing(tests.outlet('A'), '2026-02-04') ->> 'closing_id')::uuid;
select throws_ok($$ select public.record_handover(pg_temp.k('c4'), tests.staff('Bstaff'), 10000, 'drawer') $$, '22023', null,
  'commission can only be handed to an employee working at this outlet that day');
select throws_ok($$ select public.record_handover(pg_temp.k('c4'), tests.staff('headstaff'), 60000, 'drawer') $$, '22023', null,
  'handover cannot exceed the payable');
reset role;
select tests.login_as('counter');
select lives_ok($$ select public.record_handover(pg_temp.k('c4'), tests.staff('A'), 20000, 'drawer') $$,
  'any employee working that day may receive the handover (recorded by the Shop/Staff login)');
select throws_ok($$ select public.record_commission_return(pg_temp.k('c4'), 30000, 'drawer', 'too much') $$, '22023', null,
  'return cannot exceed what was handed over');
reset role;

-- Paytm CSV import (§7) --------------------------------------------------------------------------------
select tests.login_as('counter2');
select throws_ok($$ select public.import_paytm_transactions(tests.outlet('A'), '[]', 'x.csv') $$, '42501', null,
  'a retired (legacy counter) login cannot import Paytm transactions');
reset role;
select tests.login_as('head');
select is(public.import_paytm_transactions(tests.outlet('A'), '[
  {"txn_ref":"T1","txn_time":"2026-02-04 11:00+05:30","amount":30000,"status":"success","method":"upi"},
  {"txn_ref":"T2","txn_time":"2026-02-04 12:00+05:30","amount":20000,"status":"failed"}]', 'feb.csv') - 'batch',
  '{"inserted":2,"duplicates":0,"changed":0,"changed_refs":[]}'::jsonb, 'transactions imported');
select is(public.import_paytm_transactions(tests.outlet('A'), '[
  {"txn_ref":"T1","txn_time":"2026-02-04 11:00+05:30","amount":30000,"status":"success","method":"upi"}]', 'feb-again.csv') - 'batch',
  '{"inserted":0,"duplicates":1,"changed":0,"changed_refs":[]}'::jsonb, 're-importing an identical row is a duplicate');
select is(public.import_paytm_transactions(tests.outlet('A'), '[
  {"txn_ref":"T1","txn_time":"2026-02-04 11:00+05:30","amount":99999,"status":"success"},
  {"txn_ref":"T2","txn_time":"2026-02-04 12:00+05:30","amount":20000,"status":"success"}]', 'feb-later.csv') - 'batch',
  '{"inserted":0,"duplicates":0,"changed":2,"changed_refs":["T1","T2"]}'::jsonb,
  'rows whose amount or status changed are reported, not silently skipped');
select is((select array_agg(amount::text || status order by txn_ref) from public.paytm_transactions where outlet_id = tests.outlet('A')),
  array['30000success','20000failed'], 'earlier imported rows are never overwritten');
select ok((public.update_draft(pg_temp.k('c4'), 10000, null, null, '{"50000":1}', null, null) -> 'warnings') ? 'paytm_import_mismatch',
  'manual Paytm total that differs from imported successes is flagged');
reset role;

-- Sync issue resolution ------------------------------------------------------------------------------------
insert into k select 'issue', null;
select tests.login_as('counter');
select public.sync_ops(tests.outlet('A'), gen_random_uuid(), 'Tablet', jsonb_build_array(
  tests.op('create_entry', gen_random_uuid(), 1, '{"kind":"expense","amount":5000}')));
select throws_ok($$ select public.resolve_sync_issue((select id from public.sync_ops where status = 'failed' limit 1), 'x') $$,
  '42501', null, 'counter cannot resolve sync issues');
reset role;
select tests.login_as('manager');
select lives_ok($$ select public.resolve_sync_issue((select id from public.sync_ops where status = 'failed' limit 1),
  're-entered with a description') $$, 'manager resolves with a note');
reset role;

-- Another outlet without an initial float cannot close ------------------------------------------------------
select tests.entry('service', 1000, '2026-02-01', jsonb_build_object('staff_id', tests.staff('Bstaff'), 'outlet_id', tests.outlet('B')));
select ok((app.compute_day(tests.outlet('B'), '2026-02-01') -> 'blockers') ? 'initial_float_missing',
  'first closing needs the initial float');

select * from finish();
rollback;
