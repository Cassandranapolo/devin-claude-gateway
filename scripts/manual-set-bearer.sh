#!/usr/bin/env bash
# scripts/manual-set-bearer.sh — set DEVIN_BEARER manually (no Chromium needed).
#
# Use this when you cannot run scripts/switch-account.sh because you don't have
# a desktop / Chromium (e.g. you're working from a phone via SSH).
#
# How to get the bearer token:
#   1. Log in to https://app.devin.ai in any browser (mobile is fine).
#   2. Open browser DevTools (Kiwi Browser on Android, Eruda bookmarklet, or
#      desktop DevTools).
#   3. Application -> Storage / Cookies -> find `storage_auth1_session`.
#   4. Copy the `token` field (looks like `auth1_xxxxxxxxxxxxxxxxxxxxx`).
#
# Usage:
#   bash scripts/manual-set-bearer.sh auth1_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#
# Optionally pass a fresh cookie string if your account needs it:
#   bash scripts/manual-set-bearer.sh auth1_xxx 'cookie1=val1; cookie2=val2'

set -euo pipefail

BEARER="${1:-}"
COOKIE="${2:-}"

if [[ -z "$BEARER" ]]; then
  echo "Usage: $0 <auth1_bearer> [cookie_string]" >&2
  echo "  auth1_bearer must start with 'auth1_' (extracted from storage_auth1_session)" >&2
  exit 2
fi

if [[ "$BEARER" != auth1_* ]]; then
  echo "ERROR: bearer harus diawali 'auth1_'. Yang dikasih: '${BEARER:0:20}...'" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR"

if [[ ! -f .env ]]; then
  echo "ERROR: .env tidak ditemukan di $REPO_DIR" >&2
  exit 1
fi

BACKUP=".env.bak.$(date +%Y%m%d-%H%M%S)"
cp .env "$BACKUP"
echo "[1/5] Backup .env -> $BACKUP"

echo "[2/5] Update DEVIN_BEARER..."
if grep -q '^DEVIN_BEARER=' .env; then
  sed -i "s|^DEVIN_BEARER=.*|DEVIN_BEARER=$BEARER|" .env
else
  echo "DEVIN_BEARER=$BEARER" >> .env
fi

if [[ -n "$COOKIE" ]]; then
  echo "       Update DEVIN_COOKIE..."
  if grep -q '^DEVIN_COOKIE=' .env; then
    # Use a different delimiter because cookie may contain '/' or '|'.
    awk -v c="$COOKIE" 'BEGIN{done=0} /^DEVIN_COOKIE=/{print "DEVIN_COOKIE=" c; done=1; next} {print} END{if(!done) print "DEVIN_COOKIE=" c}' .env > .env.tmp
    mv .env.tmp .env
  else
    echo "DEVIN_COOKIE=$COOKIE" >> .env
  fi
fi

echo "[3/5] Clear DEVIN_ORG_ID lama (auto-detect dari bearer baru)..."
sed -i '/^DEVIN_ORG_ID=/d' .env

echo "[4/5] Force-recreate container biar baca .env baru..."
docker compose up -d --force-recreate gateway
sleep 3

echo "[5/5] Test gateway..."
KEY=$(grep ^GATEWAY_API_KEY .env | cut -d= -f2)
HTTP_CODE=$(curl -s -o /tmp/gw-resp -w "%{http_code}" -X POST http://localhost:3000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model":"claude-opus-4-7","messages":[{"role":"user","content":"halo bearer baru"}]}')

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "Gateway OK (HTTP $HTTP_CODE)"
  echo "Response:"
  cat /tmp/gw-resp
  echo
else
  echo "ERROR: Gateway returned HTTP $HTTP_CODE" >&2
  cat /tmp/gw-resp >&2
  echo >&2
  echo "Coba update DEVIN_COOKIE juga (pass sebagai arg ke-2):" >&2
  echo "  bash scripts/manual-set-bearer.sh '$BEARER' 'cookie_string_here'" >&2
  exit 1
fi
