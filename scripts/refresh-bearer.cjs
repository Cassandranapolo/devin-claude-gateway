#!/usr/bin/env node
/*
 * Devin auth1 bearer refresher.
 *
 *   node scripts/refresh-bearer.cjs --bootstrap    # one-time interactive login
 *   node scripts/refresh-bearer.cjs                # headless cron-friendly refresh
 *
 * Bootstrap opens a real Chromium window so you can log in to Devin once
 * (email + verification code). When you land on /sessions the script saves
 * cookies + localStorage to data/devin-state.json. Refresh re-uses that file
 * headlessly, reads the rotated auth1 token, writes it back to .env, and
 * restarts the gateway container.
 */

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const ENV_PATH = process.env.GATEWAY_ENV_FILE || path.join(ROOT, '.env');
const STATE_PATH = process.env.DEVIN_STATE_FILE || path.join(ROOT, 'data', 'devin-state.json');
const LOGIN_URL = 'https://app.devin.ai/auth/login';
const SESSIONS_URL = 'https://app.devin.ai/sessions';

const args = new Set(process.argv.slice(2));
const isBootstrap = args.has('--bootstrap');
const skipRestart = args.has('--no-restart') || process.env.SKIP_RESTART === '1';

function log(msg) {
  // eslint-disable-next-line no-console
  console.log(`[${new Date().toISOString()}] ${msg}`);
}
function err(msg) {
  // eslint-disable-next-line no-console
  console.error(`[${new Date().toISOString()}] ${msg}`);
}

function updateEnvLine(file, key, value) {
  let lines = [];
  if (fs.existsSync(file)) {
    lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  }
  let replaced = false;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].match(new RegExp(`^${key}\\s*=`))) {
      lines[i] = `${key}=${value}`;
      replaced = true;
      break;
    }
  }
  if (!replaced) lines.push(`${key}=${value}`);
  if (lines.length && lines[lines.length - 1] !== '') lines.push('');
  fs.writeFileSync(file, lines.join('\n'), { mode: 0o600 });
}

async function bootstrap() {
  log('starting bootstrap (headed)...');
  log('a Chromium window will open. log in to Devin: enter email -> get code from email -> enter code -> land on /sessions.');
  log('the script saves state automatically when you reach /sessions.');

  const browser = await chromium.launch({ headless: false });
  const ctx = await browser.newContext({
    viewport: { width: 1280, height: 800 },
  });
  const page = await ctx.newPage();
  await page.goto(LOGIN_URL, { waitUntil: 'domcontentloaded' });

  log('waiting for you to land on /sessions or /orgs (timeout 10 minutes)...');
  await page.waitForURL(
    url => /app\.devin\.ai\/(sessions|orgs)/.test(url.toString()) && !url.toString().includes('/auth/'),
    { timeout: 10 * 60 * 1000 },
  );
  // Give the SPA a moment to fully populate localStorage / cookies.
  await page.waitForTimeout(4000);

  fs.mkdirSync(path.dirname(STATE_PATH), { recursive: true });
  try {
    await ctx.storageState({ path: STATE_PATH });
  } catch (e) {
    if (e && e.code === 'EACCES') {
      err(`EACCES: tidak bisa nulis ke ${STATE_PATH}.`);
      err(`folder data/ kemungkinan owned by root karena Docker mount.`);
      err(`fix: sudo chown -R "$USER:$USER" "${path.dirname(STATE_PATH)}"`);
      err(`lalu jalanin ulang: node scripts/refresh-bearer.cjs --bootstrap`);
      await browser.close();
      process.exit(4);
    }
    throw e;
  }
  fs.chmodSync(STATE_PATH, 0o600);
  log(`saved state to ${STATE_PATH}`);

  // Also do a one-shot bearer refresh so .env is populated immediately.
  const result = await readAuth(page);
  if (result.token) {
    log(`extracted bearer (length=${result.token.length}); writing to .env`);
    updateEnvLine(ENV_PATH, 'DEVIN_BEARER', result.token);
    if (result.orgId) updateEnvLine(ENV_PATH, 'DEVIN_ORG_ID', result.orgId);
  } else {
    err(`could not read auth1_session from localStorage: ${result.error || 'unknown'}`);
  }

  await browser.close();
  log('bootstrap done.');
}

async function readAuth(page) {
  return page.evaluate(() => {
    const raw = localStorage.getItem('auth1_session');
    if (!raw) return { error: 'auth1_session missing from localStorage' };
    try {
      const parsed = JSON.parse(raw);
      const orgId = localStorage.getItem('last-internal-org-for-external-org-v1-null');
      return { token: parsed.token, orgId };
    } catch (e) {
      return { error: 'auth1_session parse error: ' + e.message };
    }
  });
}

async function refresh() {
  if (!fs.existsSync(STATE_PATH)) {
    err(`state file ${STATE_PATH} missing. run \`node scripts/refresh-bearer.cjs --bootstrap\` first.`);
    process.exit(1);
  }

  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ storageState: STATE_PATH });
  const page = await ctx.newPage();

  log(`navigating to ${SESSIONS_URL} ...`);
  await page.goto(SESSIONS_URL, { waitUntil: 'networkidle', timeout: 60000 });
  await page.waitForTimeout(2000);

  if (/\/auth\//.test(page.url())) {
    err(`state file STALE (browser dipantulkan ke ${page.url()}).`);
    err(`fix: ulangi bootstrap di mesin ber-GUI:`);
    err(`     node scripts/refresh-bearer.cjs --bootstrap`);
    err(`     (lalu scp data/devin-state.json ke VPS kalau bootstrap di laptop)`);
    await browser.close();
    process.exit(2);
  }

  const result = await readAuth(page);
  if (!result.token) {
    err(`tidak bisa baca bearer dari localStorage: ${result.error || 'unknown'}`);
    err(`fix: ulangi bootstrap (auth1_session sudah expired atau hilang):`);
    err(`     node scripts/refresh-bearer.cjs --bootstrap`);
    await browser.close();
    process.exit(3);
  }

  log(`extracted bearer (length=${result.token.length}); updating ${ENV_PATH}`);
  updateEnvLine(ENV_PATH, 'DEVIN_BEARER', result.token);
  if (result.orgId) {
    updateEnvLine(ENV_PATH, 'DEVIN_ORG_ID', result.orgId);
  } else {
    log('warning: DEVIN_ORG_ID tidak terbaca dari localStorage, nilai lama dipertahankan.');
  }

  // Persist refreshed cookies for next run.
  await ctx.storageState({ path: STATE_PATH });
  fs.chmodSync(STATE_PATH, 0o600);
  await browser.close();

  if (skipRestart) {
    log('skipping container restart (SKIP_RESTART set).');
    return;
  }

  log('restarting gateway container...');
  const r = spawnSync('docker', ['compose', 'up', '-d', '--force-recreate', 'gateway'], {
    cwd: ROOT,
    stdio: 'inherit',
  });
  if (r.status !== 0) {
    err(`docker compose up -d --force-recreate returned ${r.status}; you may need to restart manually.`);
  } else {
    log('gateway restarted.');
  }
}

(async () => {
  try {
    if (isBootstrap) await bootstrap();
    else await refresh();
  } catch (e) {
    err(`fatal: ${e && e.stack ? e.stack : e}`);
    process.exit(99);
  }
})();
