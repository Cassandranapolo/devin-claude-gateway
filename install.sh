#!/usr/bin/env bash
# devin-claude-gateway installer
#
# One-shot installer that:
#   1. Verifies docker is available (or installs it)
#   2. Builds the gateway image
#   3. Asks you for DEVIN_BEARER, DEVIN_ORG_ID, DEVIN_COOKIE (interactively)
#   4. Generates a random GATEWAY_API_KEY
#   5. Writes .env with mode 600
#   6. Starts the container
#   7. Smoke-tests /health and /v1/chat/completions
#
# Usage (from inside a fresh clone):
#   bash install.sh
#
# Or, one-liner from anywhere:
#   curl -fsSL https://raw.githubusercontent.com/Cassandranapolo/devin-claude-gateway/main/install.sh | bash -s -- --clone

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Cassandranapolo/devin-claude-gateway.git}"
PORT="${PORT:-3000}"
DO_CLONE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clone) DO_CLONE=1; shift ;;
    --port)  PORT="$2"; shift 2 ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_lib.sh
source "$SCRIPT_DIR/scripts/_lib.sh"

# --- 1. Optionally clone ----------------------------------------------------
if [[ "$DO_CLONE" == "1" ]]; then
  if [[ ! -d devin-claude-gateway ]]; then
    info "cloning $REPO_URL ..."
    git clone "$REPO_URL"
  else
    info "devin-claude-gateway/ already exists, skipping clone"
  fi
  cd devin-claude-gateway
fi

if [[ ! -f docker-compose.yml ]]; then
  err "docker-compose.yml not found. cd into the cloned repo first, or run with --clone."
  exit 1
fi

ROOT="$(pwd)"

# --- 2. Make sure docker is installed ---------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  warn "docker tidak terpasang. mau aku install otomatis? (Y/n)"
  read -r yn
  if [[ "${yn:-Y}" =~ ^[Yy]$|^$ ]]; then
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER" || true
    warn "kamu mungkin harus logout/login ulang biar 'docker' bisa dijalanin tanpa sudo."
  else
    err "skip install docker. install dulu, lalu jalanin install.sh lagi."
    exit 1
  fi
fi

if ! docker compose version >/dev/null 2>&1; then
  err "docker compose plugin tidak ada. install docker-ce dari https://docs.docker.com/engine/install/ ya."
  exit 1
fi

# --- 3. Adjust port in docker-compose.yml if needed -------------------------
if [[ "$PORT" != "3000" ]]; then
  info "menyetel port host ke $PORT (di docker-compose.yml)"
  sed -i.bak "s/\"3000:3000\"/\"$PORT:3000\"/" docker-compose.yml
fi

# --- 4. Get DEVIN_* values ---------------------------------------------------
ENV_FILE="$ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
  warn ".env sudah ada. skip pertanyaan kredensial Devin (kalau mau ganti, hapus .env dulu)."
else
  cat <<'BANNER'

Gateway perlu 3 nilai dari browser Devin-mu:
  - DEVIN_BEARER         (token "auth1_..." dari localStorage)
  - DEVIN_ORG_ID         ("org-..." 32 hex)
  - DEVIN_COOKIE         (document.cookie isi tab Devin)

Cara ambil cepat: buka https://app.devin.ai (sudah login), F12 -> Console, paste:

  (() => {
    const a = JSON.parse(localStorage.getItem('auth1_session') || '{}');
    const orgId = localStorage.getItem('last-internal-org-for-external-org-v1-null');
    const out = `DEVIN_BEARER=${a.token||''}\nDEVIN_ORG_ID=${orgId||''}\nDEVIN_COOKIE=${document.cookie}`;
    copy(out);
    return 'Copied: ' + out.length + ' chars';
  })()

Lalu paste hasilnya di sini ketika diminta.

BANNER

  read -rp "DEVIN_BEARER: " DEVIN_BEARER
  read -rp "DEVIN_ORG_ID: " DEVIN_ORG_ID
  read -rp "DEVIN_COOKIE (boleh kosong, optional): " DEVIN_COOKIE

  if [[ -z "$DEVIN_BEARER" ]]; then
    err "DEVIN_BEARER wajib diisi."
    exit 1
  fi

  GATEWAY_API_KEY="$(openssl rand -hex 32)"

  cp .env.example "$ENV_FILE"
  env_set "$ENV_FILE" DEVIN_BEARER     "$DEVIN_BEARER"
  env_set "$ENV_FILE" DEVIN_ORG_ID     "$DEVIN_ORG_ID"
  # Cookie value sering punya literal '$' (mis. _ga_...$o2$g1$t...) yang bisa
  # di-interpretasi docker-compose sebagai variable substitution. Escape '$'
  # ke '$$' biar nilainya dipassthrough verbatim ke container.
  env_set "$ENV_FILE" DEVIN_COOKIE     "$(escape_dollar "$DEVIN_COOKIE")"
  env_set "$ENV_FILE" GATEWAY_API_KEY  "$GATEWAY_API_KEY"
  chmod 600 "$ENV_FILE"
  ok ".env tertulis dengan GATEWAY_API_KEY baru."
fi

# --- 5. Build & start --------------------------------------------------------
info "building & starting container ..."
docker compose down >/dev/null 2>&1 || true
docker compose up -d --build

info "menunggu container ready ..."
for i in {1..15}; do
  if curl -fsS "http://localhost:$PORT/health" >/dev/null 2>&1; then
    ok "gateway listening on :$PORT"
    break
  fi
  sleep 1
done

# --- 6. Smoke test -----------------------------------------------------------
KEY="$(grep ^GATEWAY_API_KEY "$ENV_FILE" | cut -d= -f2)"
info "smoke test ..."
RESP="$(curl -s -X POST "http://localhost:$PORT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model":"claude-opus-4-7","messages":[{"role":"user","content":"reply with exactly: OK"}]}' || true)"

if echo "$RESP" | grep -q '"content"'; then
  ok "smoke test passed. response:"
  echo "$RESP" | head -c 400
  echo
else
  warn "smoke test failed. response:"
  echo "$RESP"
  echo
  warn "cek logs: docker compose logs --tail=50"
fi

cat <<EOF

==== install.sh selesai ====

Endpoint kamu:
  OpenAI-compatible:    http://<ip-vps>:$PORT/v1
  Anthropic-compatible: http://<ip-vps>:$PORT/anthropic
  Model:                claude-opus-4-7
  API Key:              (lihat 'grep GATEWAY_API_KEY $ENV_FILE')

Auto-refresh DEVIN_BEARER (recommended):
  bash scripts/install-refresh.sh --cron 15
  node scripts/refresh-bearer.cjs --bootstrap   (di laptop yang punya layar)
  scp data/devin-state.json user@vps:$ROOT/data/

Detail lengkap di README.md.

EOF
