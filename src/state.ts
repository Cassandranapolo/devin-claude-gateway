import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname } from 'node:path';
import { config } from './config.js';

interface PersistedState {
  orgId?: string;
  userId?: string;
  orgName?: string;
  bearer?: string;
  bearerExpiresAt?: number;
  cookieFingerprint?: string;
  updatedAt?: string;
}

let cache: PersistedState | null = null;

function load(): PersistedState {
  if (cache) return cache;
  if (existsSync(config.stateFile)) {
    try {
      cache = JSON.parse(readFileSync(config.stateFile, 'utf8')) as PersistedState;
      return cache;
    } catch {
      // fall through to empty
    }
  }
  cache = {};
  return cache;
}

export function persist(patch: Partial<PersistedState>): void {
  const next = { ...load(), ...patch, updatedAt: new Date().toISOString() };
  cache = next;
  mkdirSync(dirname(config.stateFile), { recursive: true });
  writeFileSync(config.stateFile, JSON.stringify(next, null, 2), 'utf8');
}

export function getState(): PersistedState {
  return load();
}

export function clearBearer(): void {
  persist({ bearer: undefined, bearerExpiresAt: undefined });
}
