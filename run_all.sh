#!/usr/bin/env bash
# Run the KCP database test suite.
#
# Local (plain PostgreSQL) -- rebuilds a throwaway database and installs a
# minimal stand-in for Supabase's auth schema:
#
#   ./supabase/tests/run_all.sh
#   PGDATABASE=kcp_verify ./supabase/tests/run_all.sh
#
# Supabase CI -- the database exists and `supabase db start` has already
# applied supabase/migrations/, so skip both the rebuild and the shim:
#
#   KCP_MODE=supabase ./supabase/tests/run_all.sh
#
# The auth shim is NEVER applied to Supabase, which provides the real one.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${KCP_MODE:-local}"
DB="${PGDATABASE:-kcp}"
PSQL=(psql -v ON_ERROR_STOP=1 -q --no-psqlrc)

if [[ "$MODE" == "local" ]]; then
  echo "==> rebuilding database '$DB'"
  psql -q -d postgres -c "drop database if exists \"$DB\";" \
                      -c "create database \"$DB\";"
fi

run() {
  local label="$1" file="$2"
  printf '%-46s' "$label"
  if out=$("${PSQL[@]}" -d "$DB" -f "$file" 2>&1); then
    echo "PASS"
    echo "$out" | grep -E 'NOTICE:.*(PASS|legs)' | sed 's/^.*NOTICE:  /    /' || true
  else
    echo "FAIL"
    echo "$out" | grep -E 'ERROR|CONTEXT' | head -5 | sed 's/^/    /'
    exit 1
  fi
}

if [[ "$MODE" == "local" ]]; then
  # Supabase supplies auth.users and auth.uid(); plain PostgreSQL does not.
  run "auth shim (local only)"   "$ROOT/supabase/tests/harness/00_local_auth_shim.sql"
  run "baseline schema"          "$ROOT/supabase/migrations/00000000000001_kcp_baseline.sql"
else
  run "auth helper (supabase)"   "$ROOT/supabase/tests/harness/00_supabase_become.sql"
fi

run "BASIS pilot seed"         "$ROOT/supabase/seeds/basis_pilot.sql"
run "BASIS equivalence"        "$ROOT/supabase/tests/equivalence_basis_generic.sql"
run "owner invariant"          "$ROOT/supabase/tests/regression_owner_invariant.sql"
run "group lifecycle e2e"      "$ROOT/supabase/tests/integration_group_lifecycle.sql"

echo
echo "All tests passed."
