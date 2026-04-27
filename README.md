# devin-claude-gateway

Gateway self-hosted yang ngebungkus Claude Opus 4.7 dari Devin web app
sebagai endpoint **OpenAI-compatible** dan **Anthropic-compatible**. Cocok
buat coding-assistant client (OpenClaw, Hermes, Cline, Continue, dsb.)
yang udah biasa ngomong pakai protokol OpenAI atau Anthropic.

## Disclaimer

> **Baca dulu sebelum pakai:**
>
> Gateway ini bekerja dengan menyamar sebagai sesi browser kamu yang sudah
> login di `app.devin.ai`, lalu memanggil endpoint internal `app.devin.ai/api/*`.
> Itu **bukan** API resmi Devin (V1/V2/V3). Cara kerja ini hampir pasti
> melanggar Terms of Service Devin/Cognition. Token autentikasi-nya juga
> dirotasi setiap 15-30 menit dan struktur API internal bisa berubah
> sewaktu-waktu tanpa pemberitahuan.
>
> Repo ini dibagi sebagai **proof-of-concept untuk pembelajaran pribadi**.
> Risiko pemakaian sepenuhnya ditanggung user. Kalau kamu mau jalur stabil
> yang didukung resmi, pakai API Anthropic asli (`api.anthropic.com`).

> **Penting: 1 akun Devin = 1 instance gateway.**
> Pakai **akun Devin kamu sendiri**. Jangan share kredensial Devin (state
> file, bearer token, cookie) ke orang lain dan jangan minjem akun Devin
> teman. Kenapa:
>
> 1. **Cognition fingerprint sesi.** Banyak gateway memakai 1 akun Devin
>    yang sama dari banyak IP = pola yang gampang ke-detect → suspend akun.
> 2. **Token rotasi tabrakan.** Kalau 2 instance refresh token bareng,
>    bisa saling override → semua kena 401.
> 3. **Etika & TOS.** Akun Devin terikat email & 1 user; sharing kredensial
>    melanggar TOS.
>
> Kalau temen mau pakai gateway ini juga, mereka tinggal **install di
> mesin mereka sendiri pakai akun Devin mereka sendiri**. Tutorial-nya
> sama persis kayak yang ada di README ini.

## Yang akan kamu dapat

| Klien minta | Pukul ke gateway |
|---|---|
| `https://api.openai.com/v1/chat/completions` | `http://<vps>:3000/v1/chat/completions` |
| `https://api.openai.com/v1/models` | `http://<vps>:3000/v1/models` |
| `https://api.anthropic.com/v1/messages` | `http://<vps>:3000/anthropic/v1/messages` |

Request streaming (`stream: true`) didukung. Tiap request bikin **1 sesi
Devin baru**, gateway nungguin balasan pertama Devin lalu di-relay ke klien
sebagai response OpenAI/Anthropic-style.

## Prereq

- **Mesin yang bisa jalanin Docker** — VPS, PC desktop, laptop, Raspberry
  Pi, NAS. Apa aja, asal punya Docker. Detail per-platform di section
  [Multi-platform install](#multi-platform-install).
- Akun Devin yang udah login (email login, Google OAuth, atau GitHub OAuth — apa aja yang penting bisa login di browser).
- Klien yang dukung OpenAI/Anthropic API (OpenClaw, Hermes, Cline, dll.).

Yang akan di-install otomatis sama installer:
- Docker + Docker Compose
- Image `node:20-alpine`
- (opsional, buat auto-refresh) Playwright + Chromium

## Bisa di-install di mana?

| Tempat | Cocok kalau | Catatan |
|---|---|---|
| **VPS Linux** (DigitalOcean, Tencent, Hetzner, dll.) | Mau gateway 24/7 stabil | Wajib kalau klien-mu (Telegram bot, dll.) butuh akses dari mana aja |
| **PC desktop / laptop** Linux/macOS/Windows-WSL2 | Klien jalan di PC yang sama | Cuma aktif pas PC nyala. Pakai `localhost:3000` |
| **Raspberry Pi / mini-PC / NAS di rumah** | Mau 24/7 hemat duit | Bergantung internet rumah. Pakai DDNS atau lokal aja |
| **Mobile (Android/iOS)** | tidak didukung | Docker nggak ada native di mobile |

Kalau klien-mu (OpenClaw, Hermes) jalan di mesin yang **berbeda** dengan
gateway, klien tinggal pakai `http://<ip-mesin-gateway>:3000/v1` sebagai
base URL.

## Quick install (1 baris)

Di VPS, jalanin:

```bash
curl -fsSL https://raw.githubusercontent.com/Cassandranapolo/devin-claude-gateway/main/install.sh | bash -s -- --clone
```

Installer akan:
1. Clone repo ke folder `devin-claude-gateway`
2. Cek/install Docker
3. Tanyain `DEVIN_BEARER`, `DEVIN_ORG_ID`, `DEVIN_COOKIE` (cara ambil di
   bawah)
4. Generate `GATEWAY_API_KEY` random
5. Tulis `.env` dengan permission 600
6. Build & start container
7. Smoke test ke `/v1/chat/completions`

Total ~3 menit (kecuali kalau Docker belum ke-install, plus 2-3 menit
buat install Docker).

## Multi-platform install

Step-by-step per platform. Setelah Docker ready, langkah selanjutnya
(jalanin `install.sh`) sama persis di semua platform.

### Linux (VPS / desktop / Raspberry Pi)

Ubuntu / Debian / CentOS / Fedora — apa aja yang punya systemd:

```bash
# 1. install Docker (kalau belum)
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
newgrp docker

# 2. jalanin installer (1 baris)
curl -fsSL https://raw.githubusercontent.com/Cassandranapolo/devin-claude-gateway/main/install.sh | bash -s -- --clone
```

Setelah selesai, gateway listen di `http://localhost:3000` di mesin itu.
Dari mesin lain di network yang sama, pakai `http://<ip-lan>:3000`.
Dari internet, pakai IP publik VPS (kalau di VPS).

### macOS

```bash
# 1. install Docker Desktop dari https://www.docker.com/products/docker-desktop
# (download .dmg, install, buka Docker Desktop, tunggu icon Docker di menu bar)

# 2. install git (kalau belum) — paling gampang lewat Homebrew:
brew install git

# 3. jalanin installer
curl -fsSL https://raw.githubusercontent.com/Cassandranapolo/devin-claude-gateway/main/install.sh | bash -s -- --clone
```

Catatan macOS: Docker Desktop pakai resource agak boros (~2 GB RAM idle).
Pastikan Mac kamu nggak sleep, atau set "prevent sleep when on power" di
**System Settings → Battery → Options**.

### Windows (lewat WSL2)

```powershell
# 1. install WSL2 + Ubuntu (sekali doang, di PowerShell sebagai admin)
wsl --install -d Ubuntu

# Setelah PC restart, buka Ubuntu dari Start Menu, set username & password
```

Lalu di terminal Ubuntu (WSL):

```bash
# 2. install Docker di WSL
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
# logout-login WSL atau jalankan: newgrp docker

# 3. jalanin installer
curl -fsSL https://raw.githubusercontent.com/Cassandranapolo/devin-claude-gateway/main/install.sh | bash -s -- --clone
```

Catatan Windows:
- **Klien Windows native (BUKAN WSL)** akses gateway via `http://localhost:3000` — WSL2 sudah auto-forward port ke host Windows.
- Kalau pakai Docker Desktop for Windows, buka **Docker Desktop → Settings → Resources → WSL Integration**, enable "Ubuntu". Dengan ini `docker` command di WSL pakai engine dari Docker Desktop.
- Bisa juga install Docker Engine murni di WSL (cara di atas), tanpa Docker Desktop. Pilihan kamu.

### Raspberry Pi / mini-PC ARM

Sama persis kayak Linux. Image `node:20-alpine` sudah punya build untuk
`linux/arm64` dan `linux/arm/v7`, jadi ngedrop di Pi 4 / Pi 5 langsung
jalan tanpa perubahan.

```bash
# di Raspberry Pi OS (Debian-based)
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker pi   # atau username Pi-mu
newgrp docker

curl -fsSL https://raw.githubusercontent.com/Cassandranapolo/devin-claude-gateway/main/install.sh | bash -s -- --clone
```

Untuk akses dari luar rumah (kalau Pi-nya ngehadep internet via DDNS),
jangan lupa port forward 3000/tcp di router-mu.

## Cara ambil DEVIN_BEARER, DEVIN_ORG_ID, DEVIN_COOKIE

1. Buka https://app.devin.ai di Chrome, **login**.
2. **Klik salah satu sesi** di sidebar dulu (biar konteks org-nya ke-load).
3. Buka DevTools (F12) → tab **Console** → paste:

   ```js
   (() => {
     const a = JSON.parse(localStorage.getItem('auth1_session') || '{}');
     const orgId = localStorage.getItem('last-internal-org-for-external-org-v1-null');
     const out = `DEVIN_BEARER=${a.token || ''}\nDEVIN_ORG_ID=${orgId || ''}\nDEVIN_COOKIE=${document.cookie}`;
     copy(out);
     console.log(out.replace(/(token|auth1)_[A-Za-z0-9]+/g, '$1_***'));
     return out.length;
   })()
   ```

4. Console akan print preview (token tersamar). Sekaligus, isi lengkapnya
   sudah ke-copy ke clipboard kamu — siap di-paste ketika installer
   nanyain.

> Token `auth1_*` rotasi tiap 15-30 menit. Setelah install pertama,
> set up auto-refresh (bagian berikutnya) biar nggak harus ngulang manual.

## Pakai dari klien (OpenClaw / Hermes / generic)

### OpenAI-compatible

```
Base URL:    http://<vps-ip>:3000/v1
API Key:     <GATEWAY_API_KEY dari .env>
Model:       claude-opus-4-7   (atau devin-opus-4-7)
```

### Anthropic-compatible

```
Base URL:    http://<vps-ip>:3000/anthropic
API Key:     <GATEWAY_API_KEY dari .env>
Model:       claude-opus-4-7
```

Ambil API key:
```bash
grep ^GATEWAY_API_KEY .env | cut -d= -f2
```

Aliasing model:

| Yang kamu minta | Yang dikirim ke Devin (`devin_version_override`) |
|---|---|
| `claude-opus-*`, `devin-opus-4-7` (default) | `devin-opus-4-7` |
| `claude-sonnet-*`, `claude-3-5-sonnet*`, `devin-2-5` | `devin-2-5` |
| `devin-0929-brocade` | `devin-0929-brocade` |
| lainnya | nilai `DEVIN_MODEL_DEFAULT` di `.env` |

## Auto-refresh DEVIN_BEARER (rekomendasi)

Token `auth1_*` rotasi tiap 15-30 menit. Tanpa auto-refresh, gateway bakal
balikin error `devin_unauthorized` setelah ~30 menit. Auto-refresh kerjanya:

1. Sekali doang, kamu **bootstrap** di laptop yang ada layarnya (Linux
   desktop, macOS, atau **Windows + WSL2**) — Chromium kebuka, kamu login
   Devin, script otomatis save session state ke `data/devin-state.json`.
2. State file di-upload ke VPS via `scp`.
3. **Cron di VPS** jalan tiap 15 menit: pakai state file untuk buka
   Devin headless, ambil token baru, tulis ke `.env`, restart container.
4. Pas state file expired (biasanya tiap beberapa minggu), kamu cuma perlu
   ulang langkah 1 + 2.

### Setup di VPS

```bash
cd ~/devin-claude-gateway
bash scripts/install-refresh.sh --cron 15
```

Yang di-install:
- Playwright (npm package)
- Chromium binary (~170 MB)
- System libs (libnss3, libxkbcommon0, dll.)
- Crontab entry: `*/15 * * * * cd <root> && node scripts/refresh-bearer.cjs >> data/refresh.log 2>&1`

### Bootstrap di laptop (WSL Ubuntu / Linux desktop / macOS)

> Kalau kamu pakai Windows, install **WSL2 + Ubuntu** dulu (`wsl --install`),
> lalu lakukan langkah ini di terminal WSL Ubuntu. WSL2 di Windows 11
> sudah otomatis support GUI lewat WSLg.

```bash
# clone repo di laptop juga
git clone https://github.com/Cassandranapolo/devin-claude-gateway.git
cd devin-claude-gateway

# install playwright + chromium di laptop
npm install playwright --no-audit --no-fund --no-save
npx playwright install chromium
npx playwright install-deps chromium  # butuh sudo

# RUN BOOTSTRAP — chromium window kebuka di Windows desktop
node scripts/refresh-bearer.cjs --bootstrap
```

Di window Chromium yang kebuka:
1. **Pakai email login flow Devin**, jangan klik "Continue with Google"
   atau "Continue with GitHub" (Google block browser otomasi).
2. Ketik email kamu di kotak "Email"
3. Klik **Log in**
4. Devin kirim kode 6 digit ke email — buka Gmail, copy kode
5. Paste kode di Chromium, klik **Continue**
6. Kalau Devin redirect ke `/org/<slug>/...`, klik **Sessions** di sidebar
   biar URL ganti ke `/sessions`
7. Tunggu ~3 detik, script auto-save state file & close window

Setelah selesai:

```bash
ls -la data/devin-state.json
# harus ada file ~17KB

# upload ke VPS
scp data/devin-state.json ubuntu@<vps-ip>:~/devin-claude-gateway/data/
```

### Verify auto-refresh

Di VPS:

```bash
cd ~/devin-claude-gateway
node scripts/refresh-bearer.cjs   # manual run
```

Output yang diharapkan:
```
[ts] navigating to https://app.devin.ai/sessions ...
[ts] extracted bearer (length=58); updating /home/ubuntu/devin-claude-gateway/.env
[ts] restarting gateway container...
[ts] gateway restarted.
```

Lalu:
```bash
KEY=$(grep ^GATEWAY_API_KEY .env | cut -d= -f2)
curl -s http://localhost:3000/health
curl -s -X POST http://localhost:3000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model":"claude-opus-4-7","messages":[{"role":"user","content":"ok?"}]}'
```

Monitor log refresh:
```bash
tail -f data/refresh.log
```

## Konfigurasi (.env)

Daftar key yang umum diubah:

| Key | Default | Catatan |
|---|---|---|
| `PORT` | `3000` | Port HTTP gateway |
| `GATEWAY_API_KEY` | (random) | API key untuk klien-mu (di-generate auto) |
| `DEVIN_BEARER` | (wajib) | Token `auth1_*` |
| `DEVIN_ORG_ID` | (wajib) | `org-<32 hex>` |
| `DEVIN_COOKIE` | (opsional) | Cookie tab Devin (kadang dibutuhin pas org belum di-cache) |
| `DEVIN_MODEL_DEFAULT` | `devin-opus-4-7` | Fallback model |
| `DEVIN_REPLY_TIMEOUT_S` | `120` | Berapa lama nunggu Devin balas |
| `DEVIN_PLANNER_TYPE` | `fast` | `fast` atau `default` |
| `DEVIN_PLANNING_MODE` | `automatic` | `automatic` atau `manual` |

## Troubleshooting

| Error | Artinya | Fix |
|---|---|---|
| `devin_token_expired` | Bearer expired | Refresh manual: paste bearer baru ke `.env`, `docker compose restart`. Atau set up auto-refresh. |
| `devin_unauthorized` | Devin balikin 401 | Re-extract `DEVIN_BEARER` + `DEVIN_ORG_ID`. Pastikan login dulu, klik 1 sesi, baru extract. |
| `devin_no_org` | Post-auth nggak return org id | Set `DEVIN_ORG_ID` manual di `.env` (ambil dari URL: `app.devin.ai/orgs/<id>/...` atau `last-internal-org-for-external-org-v1-null` di localStorage). |
| `devin_session_failed` | Devin error sebelum balas | Retry biasa — kadang server-side hiccup. |
| `devin_timeout` | Reply > `DEVIN_REPLY_TIMEOUT_S` | Naikin timeout di `.env`. |
| `missing_bearer` | Nggak ada `DEVIN_BEARER` di `.env` | Cek `.env`, pastikan key namanya pas. |
| Container restart loop | Build error / .env salah | `docker compose logs --tail=50` |
| Port 3000 dipake | Aplikasi lain pakai 3000 | Ganti `PORT=3300` di `.env` + edit `docker-compose.yml` jadi `"3300:3000"`. |
| Auto-refresh `state file is stale` | State file expired | Bootstrap ulang di laptop, scp lagi state file-nya. |

## Cara update ke versi terbaru

```bash
cd ~/devin-claude-gateway
git pull
docker compose down
docker compose up -d --build
```

Atau wipe-clean reinstall:

```bash
cd ~ && rm -rf devin-claude-gateway
curl -fsSL https://raw.githubusercontent.com/Cassandranapolo/devin-claude-gateway/main/install.sh | bash -s -- --clone
```

## Limitations

- **Tiap chat request bikin sesi Devin baru.** History multi-turn di-rebuild
  dari array `messages` yang dikirim klien.
- **Streaming token bukan token-by-token asli.** Gateway buffer balasan
  full, lalu re-chunks ke SSE buat klien yang butuh `stream: true`.
- **Tool use & vision belum didukung.** Cuma teks in/out.
- **Cuma first reply Devin.** Gateway baca first `devin_message`-nya Devin
  lalu return. Gateway nggak ngikutin Devin's task lebih lanjut.
- **Cognition bisa fingerprint & block kapan aja.** Akun atau IP-mu bisa
  ke-suspend.

## Cara kerja (untuk yang penasaran)

1. Klien kirim `POST /v1/chat/completions` ke gateway.
2. Gateway merge semua `messages` jadi 1 prompt teks.
3. Gateway `POST /api/sessions` ke `app.devin.ai` dengan
   `Authorization: Bearer <DEVIN_BEARER>` dan `Cookie: <DEVIN_COOKIE>`.
4. Devin balikin `session_id`. Gateway poll `GET /api/sessions/<id>` tiap
   500 ms sampai `latest_message_contents.type === "devin_message"`.
5. Gateway bungkus reply jadi format response OpenAI/Anthropic, return ke
   klien.

Detail di `src/devin.ts` (~150 baris).

## Project layout

```
src/
  index.ts             # Hono app, route registration
  config.ts            # .env parsing, defaults
  state.ts             # disk cache (org_id)
  cookies.ts           # cookie parsing helpers
  jwt.ts               # JWT decode (legacy bearer support)
  devin.ts             # actual Devin API client (create + poll session)
  routes/
    openai.ts          # /v1/chat/completions, /v1/models
    anthropic.ts       # /anthropic/v1/messages
scripts/
  install-refresh.sh   # install Playwright + cron
  refresh-bearer.cjs   # bootstrap & headless refresh
  extract-cookie.js    # one-shot cookie helper (alternative)
install.sh             # one-line installer (clone + setup + start)
docker-compose.yml
Dockerfile
.env.example
```

## License

MIT — see `LICENSE`. **Tapi:** repo ini berisi reverse-engineered glue
code ke API non-publik milik Cognition Labs. License MIT cuma berlaku
buat **kode** di repo ini, bukan buat akses ke API Devin atau hak guna
service Cognition. Pastikan kamu pakai sesuai TOS Devin.

## Credits

- Original problem framing & v0.1 prototype: percakapan privat
- Reverse engineering of `app.devin.ai` internal API: ngintip request
  network di DevTools tab kamu sendiri
- Inspirasi: `Galkurta/AI-Gateway`'s `devin-web` adapter (yang sering 401
  karena nggak handle org_id resolution / auth1 tokens)
