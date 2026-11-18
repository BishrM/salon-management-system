begin;
\ir helpers.psql
select tests.ops_fixture();

select plan(22);

-- Receipt at 12:00 IST on 2026-11-10 (business date 2026-11-10 with cutoff 04:00).
create function pg_temp.c(p_delta_s numeric, p_offset_ms bigint default 0, p_lower timestamptz default null,
                          p_last_sync timestamptz default null)
returns record language sql as $$
  select business_date, basis, flags from app.classify_time(
    tests.outlet('A'), null, 1,
    timestamptz '2026-11-10 12:00+05:30' - make_interval(secs => p_delta_s) - make_interval(secs => p_offset_ms / 1000.0),
    p_offset_ms, p_last_sync, p_lower, timestamptz '2026-11-10 12:00+05:30')
$$;
create function pg_temp.basis(p_delta_s numeric, p_lower timestamptz default null) returns text language sql as $$
  select basis::text from app.classify_time(tests.outlet('A'), null, 1,
    timestamptz '2026-11-10 12:00+05:30' - make_interval(secs => p_delta_s), 0, null, p_lower,
    timestamptz '2026-11-10 12:00+05:30')
$$;
create function pg_temp.flags(p_delta_s numeric, p_offset_ms bigint default 0, p_lower timestamptz default null)
returns text[] language sql as $$
  select flags from app.classify_time(tests.outlet('A'), null, 1,
    timestamptz '2026-11-10 12:00+05:30' - make_interval(secs => p_delta_s) - make_interval(secs => p_offset_ms / 1000.0),
    p_offset_ms, null, p_lower, timestamptz '2026-11-10 12:00+05:30')
$$;
create function pg_temp.bdate(p_delta_s numeric, p_lower timestamptz) returns date language sql as $$
  select business_date from app.classify_time(tests.outlet('A'), null, 1,
    timestamptz '2026-11-10 12:00+05:30' - make_interval(secs => p_delta_s), 0, null, p_lower,
    timestamptz '2026-11-10 12:00+05:30')
$$;

-- Online window boundaries (default 120 s, H2: absolute Δ) --------------------------------------------------
select is(pg_temp.basis(120), 'online', 'Δ = +window → online');
select is(pg_temp.basis(-120), 'online', 'Δ = −window → online');
select isnt(pg_temp.basis(121, '2026-11-10 09:00+05:30'), 'online', 'Δ = window + 1 s → offline path');
select ok(not ('future_time' = any (pg_temp.flags(-120))), 'Δ = −window → no future_time flag');
select ok(pg_temp.flags(-121) @> array['future_time', 'timestamp_suspect'], 'Δ = −(window + 1 s) → future_time + timestamp_suspect');
select is(pg_temp.bdate(-6 * 3600, '2026-11-10 09:00+05:30'), null::date,
  'device 6 h ahead is never online and lands in Unassigned even with same-day bounds');

-- Offline bounds ------------------------------------------------------------------------------------------
select is(pg_temp.basis(3 * 3600, '2026-11-10 08:00+05:30'), 'offline_bounded', 'bounds inside one business day → offline_bounded');
select is(pg_temp.bdate(3 * 3600, '2026-11-10 08:00+05:30'), date '2026-11-10', '… dated that day');
-- Bounds span 2026-11-09 → 2026-11-10; estimate 2026-11-10 02:00 IST is before the 04:00 cutoff → 2026-11-09.
select is(pg_temp.bdate(10 * 3600, '2026-11-09 20:00+05:30'), date '2026-11-09',
  'bounds span days, estimate inside → the estimate''s business day (cutoff applied)');
select ok('estimated_date' = any (pg_temp.flags(10 * 3600, 0, '2026-11-09 20:00+05:30')), '… flagged estimated_date');
select ok('timestamp_suspect' = any (pg_temp.flags(30 * 3600, 0, '2026-11-09 20:00+05:30')),
  'estimate before the lower bound → timestamp_suspect');
select is(pg_temp.bdate(30 * 3600, '2026-11-09 20:00+05:30'), null::date, '… and Unassigned');
select ok('timestamp_suspect' = any (pg_temp.flags(10 * 3600, 0, null)), 'no lower bound and not online → suspect');
-- lower = least(server last contact, device last sync): a stale device claim widens the bounds.
select is((select bound_lower from app.classify_time(tests.outlet('A'), null, 1, timestamptz '2026-11-10 09:00+05:30', 0,
            timestamptz '2026-11-09 18:00+05:30', timestamptz '2026-11-10 08:00+05:30', timestamptz '2026-11-10 12:00+05:30')),
  timestamptz '2026-11-09 18:00+05:30', 'lower bound is the earlier of last contact and device last sync');

-- Clock offset and gap thresholds ---------------------------------------------------------------------------
select ok(not ('clock_offset' = any (pg_temp.flags(0, 300000))), 'offset = clock_warn_s → no flag');
select ok('clock_offset' = any (pg_temp.flags(0, 301000)), 'offset = clock_warn_s + 1 s → clock_offset');
select ok(not ('long_gap' = any (pg_temp.flags(48 * 3600, 0, '2026-11-07 12:00+05:30'))), 'gap = gap_flag_h → no flag');
select ok('long_gap' = any (pg_temp.flags(48 * 3600 + 1, 0, '2026-11-07 12:00+05:30')), 'gap = gap_flag_h + 1 s → long_gap');

-- Custom thresholds (G4) ------------------------------------------------------------------------------------
select tests.login_as('manager');
select throws_ok($$ select public.set_offline_thresholds(tests.outlet('A'), 60, 60, 24, 'x') $$, '42501', null,
  'only the owner changes offline thresholds');
reset role;
select tests.login_as('owner');
select throws_ok($$ select public.set_offline_thresholds(tests.outlet('A'), 0, 60, 24, 'x') $$, '22023', null,
  'non-positive thresholds rejected');
select lives_ok($$ select public.set_offline_thresholds(tests.outlet('A'), 30, 60, 24, 'tablet clock is reliable') $$,
  'owner sets custom thresholds');
reset role;
select isnt(pg_temp.basis(31, '2026-11-10 09:00+05:30'), 'online', 'custom window: Δ = 31 s is no longer online');

select * from finish();
rollback;
