#!/usr/bin/env bash
# Runs the pgTAP suite against a plain local PostgreSQL 17 (no Docker needed).
# Fallback for machines where `supabase start` cannot run; CI uses `supabase test db`.
#   PGHOST/PGPORT/PGUSER select the server (defaults 127.0.0.1:54399, postgres).
# Creates a throwaway database, loads a Supabase auth stub + pgTAP shim, applies every migration,
# runs each supabase/tests/*.sql file, and exits non-zero on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."

export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-54399}" PGUSER="${PGUSER:-postgres}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
PSQL="${PSQL:-$(command -v psql || echo /opt/homebrew/opt/postgresql@17/bin/psql)}"
DB="salonops_test_$$"

"$PSQL" -qX -d postgres -c "create database $DB" >/dev/null
trap '"$PSQL" -qX -d postgres -c "drop database if exists $DB with (force)" >/dev/null' EXIT
run() { PGOPTIONS='-c search_path=public,extensions' "$PSQL" -qX -v ON_ERROR_STOP=1 -d "$DB" "$@"; }

run -f supabase/tests/local/auth_stub.psql >/dev/null
run -f supabase/tests/local/pgtap_shim.psql >/dev/null
for m in supabase/migrations/*.sql; do
  run -f "$m" >/dev/null || { echo "MIGRATION FAILED: $m"; exit 1; }
done
echo "migrations applied: $(ls supabase/migrations/*.sql | wc -l | tr -d ' ')"

if [[ "${WITH_SEED:-0}" == 1 ]]; then run -f supabase/seed.sql >/dev/null && echo "seed applied"; fi

fail=0; total=0
for t in ${TESTS:-supabase/tests/*.sql}; do
  out="$(run -tA -v pgtap_shim=1 -f "$t" 2>&1)" || true
  n_ok=$(grep -c '^ok ' <<<"$out" || true)
  n_bad=$(grep -c '^not ok ' <<<"$out" || true)
  total=$((total + n_ok + n_bad))
  if [[ $n_bad -gt 0 ]] || grep -qE '^# Looks like|ERROR:' <<<"$out"; then
    fail=1; echo "FAIL $t ($n_ok ok, $n_bad not ok)"
    grep -E '^not ok|^#|ERROR:|DETAIL:|CONTEXT:' <<<"$out" | head -40
  else
    echo "ok   $t ($n_ok assertions)"
  fi
done
echo "total assertions: $total"
exit $fail
