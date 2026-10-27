// The runner's own small-model calls (docs/protocol.md, "Settings and
// models"): classify, extract, summarize and generate, all through
// OpenRouter with one key. Features ask for a job, not a model; ROUTES
// says which models answer it, in order, so swapping one touches that
// table alone. A call never throws: a failed one says why, and the feature
// falls back to what it did before there was a key.
import fs from 'node:fs';
import path from 'node:path';
import type { Clock } from '../clock.ts';
import type { Logger } from '../log.ts';
import { expandHome, paths } from '../config.ts';
import { chat } from './openrouter.ts';
import type { ChatResponse, Fetch } from './openrouter.ts';
import { Ledger } from './ledger.ts';

export type ModelJob = 'classify' | 'extract' | 'summarize' | 'generate';

export const HAIKU = 'anthropic/claude-haiku-5.5';

// ScaleDown's Extract and Summarize cost about $0.04 per million input
// tokens with free output, so they go first; Haiku answers when they fail
// or say something we can't read. ScaleDown's Classify is only on its own
// API, so classify goes to Haiku until a feature needs typed decisions.
export const ROUTES: Record<ModelJob, string[]> = {
  classify: [HAIKU],
  extract: ['scaledown/extract', HAIKU],
  summarize: ['scaledown/summarize', HAIKU],
  generate: [HAIKU],
};

export type ModelFailure = 'no-key' | 'off' | 'private' | 'over-budget' | 'timeout' | 'provider';

export type ModelResult<T> =
  | { ok: true; value: T; model: string; costUsd?: number }
  | { ok: false; reason: ModelFailure; message: string };

// Every call names the feature asking (for the usage file) and, when it
// sends a thread's text, the thread's folder (for private folders).
type Common = { feature: string; cwd?: string };

export type ClassifyParams = Common & { text: string; labels: string[]; instructions?: string };
export type ExtractParams = Common & { text: string; fields: Record<string, string> };
export type SummarizeParams = Common & { text: string; maxWords?: number };
export type GenerateParams = Common & { prompt: string; system?: string; maxTokens?: number };

export type ModelSettings = { dailyBudgetUsd: number; privateFolders: string[] };

export type ModelsOptions = {
  home: string;
  clock: Clock;
  log: Logger;
  settings: () => ModelSettings;
  fetch?: Fetch;
  // Tells every client (runner.notice).
  notice?: (level: 'info' | 'warning' | 'error', message: string) => void;
  // After each call that went out, so the Settings window's spend can follow.
  onSpend?: () => void;
  timeoutMs?: number;
  maxInFlight?: number;
};

const TIMEOUT_MS = 20_000;
const MAX_IN_FLIGHT = 4;

export function keyPath(home: string): string {
  return path.join(paths.secrets(home), 'openrouter-key');
}

export function readKey(home: string): string | undefined {
  try {
    return fs.readFileSync(keyPath(home), 'utf8').trim() || undefined;
  } catch {
    return undefined;
  }
}

// null removes it. The secrets folder is 0700 and the file 0600, like
// runner-token: only the runner (and Mike) can read it.
export function writeKey(home: string, key: string | null): void {
  const file = keyPath(home);
  if (key === null) {
    fs.rmSync(file, { force: true });
    return;
  }
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, key.trim() + '\n', { mode: 0o600 });
  fs.chmodSync(file, 0o600);
}

export function keyHint(key: string | undefined): string | undefined {
  return key && key.length >= 8 ? key.slice(-4) : undefined;
}

// A folder in the list, or anywhere under one.
export function isPrivate(cwd: string, folders: string[]): boolean {
  const at = path.resolve(expandHome(cwd));
  return folders.some((f) => {
    const p = path.resolve(expandHome(f));
    return at === p || at.startsWith(p.endsWith(path.sep) ? p : p + path.sep);
  });
}

// What one route asks a model, and how to read its answer (undefined: it
// said something we can't use, so try the next model).
type Attempt<T> = {
  system?: string;
  user: string;
  maxTokens?: number;
  jsonSchema?: { name: string; schema: Record<string, unknown> };
  extra?: Record<string, unknown>;
  read: (text: string) => T | undefined;
};

export class Models {
  private opts: ModelsOptions;
  private ledger: Ledger;
  private inFlight = 0;
  private waiting: (() => void)[] = [];
  // The local day the over-budget notice was last sent, so it's said once.
  private overBudgetNoticeDay?: string;

  constructor(opts: ModelsOptions) {
    this.opts = opts;
    this.ledger = new Ledger(opts.home, opts.clock.now());
  }

  hasKey(): boolean {
    return Boolean(readKey(this.opts.home));
  }

  spentTodayUsd(): number {
    return this.ledger.today(this.opts.clock.now());
  }

  spentMonthUsd(): number {
    return this.ledger.month(this.opts.clock.now());
  }

  // Picks one of `labels` for the text.
  classify(p: ClassifyParams): Promise<ModelResult<string>> {
    const labels = [...new Set(p.labels)];
    return this.run('classify', p, () => ({
      system: `${p.instructions ? p.instructions.trim() + '\n\n' : ''}Answer with one of these labels: ${labels.join(', ')}.`,
      user: p.text,
      maxTokens: 50,
      jsonSchema: {
        name: 'label',
        schema: { type: 'object', properties: { label: { type: 'string', enum: labels } }, required: ['label'], additionalProperties: false },
      },
      read: (text) => {
        const label = (parseObject(text)?.label ?? text.trim()) as unknown;
        return typeof label === 'string' && labels.includes(label) ? label : undefined;
      },
    }));
  }

  // Pulls named fields out of the text; `fields` maps each name to a plain
  // description of it. A field the text doesn't give is null.
  extract(p: ExtractParams): Promise<ModelResult<Record<string, string | null>>> {
    const names = Object.keys(p.fields);
    const read = (text: string) => {
      const obj = parseObject(text);
      if (!obj) return undefined;
      const out: Record<string, string | null> = {};
      for (const n of names) {
        const v = obj[n];
        out[n] = v === undefined || v === null || v === '' ? null : Array.isArray(v) ? v.map(String).join('\n') : String(v);
      }
      return out;
    };
    return this.run('extract', p, (model) =>
      model.startsWith('scaledown/')
        ? // ScaleDown takes the fields as provider options rather than a prompt.
          { user: p.text, extra: { provider: { options: { scaledown: { entities: p.fields } } } }, read }
        : {
            system: `Extract these fields from the text. Use null for any the text doesn't give.\n${names.map((n) => `- ${n}: ${p.fields[n]}`).join('\n')}`,
            user: p.text,
            maxTokens: 1000,
            jsonSchema: {
              name: 'fields',
              schema: {
                type: 'object',
                properties: Object.fromEntries(names.map((n) => [n, { type: ['string', 'null'], description: p.fields[n] }])),
                required: names,
                additionalProperties: false,
              },
            },
            read,
          },
    );
  }

  summarize(p: SummarizeParams): Promise<ModelResult<string>> {
    const words = p.maxWords ?? 80;
    const maxTokens = Math.ceil(words * 2) + 50;
    const read = (text: string) => text.trim() || undefined;
    return this.run('summarize', p, (model) =>
      model.startsWith('scaledown/')
        ? { user: p.text, maxTokens, read }
        : { system: `Summarise the text in at most ${words} words. Plain text, no preamble.`, user: p.text, maxTokens, read },
    );
  }

  generate(p: GenerateParams): Promise<ModelResult<string>> {
    return this.run('generate', p, () => ({ system: p.system, user: p.prompt, maxTokens: p.maxTokens ?? 500, read: (t) => t.trim() || undefined }));
  }

  private async run<T>(job: ModelJob, p: Common, attempt: (model: string) => Attempt<T>): Promise<ModelResult<T>> {
    const key = readKey(this.opts.home);
    if (!key) return { ok: false, reason: 'no-key', message: 'No OpenRouter key is set (Settings, Models).' };
    const s = this.opts.settings();
    if (!(s.dailyBudgetUsd > 0)) return { ok: false, reason: 'off', message: 'Model calls are off (the daily budget is 0).' };
    if (p.cwd && isPrivate(p.cwd, s.privateFolders)) return { ok: false, reason: 'private', message: `${p.cwd} is a private folder.` };
    const over = (): ModelResult<T> | undefined =>
      this.spentTodayUsd() >= this.opts.settings().dailyBudgetUsd
        ? { ok: false, reason: 'over-budget', message: `Today's model budget of ${usd(this.opts.settings().dailyBudgetUsd)} is spent.` }
        : undefined;
    const before = over();
    if (before) return before;

    await this.acquire();
    try {
      // Checked again: calls that waited for a slot may have spent it.
      const after = over();
      if (after) return after;
      let last: ChatResponse | undefined;
      for (const model of ROUTES[job]) {
        const a = attempt(model);
        for (let tries = 0; tries < 2; tries++) {
          const started = this.opts.clock.now();
          const res = await chat({
            key,
            model,
            system: a.system,
            user: a.user,
            maxTokens: a.maxTokens,
            jsonSchema: a.jsonSchema,
            extra: a.extra,
            timeoutMs: this.opts.timeoutMs ?? TIMEOUT_MS,
            fetch: this.opts.fetch ?? fetch,
          });
          const value = res.ok ? a.read(res.text) : undefined;
          this.record(job, p.feature, model, started, res, res.ok && value === undefined ? 'unreadable answer' : undefined);
          if (res.ok && value !== undefined) return { ok: true, value, model, costUsd: res.costUsd };
          last = res;
          if (res.ok || !res.retry) break;
        }
      }
      if (last && !last.ok && last.timedOut) return { ok: false, reason: 'timeout', message: last.message };
      return { ok: false, reason: 'provider', message: last && !last.ok ? last.message : "The model's answer couldn't be read." };
    } finally {
      this.release();
    }
  }

  private record(job: ModelJob, feature: string, model: string, started: number, res: ChatResponse, unreadable?: string): void {
    const now = this.opts.clock.now();
    const line = {
      ts: new Date(now).toISOString(),
      feature,
      job,
      model,
      ok: res.ok && !unreadable,
      ms: now - started,
      ...(res.ok ? { inputTokens: res.inputTokens, outputTokens: res.outputTokens } : {}),
      ...(res.costUsd !== undefined ? { costUsd: res.costUsd } : {}),
      ...(!res.ok ? { error: res.message.slice(0, 300) } : unreadable ? { error: unreadable } : {}),
    };
    this.ledger.add(line);
    if (!line.ok) this.opts.log.warn('model call failed', { feature, job, model, error: line.error });
    const budget = this.opts.settings().dailyBudgetUsd;
    const day = new Date(now).toDateString();
    if (budget > 0 && this.spentTodayUsd() >= budget && this.overBudgetNoticeDay !== day) {
      this.overBudgetNoticeDay = day;
      this.opts.notice?.('warning', `Today's model budget of ${usd(budget)} is spent, so titles, summaries and the like wait for tomorrow. Change it in Settings.`);
    }
    this.opts.onSpend?.();
  }

  private acquire(): Promise<void> {
    if (this.inFlight < (this.opts.maxInFlight ?? MAX_IN_FLIGHT)) {
      this.inFlight++;
      return Promise.resolve();
    }
    return new Promise((resolve) => this.waiting.push(resolve));
  }

  private release(): void {
    const next = this.waiting.shift();
    // The slot passes straight to the next caller.
    if (next) next();
    else this.inFlight--;
  }
}

function parseObject(text: string): Record<string, unknown> | undefined {
  // Models sometimes wrap JSON in a code fence.
  const m = /\{[\s\S]*\}/.exec(text);
  if (!m) return undefined;
  try {
    const v = JSON.parse(m[0]);
    return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

export function usd(n: number): string {
  // A day of titles is a fraction of a cent, so small amounts keep 4 places.
  return n === 0 || n >= 0.01 ? `$${n.toFixed(2)}` : `$${n.toFixed(4)}`;
}
