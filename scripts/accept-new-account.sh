#!/usr/bin/env bash
# scripts/accept-new-account.sh — run on VPS, called by switch-account.sh
# Clears stale DEVIN_ORG_ID, refreshes bearer, recreates container, tests gateway.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR"

if [[ ! -s data/devin-state.json ]]; then
  echo "ERROR: data/devin-state.json hilang. Upload state.json dulu." >&2
  exit 1
fi

BACKUP=".env.bak.$(date +%Y%m%d-%H%M%S)"
cp .env "$BACKUP"
echo "[1/4] Backup .env -> $BACKUP"

echo "[2/4] Clear DEVIN_ORG_ID lama..."
sed -i '/^DEVIN_ORG_ID=/d' .env

echo "[3/4] Refresh bearer + recreate container..."
node scripts/refresh-bearer.cjs

sleep 3

echo "[4/4] Test gateway..."
KEY=$(grep ^GATEWAY_API_KEY .env | cut -d= -f2)
HTTP_CODE=$(curl -s -o /tmp/gw-resp -w "%{http_code}" -X POST http://localhost:3000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model":"claude-opus-4-7","messages":[{"role":"user","content":"halo akun baru"}]}')

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "Gateway OK (HTTP $HTTP_CODE)"
  echo "Response:"
  cat /tmp/gw-resp
  echo
else
  echo "ERROR: Gateway returned HTTP $HTTP_CODE" >&2
  cat /tmp/gw-resp >&2
  echo >&2
  exit 1
fi
