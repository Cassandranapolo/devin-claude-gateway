#!/usr/bin/env bash
# scripts/manual-set-bearer.sh — set DEVIN_BEARER (and optionally DEVIN_COOKIE
# / DEVIN_ORG_ID) di .env tanpa butuh Chromium. Cocok kalau kamu cuma punya
# akses SSH ke VPS dari HP / komputer tanpa GUI.
#
# Cara ambil bearer (dari browser yang udah login akun Devin baru):
#   buka https://app.devin.ai, klik 1 sesi di sidebar (biar org ke-load), lalu
#   tekan F12 -> Console -> paste:
#
#     (() => {
#       const a = JSON.parse(localStorage.getItem('auth1_session') || '{}');
#       const orgId = localStorage.getItem('last-internal-org-for-external-org-v1-null');
#       const out = `DEVIN_BEARER=${a.token||''}\nDEVIN_ORG_ID=${orgId||''}\nDEVIN_COOKIE=${document.cookie}`;
#       copy(out);
#       return 'copied ' + out.length + ' chars';
#     })()
#
# Usage:
#   bash scripts/manual-set-bearer.sh <auth1_bearer>
#   bash scripts/manual-set-bearer.sh <auth1_bearer> <cookie_string>
#   bash scripts/manual-set-bearer.sh <auth1_bearer> <cookie_string> <org_id>
#
# Flags (boleh dipasang sebelum positional args):
#   --clear-org   Hapus DEVIN_ORG_ID lama biar gateway auto-resolve dari bearer
#                 baru. Default: PRESERVE org_id lama supaya akun yang baru
#                 di-pin tidak kena 401 "No organizations found for auth1 user".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/_lib.sh
source "$SCRIPT_DIR/_lib.sh"
cd "$REPO_DIR"

CLEAR_ORG=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clear-org) CLEAR_ORG=1; shift ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --) shift; while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done ;;
    -*)
      err "flag tidak dikenal: $1"
      hint "lihat 'bash $0 --help'"
      exit 2
      ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

BEARER="${POSITIONAL[0]:-}"
COOKIE="${POSITIONAL[1]:-}"
ORG_ID="${POSITIONAL[2]:-}"

if [[ -z "$BEARER" ]]; then
  err "argumen <auth1_bearer> wajib."
  hint "Usage: bash $0 <auth1_bearer> [cookie_string] [org_id]"
  exit 2
fi

if [[ "$BEARER" != auth1_* ]]; then
  err "bearer harus diawali 'auth1_'. Yang dikasih: '${BEARER:0:20}...'"
  hint "ambil dari localStorage.getItem('auth1_session').token di DevTools"
  exit 2
fi

require_cmd docker "install Docker dulu: https://docs.docker.com/engine/install/"
require_file ".env" "jalanin install.sh dulu, atau cd ke folder repo gateway"

TOTAL=5
step 1 $TOTAL "backup .env -> .env.bak.$(date +%Y%m%d-%H%M%S)"
BACKUP=".env.bak.$(date +%Y%m%d-%H%M%S)"
cp .env "$BACKUP"

step 2 $TOTAL "update DEVIN_BEARER ..."
env_set .env DEVIN_BEARER "$BEARER"

if [[ -n "$COOKIE" ]]; then
  step 2 $TOTAL "update DEVIN_COOKIE (escape \$ -> \$\$) ..."
  ESCAPED_COOKIE="$(escape_dollar "$COOKIE")"
  env_set .env DEVIN_COOKIE "$ESCAPED_COOKIE"
fi

if [[ -n "$ORG_ID" ]]; then
  step 3 $TOTAL "update DEVIN_ORG_ID ke '$ORG_ID' ..."
  env_set .env DEVIN_ORG_ID "$ORG_ID"
elif [[ "$CLEAR_ORG" == "1" ]]; then
  step 3 $TOTAL "clear DEVIN_ORG_ID (akan auto-resolve dari bearer baru) ..."
  env_unset .env DEVIN_ORG_ID
else
  EXISTING_ORG="$(env_get .env DEVIN_ORG_ID || true)"
  if [[ -z "$EXISTING_ORG" ]]; then
    warn "DEVIN_ORG_ID kosong di .env. Gateway akan coba auto-resolve dari bearer."
    hint "kalau gagal dengan 'No organizations found', isi DEVIN_ORG_ID manual"
    hint "  → re-run: bash $0 '$BEARER' '' '<org_id>'"
  else
    step 3 $TOTAL "preserve DEVIN_ORG_ID lama ('${EXISTING_ORG:0:14}...') -- pakai --clear-org kalau mau dihapus"
  fi
fi

step 4 $TOTAL "force-recreate container biar baca .env baru ..."
docker compose up -d --force-recreate gateway
sleep 5

step 5 $TOTAL "test gateway /v1/chat/completions ..."
KEY="$(env_get .env GATEWAY_API_KEY || true)"
if [[ -z "$KEY" ]]; then
  err "GATEWAY_API_KEY kosong di .env. Container belum jalan dengan benar."
  hint "cek: docker compose logs --tail=80 gateway"
  exit 1
fi

PORT="$(env_get .env PORT || true)"
PORT="${PORT:-3000}"

TMP_RESP="$(mktemp)"
trap 'rm -f "$TMP_RESP"' EXIT
HTTP_CODE="$(curl -s -o "$TMP_RESP" -w '%{http_code}' \
  -X POST "http://localhost:$PORT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model":"claude-opus-4-7","messages":[{"role":"user","content":"reply with exactly: OK"}]}' \
  || echo '000')"

if [[ "$HTTP_CODE" == "200" ]]; then
  ok "gateway respond HTTP 200. response:"
  head -c 400 "$TMP_RESP"; echo
  ok "selesai. .env lama disimpan di $BACKUP"
  exit 0
fi

err "gateway respond HTTP $HTTP_CODE."
echo "---- response body ----"
cat "$TMP_RESP"; echo
echo "---- container logs (tail 30) ----"
docker compose logs --tail=30 gateway || true
echo "-----------------------"
warn "kemungkinan penyebab + cara fix:"
case "$HTTP_CODE" in
  000) hint "container belum siap. tunggu 5-10 detik, lalu ulang test:"
       hint "  KEY=\$(grep ^GATEWAY_API_KEY .env | cut -d= -f2)"
       hint "  curl http://localhost:$PORT/health"
       ;;
  401) hint "bearer invalid / expired, atau auth1 ga punya org."
       hint "  - bearer baru dari console di tab yang udah login + klik 1 sesi"
       hint "  - kalau pakai --clear-org, kasih ulang org_id manual:"
       hint "      bash $0 '$BEARER' '$COOKIE' '<org_id>'"
       ;;
  404|502|503) hint "container ga listen port $PORT. cek:"
       hint "  docker compose ps"
       hint "  docker compose logs --tail=50 gateway"
       ;;
esac
hint ".env lama bisa di-restore: cp $BACKUP .env && docker compose up -d --force-recreate gateway"
exit 1
