#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p backups
stamp="$(date +%Y%m%d_%H%M%S)"
out="backups/kcp_${stamp}.dump"

docker compose exec -T db pg_dump -U kcp -d kcp -Fc > "$out"

echo "KCP database backup written to: $out"
