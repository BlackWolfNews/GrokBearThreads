// The sidebar table (step 6 part 2, docs/step6-plan.md): this runner's
// threads as small `threadIndex` rows in the backend, and the other
// runners' rows watched live and handed to the Mac app as
// `remoteThreads.updated`, so the app lists every runner's threads and only
// talks to another runner while one of its threads is open. Runners never
// talk to each other; the backend is between them.
//
// A row is written only when something a sidebar row shows changes. The
// preview line and the last activity time go up with it but never cause a
// write by themselves: they move all through a turn, and a write is what
// re-runs every watching query.
import fs from 'node:fs';
import path from 'node:path';
import type { Clock, TimerHandle } from './clock.ts';
import type { Logger } from './log.ts';
import type { ThreadSummary } from './protocol.ts';
import type { Notification } from './runner.ts';
import type { Post, Subscribe } from './sync.ts';

export type IndexRow = {
  threadId: string;
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
  snoozedUntil?: string;
  archivedAt?: string;
  startedBy?: { kind: string; label: string; icon?: string; threadTitle?: string; why?: string };
};

// What the Mac app gets (docs/protocol.md, "Other runners' threads").
export type RemoteRunner = { id: string; name: string; icon?: string; online: boolean; lastSeenAt: string; rpcUrl?: string; tokenFile?: string };
export type RemoteThread = IndexRow & { runnerId: string };
export type RemoteThreads = { runners: RemoteRunner[]; threads: RemoteThread[] };

const FLUSH_MS = 1000;
const BATCH = 50;
// As on the phone: not heard from for this long is offline.
const ONLINE_MS = 3 * 60_000;

export function toIndexRow(t: ThreadSummary, withStartedBy = true): IndexRow {
  const row: IndexRow = {
    threadId: t.id,
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
  };
  if (t.model) row.model = t.model;
  if (t.snoozedUntil) row.snoozedUntil = t.snoozedUntil;
  if (t.archivedAt) row.archivedAt = t.archivedAt;
  if (withStartedBy && t.startedBy) {
    // Not the thread's id: only the row's tooltip uses this, by that title.
    const { kind, label, icon, threadTitle, why } = t.startedBy;
    row.startedBy = { kind, label, ...(icon ? { icon } : {}), ...(threadTitle ? { threadTitle } : {}), ...(why ? { why } : {}) };
  }
  return row;
}

// The part of a row that decides whether it's written.
function writeKey(r: IndexRow): string {
  const { preview: _p, lastActivityAt: _l, ...rest } = r;
  return JSON.stringify(rest);
}

// Where another runner's token goes on this Mac, copied in once, so the app
// can open its threads (`tokenFile` on RemoteRunner).
export function runnerTokenFile(home: string, runnerId: string): string {
  return path.join(home, 'secrets', 'runners', `${runnerId}.token`);
}

export class ThreadIndex {
  private deps: {
    post: Post;
    subscribe?: Subscribe;
    key?: string;
    runnerId: string;
    home: string;
    host: { list(include: ('inbox' | 'snoozed' | 'archived')[]): ThreadSummary[]; onNotification(fn: (n: Notification) => void): () => void };
    publish?: (n: Notification) => void;
    clock: Clock;
    log: Logger;
    // Whether the backend's validator knows startedBy (API 23). It would turn
    // the whole batch down otherwise, and the sidebar would stop updating.
    takesStartedBy?: () => boolean;
  };
  private running = false;
  private sent = new Map<string, string>(); // threadId -> writeKey as sent
  private dirty = new Map<string, IndexRow>();
  private removed = new Set<string>();
  private full = true;
  private timer?: TimerHandle;
  private flushing = false;
  private unlisten?: () => void;
  private unsubscribe?: () => void;
  private remote: RemoteThreads = { runners: [], threads: [] };

  constructor(deps: ThreadIndex['deps']) {
    this.deps = deps;
  }

  /** Once a heartbeat says the backend has the table (API 12). */
  start(): void {
    if (this.running) return;
    this.running = true;
    this.full = true;
    for (const t of this.deps.host.list(['inbox', 'snoozed', 'archived'])) this.mark(t);
    this.unlisten = this.deps.host.onNotification((n) => {
      if (n.method === 'thread.updated') this.mark(n.params.thread);
      else if (n.method === 'thread.deleted') {
        this.dirty.delete(n.params.threadId);
        this.sent.delete(n.params.threadId);
        this.removed.add(n.params.threadId);
      } else return;
      this.schedule();
    });
    this.schedule(0);
    this.unsubscribe = this.deps.subscribe?.(
      'sync:otherRunnersThreads',
      { key: this.deps.key, runnerId: this.deps.runnerId },
      (v) => this.onRemote(v),
      (e) => this.deps.log.warn('the other runners’ threads subscription failed', { error: String(e) }),
    );
    this.deps.log.info('thread index on', { threads: this.dirty.size });
  }

  stop(): void {
    this.running = false;
    this.timer?.cancel();
    this.timer = undefined;
    this.unlisten?.();
    this.unsubscribe?.();
    this.unsubscribe = undefined;
  }

  /** remoteThreads.list. Empty until the backend has answered. */
  list(): RemoteThreads {
    return this.withTokens(this.remote);
  }

  /** The backend got new enough for what rows held back: they go again. */
  refresh(): void {
    if (!this.running) return;
    for (const t of this.deps.host.list(['inbox', 'snoozed', 'archived'])) this.mark(t);
    this.schedule();
  }

  private mark(t: ThreadSummary): void {
    const row = toIndexRow(t, this.deps.takesStartedBy?.() ?? true);
    if (this.sent.get(t.id) === writeKey(row)) {
      this.dirty.delete(t.id);
      return;
    }
    this.removed.delete(t.id);
    this.dirty.set(t.id, row);
  }

  private schedule(ms = FLUSH_MS): void {
    if (!this.running || this.timer) return;
    this.timer = this.deps.clock.setTimeout(() => {
      this.timer = undefined;
      void this.flush();
    }, ms);
  }

  private async flush(): Promise<void> {
    if (!this.running || this.flushing) return;
    if (!this.dirty.size && !this.removed.size && !this.full) return;
    this.flushing = true;
    const rows = [...this.dirty.values()];
    const removed = [...this.removed];
    const full = this.full;
    this.dirty.clear();
    this.removed.clear();
    try {
      const keep = full ? this.deps.host.list(['inbox', 'snoozed', 'archived']).map((t) => t.id) : undefined;
      for (let i = 0; i < Math.max(rows.length, 1); i += BATCH) {
        const batch = rows.slice(i, i + BATCH);
        const last = i + BATCH >= rows.length;
        await this.deps.post('mutation', 'sync:setThreadIndex', {
          key: this.deps.key,
          runnerId: this.deps.runnerId,
          rows: batch,
          removed: last ? removed : [],
          ...(last && keep ? { keep } : {}),
        });
        for (const r of batch) this.sent.set(r.threadId, writeKey(r));
      }
      this.full = false;
    } catch (e) {
      // Put back what didn't go, unless something newer is waiting.
      for (const r of rows) if (!this.dirty.has(r.threadId) && this.sent.get(r.threadId) !== writeKey(r)) this.dirty.set(r.threadId, r);
      for (const id of removed) this.removed.add(id);
      this.deps.log.warn('could not write the thread index; trying again', { error: String(e) });
      this.flushing = false;
      this.schedule(15_000);
      return;
    }
    this.flushing = false;
    if (this.dirty.size || this.removed.size) this.schedule();
  }

  private onRemote(v: unknown): void {
    const value = v as { runners?: { runnerId: string; name: string; icon?: string; lastSeenAt: number; rpcUrl?: string }[]; threads?: RemoteThread[] } | null;
    const now = this.deps.clock.now();
    this.remote = {
      runners: (value?.runners ?? [])
        .filter((r) => r.lastSeenAt > 0 || (value?.threads ?? []).some((t) => t.runnerId === r.runnerId))
        .map((r) => ({
          id: r.runnerId,
          name: r.name,
          ...(r.icon ? { icon: r.icon } : {}),
          online: now - r.lastSeenAt < ONLINE_MS,
          lastSeenAt: new Date(r.lastSeenAt).toISOString(),
          ...(r.rpcUrl ? { rpcUrl: r.rpcUrl } : {}),
        })),
      threads: value?.threads ?? [],
    };
    this.deps.publish?.({ method: 'remoteThreads.updated', params: this.withTokens(this.remote) });
  }

  // The token file is named only when it's there: no file, no way in.
  private withTokens(r: RemoteThreads): RemoteThreads {
    return {
      threads: r.threads,
      runners: r.runners.map((x) => {
        const file = runnerTokenFile(this.deps.home, x.id);
        return fs.existsSync(file) ? { ...x, tokenFile: file } : x;
      }),
    };
  }
}
