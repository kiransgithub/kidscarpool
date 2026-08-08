#!/usr/bin/env bash
# Rebuild a throwaway database from the baseline and run every test.
#
#   ./supabase/tests/run_all.sh                  # uses local socket, db "kcp"
#   PGDATABASE=kcp_ci ./supabase/tests/run_all.sh
#
# The harness file supplies a minimal stand-in for Supabase's auth schema so
# the same SQL runs on plain PostgreSQL in CI. It is never applied to Supabase.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DB="${PGDATABASE:-kcp}"
PSQL=(psql -v ON_ERROR_STOP=1 -q --no-psqlrc)

echo "==> rebuilding database '$DB'"
psql -q -d postgres -c "drop database if exists \"$DB\";" \
                    -c "create database \"$DB\";"

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

run "auth shim (local only)"   "$ROOT/supabase/tests/harness/00_local_auth_shim.sql"
run "baseline schema"          "$ROOT/supabase/migrations/00000000000001_kcp_baseline.sql"
run "BASIS pilot seed"         "$ROOT/supabase/seeds/basis_pilot.sql"
run "BASIS equivalence"        "$ROOT/supabase/tests/equivalence_basis_generic.sql"
run "owner invariant"          "$ROOT/supabase/tests/regression_owner_invariant.sql"
run "group lifecycle e2e"      "$ROOT/supabase/tests/integration_group_lifecycle.sql"

echo
echo "All tests passed."
