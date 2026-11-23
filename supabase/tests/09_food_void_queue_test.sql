begin;
\ir helpers.psql
select tests.ops_fixture();

-- Migration …001300: atomic "remove and cancel payment" for food, blocked_by, withdraw_sync_op.
select plan(31);

create temp table ids (k text primary key, v uuid);
grant select, insert on ids to authenticated;
insert into ids select k, gen_random_uuid() from unnest(array[
  'dev', 'f0', 'f1', 'p1', 'f2', 'p2', 'e1', 'void_plain', 'void_rev', 'void_stale', 's9']) k;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
grant execute on function pg_temp.id(text) to authenticated;
create temp table res (k text primary key, v jsonb);
grant select, insert on res to authenticated;
create function pg_temp.paid(p_food uuid) returns bigint language sql as $$
  select coalesce(sum(case when reverses_payment_id is null then amount else -amount end), 0)
    from public.food_payments where food_id = p_food $$;
create function pg_temp.r(p_k text) returns jsonb language sql as $$ select v -> 'results' -> 0 from res where k = p_k $$;
grant execute on function pg_temp.r(text) to authenticated;

-- Fixture: unpaid food f0, paid food f1 (₹300 from the drawer), paid food f2 (₹200), an expense e1.
select tests.login_as('counter');
select is((select count(*)::int from jsonb_array_elements(public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array(
  tests.op('create_entry', pg_temp.id('f0'), 1, '{"kind":"food","meal":"breakfast","amount":10000}'),
  tests.op('create_entry', pg_temp.id('f1'), 2, jsonb_build_object('kind', 'food', 'meal', 'dinner', 'amount', 30000,
    'pay_now', true, 'payment_id', pg_temp.id('p1'))),
  tests.op('create_entry', pg_temp.id('f2'), 3, jsonb_build_object('kind', 'food', 'meal', 'lunch', 'amount', 20000,
    'pay_now', true, 'payment_id', pg_temp.id('p2'))),
  tests.op('create_entry', pg_temp.id('e1'), 4, '{"kind":"expense","amount":5000,"description":"Tea"}')
)) -> 'results') x where x ->> 'status' = 'applied'), 4, 'fixture entries applied');

-- 1. Food with no payments voids normally --------------------------------------------------------------
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array(
  tests.op('void_entry', pg_temp.id('f0'), 5, '{}', '{"base_version":1,"reason":"wrong meal"}')))
  -> 'results' -> 0 -> 'result' ->> 'status', 'voided', 'unpaid food entry can be voided');

-- 2. Paid food without the flag: actionable error, nothing changes ---------------------------------------
insert into res select 'plain', public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array(
  tests.op('void_entry', pg_temp.id('f1'), 6, '{}', '{"base_version":1,"reason":"testing"}')));
select is(pg_temp.r('plain') ->> 'status', 'failed', 'plain void of paid food fails');
select ok(pg_temp.r('plain') ->> 'error' like '%₹300 already paid%Remove and cancel payment%nothing was changed%',
  'error names the paid amount and the safe action');
reset role;
select is((select status from public.entries where id = pg_temp.id('f1')), 'active'::text, 'food stays active');
select is(pg_temp.paid(pg_temp.id('f1')), 30000::bigint, 'payment untouched after the failed void');
select is((select count(*)::int from public.food_payments where food_id = pg_temp.id('f1') and reverses_payment_id is not null), 0,
  'no reversal written by the failed void');

-- 3. A later op on the same record waits behind the failure and names it ---------------------------------
select tests.login_as('counter');
insert into res select 'blocked', public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array(
  tests.op('void_entry', pg_temp.id('f1'), 7, '{"reverse_payments":true}', '{"base_version":1,"reason":"remove it"}')));
select is(pg_temp.r('blocked') ->> 'status', 'blocked', 'later op on the record is blocked by the unresolved failure');
select is(pg_temp.r('blocked') ->> 'blocked_by', (select op_id::text from public.sync_ops where device_id = pg_temp.id('dev') and device_seq = 6),
  'blocked result names the op it waits for');
reset role;
select is((select count(*)::int from public.sync_ops where device_id = pg_temp.id('dev') and device_seq = 7), 0,
  'blocked op is not stored (the device keeps it)');

-- 4. Withdrawing the failed op: only by the person who sent it, with a reason -----------------------------
select tests.login_as('manager');
select throws_ok(format($$ select public.withdraw_sync_op(%L, 'not mine') $$, pg_temp.r('blocked') ->> 'blocked_by'),
  '42501', null, 'another user cannot withdraw the op');
reset role;
select tests.login_as('manager');
select throws_ok(format($$ select public.withdraw_sync_op(%L, 'manager') $$, pg_temp.r('blocked') ->> 'blocked_by'),
  '42501', null, 'a manager cannot withdraw someone else''s op either (managers use resolve_sync_issue)');
reset role;
select tests.login_as('counter');
select throws_ok(format($$ select public.withdraw_sync_op(%L, '  ') $$, pg_temp.r('blocked') ->> 'blocked_by'),
  null, null, 'withdrawal needs a reason');
select lives_ok(format($$ select public.withdraw_sync_op(%L, 'used the wrong button') $$, pg_temp.r('blocked') ->> 'blocked_by'),
  'the sender withdraws their failed op');
select lives_ok(format($$ select public.withdraw_sync_op(%L, 'again') $$, pg_temp.r('blocked') ->> 'blocked_by'),
  'withdrawing twice is harmless (retry-safe)');
reset role;
select is((select row(status, resolved_by, resolution_note)::text from public.sync_ops where device_id = pg_temp.id('dev') and device_seq = 6),
  row('failed', tests.uid('counter'), 'Withdrawn by the person who sent it: used the wrong button')::text,
  'withdrawn op stays stored as failed, resolved by the sender, with the reason');
select ok(exists (select 1 from public.audit_logs where table_name = 'sync_ops' and reason = 'used the wrong button'),
  'withdrawal is in the audit log');

-- 5. Remove and cancel payment: reversal + void in one op ------------------------------------------------
select tests.login_as('counter');
insert into ids values ('void_rev_op', gen_random_uuid());
insert into res select 'rev_op', tests.op('void_entry', pg_temp.id('f1'), 7, '{"reverse_payments":true}',
  jsonb_build_object('base_version', 1, 'reason', 'remove it', 'op_id', pg_temp.id('void_rev_op')));
insert into res select 'rev', public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array((select v from res where k = 'rev_op')));
select is(pg_temp.r('rev') ->> 'status', 'applied', 'the waiting op replays after the withdrawal and applies');
select is(jsonb_array_length(pg_temp.r('rev') -> 'result' -> 'reversed_payment_ids'), 1, 'one payment reversed');
reset role;
select is((select status from public.entries where id = pg_temp.id('f1')), 'voided'::text, 'food voided');
select is(pg_temp.paid(pg_temp.id('f1')), 0::bigint, 'net paid is zero: no food cost or payment counted twice');
select is((select row(amount, paid_from, reason, recorded_by)::text from public.food_payments
            where reverses_payment_id = pg_temp.id('p1')),
  row(30000::bigint, 'drawer', 'remove it', tests.uid('counter'))::text, 'reversal mirrors the payment, with reason and user');
select ok(exists (select 1 from public.audit_logs where table_name = 'food_payments' and action = 'INSERT' and reason = 'remove it'),
  'reversal is in the audit log with the reason');

-- 6. Retrying the same op is idempotent -----------------------------------------------------------------
select tests.login_as('counter');
insert into res select 'retry', public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array((select v from res where k = 'rev_op')));
select is(pg_temp.r('retry') ->> 'duplicate', 'true', 'retry is recognised as a duplicate');
reset role;
select is((select count(*)::int from public.food_payments where reverses_payment_id = pg_temp.id('p1')), 1, 'retry did not add a second reversal');

-- 7. A failing remove-and-cancel changes nothing ---------------------------------------------------------
select tests.login_as('counter');
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array(
  tests.op('void_entry', pg_temp.id('f2'), 8, '{"reverse_payments":true}', '{"base_version":9,"reason":"stale copy"}')))
  -> 'results' -> 0 ->> 'status', 'conflict', 'stale version is refused');
reset role;
select is(pg_temp.paid(pg_temp.id('f2')), 20000::bigint, 'payment of f2 intact after the refused op');
select is((select status from public.entries where id = pg_temp.id('f2')), 'active'::text, 'f2 still active');
select tests.login_as('counter');
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array(
  tests.op('void_entry', pg_temp.id('e1'), 9, '{"reverse_payments":true}', '{"base_version":1,"reason":"x"}')))
  -> 'results' -> 0 ->> 'error', 'reverse_payments applies only to food entries', 'flag is refused for non-food entries');

-- 8. Conflicts are not withdrawable by the sender (management only) --------------------------------------
select is(public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Tablet', jsonb_build_array(
  tests.op('create_entry', pg_temp.id('s9'), 9, '{"kind":"service","amount":1000}')))
  -> 'results' -> 0 ->> 'status', 'conflict', 'reusing a device sequence with other content is a conflict');
select throws_ok(format($$ select public.withdraw_sync_op(%L, 'mine') $$,
  (select op_id from public.sync_ops where device_id = pg_temp.id('dev') and device_seq = 9 and status = 'conflict')),
  '42501', null, 'conflicts cannot be withdrawn by the sender');
reset role;

select * from finish();
rollback;
