#!/usr/bin/env bash
set -Eeuo pipefail

group_code="${1:-KCP-PHOENIX-2026}"
mkdir -p audit-exports
stamp="$(date +%Y%m%d_%H%M%S)"
out="audit-exports/${group_code}_${stamp}.csv"

docker compose exec -T db psql -U kcp -d kcp -v ON_ERROR_STOP=1 \
  -c "\\copy (select id,group_code,actor_name,actor_phone,action,entity_type,entity_id,details,occurred_at from audit_events where group_code='${group_code//\'/\'\'}' order by id) to stdout with csv header" \
  > "$out"

echo "KCP audit export written to: $out"
