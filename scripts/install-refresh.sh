#!/usr/bin/env bash
# Install the Playwright-based bearer refresher and (optionally) a cron job.
#
# Usage:
#   bash scripts/install-refresh.sh                # install deps only
#   bash scripts/install-refresh.sh --cron 15      # also install crontab @ every N minutes
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CRON_MIN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cron)
      CRON_MIN="${2:-15}"
      shift 2
      ;;
    *)
      echo "unknown arg: $1"
      exit 2
      ;;
  esac
done

if ! command -v node >/dev/null 2>&1; then
  echo "node is not installed. install Node 20+ first:"
  echo "  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -"
  echo "  sudo apt-get install -y nodejs"
  exit 1
fi

if ! [ -d node_modules/playwright ]; then
  echo "[install] adding playwright..."
  npm install playwright --no-audit --no-fund --no-save
fi

echo "[install] downloading Chromium for Playwright..."
npx --yes playwright install chromium

# Try to install Chromium runtime libs. Best-effort; non-fatal on missing sudo.
echo "[install] installing system libraries Chromium needs (best-effort)..."
sudo apt-get update -y >/dev/null 2>&1 || true
sudo apt-get install -y \
  libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 \
  libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 \
  libcairo2 libasound2 libatspi2.0-0 fonts-liberation \
  >/dev/null 2>&1 || true

mkdir -p "$ROOT/data" 2>/dev/null || true
chmod 700 "$ROOT/data" 2>/dev/null || true

if [[ -n "$CRON_MIN" ]]; then
  CRON_LINE="*/$CRON_MIN * * * * cd $ROOT && /usr/bin/env node scripts/refresh-bearer.cjs >> $ROOT/data/refresh.log 2>&1"
  echo "[install] adding crontab line:"
  echo "  $CRON_LINE"
  TMP="$(mktemp)"
  crontab -l 2>/dev/null > "$TMP" || true
  # Remove any existing entry for this script
  grep -v 'scripts/refresh-bearer.cjs' "$TMP" > "${TMP}.new" || true
  echo "$CRON_LINE" >> "${TMP}.new"
  crontab "${TMP}.new"
  rm -f "$TMP" "${TMP}.new"
  echo "[install] cron installed. current crontab:"
  crontab -l
fi

cat <<EOF

==== install-refresh done ====

Next steps:

  1. Bootstrap once on a machine with a screen (your laptop's WSL with an X
     server, or this VPS via SSH -X if MobaXterm/X11 forwarding is enabled):

       node scripts/refresh-bearer.cjs --bootstrap

     A Chromium window opens. Log in to Devin (email -> get code from your
     mailbox -> paste code -> land on /sessions). The script saves
     ./data/devin-state.json automatically.

  2. If you ran bootstrap on your laptop, copy the state file to the VPS:

       scp data/devin-state.json user@vps:~/devin-claude-gateway/data/

  3. Trigger a manual refresh on the VPS to confirm it works:

       node scripts/refresh-bearer.cjs

     This should rewrite DEVIN_BEARER in .env and restart the gateway container.

  4. (If you didn't pass --cron) set up cron yourself, eg every 15 minutes:

       (crontab -l 2>/dev/null; echo "*/15 * * * * cd $ROOT && node scripts/refresh-bearer.cjs >> $ROOT/data/refresh.log 2>&1") | crontab -

  5. Watch log:    tail -f $ROOT/data/refresh.log

EOF
