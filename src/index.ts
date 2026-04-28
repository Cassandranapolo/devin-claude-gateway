import { serve } from '@hono/node-server';
import { Hono, type MiddlewareHandler } from 'hono';
import { logger } from 'hono/logger';
import { config } from './config.js';
import { openaiRouter } from './routes/openai.js';
import { anthropicRouter } from './routes/anthropic.js';
import { getState } from './state.js';

const app = new Hono();

app.use('*', logger());

// Gateway-level API key check. Mounted only on routes the gateway actually
// serves (`/v1/*` and `/anthropic/*`). Unknown paths fall through to a
// natural 404 instead of returning 401, so clients doing capability
// auto-detection (Ollama-style probes for `/api/tags`, `/v1/props`, etc.)
// can correctly identify the server type.
const apiKeyGate: MiddlewareHandler = async (c, next) => {
  if (!config.gatewayApiKey) return next();
  const auth = c.req.header('authorization');
  const xApiKey = c.req.header('x-api-key');
  const presented = auth?.replace(/^Bearer\s+/i, '').trim() ?? xApiKey?.trim();
  if (presented !== config.gatewayApiKey) {
    return c.json({ error: { message: 'Invalid gateway API key.', type: 'authentication_error' } }, 401);
  }
  return next();
};

app.get('/', c =>
  c.json({
    name: 'devin-claude-gateway',
    version: '0.3.2',
    endpoints: {
      openai_compatible: ['/v1/chat/completions', '/v1/models'],
      anthropic_compatible: ['/anthropic/v1/messages'],
    },
    devin_model_default: config.devinModelDefault,
    org_id_resolved: !!(config.devinOrgId ?? getState().orgId),
  }),
);

app.get('/health', c => c.json({ ok: true }));

// Apply auth only to the routes we actually serve, so that probes for
// unsupported paths (Ollama-style `/api/tags`, llama.cpp `/v1/props`, etc.)
// return a natural 404 instead of a misleading 401.
app.use('/v1/chat/completions', apiKeyGate);
app.use('/v1/models', apiKeyGate);
app.use('/v1/models/*', apiKeyGate);
app.use('/anthropic/v1/messages', apiKeyGate);

app.route('/v1', openaiRouter);
app.route('/anthropic', anthropicRouter);

const port = config.port;
serve({ fetch: app.fetch, port, hostname: config.host }, info => {
  // eslint-disable-next-line no-console
  console.log(`devin-claude-gateway listening on http://${info.address}:${info.port}`);
  if (!config.devinCookie && !config.devinBearer) {
    // eslint-disable-next-line no-console
    console.warn('WARNING: No DEVIN_COOKIE or DEVIN_BEARER configured. Requests will fail until you set one in .env.');
  }
});
