export interface DecodedJwt {
  exp?: number;
  iat?: number;
  sub?: string;
  org_id?: string;
  [key: string]: unknown;
}

/**
 * Decode a JWT without verifying signature. Returns null on failure.
 * Used only to inspect non-secret fields like `exp` so we can refresh proactively.
 */
export function decodeJwt(token: string): DecodedJwt | null {
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const [, payload] = parts;
  if (!payload) return null;
  try {
    const padded = payload.replace(/-/g, '+').replace(/_/g, '/');
    const json = Buffer.from(padded, 'base64').toString('utf8');
    return JSON.parse(json) as DecodedJwt;
  } catch {
    return null;
  }
}

/**
 * @returns true iff token is parseable and exp is more than `bufferSeconds` in the future.
 */
export function isFresh(token: string, bufferSeconds = 300): boolean {
  const payload = decodeJwt(token);
  if (!payload || typeof payload.exp !== 'number') return false;
  const nowSec = Math.floor(Date.now() / 1000);
  return payload.exp - bufferSeconds > nowSec;
}

export function jwtExpiryMs(token: string): number | null {
  const payload = decodeJwt(token);
  if (!payload || typeof payload.exp !== 'number') return null;
  return payload.exp * 1000;
}
