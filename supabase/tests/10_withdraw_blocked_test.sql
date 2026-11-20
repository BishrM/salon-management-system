begin;
\ir helpers.psql
select tests.ops_fixture();

-- Migration …001400 (defect D7): a blocked op is never stored, so it could not be withdrawn or resolved.
-- withdraw_blocked_op stores it as failed + withdrawn; re-sending it later is a duplicate and never runs.
select plan(16);

create temp table ids (k text primary key, v uuid);
grant select on ids to authenticated;
insert into ids select k, gen_random_uuid() from unnest(array['dev', 'gone', 'e1', 'dev2']) k;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
grant execute on function pg_temp.id(text) to authenticated;
create temp table ops (k text primary key, v jsonb);
grant select on ops to authenticated;
-- Two changes to an entry the server does not have (lost, or removed by a staging reset), and one ready op.
insert into ops values
  ('void',    tests.op('void_entry', (select v from ids where k = 'gone'), 7, '{}', '{"base_version":1,"reason":"old void"}')),
  ('correct', tests.op('correct_entry', (select v from ids where k = 'gone'), 8, '{"amount":30000}', '{"base_version":1,"reason":"fix"}')),
  ('create',  tests.op('create_entry', (select v from ids where k = 'e1'), 9, '{"kind":"expense","amount":5000,"description":"Tea"}'));
create function pg_temp.op(p text) returns jsonb language sql as $$ select v from ops where k = p $$;
grant execute on function pg_temp.op(text) to authenticated;
create function pg_temp.send(p text) returns jsonb language sql as $$
  select public.sync_ops(tests.outlet('A'), pg_temp.id('dev'), 'Computer', jsonb_build_array(pg_temp.op(p))) -> 'results' -> 0 $$;
grant execute on function pg_temp.send(text) to authenticated;
create function pg_temp.wd(p text, p_note text default 'entry no longer exists') returns void language sql as $$
  select public.withdraw_blocked_op(tests.outlet('A'), pg_temp.id('dev'), 'Computer', pg_temp.op(p), p_note) $$;
grant execute on function pg_temp.wd(text, text) to authenticated;

select tests.login_as('counter');
select is(pg_temp.send('void') ->> 'status', 'blocked', 'a change to a missing entry is blocked');
select is((select count(*)::int from public.sync_ops where op_id = (pg_temp.op('void') ->> 'op_id')::uuid), 0,
  'blocked ops are not stored (nobody could withdraw or resolve them before this fix)');

-- The server never stored this op, so it cannot know who wrote it (exactly as for sync_ops: whoever sends an
-- op becomes its submitter). The device outbox is user-scoped, so only its owner's session offers it.
select tests.login_as('outsider');
select throws_ok($$ select pg_temp.wd('void') $$, '42501', null, 'a user without access to the outlet cannot withdraw it');

select tests.login_as('counter');
select throws_ok($$ select pg_temp.wd('void', '  ') $$, null, null, 'withdrawal needs a reason');
select throws_ok($$ select pg_temp.wd('create') $$, '22023', null, 'an op that is not blocked cannot be withdrawn');
select lives_ok($$ select pg_temp.wd('void') $$, 'the sender withdraws the blocked op');
select lives_ok($$ select pg_temp.wd('void') $$, 'withdrawing twice is harmless (retry-safe)');
select ok((select status = 'failed' and resolved_by = tests.uid('counter') and submitted_by = tests.uid('counter')
             and resolution_note like 'Withdrawn by the person who sent it: entry no longer exists'
             and payload_hash = md5(pg_temp.op('void')::text)
           from public.sync_ops where op_id = (pg_temp.op('void') ->> 'op_id')::uuid),
  'withdrawn op is stored as failed, resolved by the sender, with the reason and the original payload');
reset role;
select is((select count(*)::int from public.audit_logs where table_name = 'sync_ops' and reason = 'entry no longer exists'), 1,
  'the withdrawal is in the audit log');

select tests.login_as('counter');
select ok((select (r ->> 'duplicate')::boolean and r ->> 'status' = 'failed' from pg_temp.send('void') r),
  're-sending the withdrawn op is a duplicate and never executes');
select is(pg_temp.send('correct') ->> 'status', 'blocked', 'the later change is still blocked (its entry is still missing)');
select lives_ok($$ select pg_temp.wd('correct') $$, 'it can be withdrawn the same way');
select ok((select (r ->> 'duplicate')::boolean from pg_temp.send('correct') r), 'and is then a duplicate too');
select throws_ok($$ select public.withdraw_blocked_op(tests.outlet('A'), pg_temp.id('dev2'), 'Computer',
    pg_temp.op('void') || '{"device_seq": 1}', 'reuse') $$, 'SO409', null,
  'an op id the server already has cannot be withdrawn again under another device or seq');
select is(pg_temp.send('create') ->> 'status', 'applied', 'ordinary ops on the device still apply');
reset role;
select is((select count(*)::int from public.entries where id = pg_temp.id('gone')), 0, 'nothing was applied to the missing entry');

select * from finish();
rollback;
