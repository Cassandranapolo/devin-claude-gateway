#!/usr/bin/env bash
# scripts/install-refresh.sh — install Playwright + Chromium + libs +
# (optional) crontab supaya DEVIN_BEARER bisa di-refresh otomatis tiap N menit.
#
# Usage:
#   bash scripts/install-refresh.sh                # install deps only
#   bash scripts/install-refresh.sh --cron 15      # juga pasang crontab tiap 15 menit
#
# Yang di-install:
#   - npm package "playwright" (di node_modules/)
#   - Chromium binary buat Playwright (~170 MB)
#   - System libs Chromium (libnss3, libxkbcommon0, dst -- best-effort)
#   - Crontab entry (kalau --cron diberi)
#
# Yang di-fix vs versi lama:
#   - chown data/ ke user yang lagi jalanin script, supaya bootstrap nanti
#     ga kena EACCES (folder data/ jadi root-owned setelah Docker mount).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/_lib.sh
source "$SCRIPT_DIR/_lib.sh"
cd "$ROOT"

CRON_MIN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cron)
      CRON_MIN="${2:-15}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      err "argumen tidak dikenal: $1"
      exit 2
      ;;
  esac
done

require_cmd node "install Node 20+ dulu:
       curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
       sudo apt-get install -y nodejs"
require_cmd npm "install npm dulu (bareng Node)"

if ! [ -d node_modules/playwright ]; then
  info "install paket playwright (npm) ..."
  npm install playwright --no-audit --no-fund --no-save
else
  info "playwright sudah terpasang, skip npm install"
fi

info "download Chromium binary buat Playwright ..."
npx --yes playwright install chromium

info "install system libs Chromium (best-effort, butuh sudo) ..."
sudo apt-get update -y >/dev/null 2>&1 || true
sudo apt-get install -y \
  libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 \
  libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 \
  libcairo2 libasound2 libatspi2.0-0 fonts-liberation \
  >/dev/null 2>&1 || warn "apt-get install gagal/sudo tidak tersedia (skip, mungkin udah lengkap)"

info "siapkan folder data/ + ambil ownership ke $USER ..."
mkdir -p "$ROOT/data" 2>/dev/null || true
# Folder data/ sering dimount ke container Docker yang jalan sebagai root,
# sehingga file di dalamnya jadi root-owned. Bootstrap (yang jalan sebagai
# user biasa) akan kena EACCES kalau ga di-chown duluan.
if ! [ -w "$ROOT/data" ] || [ "$(stat -c '%U' "$ROOT/data" 2>/dev/null || echo "")" != "$USER" ]; then
  if sudo -n true 2>/dev/null || [ "$(id -u)" = "0" ]; then
    sudo chown -R "$USER:$USER" "$ROOT/data" 2>/dev/null || true
    ok "data/ sekarang owned by $USER"
  else
    warn "data/ ga writable oleh $USER dan sudo tidak passwordless."
    hint "jalanin manual: sudo chown -R \$USER:\$USER $ROOT/data"
  fi
fi
chmod 700 "$ROOT/data" 2>/dev/null || true

if [[ -n "$CRON_MIN" ]]; then
  CRON_LINE="*/$CRON_MIN * * * * cd $ROOT && /usr/bin/env node scripts/refresh-bearer.cjs >> $ROOT/data/refresh.log 2>&1"
  info "pasang crontab line:"
  echo "  $CRON_LINE"
  TMP="$(mktemp)"
  TMP_NEW="$(mktemp)"
  crontab -l 2>/dev/null > "$TMP" || true
  # Hapus entry lama untuk script ini supaya ga dobel
  grep -v 'scripts/refresh-bearer.cjs' "$TMP" > "$TMP_NEW" || true
  echo "$CRON_LINE" >> "$TMP_NEW"
  crontab "$TMP_NEW"
  rm -f "$TMP" "$TMP_NEW"
  ok "cron terpasang. crontab sekarang:"
  crontab -l
else
  warn "crontab tidak dipasang. Tanpa cron, bearer auth1 expired tiap 15-30 menit."
  hint "pasang nanti dengan: bash $0 --cron 15"
fi

cat <<EOF

==== install-refresh selesai ====

LANGKAH BERIKUTNYA (urut, per mesin):

  [LAPTOP/PC dengan layar]  bootstrap state file (one-time):

      git clone https://github.com/Cassandranapolo/devin-claude-gateway.git
      cd devin-claude-gateway
      bash scripts/install-refresh.sh           # tanpa --cron, deps doang
      node scripts/refresh-bearer.cjs --bootstrap

      (Atau di VPS ini lewat MobaXterm/SSH -X kalau X11 forwarding aktif.)

      Chromium kebuka -> login Devin lewat email + kode 6 digit ->
      tunggu sampai URL berakhiran /sessions -> script auto-save state.

  [LAPTOP/PC -> VPS]  upload state file:

      scp data/devin-state.json $USER@<vps-ip>:$ROOT/data/

  [VPS]  test refresh manual sekali:

      cd $ROOT
      node scripts/refresh-bearer.cjs

      Output yang diharapkan:
        [ts] navigating to https://app.devin.ai/sessions ...
        [ts] extracted bearer (length=58); updating $ROOT/.env
        [ts] gateway restarted.

  [VPS]  pantau cron jalan tiap $([ -n "$CRON_MIN" ] && echo "$CRON_MIN" || echo "N") menit:

      tail -f $ROOT/data/refresh.log

EOF
