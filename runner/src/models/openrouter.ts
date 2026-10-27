// One chat completion through OpenRouter. Plain fetch: three request shapes
// don't need an SDK. Never throws for an HTTP or network problem; the
// caller (models/index.ts) decides whether to try again or move on.

export const OPENROUTER_URL = 'https://openrouter.ai/api/v1/chat/completions';

export type Fetch = typeof fetch;

export type ChatRequest = {
  key: string;
  model: string;
  system?: string;
  user: string;
  maxTokens?: number;
  // OpenRouter's structured outputs, for models that take them (Haiku).
  jsonSchema?: { name: string; schema: Record<string, unknown> };
  // Extra body fields for one provider's own options (ScaleDown's).
  extra?: Record<string, unknown>;
  timeoutMs: number;
  fetch: Fetch;
};

export type ChatResponse =
  | { ok: true; text: string; inputTokens?: number; outputTokens?: number; costUsd?: number }
  // retry: worth one more go (a network error, a 5xx, a 429).
  | { ok: false; timedOut: boolean; retry: boolean; status?: number; message: string; costUsd?: number };

export async function chat(req: ChatRequest): Promise<ChatResponse> {
  const messages: { role: string; content: string }[] = [];
  if (req.system) messages.push({ role: 'system', content: req.system });
  messages.push({ role: 'user', content: req.user });
  const body: Record<string, unknown> = { model: req.model, messages, usage: { include: true }, ...req.extra };
  if (req.maxTokens) body.max_tokens = req.maxTokens;
  if (req.jsonSchema) body.response_format = { type: 'json_schema', json_schema: { name: req.jsonSchema.name, strict: true, schema: req.jsonSchema.schema } };
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), req.timeoutMs);
  timer.unref?.();
  try {
    const res = await req.fetch(OPENROUTER_URL, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${req.key}`,
        'content-type': 'application/json',
        // OpenRouter's app attribution, so its dashboard says what spent it.
        'x-title': 'Threadbare',
      },
      body: JSON.stringify(body),
      signal: ctl.signal,
    });
    const raw = await res.text();
    let json: OpenRouterReply | undefined;
    try {
      json = JSON.parse(raw) as OpenRouterReply;
    } catch {
      // Not JSON: a proxy's error page. Said below.
    }
    if (!res.ok || json?.error) {
      const status = json?.error?.code && typeof json.error.code === 'number' ? json.error.code : res.status;
      const message = json?.error?.message ?? (raw.slice(0, 200) || res.statusText);
      return { ok: false, timedOut: false, retry: status >= 500 || status === 429, status, message: `OpenRouter ${status}: ${message}` };
    }
    const text = json?.choices?.[0]?.message?.content;
    if (typeof text !== 'string') {
      return { ok: false, timedOut: false, retry: false, message: 'OpenRouter sent no text', costUsd: json?.usage?.cost };
    }
    return {
      ok: true,
      text,
      inputTokens: json?.usage?.prompt_tokens,
      outputTokens: json?.usage?.completion_tokens,
      costUsd: json?.usage?.cost,
    };
  } catch (e) {
    const timedOut = ctl.signal.aborted;
    return { ok: false, timedOut, retry: !timedOut, message: timedOut ? `Timed out after ${Math.round(req.timeoutMs / 1000)} s` : `Couldn't reach OpenRouter: ${(e as Error).message}` };
  } finally {
    clearTimeout(timer);
  }
}

type OpenRouterReply = {
  choices?: { message?: { content?: unknown } }[];
  usage?: { prompt_tokens?: number; completion_tokens?: number; cost?: number };
  error?: { code?: number | string; message?: string };
};
