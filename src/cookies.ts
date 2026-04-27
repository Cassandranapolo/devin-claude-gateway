/**
 * Parse a "Cookie:" header value (k=v pairs separated by `; `) into a map.
 * Tolerates URL-encoded values; values are returned as-is (still URL-encoded
 * if they were that way in the source) so re-serializing produces the same
 * exact string the browser sent.
 */
export function parseCookieString(raw: string): Record<string, string> {
  const out: Record<string, string> = {};
  if (!raw) return out;
  for (const pair of raw.split(/;\s*/)) {
    if (!pair) continue;
    const eq = pair.indexOf('=');
    if (eq < 0) continue;
    const key = pair.slice(0, eq).trim();
    const value = pair.slice(eq + 1).trim();
    if (key) out[key] = value;
  }
  return out;
}

export function serializeCookies(cookies: Record<string, string>): string {
  return Object.entries(cookies)
    .filter(([, v]) => v !== undefined && v !== '')
    .map(([k, v]) => `${k}=${v}`)
    .join('; ');
}

/**
 * Many Devin storage cookies are URL-encoded JSON. Decode safely.
 */
export function decodeJsonCookie<T = unknown>(raw: string | undefined): T | null {
  if (!raw) return null;
  try {
    let value = raw;
    if (value.startsWith('%') || value.includes('%7B') || value.includes('%22')) {
      value = decodeURIComponent(value);
    }
    return JSON.parse(value) as T;
  } catch {
    return null;
  }
}

/**
 * Cheap stable fingerprint for a cookie set. Used to detect when the operator
 * pasted a fresh DEVIN_COOKIE so we can invalidate cached bearer/org_id.
 */
export function cookieFingerprint(cookies: Record<string, string>): string {
  const interesting = ['auth1_session', 'storage_auth1_session', 'sessionToken', '_devin_session', '_dd_s'];
  const parts: string[] = [];
  for (const k of interesting) {
    const v = cookies[k];
    if (v) parts.push(`${k}:${v.length}`);
  }
  return parts.join('|') || 'empty';
}
