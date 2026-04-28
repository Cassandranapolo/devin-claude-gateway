import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

function loadDotenv(path: string): void {
  if (!existsSync(path)) return;
  const text = readFileSync(path, 'utf8');
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (process.env[key] === undefined) process.env[key] = value;
  }
}

loadDotenv(resolve(process.cwd(), '.env'));

function envNum(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const n = Number(raw);
  return Number.isFinite(n) ? n : fallback;
}

export interface Config {
  port: number;
  host: string;
  gatewayApiKey: string | null;
  stateFile: string;
  devinCookie: string;
  devinBearer: string | null;
  devinOrgId: string | null;
  devinModelDefault: string;
  devinReplyTimeoutMs: number;
  devinPlannerType: string;
  devinPlanningMode: string;
  devinUsername: string;
}

export const config: Config = {
  port: envNum('PORT', 3000),
  host: process.env.HOST ?? '0.0.0.0',
  gatewayApiKey: process.env.GATEWAY_API_KEY?.trim() || null,
  stateFile: resolve(process.cwd(), process.env.STATE_FILE ?? './data/state.json'),
  devinCookie: process.env.DEVIN_COOKIE?.trim() ?? '',
  devinBearer: process.env.DEVIN_BEARER?.trim() || null,
  devinOrgId: process.env.DEVIN_ORG_ID?.trim() || null,
  devinModelDefault: process.env.DEVIN_MODEL_DEFAULT?.trim() || 'devin-opus-4-7',
  devinReplyTimeoutMs: envNum('DEVIN_REPLY_TIMEOUT_S', 180) * 1000,
  devinPlannerType: process.env.DEVIN_PLANNER_TYPE?.trim() || 'fast',
  devinPlanningMode: process.env.DEVIN_PLANNING_MODE?.trim() || 'automatic',
  devinUsername: process.env.DEVIN_USERNAME?.trim() || 'User',
};

export const DEVIN_BASE_URL = 'https://app.devin.ai';

export const DEVIN_MODELS = [
  { id: 'devin-opus-4-7', name: 'Devin Opus 4.7', owned_by: 'cognition' },
  { id: 'devin-2-5', name: 'Devin 2.5', owned_by: 'cognition' },
  { id: 'devin-0929-brocade', name: 'Devin Brocade', owned_by: 'cognition' },
  { id: 'claude-opus-4-7', name: 'Claude Opus 4.7 (alias \u2192 devin-opus-4-7)', owned_by: 'cognition' },
];

const VALID_DEVIN_MODELS = new Set(['devin-opus-4-7', 'devin-2-5', 'devin-0929-brocade']);

// User-defined aliases via MODEL_ALIASES env var.
// Format: "from1=to1,from2=to2" (case-insensitive on the `from` side).
// Example: MODEL_ALIASES="gpt-4=devin-opus-4-7,gpt-4o=devin-2-5"
function parseModelAliases(): Record<string, string> {
  const raw = process.env.MODEL_ALIASES?.trim();
  if (!raw) return {};
  const out: Record<string, string> = {};
  for (const pair of raw.split(',')) {
    const eq = pair.indexOf('=');
    if (eq < 0) continue;
    const from = pair.slice(0, eq).trim().toLowerCase();
    const to = pair.slice(eq + 1).trim();
    if (from && to) out[from] = to;
  }
  return out;
}

const customAliases = parseModelAliases();

export function resolveDevinModel(requested: string | undefined): string {
  if (!requested) return config.devinModelDefault;
  const lower = requested.toLowerCase();
  // 1. User-defined custom aliases take highest priority.
  if (customAliases[lower]) {
    const target = customAliases[lower];
    if (VALID_DEVIN_MODELS.has(target)) return target;
  }
  // 2. Built-in family aliases.
  if (lower.startsWith('claude-opus')) return 'devin-opus-4-7';
  if (lower.startsWith('claude-sonnet') || lower.startsWith('claude-3-5-sonnet')) return 'devin-2-5';
  // 3. Pass-through for known Devin model ids.
  if (DEVIN_MODELS.some(m => m.id === requested)) return requested;
  // 4. Fallback default.
  return config.devinModelDefault;
}
