#!/usr/bin/env bash
# scripts/switch-account.sh — run on PC (the machine with Chromium)
# Bootstrap a NEW Devin account, upload state to VPS, and reload gateway.
#
# Config: copy .env.switch.example to .env.switch and fill in VPS_HOST + VPS_PATH.
# Or pass them as env vars: VPS_HOST=ubuntu@1.2.3.4 VPS_PATH=~/gw bash scripts/switch-account.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR"

if [[ -f .env.switch ]]; then
  set -a; source .env.switch; set +a
fi

: "${VPS_HOST:=}"
: "${VPS_PATH:=~/devin-claude-gateway}"

if [[ -z "$VPS_HOST" ]]; then
  read -rp "VPS host (e.g. ubuntu@1.2.3.4): " VPS_HOST
fi

echo "============================================"
echo " Devin Claude Gateway: switch to NEW account"
echo "============================================"
echo " Local repo : $REPO_DIR"
echo " VPS host   : $VPS_HOST"
echo " VPS path   : $VPS_PATH"
echo "============================================"
echo

if [[ -s data/devin-state.json ]]; then
  mkdir -p data/backups
  BACKUP="data/backups/devin-state-$(date +%Y%m%d-%H%M%S).json"
  cp data/devin-state.json "$BACKUP"
  echo "[1/5] Backup state lama -> $BACKUP"
else
  echo "[1/5] No previous state.json (fresh setup)"
fi

echo "[2/5] Clear state.json lama biar Chromium fresh..."
rm -f data/devin-state.json

echo "[3/5] Bootstrap akun BARU. Window Chromium akan muncul."
echo "      Login pakai akun Devin baru, tunggu sampai landing /sessions, lalu tutup Chromium."
node scripts/refresh-bearer.cjs --bootstrap

if [[ ! -s data/devin-state.json ]]; then
  echo "ERROR: data/devin-state.json kosong setelah bootstrap." >&2
  echo "Kemungkinan window Chromium ditutup sebelum login selesai. Ulangi." >&2
  exit 1
fi

echo "[4/5] Upload state.json ke VPS ($VPS_HOST:$VPS_PATH/data/)..."
ssh "$VPS_HOST" "mkdir -p $VPS_PATH/data"
scp data/devin-state.json "$VPS_HOST:$VPS_PATH/data/"

echo "[5/5] Refresh bearer + test gateway di VPS..."
ssh "$VPS_HOST" "cd $VPS_PATH && bash scripts/accept-new-account.sh"

echo
echo "============================================"
echo " DONE. Gateway sekarang pakai akun baru."
echo "============================================"
