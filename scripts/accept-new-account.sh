#!/usr/bin/env bash
# scripts/accept-new-account.sh — dipanggil otomatis oleh switch-account.sh
# setelah state file baru diupload ke VPS. Manual call juga boleh.
#
# Apa yang dia lakukan:
#   1. Backup .env lama
#   2. Run refresh-bearer.cjs sekali (headless) supaya bearer + org_id baru
#      di-extract dari devin-state.json dan ditulis ke .env
#   3. Recreate gateway container dengan .env baru
#   4. Smoke test /v1/chat/completions
#
# Tidak menghapus DEVIN_ORG_ID secara paksa: refresh-bearer.cjs sudah menulis
# ulang DEVIN_ORG_ID kalau berhasil meng-extract dari localStorage akun baru;
# kalau ekstraksi gagal, org_id lama tetap dipertahankan supaya tidak terjadi
# 401 "No organizations found for auth1 user".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/_lib.sh
source "$SCRIPT_DIR/_lib.sh"
cd "$REPO_DIR"

require_cmd docker "install Docker dulu"
require_cmd node   "install Node 20+ dulu"
require_file "data/devin-state.json" \
  "upload state.json hasil bootstrap dulu: scp data/devin-state.json user@vps:$REPO_DIR/data/"
require_file ".env" "jalanin install.sh dulu"

TOTAL=4
BACKUP=".env.bak.$(date +%Y%m%d-%H%M%S)"
step 1 $TOTAL "backup .env -> $BACKUP"
cp .env "$BACKUP"

step 2 $TOTAL "refresh bearer dari state.json akun baru ..."
if ! node scripts/refresh-bearer.cjs; then
  err "refresh-bearer.cjs gagal."
  hint "kemungkinan state file expired. ulangi bootstrap di laptop dengan Chromium:"
  hint "  node scripts/refresh-bearer.cjs --bootstrap"
  hint "lalu scp ulang data/devin-state.json ke VPS."
  hint ".env asli ada di $BACKUP — restore dengan: cp $BACKUP .env"
  exit 1
fi

sleep 3

step 3 $TOTAL "test gateway ..."
KEY="$(env_get .env GATEWAY_API_KEY || true)"
PORT="$(env_get .env PORT || echo 3000)"
PORT="${PORT:-3000}"

if [[ -z "$KEY" ]]; then
  err "GATEWAY_API_KEY kosong di .env."
  hint "cek: docker compose logs --tail=80 gateway"
  exit 1
fi

TMP_RESP="$(mktemp)"
trap 'rm -f "$TMP_RESP"' EXIT
HTTP_CODE="$(curl -s -o "$TMP_RESP" -w '%{http_code}' \
  -X POST "http://localhost:$PORT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model":"claude-opus-4-7","messages":[{"role":"user","content":"halo akun baru"}]}' \
  || echo '000')"

if [[ "$HTTP_CODE" == "200" ]]; then
  step 4 $TOTAL "smoke test passed (HTTP 200):"
  head -c 400 "$TMP_RESP"; echo
  ok "gateway sekarang pakai akun baru. .env lama disimpan di $BACKUP"
  exit 0
fi

err "gateway respond HTTP $HTTP_CODE."
echo "---- response body ----"; cat "$TMP_RESP"; echo
echo "---- container logs ----"; docker compose logs --tail=30 gateway || true
echo "------------------------"
warn "kemungkinan + cara fix:"
case "$HTTP_CODE" in
  401) hint "auth1 ditolak. ambil bearer + org_id dari console akun baru, lalu:"
       hint "  bash scripts/manual-set-bearer.sh '<auth1_xxx>' '<cookie>' '<org_id>'"
       ;;
  000) hint "container belum siap. coba ulang setelah 10 detik:"
       hint "  curl http://localhost:$PORT/health"
       ;;
  *)   hint "lihat container logs di atas untuk detail."
       ;;
esac
hint "restore .env lama: cp $BACKUP .env && docker compose up -d --force-recreate gateway"
exit 1
