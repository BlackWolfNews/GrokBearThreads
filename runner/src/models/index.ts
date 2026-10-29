// The runner's own small-model calls (docs/protocol.md, "Settings and
// models"): classify, extract, summarize and generate, on a Claude pool's
// logins through the official CLI, or through OpenRouter with one key.
// Features ask for a job, not a model; ROUTES says which models answer it,
// in order, so swapping one touches that table alone. A call never throws:
// a failed one says why, and the feature falls back to what it did before
// there was a model to ask.
import fs from 'node:fs';
import path from 'node:path';
import type { Clock } from '../clock.ts';
import type { Logger } from '../log.ts';
import type { Account, Pool } from '../protocol.ts';
import { expandHome, paths } from '../config.ts';
import { pickInPool } from '../pools.ts';
import { chat } from './openrouter.ts';
import type { ChatResponse, Fetch } from './openrouter.ts';
import { askCli, cliDir } from './claude-pool.ts';
import type { AskCli, CliResponse } from './claude-pool.ts';
import { Ledger } from './ledger.ts';
import type { UsageLine } from './ledger.ts';

export type ModelJob = 'classify' | 'extract' | 'summarize' | 'generate' | 'decide';

// Haiku through OpenRouter, and Haiku on a login in the settings' pool.
// A route starting "pool:" runs on the pool; any other is an OpenRouter id.
export const HAIKU = 'anthropic/claude-haiku-5.5';
export const POOL_HAIKU = 'pool:claude-haiku-5-5';
// Opus, for the few calls that need judgment more than speed (a generate
// with `strong`): Mike's words for when to wake a thread.
export const OPUS = 'anthropic/claude-opus-5.5';
export const POOL_OPUS = 'pool:claude-opus-5-5';
const POOL_PREFIX = 'pool:';

// Haiku on the pool comes before Haiku on OpenRouter: it's the same model,
// and the logins' room is there anyway. ScaleDown's Extract and Summarize
// cost about $0.04 per million input tokens with free output, so they go
// first when there's a key; Haiku answers when they fail or say something
// we can't read. ScaleDown's Classify is only on its own API, so classify
// goes to Haiku until a feature needs typed decisions.
export const ROUTES: Record<ModelJob, string[]> = {
  classify: [POOL_HAIKU, HAIKU],
  extract: ['scaledown/extract', POOL_HAIKU, HAIKU],
  summarize: ['scaledown/summarize', POOL_HAIKU, HAIKU],
  generate: [POOL_HAIKU, HAIKU],
  decide: [POOL_OPUS, OPUS],
};

export type ModelFailure = 'no-key' | 'off' | 'private' | 'over-budget' | 'no-room' | 'timeout' | 'provider';

export type ModelResult<T> =
  // tokens: in and out together, when the provider said. notionalUsd: what
  // a pool call would have cost on the API, which isn't spent.
  | { ok: true; value: T; model: string; costUsd?: number; tokens?: number; notionalUsd?: number }
  | { ok: false; reason: ModelFailure; message: string };

// Every call names the feature asking (for the usage file) and, when it
// sends a thread's text, the thread's folder (for private folders).
type Common = { feature: string; cwd?: string };

export type ClassifyParams = Common & { text: string; labels: string[]; instructions?: string };
export type ExtractParams = Common & { text: string; fields: Record<string, string> };
export type SummarizeParams = Common & { text: string; maxWords?: number };
// strong: on ROUTES.decide (Opus) rather than the small model.
export type GenerateParams = Common & { prompt: string; system?: string; maxTokens?: number; strong?: boolean };

// pool: the pool whose Claude logins answer "pool:" routes; null for none.
export type ModelSettings = { dailyBudgetUsd: number; privateFolders: string[]; pool?: string | null };

// What the Models layer needs of the runner for pool calls.
export type PoolHost = {
  // The pool and its logins this runner can use, with their room as the
  // runner knows it; undefined when there's no pool by that id.
  pool(id: string): { pool: Pool; accounts: Account[] } | undefined;
  // A login that answered that it's out of room, as a turn would.
  ranDry(accountId: string): void;
};

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
  // Pool calls: the runner's pools and the claude binary. Without a host,
  // pool routes are skipped.
  poolHost?: PoolHost;
  claudePath?: string;
  registry?: { add(pid: number, command: string): void; remove(pid: number): void };
  // Stands in for the CLI in tests.
  askCli?: AskCli;
  poolTimeoutMs?: number;
};

const TIMEOUT_MS = 20_000;
const MAX_IN_FLIGHT = 4;
// A CLI takes 3 to 5 seconds to start and answer, and each is a whole
// process, so fewer at once and a longer wait than OpenRouter's.
const POOL_TIMEOUT_MS = 60_000;
const POOL_MAX_IN_FLIGHT = 2;
export const DEFAULT_POOL = 'claude';

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
type Failure = { ok: false; reason: ModelFailure; message: string };

// Why a route didn't run, best first: the reason a feature is told when
// none did. Out of room comes back by itself; no key needs Mike.
const SKIP_ORDER: ModelFailure[] = ['no-room', 'over-budget', 'off', 'no-key'];

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
  private poolInFlight = 0;
  private poolWaiting: (() => void)[] = [];
  // The login the last pool call ran on, kept while it has room so its
  // prompt cache stays warm.
  private lastLogin?: string;
  // The local day the over-budget notice was last sent, so it's said once.
  private overBudgetNoticeDay?: string;

  constructor(opts: ModelsOptions) {
    this.opts = opts;
    this.ledger = new Ledger(opts.home, opts.clock.now());
  }

  hasKey(): boolean {
    return Boolean(readKey(this.opts.home));
  }

  // The pool small jobs run on, from the settings.
  poolId(): string | null {
    const p = this.opts.settings().pool;
    return p === undefined ? DEFAULT_POOL : p;
  }

  // Why no call could go out at all, or undefined when one might: there's
  // a pool with a Claude login, or a key. Room and budget aren't checked;
  // a call finds those out.
  unavailable(): string | undefined {
    if (this.hasKey() || this.poolLogins()) return undefined;
    const id = this.poolId();
    return id === null ? 'No OpenRouter key' : 'No Claude pool or OpenRouter key';
  }

  private poolLogins(): { pool: Pool; accounts: Account[] } | undefined {
    const id = this.poolId();
    if (id === null || !this.opts.poolHost) return undefined;
    const found = this.opts.poolHost.pool(id);
    if (!found) return undefined;
    const accounts = found.accounts.filter((a) => a.provider === 'claude' && found.pool.accountIds.includes(a.id));
    return accounts.length ? { pool: found.pool, accounts } : undefined;
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
    return this.run(p.strong ? 'decide' : 'generate', p, () => ({ system: p.system, user: p.prompt, maxTokens: p.maxTokens ?? 500, read: (t) => t.trim() || undefined }));
  }

  private async run<T>(job: ModelJob, p: Common, attempt: (model: string) => Attempt<T>): Promise<ModelResult<T>> {
    const s = this.opts.settings();
    if (p.cwd && isPrivate(p.cwd, s.privateFolders)) return { ok: false, reason: 'private', message: `${p.cwd} is a private folder.` };
    const skipped: Failure[] = [];
    let failed: Failure | undefined;
    await this.acquire();
    try {
      for (const model of ROUTES[job]) {
        const a = attempt(model);
        const res = model.startsWith(POOL_PREFIX) ? await this.viaPool(job, p, model.slice(POOL_PREFIX.length), a) : await this.viaOpenRouter(job, p, model, a);
        if (res.ok) return res;
        if ('skipped' in res) skipped.push(res.skipped);
        else failed = res;
      }
    } finally {
      this.release();
    }
    // A route that ran and failed says more than one that never ran.
    if (failed) return failed;
    for (const reason of SKIP_ORDER) {
      const f = skipped.find((x) => x.reason === reason);
      if (f) return f;
    }
    return { ok: false, reason: 'provider', message: "The model's answer couldn't be read." };
  }

  // One OpenRouter route: skipped with no key, a budget of 0 or the day's
  // budget spent; else tried, and once more on an error worth it.
  private async viaOpenRouter<T>(job: ModelJob, p: Common, model: string, a: Attempt<T>): Promise<ModelResult<T> | { ok: false; skipped: Failure }> {
    const key = readKey(this.opts.home);
    if (!key) return skip('no-key', 'No OpenRouter key is set and no Claude pool could answer (Settings, Models).');
    const budget = this.opts.settings().dailyBudgetUsd;
    if (!(budget > 0)) return skip('off', 'OpenRouter calls are off (the daily budget is 0).');
    if (this.spentTodayUsd() >= budget) return skip('over-budget', `Today's model budget of ${usd(budget)} is spent.`);
    let last: ChatResponse | undefined;
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
      const unreadable = res.ok && value === undefined ? 'unreadable answer' : undefined;
      this.record({
        job,
        feature: p.feature,
        model,
        started,
        ok: res.ok && !unreadable,
        ...(res.ok ? { inputTokens: res.inputTokens, outputTokens: res.outputTokens } : {}),
        ...(res.costUsd !== undefined ? { costUsd: res.costUsd } : {}),
        ...(!res.ok ? { error: res.message } : unreadable ? { error: unreadable } : {}),
      });
      if (res.ok && value !== undefined) return { ok: true, value, model, costUsd: res.costUsd, ...tokensOf(res) };
      last = res;
      if (res.ok || !res.retry) break;
    }
    if (last && !last.ok && last.timedOut) return { ok: false, reason: 'timeout', message: last.message };
    return { ok: false, reason: 'provider', message: last && !last.ok ? last.message : "The model's answer couldn't be read." };
  }

  // One pool route: skipped with no pool or no login with room; else run
  // on a login, and on the next one if that says it's out of room.
  private async viaPool<T>(job: ModelJob, p: Common, model: string, a: Attempt<T>): Promise<ModelResult<T> | { ok: false; skipped: Failure }> {
    if (!this.poolLogins()) {
      const id = this.poolId();
      return skip('no-key', id === null ? 'Small jobs are on no pool.' : `No pool called ${id} has a Claude login.`);
    }
    if (!this.opts.claudePath) return skip('off', 'Pool calls are off in this runner.');
    await this.acquirePool();
    try {
      const tried: string[] = [];
      let title = '';
      for (;;) {
        // Read again each time round: the last call may have used up a login.
        const found = this.poolLogins();
        if (!found) return skip('no-key', 'The pool has no Claude login.');
        title = found.pool.title;
        const id = pickInPool(found.pool, found.accounts, { provider: 'claude', current: this.lastLogin, exclude: tried });
        const account = id ? found.accounts.find((x) => x.id === id) : undefined;
        if (!account) break;
        tried.push(account.id);
        const started = this.opts.clock.now();
        const res: CliResponse = await (this.opts.askCli ?? askCli)({
          claudePath: this.opts.claudePath,
          account,
          model,
          system: a.system,
          user: a.user,
          jsonSchema: a.jsonSchema?.schema,
          cwd: cliDir(this.opts.home),
          timeoutMs: this.opts.poolTimeoutMs ?? POOL_TIMEOUT_MS,
          registry: this.opts.registry,
        });
        const value = res.ok ? a.read(res.text) : undefined;
        const unreadable = res.ok && value === undefined ? 'unreadable answer' : undefined;
        this.record({
          job,
          feature: p.feature,
          model,
          started,
          ok: res.ok && !unreadable,
          accountId: account.id,
          ...(res.ok ? { inputTokens: res.inputTokens, outputTokens: res.outputTokens, notionalUsd: res.notionalUsd } : {}),
          ...(!res.ok ? { error: res.message } : unreadable ? { error: unreadable } : {}),
        });
        if (res.ok && value !== undefined) {
          this.lastLogin = account.id;
          return { ok: true, value, model: `${model} on ${account.id}`, ...tokensOf(res), ...(res.notionalUsd !== undefined ? { notionalUsd: res.notionalUsd } : {}) };
        }
        if (!res.ok && res.limit) {
          this.opts.poolHost?.ranDry(account.id);
          if (this.lastLogin === account.id) this.lastLogin = undefined;
          continue;
        }
        if (!res.ok && res.timedOut) return { ok: false, reason: 'timeout', message: res.message };
        return { ok: false, reason: 'provider', message: res.ok ? "The model's answer couldn't be read." : res.message };
      }
      return skip('no-room', `Every login in ${title || 'the pool'} is out of room.`);
    } finally {
      this.releasePool();
    }
  }

  private record(r: { job: ModelJob; feature: string; model: string; started: number; ok: boolean } & Partial<Omit<UsageLine, 'ts' | 'ms'>>): void {
    const now = this.opts.clock.now();
    const { started, error, ...rest } = r;
    const line: UsageLine = {
      ts: new Date(now).toISOString(),
      ...rest,
      ms: now - started,
      ...(error ? { error: error.slice(0, 300) } : {}),
    };
    for (const k of Object.keys(line) as (keyof UsageLine)[]) if (line[k] === undefined) delete line[k];
    this.ledger.add(line);
    if (!line.ok) this.opts.log.warn('model call failed', { feature: r.feature, job: r.job, model: r.model, accountId: r.accountId, error: line.error });
    const budget = this.opts.settings().dailyBudgetUsd;
    const day = new Date(now).toDateString();
    if (line.costUsd && budget > 0 && this.spentTodayUsd() >= budget && this.overBudgetNoticeDay !== day) {
      this.overBudgetNoticeDay = day;
      this.opts.notice?.('warning', `Today's OpenRouter budget of ${usd(budget)} is spent, so anything only OpenRouter can do waits for tomorrow. Change it in Settings.`);
    }
    this.opts.onSpend?.();
  }

  private acquirePool(): Promise<void> {
    if (this.poolInFlight < POOL_MAX_IN_FLIGHT) {
      this.poolInFlight++;
      return Promise.resolve();
    }
    return new Promise((resolve) => this.poolWaiting.push(resolve));
  }

  private releasePool(): void {
    const next = this.poolWaiting.shift();
    if (next) next();
    else this.poolInFlight--;
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

function skip(reason: ModelFailure, message: string): { ok: false; skipped: Failure } {
  return { ok: false, skipped: { ok: false, reason, message } };
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

function tokensOf(res: { inputTokens?: number; outputTokens?: number }): { tokens?: number } {
  return res.inputTokens === undefined && res.outputTokens === undefined ? {} : { tokens: (res.inputTokens ?? 0) + (res.outputTokens ?? 0) };
}
