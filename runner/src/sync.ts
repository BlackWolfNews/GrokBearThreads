// The Convex mirror (docs/convex-backend.md, shape A): the runner stays the
// source of truth and copies the phone's view of each thread, plus its own
// heartbeat, to the Convex project the phone reads. Written on change and
// coalesced, never per token; best effort, so nothing the Mac app does
// waits on it, and a runner with no internet carries on and writes each
// changed row once when it's back.
//
// Off unless runner.json has a `sync.url` and secrets/convex-key holds the
// key the deployment's RUNNER_KEY was set to (`npx convex env set`).
// THREADBARE_SYNC=off turns it off whatever runner.json says, which
// check.sh sets so no test runner ever writes to the real project.
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import type { Clock, TimerHandle } from './clock.ts';
import type { Logger } from './log.ts';
import type { ThreadSummary } from './protocol.ts';
import type { Notification } from './runner.ts';
import { paths, readRunnerJson, writeRunnerJson } from './config.ts';

// At most one write per thread this often while a turn runs: a running
// thread's preview and working line change many times a second.
export const SYNC_COALESCE_MS = 2000;
export const HEARTBEAT_MS = 60_000;
// Threads per upsert mutation.
export const SYNC_BATCH = 50;
const BACKOFF_MIN_MS = 5000;
const BACKOFF_MAX_MS = 5 * 60_000;
const POST_TIMEOUT_MS = 15_000;
const ALL: ('inbox' | 'snoozed' | 'archived')[] = ['inbox', 'snoozed', 'archived'];

export type SyncConfig = {
  enabled: boolean;
  url?: string;
  name?: string;
  runnerId?: string;
};

// runner.status's `sync` (docs/protocol.md, "Sync").
export type SyncStatus = {
  state: 'off' | 'ok' | 'error';
  reason?: string; // why it's off
  url?: string;
  runnerId?: string;
  name?: string;
  threads?: number; // rows written since start
  lastSyncAt?: string;
  lastError?: string;
  pending?: number; // changes waiting to be written
  retryAt?: string;
};

// The phone's view of a thread: convex/schema.ts's threadFields plus view.
export type ThreadDoc = {
  threadId: string;
  runnerId: string;
  title: string;
  cwd: string;
  accountId: string;
  provider: string;
  model?: string;
  status: string;
  needsYou: boolean;
  unread: boolean;
  preview: string;
  createdAt: string;
  lastActivityAt: string;
  lastActivityMs: number;
  snoozedUntil?: string;
  snoozedUntilRestart?: boolean;
  archivedAt?: string;
  costUsd?: number;
  projects?: { id: string; title: string }[];
  working?: string;
  view: 'inbox' | 'hibernating' | 'den';
};

// One call to the deployment's HTTP API; tests pass a fake.
export type Post = (kind: 'mutation' | 'query', fn: string, args: Record<string, unknown>) => Promise<unknown>;

type Host = {
  onNotification(fn: (n: Notification) => void): () => void;
  list(include: ('inbox' | 'snoozed' | 'archived')[]): ThreadSummary[];
};

export type SyncDeps = {
  config: SyncConfig;
  key?: string;
  runner: Host;
  version: string;
  release?: string;
  startedAt: string;
  clock: Clock;
  log: Logger;
  post?: Post;
};

// POST /api/mutation or /api/query on a Convex deployment, the plain HTTP
// API, so the runner needs no Convex client and a fake is one function.
export function convexPoster(url: string, fetchFn: typeof fetch = fetch): Post {
  const base = url.replace(/\/+$/, '');
  return async (kind, fn, args) => {
    const res = await fetchFn(`${base}/api/${kind}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path: fn, args, format: 'json' }),
      signal: AbortSignal.timeout(POST_TIMEOUT_MS),
    });
    const body = (await res.json().catch(() => undefined)) as { status?: string; value?: unknown; errorMessage?: string } | undefined;
    if (!res.ok || !body || body.status !== 'success') throw new Error(body?.errorMessage ?? `HTTP ${res.status}`);
    return body.value;
  };
}

// The id this runner writes under, made once and kept in runner.json so
// it survives restarts and releases (a data dir is one runner).
export function ensureRunnerId(home: string): string {
  const json = readRunnerJson(home);
  if (json.sync?.runnerId) return json.sync.runnerId;
  const id = crypto.randomBytes(6).toString('hex');
  writeRunnerJson(home, { ...json, sync: { ...json.sync, runnerId: id } });
  return id;
}

export function readSyncKey(home: string): string | undefined {
  try {
    const key = fs.readFileSync(path.join(paths.secrets(home), 'convex-key'), 'utf8').trim();
    return key || undefined;
  } catch {
    return undefined;
  }
}

// "M5" from "M5.local", unless runner.json names the runner.
export function defaultRunnerName(hostname = os.hostname()): string {
  return hostname.replace(/\.local$/i, '') || 'runner';
}

export function toThreadDoc(t: ThreadSummary, runnerId: string, now: number): ThreadDoc {
  const doc: ThreadDoc = {
    threadId: t.id,
    runnerId,
    title: t.title,
    cwd: t.cwd,
    accountId: t.accountId,
    provider: t.provider,
    status: t.status,
    needsYou: t.needsYou,
    unread: t.lastSeq > t.lastSeenSeq,
    preview: t.preview,
    createdAt: t.createdAt,
    lastActivityAt: t.lastActivityAt,
    lastActivityMs: Date.parse(t.lastActivityAt) || 0,
    view: t.archivedAt ? 'den' : t.snoozedUntil && Date.parse(t.snoozedUntil) > now ? 'hibernating' : 'inbox',
  };
  if (t.model) doc.model = t.model;
  if (t.snoozedUntil) doc.snoozedUntil = t.snoozedUntil;
  if (t.snoozedUntilRestart) doc.snoozedUntilRestart = true;
  if (t.archivedAt) doc.archivedAt = t.archivedAt;
  // To the cent: a running thread's cost moves every turn and the phone
  // doesn't need a write for the fourth decimal.
  if (t.costUsd !== undefined) doc.costUsd = Math.round(t.costUsd * 100) / 100;
  if (t.projects?.length) doc.projects = t.projects.map((p) => ({ id: p.id, title: p.title }));
  const working = t.background?.find((b) => !b.finished)?.description;
  if (working) doc.working = working;
  return doc;
}

export class ConvexSync {
  private deps: SyncDeps;
  private post: Post;
  private runnerId: string;
  private name: string;
  private off?: string; // why it isn't running
  private running = false;
  private unsub?: () => void;
  private dirty = new Map<string, ThreadDoc>();
  private removed = new Set<string>();
  private sent = new Map<string, string>(); // threadId -> the doc last written, as JSON
  private flushTimer?: TimerHandle;
  private heartbeatTimer?: TimerHandle;
  private lastFlushAt = -Infinity;
  private flushing = false;
  private full = true; // the first write after start covers everything, then prunes
  private backoffMs = 0;
  private retryAt?: number;
  private lastError?: string;
  private lastLogged?: string;
  private lastSyncAt?: number;
  private written = 0;

  constructor(deps: SyncDeps) {
    this.deps = deps;
    this.runnerId = deps.config.runnerId ?? 'runner';
    this.name = deps.config.name ?? defaultRunnerName();
    const { enabled, url } = deps.config;
    if (!enabled) this.off = 'sync.enabled is false';
    else if (!url) this.off = 'no sync.url in runner.json';
    else if (!deps.key) this.off = 'no secrets/convex-key';
    this.post = deps.post ?? (url ? convexPoster(url) : async () => undefined);
  }

  start(): void {
    if (this.off || this.running) return;
    this.running = true;
    this.unsub = this.deps.runner.onNotification((n) => this.onNotification(n));
    for (const t of this.deps.runner.list(ALL)) this.mark(t);
    this.full = true;
    this.scheduleFlush();
    this.heartbeat();
    this.deps.log.info('convex sync on', { url: this.deps.config.url, runnerId: this.runnerId, name: this.name });
  }

  // A draining runner stops without a word: the new release writes
  // everything again under the same runnerId. A runner stopping for good
  // says bye, so the phone shows it offline now.
  async stop(opts: { bye?: boolean } = {}): Promise<void> {
    if (!this.running) return;
    this.running = false;
    this.unsub?.();
    this.flushTimer?.cancel();
    this.heartbeatTimer?.cancel();
    this.flushTimer = undefined;
    this.heartbeatTimer = undefined;
    if (opts.bye) await this.post('mutation', 'sync:bye', { key: this.deps.key, runnerId: this.runnerId }).catch(() => {});
  }

  status(): SyncStatus {
    if (this.off) return { state: 'off', reason: this.off };
    const s: SyncStatus = {
      state: this.lastError && this.retryAt !== undefined ? 'error' : 'ok',
      url: this.deps.config.url,
      runnerId: this.runnerId,
      name: this.name,
      threads: this.written,
      pending: this.dirty.size + this.removed.size,
    };
    if (this.lastSyncAt !== undefined) s.lastSyncAt = new Date(this.lastSyncAt).toISOString();
    if (this.lastError) s.lastError = this.lastError;
    if (this.retryAt !== undefined) s.retryAt = new Date(this.retryAt).toISOString();
    return s;
  }

  // Writes whatever is waiting now, however recent the last write; tests
  // and a stop that wants the last state out use it.
  async flushNow(): Promise<void> {
    this.flushTimer?.cancel();
    this.flushTimer = undefined;
    this.lastFlushAt = -Infinity;
    this.retryAt = undefined;
    await this.flush();
  }

  private onNotification(n: Notification): void {
    if (n.method === 'thread.updated') {
      this.mark(n.params.thread);
      this.scheduleFlush();
    } else if (n.method === 'thread.deleted') {
      const id = n.params.threadId;
      this.dirty.delete(id);
      this.sent.delete(id);
      this.removed.add(id);
      this.scheduleFlush();
    }
  }

  // Only a change the phone would see makes a write.
  private mark(t: ThreadSummary): void {
    const doc = toThreadDoc(t, this.runnerId, this.deps.clock.now());
    if (this.sent.get(t.id) === JSON.stringify(doc)) {
      this.dirty.delete(t.id);
      return;
    }
    this.dirty.set(t.id, doc);
  }

  private scheduleFlush(): void {
    if (!this.running || this.flushTimer) return;
    if (!this.dirty.size && !this.removed.size && !this.full) return;
    const now = this.deps.clock.now();
    let delay = Math.max(0, this.lastFlushAt + SYNC_COALESCE_MS - now);
    if (this.retryAt !== undefined) delay = Math.max(delay, this.retryAt - now);
    this.flushTimer = this.deps.clock.setTimeout(() => {
      this.flushTimer = undefined;
      void this.flush();
    }, delay);
  }

  private async flush(): Promise<void> {
    if (this.flushing || !this.running) return;
    this.flushing = true;
    this.lastFlushAt = this.deps.clock.now();
    const docs = [...this.dirty.values()];
    const removed = [...this.removed];
    this.dirty.clear();
    this.removed.clear();
    const key = this.deps.key;
    try {
      for (let i = 0; i < docs.length; i += SYNC_BATCH) {
        const batch = docs.slice(i, i + SYNC_BATCH);
        await this.post('mutation', 'sync:upsertThreads', { key, threads: batch });
        for (const d of batch) this.sent.set(d.threadId, JSON.stringify(d));
        this.written += batch.length;
      }
      if (removed.length) await this.post('mutation', 'sync:removeThreads', { key, threadIds: removed });
      if (this.full) {
        const keep = this.deps.runner.list(ALL).map((t) => t.id);
        await this.post('mutation', 'sync:prune', { key, runnerId: this.runnerId, keep });
        this.full = false;
      }
      this.lastSyncAt = this.deps.clock.now();
      this.backoffMs = 0;
      this.retryAt = undefined;
      if (this.lastError) {
        this.deps.log.info('convex sync is back', { url: this.deps.config.url });
        this.lastError = undefined;
        this.lastLogged = undefined;
      }
    } catch (e) {
      // Put back what didn't get written, unless a newer version arrived
      // meanwhile, and try again later; one log line per distinct error.
      for (const d of docs) if (!this.dirty.has(d.threadId) && this.sent.get(d.threadId) !== JSON.stringify(d)) this.dirty.set(d.threadId, d);
      for (const id of removed) this.removed.add(id);
      this.backoffMs = this.backoffMs ? Math.min(this.backoffMs * 2, BACKOFF_MAX_MS) : BACKOFF_MIN_MS;
      this.retryAt = this.deps.clock.now() + this.backoffMs;
      this.lastError = String((e as Error)?.message ?? e);
      if (this.lastError !== this.lastLogged) {
        this.lastLogged = this.lastError;
        this.deps.log.warn('convex sync failed; will retry', { error: this.lastError, pending: this.dirty.size + this.removed.size, retryInMs: this.backoffMs });
      }
    } finally {
      this.flushing = false;
    }
    this.scheduleFlush();
  }

  private heartbeat(): void {
    if (!this.running) return;
    const runner = {
      runnerId: this.runnerId,
      name: this.name,
      version: this.deps.version,
      ...(this.deps.release ? { release: this.deps.release } : {}),
      startedAt: this.deps.startedAt,
      draining: false,
      threadCount: this.deps.runner.list(ALL).length,
    };
    void this.post('mutation', 'sync:heartbeat', { key: this.deps.key, runner }).catch((e) => {
      this.deps.log.debug('convex heartbeat failed', { error: String(e) });
    });
    this.heartbeatTimer = this.deps.clock.setTimeout(() => this.heartbeat(), HEARTBEAT_MS);
  }
}
