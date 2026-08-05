#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
PORT="${KCP_PORT:-8090}"
find . -name '._*' -delete 2>/dev/null || true
docker compose up --build -d
printf '\nKCP server started. Waiting for health check on port %s...\n' "$PORT"
for _ in {1..30}; do
  if curl --fail --silent "http://localhost:${PORT}/health" >/dev/null; then
    curl --fail --silent "http://localhost:${PORT}/health" && printf '\n'
    break
  fi
  sleep 1
done
printf '\nMac Wi-Fi address: '
ipconfig getifaddr en0 || true
printf '\nEnter http://<address>:%s in Kidscarpool → Settings → Central family database.\n' "$PORT"
