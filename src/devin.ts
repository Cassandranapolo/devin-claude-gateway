import { randomUUID } from 'node:crypto';
import { config, DEVIN_BASE_URL } from './config.js';
import { parseCookieString, serializeCookies, decodeJsonCookie, cookieFingerprint } from './cookies.js';
import { decodeJwt, isFresh, jwtExpiryMs } from './jwt.js';
import { getState, persist, clearBearer } from './state.js';

interface AuthSnapshot {
  cookies: Record<string, string>;
  bearer: string;
  fingerprint: string;
}

interface PostAuthResponse {
  org_id?: string;
  org_name?: string;
  user_id?: string;
  result?: { org_id?: string; org_name?: string };
  internalOrgId?: string;
  orgName?: string;
  userId?: string;
}

const cookieMapCache = new Map<string, Record<string, string>>();

function cookies(): Record<string, string> {
  const raw = config.devinCookie;
  let cached = cookieMapCache.get(raw);
  if (!cached) {
    cached = parseCookieString(raw);
    cookieMapCache.set(raw, cached);
  }
  return cached;
}

function extractBearerFromCookies(map: Record<string, string>): string | null {
  // Highest priority: explicit override jar.
  for (const k of ['__devin_bearer', 'devin_bearer', '__devin_auth1_token', 'devin_auth1_token']) {
    const v = map[k];
    if (v) return v.replace(/^Bearer\s+/i, '');
  }

  // Devin's localStorage stores auth as JSON `{ token, userId, ... }`.
  // Historically the key was `storage_auth1_session`; after the Dec-2025
  // unscoped-auth0-token migration the key became `auth1_session`.
  const session = decodeJsonCookie<{ token?: string }>(map.auth1_session ?? map.storage_auth1_session);
  if (session?.token) return session.token;

  // Fallback: scan any cookie value that looks like a JWT.
  for (const value of Object.values(map)) {
    const match = value.match(/[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/);
    if (match && decodeJwt(match[0])) return match[0];
  }

  // Fallback: any value starting with `auth1_` is a Devin opaque session token.
  for (const value of Object.values(map)) {
    const match = value.match(/auth1_[A-Za-z0-9]{16,}/);
    if (match) return match[0];
  }
  return null;
}

/**
 * Devin's auth1 system uses opaque (non-JWT) tokens prefixed with `auth1_`.
 * Returns true if the token is one of those (so callers can skip JWT-only logic).
 */
function isOpaqueAuth1(token: string): boolean {
  return token.startsWith('auth1_') && !token.includes('.');
}

function snapshot(): AuthSnapshot {
  const map = cookies();
  const bearer = config.devinBearer ?? extractBearerFromCookies(map);
  if (!bearer) {
    throw new GatewayError(
      'Missing Devin bearer token. Either set DEVIN_BEARER explicitly, or paste a DEVIN_COOKIE that includes auth1_session (or storage_auth1_session on older Devin builds).',
      500,
      'missing_bearer',
    );
  }
  return { cookies: map, bearer, fingerprint: cookieFingerprint(map) };
}

function buildHeaders(auth: AuthSnapshot, orgId: string | null): Record<string, string> {
  const cookieHeader = serializeCookies(auth.cookies);
  return {
    Accept: 'application/json',
    'Content-Type': 'application/json',
    Origin: DEVIN_BASE_URL,
    Referer: `${DEVIN_BASE_URL}/`,
    'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    Authorization: `Bearer ${auth.bearer}`,
    ...(cookieHeader ? { Cookie: cookieHeader } : {}),
    ...(orgId
      ? {
          'x-cog-org-id': orgId,
          'X-Org-Id': orgId,
          'X-Organization-Id': orgId,
          'X-Devin-Org-Id': orgId,
        }
      : {}),
  };
}

export class GatewayError extends Error {
  constructor(
    message: string,
    public readonly status = 502,
    public readonly code = 'devin_upstream',
  ) {
    super(message);
    this.name = 'GatewayError';
  }
}

async function readJson(res: Response): Promise<unknown> {
  const text = await res.text().catch(() => '');
  try {
    return text ? JSON.parse(text) : null;
  } catch {
    throw new GatewayError(
      `Devin returned non-JSON response (${res.status}): ${text.slice(0, 200)}`,
      502,
      'devin_bad_response',
    );
  }
}

function isObj(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === 'object' && !Array.isArray(value);
}

async function resolveOrgId(auth: AuthSnapshot, devinId: string): Promise<string> {
  if (config.devinOrgId) return config.devinOrgId;

  const state = getState();
  if (state.orgId && state.cookieFingerprint === auth.fingerprint) {
    return state.orgId;
  }

  // Try to read it directly from cookies first (cheap).
  for (const [key, value] of Object.entries(auth.cookies)) {
    if (!key.toLowerCase().includes('post-auth')) continue;
    const parsed = decodeJsonCookie<PostAuthResponse>(value);
    const orgId = parsed?.internalOrgId ?? parsed?.result?.org_id ?? parsed?.org_id;
    if (orgId) {
      persist({
        orgId,
        userId: parsed?.userId ?? parsed?.user_id,
        orgName: parsed?.orgName ?? parsed?.result?.org_name ?? parsed?.org_name,
        cookieFingerprint: auth.fingerprint,
      });
      return orgId;
    }
  }

  // Fall back to round-tripping post-auth.
  const res = await fetch(`${DEVIN_BASE_URL}/api/users/post-auth`, {
    method: 'POST',
    headers: buildHeaders(auth, null),
    body: JSON.stringify({ devin_id: devinId }),
  });
  const json = await readJson(res);
  if (!res.ok) {
    throw new GatewayError(
      `Devin /api/users/post-auth failed (${res.status}): ${JSON.stringify(json)}`,
      res.status === 401 ? 401 : 502,
      res.status === 401 ? 'devin_unauthorized' : 'devin_post_auth_failed',
    );
  }
  if (!isObj(json) || typeof json.org_id !== 'string') {
    throw new GatewayError(
      'Devin /api/users/post-auth did not return org_id. Set DEVIN_ORG_ID manually in .env.',
      502,
      'devin_no_org',
    );
  }
  persist({
    orgId: json.org_id,
    userId: typeof json.user_id === 'string' ? json.user_id : undefined,
    orgName: typeof json.org_name === 'string' ? json.org_name : undefined,
    cookieFingerprint: auth.fingerprint,
  });
  return json.org_id;
}

function preflightAuth(auth: AuthSnapshot): void {
  // Opaque auth1_* tokens carry no exp, so we can't validate them locally.
  // Trust the upstream to reject if the token is stale.
  if (!isOpaqueAuth1(auth.bearer) && !isFresh(auth.bearer, 60)) {
    const exp = jwtExpiryMs(auth.bearer);
    const reason = exp
      ? `Bearer token already expired at ${new Date(exp).toISOString()}.`
      : 'Bearer token has no parseable exp and is not a recognized opaque format (auth1_*).';
    clearBearer();
    throw new GatewayError(
      `${reason} Re-extract Devin auth from a freshly logged-in tab on app.devin.ai and update DEVIN_BEARER / DEVIN_COOKIE.`,
      401,
      'devin_token_expired',
    );
  }

  const state = getState();
  if (state.cookieFingerprint && state.cookieFingerprint !== auth.fingerprint) {
    // Cookies changed: invalidate cached org_id so we re-resolve. The fingerprint
    // will be rewritten on the next successful resolveOrgId().
    persist({ orgId: undefined, cookieFingerprint: auth.fingerprint });
  }
}

export interface ChatTurn {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

function transcriptToPrompt(turns: ChatTurn[], systemPrompt: string | null): string {
  const lines: string[] = [];
  if (systemPrompt) lines.push(`[SYSTEM]\n${systemPrompt.trim()}`);
  for (const turn of turns) {
    if (!turn.content.trim()) continue;
    if (turn.role === 'system') {
      lines.push(`[SYSTEM]\n${turn.content.trim()}`);
    } else if (turn.role === 'assistant') {
      lines.push(`[ASSISTANT]\n${turn.content.trim()}`);
    } else {
      lines.push(`[USER]\n${turn.content.trim()}`);
    }
  }
  return lines.join('\n\n');
}

interface CreateSessionArgs {
  prompt: string;
  model: string;
}

async function createSession(auth: AuthSnapshot, args: CreateSessionArgs): Promise<string> {
  const devinId = `devin-${randomUUID().replace(/-/g, '')}`;
  const orgIdHint = config.devinOrgId ?? getState().orgId ?? null;
  const userIdHint = getState().userId;

  const body = {
    devin_id: devinId,
    user_message: args.prompt,
    username: config.devinUsername,
    ...(orgIdHint ? { org_id: orgIdHint, organization_id: orgIdHint } : {}),
    ...(userIdHint ? { user_id: userIdHint } : {}),
    rich_content: [{ text: args.prompt }],
    repos: [],
    snapshot_id: null,
    tags: [],
    from_spaces: 'false',
    planner_type: config.devinPlannerType,
    planning_mode: config.devinPlanningMode,
    bypass_approval: false,
    'devin-rs': 'true',
    devin_version_override: args.model,
    additional_args: {
      planning_mode: config.devinPlanningMode,
      planner_type: config.devinPlannerType,
      from_spaces: 'false',
      bypass_approval: false,
      'devin-rs': 'true',
      devin_version_override: args.model,
    },
  };

  const res = await fetch(`${DEVIN_BASE_URL}/api/sessions`, {
    method: 'POST',
    headers: buildHeaders(auth, orgIdHint),
    body: JSON.stringify(body),
  });
  const json = await readJson(res);
  if (res.status === 401) {
    clearBearer();
    throw new GatewayError(
      `Devin /api/sessions returned 401. Body: ${JSON.stringify(json)}. ` +
        'Most likely the auth1 bearer expired or your account has no org_id linked. ' +
        'Re-extract DEVIN_COOKIE from a tab where app.devin.ai is fully loaded and a session is open.',
      401,
      'devin_unauthorized',
    );
  }
  if (!res.ok) {
    throw new GatewayError(
      `Devin /api/sessions failed (${res.status}): ${JSON.stringify(json)}`,
      502,
      'devin_create_failed',
    );
  }
  if (isObj(json) && typeof json.devin_id === 'string') return json.devin_id;
  return devinId;
}

interface PollResult {
  message: string | null;
  status: string | null;
}

async function pollOnce(auth: AuthSnapshot, orgId: string, devinId: string, startedAt: number): Promise<PollResult> {
  const params = new URLSearchParams({
    include_pinned: 'true',
    group_children: 'true',
    limit: '30',
    order_by: 'updated_at',
    sort_direction: 'desc',
    is_archived: 'false',
    session_type: 'devin',
    updated_date_from: new Date(startedAt - 60_000).toISOString(),
  });
  const userId = getState().userId;
  if (userId) params.set('creators', userId);

  const url = `${DEVIN_BASE_URL}/api/${encodeURIComponent(orgId)}/v2sessions?${params}`;
  const res = await fetch(url, { headers: buildHeaders(auth, orgId) });
  const json = await readJson(res);
  if (res.status === 401) {
    throw new GatewayError(
      `Devin v2sessions returned 401: ${JSON.stringify(json)}. Bearer or session likely rotated mid-poll.`,
      401,
      'devin_unauthorized',
    );
  }
  if (!res.ok) {
    throw new GatewayError(`Devin v2sessions failed (${res.status}): ${JSON.stringify(json)}`, 502, 'devin_poll_failed');
  }
  const list = isObj(json) && Array.isArray(json.result) ? json.result : [];
  const item = list.find(entry => isObj(entry) && entry.devin_id === devinId);
  if (!isObj(item)) return { message: null, status: null };

  const contents = item.latest_message_contents;
  let message: string | null = null;
  if (isObj(contents) && contents.type === 'devin_message' && typeof contents.message === 'string') {
    const trimmed = contents.message.trim();
    if (trimmed) message = trimmed;
  }
  const statusContents = item.latest_status_contents;
  const status = isObj(statusContents) && typeof statusContents.enum === 'string' ? statusContents.enum : null;
  return { message, status };
}

async function waitForReply(auth: AuthSnapshot, orgId: string, devinId: string, startedAt: number): Promise<string> {
  const deadline = Date.now() + config.devinReplyTimeoutMs;
  while (Date.now() < deadline) {
    const { message, status } = await pollOnce(auth, orgId, devinId, startedAt);
    if (message) return message;
    if (status === 'failed' || status === 'errored') {
      throw new GatewayError(
        `Devin session ${devinId} ended with status="${status}" before sending any message.`,
        502,
        'devin_session_failed',
      );
    }
    await new Promise(r => setTimeout(r, 2000));
  }
  throw new GatewayError(
    `Timed out after ${config.devinReplyTimeoutMs / 1000}s waiting for Devin to send first message in session ${devinId}.`,
    504,
    'devin_timeout',
  );
}

export interface DevinChatRequest {
  turns: ChatTurn[];
  systemPrompt: string | null;
  model: string;
}

export interface DevinChatResponse {
  devinId: string;
  content: string;
  promptChars: number;
  responseChars: number;
}

export async function runDevinChat(req: DevinChatRequest): Promise<DevinChatResponse> {
  const auth = snapshot();
  preflightAuth(auth);

  const startedAt = Date.now();
  const prompt = transcriptToPrompt(req.turns, req.systemPrompt);
  if (!prompt.trim()) {
    throw new GatewayError('Refusing to start a Devin session with an empty prompt.', 400, 'empty_prompt');
  }

  const devinId = await createSession(auth, { prompt, model: req.model });
  const orgId = await resolveOrgId(auth, devinId);
  const content = await waitForReply(auth, orgId, devinId, startedAt);
  return {
    devinId,
    content,
    promptChars: prompt.length,
    responseChars: content.length,
  };
}
