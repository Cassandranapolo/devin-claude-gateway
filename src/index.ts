import { serve } from '@hono/node-server';
import { Hono } from 'hono';
import { logger } from 'hono/logger';
import { config } from './config.js';
import { openaiRouter } from './routes/openai.js';
import { anthropicRouter } from './routes/anthropic.js';
import { getState } from './state.js';

const app = new Hono();

app.use('*', logger());

// Optional gateway-level API key gate. Allows clients to send either
// "Authorization: Bearer <key>" or "x-api-key: <key>".
app.use('*', async (c, next) => {
  if (!config.gatewayApiKey) return next();
  if (c.req.path === '/health' || c.req.path === '/') return next();

  const auth = c.req.header('authorization');
  const xApiKey = c.req.header('x-api-key');
  const presented = auth?.replace(/^Bearer\s+/i, '').trim() ?? xApiKey?.trim();
  if (presented !== config.gatewayApiKey) {
    return c.json({ error: { message: 'Invalid gateway API key.', type: 'authentication_error' } }, 401);
  }
  return next();
});

app.get('/', c =>
  c.json({
    name: 'devin-claude-gateway',
    version: '0.3.0',
    endpoints: {
      openai_compatible: ['/v1/chat/completions', '/v1/models'],
      anthropic_compatible: ['/anthropic/v1/messages'],
    },
    devin_model_default: config.devinModelDefault,
    org_id_resolved: !!(config.devinOrgId ?? getState().orgId),
  }),
);

app.get('/health', c => c.json({ ok: true }));

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
