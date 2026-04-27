import { Hono } from 'hono';
import { streamSSE } from 'hono/streaming';
import { config, resolveDevinModel } from '../config.js';
import { runDevinChat, GatewayError, type ChatTurn } from '../devin.js';

interface AnthropicContentBlock {
  type?: string;
  text?: string;
}

interface AnthropicMessage {
  role: 'user' | 'assistant';
  content: string | AnthropicContentBlock[];
}

interface AnthropicMessagesRequest {
  model?: string;
  system?: string | AnthropicContentBlock[];
  messages?: AnthropicMessage[];
  stream?: boolean;
  max_tokens?: number;
}

function flattenBlocks(value: string | AnthropicContentBlock[] | undefined): string {
  if (!value) return '';
  if (typeof value === 'string') return value;
  return value
    .filter(b => b && (b.type === undefined || b.type === 'text'))
    .map(b => b.text ?? '')
    .filter(Boolean)
    .join('\n');
}

function normalizeMessages(req: AnthropicMessagesRequest): { turns: ChatTurn[]; systemPrompt: string | null } {
  const turns: ChatTurn[] = [];
  for (const msg of req.messages ?? []) {
    const text = flattenBlocks(msg.content).trim();
    if (!text) continue;
    if (msg.role === 'user' || msg.role === 'assistant') {
      turns.push({ role: msg.role, content: text });
    }
  }
  const systemPrompt = flattenBlocks(req.system).trim() || null;
  return { turns, systemPrompt };
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

export const anthropicRouter = new Hono();

anthropicRouter.post('/v1/messages', async c => {
  const body = (await c.req.json().catch(() => ({}))) as AnthropicMessagesRequest;
  const messages = Array.isArray(body.messages) ? body.messages : [];
  if (messages.length === 0) {
    return c.json(
      { type: 'error', error: { type: 'invalid_request_error', message: 'messages must be non-empty' } },
      400,
    );
  }

  const { turns, systemPrompt } = normalizeMessages(body);
  const requestedModel = body.model ?? config.devinModelDefault;
  const model = resolveDevinModel(requestedModel);
  const stream = body.stream === true;
  const id = `msg_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`;

  if (!stream) {
    try {
      const result = await runDevinChat({ turns, systemPrompt, model });
      const promptText = turns.map(t => t.content).join('\n');
      return c.json({
        id,
        type: 'message',
        role: 'assistant',
        model: requestedModel,
        content: [{ type: 'text', text: result.content }],
        stop_reason: 'end_turn',
        stop_sequence: null,
        usage: {
          input_tokens: approxTokens(promptText),
          output_tokens: approxTokens(result.content),
        },
      });
    } catch (err) {
      if (err instanceof GatewayError) {
        return c.json(
          { type: 'error', error: { type: 'api_error', message: err.message, code: err.code } },
          err.status as 400 | 401 | 502 | 504,
        );
      }
      const message = err instanceof Error ? err.message : String(err);
      return c.json({ type: 'error', error: { type: 'api_error', message } }, 502);
    }
  }

  return streamSSE(c, async stream => {
    try {
      const result = await runDevinChat({ turns, systemPrompt, model });
      const promptText = turns.map(t => t.content).join('\n');
      const inputTokens = approxTokens(promptText);
      const outputTokens = approxTokens(result.content);

      await stream.writeSSE({
        event: 'message_start',
        data: JSON.stringify({
          type: 'message_start',
          message: {
            id,
            type: 'message',
            role: 'assistant',
            model: requestedModel,
            content: [],
            stop_reason: null,
            stop_sequence: null,
            usage: { input_tokens: inputTokens, output_tokens: 0 },
          },
        }),
      });
      await stream.writeSSE({
        event: 'content_block_start',
        data: JSON.stringify({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }),
      });
      for (const piece of chunkString(result.content)) {
        await stream.writeSSE({
          event: 'content_block_delta',
          data: JSON.stringify({
            type: 'content_block_delta',
            index: 0,
            delta: { type: 'text_delta', text: piece },
          }),
        });
      }
      await stream.writeSSE({
        event: 'content_block_stop',
        data: JSON.stringify({ type: 'content_block_stop', index: 0 }),
      });
      await stream.writeSSE({
        event: 'message_delta',
        data: JSON.stringify({
          type: 'message_delta',
          delta: { stop_reason: 'end_turn', stop_sequence: null },
          usage: { output_tokens: outputTokens },
        }),
      });
      await stream.writeSSE({ event: 'message_stop', data: JSON.stringify({ type: 'message_stop' }) });
    } catch (err) {
      const status = err instanceof GatewayError ? err.status : 502;
      const message = err instanceof Error ? err.message : String(err);
      const code = err instanceof GatewayError ? err.code : 'devin_upstream';
      await stream.writeSSE({
        event: 'error',
        data: JSON.stringify({ type: 'error', error: { type: 'api_error', message, code, status } }),
      });
    }
  });
});
