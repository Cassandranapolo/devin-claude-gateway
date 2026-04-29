#!/usr/bin/env bash
# scripts/switch-account.sh — JALANKAN DI PC (yang punya Chromium GUI).
#
# Apa yang dilakukan:
#   1. Backup state file lama (data/backups/devin-state-<ts>.json)
#   2. Hapus data/devin-state.json supaya Chromium bootstrap fresh
#   3. Buka Chromium → kamu login akun Devin BARU lewat email + kode OTP
#   4. Upload state.json hasil bootstrap via scp ke VPS
#   5. SSH ke VPS, jalanin scripts/accept-new-account.sh (refresh bearer +
#      restart container + smoke test)
#
# Konfigurasi (boleh lewat .env.switch atau env var):
#   VPS_HOST=ubuntu@1.2.3.4
#   VPS_PATH=~/devin-claude-gateway
#
# Contoh:
#   bash scripts/switch-account.sh
#   VPS_HOST=ubuntu@1.2.3.4 bash scripts/switch-account.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/_lib.sh
source "$SCRIPT_DIR/_lib.sh"
cd "$REPO_DIR"

if [[ -f .env.switch ]]; then
  set -a; source .env.switch; set +a
fi

: "${VPS_HOST:=}"
: "${VPS_PATH:=~/devin-claude-gateway}"

require_cmd node "install Node 20+ dulu"
require_cmd ssh  "install openssh-client dulu"
require_cmd scp  "install openssh-client dulu"

if [[ -z "$VPS_HOST" ]]; then
  read -rp "VPS host (contoh: ubuntu@1.2.3.4): " VPS_HOST
fi
if [[ -z "$VPS_HOST" ]]; then
  err "VPS_HOST wajib diisi."
  exit 2
fi

cat <<EOF
============================================
 Devin Claude Gateway: switch ke akun BARU
============================================
 Local repo : $REPO_DIR
 VPS host   : $VPS_HOST
 VPS path   : $VPS_PATH
============================================

EOF

TOTAL=5

if [[ -s data/devin-state.json ]]; then
  mkdir -p data/backups
  BACKUP="data/backups/devin-state-$(date +%Y%m%d-%H%M%S).json"
  cp data/devin-state.json "$BACKUP"
  step 1 $TOTAL "backup state lama → $BACKUP"
else
  step 1 $TOTAL "no previous state.json (fresh setup)"
fi

step 2 $TOTAL "hapus data/devin-state.json biar Chromium fresh ..."
rm -f data/devin-state.json

step 3 $TOTAL "bootstrap akun BARU (Chromium akan terbuka) ..."
warn "PENTING: login pakai email + kode OTP, JANGAN klik 'Continue with Google/GitHub'."
warn "         (Google/GitHub OAuth bakal kena bot detection di Chromium otomatis.)"
node scripts/refresh-bearer.cjs --bootstrap

if [[ ! -s data/devin-state.json ]]; then
  err "data/devin-state.json kosong setelah bootstrap."
  hint "kemungkinan window Chromium ditutup sebelum landing di /sessions. Ulangi."
  exit 1
fi

step 4 $TOTAL "upload state.json ke VPS ($VPS_HOST:$VPS_PATH/data/) ..."
if ! ssh -o BatchMode=no "$VPS_HOST" "mkdir -p $VPS_PATH/data"; then
  err "ssh ke $VPS_HOST gagal."
  hint "cek SSH keys, atau coba: ssh $VPS_HOST 'pwd' manual dulu."
  exit 1
fi
scp data/devin-state.json "$VPS_HOST:$VPS_PATH/data/"

step 5 $TOTAL "refresh bearer + test gateway di VPS ..."
if ssh "$VPS_HOST" "cd $VPS_PATH && bash scripts/accept-new-account.sh"; then
  ok "gateway di VPS sekarang pakai akun baru."
  cat <<EOF

============================================
 DONE. Cek manual kapan saja:
   ssh $VPS_HOST
   cd $VPS_PATH
   tail -n 50 data/refresh.log
============================================
EOF
  exit 0
else
  err "accept-new-account.sh gagal di VPS."
  hint "ssh ke VPS dan cek logs: docker compose logs --tail=80 gateway"
  hint "kalau perlu rollback, di VPS: ls -t .env.bak.* | head -1 lalu cp ke .env"
  exit 1
fi
