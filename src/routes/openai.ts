import { Hono, type Context } from 'hono';
import { streamSSE } from 'hono/streaming';
import { config, DEVIN_MODELS, resolveDevinModel } from '../config.js';
import { runDevinChat, GatewayError, type ChatTurn } from '../devin.js';

interface OpenAIMessage {
  role: 'system' | 'user' | 'assistant' | 'tool' | 'function';
  content: string | Array<{ type?: string; text?: string }>;
  name?: string;
}

interface OpenAIChatRequest {
  model?: string;
  messages?: OpenAIMessage[];
  stream?: boolean;
  stream_options?: { include_usage?: boolean };
  user?: string;
}

function flattenContent(content: OpenAIMessage['content']): string {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .filter(part => part && (part.type === undefined || part.type === 'text'))
    .map(part => part.text ?? '')
    .filter(Boolean)
    .join('\n');
}

function normalizeMessages(messages: OpenAIMessage[]): { turns: ChatTurn[]; systemPrompt: string | null } {
  const turns: ChatTurn[] = [];
  const systemParts: string[] = [];
  for (const msg of messages) {
    const text = flattenContent(msg.content).trim();
    if (!text) continue;
    if (msg.role === 'system') {
      systemParts.push(text);
    } else if (msg.role === 'user' || msg.role === 'assistant') {
      turns.push({ role: msg.role, content: text });
    } else {
      // Treat tool/function output as part of the user transcript so Devin sees the context.
      turns.push({ role: 'user', content: `[tool:${msg.name ?? 'unknown'}]\n${text}` });
    }
  }
  return { turns, systemPrompt: systemParts.length ? systemParts.join('\n\n') : null };
}

function approxTokens(text: string): number {
  if (!text) return 0;
  return Math.max(1, Math.ceil(text.length / 4));
}

function chunkString(text: string, size = 64): string[] {
  if (!text) return [];
  const out: string[] = [];
  for (let i = 0; i < text.length; i += size) {
    out.push(text.slice(i, i + size));
  }
  return out;
}

export const openaiRouter = new Hono();

openaiRouter.get('/models', c => {
  const data = DEVIN_MODELS.map(m => ({
    id: m.id,
    object: 'model',
    created: 0,
    owned_by: m.owned_by,
  }));
  return c.json({ object: 'list', data });
});

openaiRouter.post('/chat/completions', async c => {
  const body = (await c.req.json().catch(() => ({}))) as OpenAIChatRequest;
  const messages = Array.isArray(body.messages) ? body.messages : [];
  if (messages.length === 0) {
    return c.json({ error: { message: 'messages is required and must not be empty', type: 'invalid_request_error' } }, 400);
  }

  const { turns, systemPrompt } = normalizeMessages(messages);
  const requestedModel = body.model ?? config.devinModelDefault;
  const model = resolveDevinModel(requestedModel);
  const stream = body.stream === true;
  const id = `chatcmpl-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  const created = Math.floor(Date.now() / 1000);

  if (!stream) {
    try {
      const result = await runDevinChat({ turns, systemPrompt, model });
      return c.json({
        id,
        object: 'chat.completion',
        created,
        model: requestedModel,
        choices: [
          {
            index: 0,
            message: { role: 'assistant', content: result.content },
            finish_reason: 'stop',
          },
        ],
        usage: {
          prompt_tokens: approxTokens(turns.map(t => t.content).join('\n')),
          completion_tokens: approxTokens(result.content),
          total_tokens: approxTokens(turns.map(t => t.content).join('\n')) + approxTokens(result.content),
        },
      });
    } catch (err) {
      return errorResponse(c, err);
    }
  }

  return streamSSE(c, async stream => {
    try {
      const result = await runDevinChat({ turns, systemPrompt, model });
      const baseChunk = (delta: object, finish_reason: string | null = null) => ({
        id,
        object: 'chat.completion.chunk',
        created,
        model: requestedModel,
        choices: [{ index: 0, delta, finish_reason }],
      });
      await stream.writeSSE({ data: JSON.stringify(baseChunk({ role: 'assistant' })) });
      for (const piece of chunkString(result.content)) {
        await stream.writeSSE({ data: JSON.stringify(baseChunk({ content: piece })) });
      }
      await stream.writeSSE({ data: JSON.stringify(baseChunk({}, 'stop')) });
      if (body.stream_options?.include_usage) {
        await stream.writeSSE({
          data: JSON.stringify({
            id,
            object: 'chat.completion.chunk',
            created,
            model: requestedModel,
            choices: [],
            usage: {
              prompt_tokens: approxTokens(turns.map(t => t.content).join('\n')),
              completion_tokens: approxTokens(result.content),
              total_tokens:
                approxTokens(turns.map(t => t.content).join('\n')) + approxTokens(result.content),
            },
          }),
        });
      }
      await stream.writeSSE({ data: '[DONE]' });
    } catch (err) {
      const status = err instanceof GatewayError ? err.status : 502;
      const message = err instanceof Error ? err.message : String(err);
      const code = err instanceof GatewayError ? err.code : 'devin_upstream';
      await stream.writeSSE({
        data: JSON.stringify({ error: { message, type: 'devin_gateway_error', code, status } }),
      });
      await stream.writeSSE({ data: '[DONE]' });
    }
  });
});

function errorResponse(c: Context, err: unknown) {
  if (err instanceof GatewayError) {
    return c.json(
      { error: { message: err.message, type: 'devin_gateway_error', code: err.code } },
      err.status as 400 | 401 | 502 | 504,
    );
  }
  const message = err instanceof Error ? err.message : String(err);
  return c.json({ error: { message, type: 'devin_gateway_error', code: 'unknown' } }, 502);
}
