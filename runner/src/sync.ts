// The Convex mirror (docs/convex-backend.md, shape A): the runner stays the
// source of truth and copies the phone's view of each thread, the last few
// text messages, its projects, schedules and accounts, plus its own
// heartbeat, to the Convex project the phone reads; and it applies what
// the phone asks for (the `commands` table) through the same methods the
// Mac app uses. Written on change and coalesced, never per token; best
// effort, so nothing the Mac app does waits on it, and a runner with no
// internet carries on and writes each changed row once when it's back.
//
// Off unless runner.json has a `sync.url` and secrets/convex-key holds the
// key the deployment's RUNNER_KEY was set to (`npx convex env set`).
// THREADBEAR_SYNC=off turns it off whatever runner.json says, which
// check.sh sets so no test runner ever writes to the real project.
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { ConvexClient } from 'convex/browser';
import { phonePicture } from './project-icons.ts';
import { imagesInEvent, readShareImage, type ShareImage } from './share-images.ts';
import { makeFunctionReference } from 'convex/server';
import type { Clock, TimerHandle } from './clock.ts';
import type { Logger } from './log.ts';
import { ErrorCode } from './protocol.ts';
import type { Account, ApprovalDecision, ApprovalOption, AskAnswer, OpenAsk, PersistedEvent, Project, Question, Schedule, ThreadSummary } from './protocol.ts';
import type { Notification } from './runner.ts';
import type { ScheduleBackend, StoredSchedule } from './schedules.ts';
import { ThreadIndex, type RemoteThreads } from './thread-index.ts';
import { paths, readRunnerJson, writeRunnerJson } from './config.ts';

// At most one write per thread this often while a turn runs: a running
// thread's preview and working line change many times a second.
export const SYNC_COALESCE_MS = 2000;
export const HEARTBEAT_MS = 60_000;
// Threads per upsert mutation, and messages per append.
export const SYNC_BATCH = 50;
export const MESSAGE_BATCH = 100;
// A message longer than this is cut on the phone; the Mac has it all.
export const MESSAGE_CHARS = 8000;
// Older messages per "Load earlier messages" on the phone.
export const PAGE_SIZE = 50;
// How many events are read back for a page or the first text message.
const PAGE_EVENTS = 2000;
// Events read at a time when backfilling a thread's history.
const BACKFILL_EVENTS = 5000;
// How often presence is checked. A push is decided with whatever the backend
// last heard, so this is how late "away" can be.
export const PRESENCE_MS = 15_000;
const BACKOFF_MIN_MS = 5000;
const BACKOFF_MAX_MS = 5 * 60_000;
const POST_TIMEOUT_MS = 15_000;
const ALL: ('inbox' | 'snoozed' | 'archived')[] = ['inbox', 'snoozed', 'archived'];

export type SyncConfig = {
  enabled: boolean;
  url?: string;
  name?: string;
  runnerId?: string;
  icon?: string;
  rpcUrl?: string;
};

// runner.status's `sync` (docs/protocol.md, "Sync").
// The backend API version this runner was built for (convex/version.ts; a unit
// test keeps them equal). sync:heartbeat answers with the backend's, and a
// lower one means its backend hasn't been deployed since this runner was:
// said in runner.status, tb status and the log rather than stopping, since
// the runner only adds to what it sends while the number stays the same.
export const BACKEND_API_VERSION = 14;
// From this one a thread's row carries its open card of asks and a finished
// turn's next steps, and a message row can be `summary` (end_turn's
// bullets), so the phone shows end-of-turn cards. An older backend's
// validators would turn the write down, so it gets them without.
export const ASKS_API_VERSION = 14;
// From this backend version a project's picture goes up to file storage
// (sync:iconUploadUrl, sync:setProjectIcon); an older backend gets the
// project without it and the phone shows its symbol or first letter.
export const ICONS_API_VERSION = 5;
// From this one a thread's row carries `share` ("off" included) and a shared
// thread's pictures go to file storage (docs/website.md, "Sharing"). An
// older backend's validator would turn the whole write down, so it gets
// the row without it, and the link doesn't work until it's deployed.
export const SHARE_API_VERSION = 8;
// From this one schedules live in the backend (step 6; docs/protocol.md,
// Schedules, "Runners"): the scheduler is attached once a heartbeat says
// so, and from then on writes them there itself, so they aren't mirrored.
export const SCHEDULES_API_VERSION = 9;
// From this one the heartbeat carries the runner's icon (machine.ts); an
// older backend's validator would turn the heartbeat down.
export const RUNNER_ICON_API_VERSION = 11;
// From this one there's the sidebar table (thread-index.ts) and the
// heartbeat carries rpcUrl (step 6 part 2).
export const THREAD_INDEX_API_VERSION = 12;
// From this one a thread's row carries `woke` (back from hibernating, not
// opened yet), for the phone's "Woke up". An older backend's validator
// would turn the row down, so it goes without.
export const WOKE_API_VERSION = 13;

export type SyncStatus = {
  state: 'off' | 'ok' | 'error';
  reason?: string; // why it's off
  url?: string;
  runnerId?: string;
  name?: string;
  threads?: number; // rows written since start
  messages?: number; // likewise
  lastSyncAt?: string;
  lastError?: string;
  pending?: number; // changes waiting to be written
  retryAt?: string;
  // The phone's commands: whether the runner is listening for them, how
  // many it has applied since start, and the last one that failed.
  commands?: { state: 'off' | 'on' | 'error'; applied: number; failed: number; lastError?: string };
  // The backend's API version from the last heartbeat (0 for a backend from
  // before there was one), and the one this runner expects.
  backend?: { apiVersion: number; expected: number };
};

// The approval or question a thread is waiting on, as the phone sees it.
export type PendingApproval =
  | { approvalId: string; kind: 'approval'; name: string; title: string; options: ApprovalOption[]; inputSummary?: string }
  | { approvalId: string; kind: 'question'; questions: Question[] };

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
  woke?: { at: string; since?: string };
  archivedAt?: string;
  costUsd?: number;
  projects?: { id: string; title: string }[];
  working?: string;
  pendingApproval?: PendingApproval;
  earliestSeq?: number;
  share?: { access: 'off' | 'link'; slug: string };
  asks?: PhoneAsk[];
  asksSeq?: number;
  next?: string[];
  view: 'inbox' | 'hibernating' | 'den';
};

// An open ask as the phone sees it (convex/schema.ts): no `where`, which the
// paragraph already says, and only web links, as a file on the Mac can't
// be opened from the phone.
export type PhoneAsk = { action: string; why?: string; reply?: string; options?: string[]; suggested?: number; links?: { title: string; url: string }[]; ticked?: boolean };

// A text message, or one line for a tool call (role "tool", since backend
// API 2): what the phone and the website show of a thread.
export type MessageDoc = { threadId: string; seq: number; role: 'user' | 'assistant' | 'tool'; text: string; origin?: string; toolKind?: string; summary?: true; at: string; pagedAt?: number };

// One call to the deployment's HTTP API; tests pass a fake.
export type Post = (kind: 'mutation' | 'query', fn: string, args: Record<string, unknown>) => Promise<unknown>;

// A live query on the deployment (the commands the phone has queued):
// `onUpdate` is called with each new result, `onError` when the
// subscription fails. Returns the unsubscribe. Tests pass a fake.
export type Subscribe = (fn: string, args: Record<string, unknown>, onUpdate: (value: unknown) => void, onError: (error: Error) => void) => () => void;
export type Subscriber = { subscribe: Subscribe; close(): Promise<void> | void };
// Puts a picture's bytes at the upload URL the backend gave (file storage)
// and returns its storage id. Tests pass a fake.
export type Upload = (url: string, bytes: Uint8Array, mediaType: string) => Promise<string>;

// A phone or browser that holds a phone token (docs/protocol.md "Devices"),
// as the backend lists them (convex/tokens.ts tokenInfo).
export const DEVICE_KINDS = ['phone', 'browser'] as const;
export type DeviceKind = (typeof DEVICE_KINDS)[number];
export type Device = { id: string; kind: DeviceKind; name: string; createdAt: string; expiresAt: string; expired: boolean };

// A command the phone queued (convex/schema.ts `commands`).
export type Command = { commandId: string; kind: string; threadId?: string; args: Record<string, unknown>; createdAt: number };

type Host = {
  onNotification(fn: (n: Notification) => void): () => void;
  list(include: ('inbox' | 'snoozed' | 'archived')[]): ThreadSummary[];
  get(threadId: string): ThreadSummary;
  events(threadId: string, opts: { afterSeq?: number; beforeSeq?: number; limit?: number }): { events: PersistedEvent[] };
  // The seq ranges edits cut out of a thread (docs/protocol.md, "Editing a
  // message"), never sent up. Absent in small tests.
  cuts?: (threadId: string) => { from: number; to: number }[];
  // The lists mirrored beside the threads; absent in small tests.
  listProjects?: () => Project[];
  listSchedules?: () => Schedule[];
  listAccounts?: () => Account[];
};

// What the phone's commands are applied through: the runner's own
// methods, so a phone message or approval is the same as one from the
// Mac app (docs/protocol.md, "Sync").
// A thread's commands may go on to a draining runner (handover.ts's
// phoneCommands), so they can answer later; apply() waits for each.
export type CommandHost = {
  send(threadId: string, text: string, images: never[], opts: { origin: 'phone'; answers?: AskAnswer[] }): unknown;
  respondApproval(p: { threadId: string; approvalId: string; decision: ApprovalDecision; message?: string; answers?: Record<string, string> }): unknown;
  update(p: { threadId: string; title?: string; snoozedUntil?: string | null; archived?: boolean }): unknown;
  // Seen up to the last event it has.
  markSeen(threadId: string): unknown;
  create(p: { text: string; cwd?: string; accountId?: string; model?: string; origin: 'phone' }): { thread: ThreadSummary };
  share(threadId: string, p: { access: 'off' | 'link'; newLink?: boolean }): unknown;
  quickAsk(p: { question: string; answer: string; sources?: { title: string; url: string }[]; askedAt?: number }): { thread: ThreadSummary };
};

export type SyncDeps = {
  config: SyncConfig;
  key?: string;
  // Whether Mike is at this Mac (presence.ts), checked every PRESENCE_MS and
  // sent to the backend when it changes, so his phone only buzzes while he's
  // away. Left out, presence isn't sent.
  presence?: () => boolean | Promise<boolean>;
  // Where the sync keeps what it has sent once and for all (the full history
  // backfill), per deployment. Tests leave it out and get a backfill each start.
  statePath?: string;
  runner: Host;
  commands?: CommandHost;
  version: string;
  release?: string;
  startedAt: string;
  clock: Clock;
  log: Logger;
  post?: Post;
  subscriber?: Subscriber;
  upload?: Upload;
  // The scheduler (schedules.ts), given the backend's schedules table once
  // a heartbeat says it has one; while inBackend(), schedules.updated isn't
  // mirrored. Absent in small tests.
  schedules?: { attach(backend: ScheduleBackend): void | Promise<void>; inBackend(): boolean };
  // For the sidebar table (thread-index.ts): telling the app about other
  // runners' threads, and the data dir their tokens are copied into.
  publish?: (n: Notification) => void;
  home?: string;
};

// POST /api/mutation or /api/query on a Convex deployment, the plain HTTP
// API, so a write needs no client and a fake is one function.
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

// File storage's upload URL takes a plain POST of the bytes and answers
// `{ storageId }`.
export function convexUploader(fetchFn: typeof fetch = fetch): Upload {
  return async (url, bytes, mediaType) => {
    const res = await fetchFn(url, { method: 'POST', headers: { 'Content-Type': mediaType }, body: bytes, signal: AbortSignal.timeout(POST_TIMEOUT_MS) });
    const body = (await res.json().catch(() => undefined)) as { storageId?: unknown } | undefined;
    if (!res.ok || typeof body?.storageId !== 'string') throw new Error(`icon upload failed: HTTP ${res.status}`);
    return body.storageId;
  };
}

// The Convex client's WebSocket subscription, for the phone's commands:
// it reconnects by itself and re-runs the query whenever a row changes.
export function convexSubscriber(url: string): Subscriber {
  let client: ConvexClient | undefined;
  return {
    subscribe: (fn, args, onUpdate, onError) => {
      client ??= new ConvexClient(url, { unsavedChangesWarning: false });
      return client.onUpdate(makeFunctionReference<'query'>(fn), args, onUpdate, onError);
    },
    close: async () => {
      const c = client;
      client = undefined;
      await c?.close();
    },
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

// "M5" from "M5.local" or "m5.localdomain", unless runner.json names the
// runner.
export function defaultRunnerName(hostname = os.hostname()): string {
  return hostname.replace(/\.(local|localdomain|lan|home)$/i, '') || 'runner';
}

export function toThreadDoc(t: ThreadSummary, runnerId: string, now: number, pending?: PendingApproval, earliestSeq?: number, next?: string[]): ThreadDoc {
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
  if (t.woke) doc.woke = { ...t.woke };
  if (t.archivedAt) doc.archivedAt = t.archivedAt;
  // To the cent: a running thread's cost moves every turn and the phone
  // doesn't need a write for the fourth decimal.
  if (t.costUsd !== undefined) doc.costUsd = Math.round(t.costUsd * 100) / 100;
  if (t.projects?.length) doc.projects = t.projects.map((p) => ({ id: p.id, title: p.title }));
  const working = t.background?.find((b) => !b.finished)?.description;
  if (working) doc.working = working;
  if (pending) doc.pendingApproval = pending;
  if (earliestSeq !== undefined) doc.earliestSeq = earliestSeq;
  // "off" goes up too, so Mike's own page for the link can offer Share again.
  if (t.share) doc.share = { access: t.share.access, slug: t.share.slug };
  if (t.asks?.length && t.asksSeq !== undefined) {
    doc.asks = t.asks.map(toPhoneAsk);
    doc.asksSeq = t.asksSeq;
  }
  if (next?.length) doc.next = next;
  return doc;
}

export function toPhoneAsk(a: OpenAsk): PhoneAsk {
  const out: PhoneAsk = { action: a.action };
  if (a.why) out.why = a.why;
  if (a.reply) out.reply = a.reply;
  if (a.options?.length) {
    out.options = a.options;
    if (a.suggested !== undefined) out.suggested = a.suggested;
  }
  const links = a.links?.filter((l) => /^https?:\/\//i.test(l.url));
  if (links?.length) out.links = links.map((l) => ({ title: l.title, url: l.url }));
  if (a.ticked) out.ticked = true;
  return out;
}

// A phone send's `answers`, kept only when well formed.
function phoneAnswers(raw: unknown): AskAnswer[] | undefined {
  if (!Array.isArray(raw)) return undefined;
  const out = raw.filter((x): x is AskAnswer => !!x && typeof x.action === 'string' && typeof x.answer === 'string').map((x) => ({ action: x.action, answer: x.answer }));
  return out.length ? out : undefined;
}

// The row as a backend of version v takes it: without the fields its
// validator doesn't know yet.
function forBackend(d: ThreadDoc, v: number): ThreadDoc {
  const asks = d.asks !== undefined || d.asksSeq !== undefined || d.next !== undefined;
  if ((v >= SHARE_API_VERSION || !d.share) && (v >= WOKE_API_VERSION || !d.woke) && (v >= ASKS_API_VERSION || !asks)) return d;
  const out = { ...d };
  if (v < SHARE_API_VERSION) delete out.share;
  if (v < WOKE_API_VERSION) delete out.woke;
  if (v < ASKS_API_VERSION) {
    delete out.asks;
    delete out.asksSeq;
    delete out.next;
  }
  return out;
}

// A persisted user.message or assistant.text as a message row; anything
// else is undefined.
export function toMessageDoc(threadId: string, e: PersistedEvent): MessageDoc | undefined {
  if (e.type === 'tool.call') return { threadId, seq: e.seq, role: 'tool', text: toolLine(e), toolKind: e.kind, at: e.ts };
  if (e.type !== 'user.message' && e.type !== 'assistant.text') return undefined;
  const text = e.text.length > MESSAGE_CHARS ? e.text.slice(0, MESSAGE_CHARS) + '\n\n[cut: the rest is on the Mac]' : e.text;
  const doc: MessageDoc = { threadId, seq: e.seq, role: e.type === 'user.message' ? 'user' : 'assistant', text, at: e.ts };
  if (e.type === 'user.message' && e.origin) doc.origin = e.origin;
  if (e.type === 'assistant.text' && e.summary) doc.summary = true;
  return doc;
}

// A tool call in one line, for the phone and the website (the output stays
// on the Mac): the agent's own description of a command when it gave one
// ("Run the full check suite"), what was read, edited or searched, else the
// call's title. Never the whole input.
export function toolLine(e: { name: string; kind: string; title: string; input: Record<string, unknown> }): string {
  const str = (k: string) => (typeof e.input[k] === 'string' && (e.input[k] as string).trim() ? oneLine(e.input[k] as string) : undefined);
  const file = str('file_path') ?? str('path') ?? str('notebook_path');
  const short = (p: string) => p.replace(/^\/Users\/[^/]+/, '~');
  switch (e.kind) {
    case 'command':
      return str('description') ?? `Ran ${oneLine(e.title || str('command') || e.name)}`;
    case 'read':
      return file ? `Read ${short(file)}` : oneLine(e.title || e.name);
    case 'edit':
      return file ? `Edited ${short(file)}` : oneLine(e.title || e.name);
    case 'write':
      return file ? `Wrote ${short(file)}` : oneLine(e.title || e.name);
    case 'search':
      return str('pattern') ? `Searched for ${str('pattern')}` : oneLine(e.title || e.name);
    case 'web':
      return str('url') ? `Fetched ${str('url')}` : str('query') ? `Searched the web for ${str('query')}` : oneLine(e.title || e.name);
    case 'task':
      return str('description') ?? oneLine(e.title || e.name);
    default:
      return oneLine(e.title || e.name);
  }
}

// One line of a tool's input for the approval card: the command, the
// path, or the first short string in it. Never the whole input.
export function inputSummary(input: Record<string, unknown>): string | undefined {
  for (const k of ['command', 'file_path', 'path', 'url', 'pattern', 'query']) {
    const v = input[k];
    if (typeof v === 'string' && v.trim()) return oneLine(v);
  }
  for (const v of Object.values(input)) if (typeof v === 'string' && v.trim()) return oneLine(v);
  return undefined;
}

function oneLine(s: string): string {
  const line = s.trim().split('\n')[0]!.trim();
  return line.length > 200 ? line.slice(0, 199) + '…' : line;
}

export function toProjectDoc(p: Project) {
  return {
    id: p.id,
    title: p.title,
    folders: p.folders,
    goals: p.goals,
    state: p.state,
    notes: p.notes,
    createdBy: p.createdBy,
    archived: Boolean(p.archived),
    createdAt: p.createdAt,
    updatedAt: p.updatedAt,
    threadCount: p.threadCount,
    ...(p.lastActivityAt ? { lastActivityAt: p.lastActivityAt } : {}),
    ...(p.icon ? { icon: { ...(p.icon.symbol ? { symbol: p.icon.symbol } : {}), ...(p.icon.image ? { picture: pictureName(p.icon.image.path) } : {}), by: p.icon.by } } : {}),
  };
}

// What a project's picture is called in the mirror: the runner's copy's
// file name without its extension (`<projectId>-<hash>`), so a changed
// picture is a new name and the same one is never sent twice.
export function pictureName(iconPath: string): string {
  const base = path.basename(iconPath);
  const dot = base.lastIndexOf('.');
  return dot > 0 ? base.slice(0, dot) : base;
}

export function toScheduleDoc(s: Schedule) {
  const out: Record<string, unknown> = {
    id: s.id,
    title: s.title,
    text: s.text,
    whenText: s.whenText,
    paused: s.paused,
    createdAt: s.createdAt,
    updatedAt: s.updatedAt,
    runs: s.runs,
  };
  for (const k of ['at', 'cron', 'timezone', 'threadId', 'cwd', 'accountId', 'model', 'nextRunAt', 'finishedAt'] as const) if (s[k] !== undefined) out[k] = s[k];
  if (s.lastRun) {
    out.lastRun = { at: s.lastRun.at, outcome: s.lastRun.outcome, ...(s.lastRun.threadId ? { threadId: s.lastRun.threadId } : {}), ...(s.lastRun.note ? { note: s.lastRun.note } : {}) };
  }
  return out;
}

// A schedule as sync:saveSchedule and sync:adoptSchedules take it: the
// validator's fields only.
export function toOwnedScheduleDoc(s: StoredSchedule) {
  const out: Record<string, unknown> = {
    id: s.id,
    runnerId: s.runnerId,
    title: s.title,
    text: s.text,
    whenText: s.whenText,
    paused: s.paused,
    createdAt: s.createdAt,
    updatedAt: s.updatedAt,
    runs: s.runs,
  };
  for (const k of ['at', 'cron', 'timezone', 'threadId', 'cwd', 'accountId', 'model', 'effort', 'permissionMode', 'createdBy', 'nextRunAt', 'finishedAt', 'runRequestedAt'] as const) {
    if (s[k] !== undefined) out[k] = s[k];
  }
  if (s.lastRun) {
    out.lastRun = { at: s.lastRun.at, outcome: s.lastRun.outcome, ...(s.lastRun.threadId ? { threadId: s.lastRun.threadId } : {}), ...(s.lastRun.note ? { note: s.lastRun.note } : {}) };
  }
  return out;
}

export function toAccountDoc(a: Account) {
  const out: Record<string, unknown> = { id: a.id, provider: a.provider, title: a.title };
  for (const k of ['note', 'email', 'plan', 'defaultModel'] as const) if (a[k] !== undefined) out[k] = a[k];
  if (a.usage) {
    const u = a.usage;
    out.usage = {
      windows: u.windows.map((w) => ({ kind: w.kind, title: w.title, remainingPercent: w.remainingPercent, ...(w.resetsAt ? { resetsAt: w.resetsAt } : {}), ...(w.detail ? { detail: w.detail } : {}) })),
      readAt: u.readAt,
      source: u.source,
      ...(u.stale ? { stale: true } : {}),
      ...(u.blocked ? { blocked: true } : {}),
      ...(u.notice ? { notice: u.notice } : {}),
    };
  }
  return out;
}

type ListName = 'projects' | 'schedules' | 'accounts';

export class ConvexSync {
  private deps: SyncDeps;
  private post: Post;
  private upload: Upload;
  private subscriber?: Subscriber;
  private runnerId: string;
  private name: string;
  private off?: string; // why it isn't running
  private running = false;
  private unsub?: () => void;
  private dirty = new Map<string, ThreadDoc>();
  private removed = new Set<string>();
  private sent = new Map<string, string>(); // threadId -> the doc last written, as JSON
  private messages: MessageDoc[] = [];
  private pending = new Map<string, PendingApproval>(); // threadId -> what it waits on
  private earliest = new Map<string, number | null>(); // threadId -> seq of its first text message (null: none yet)
  private nexts = new Map<string, { lastSeq: number; next?: string[] }>(); // threadId -> its done card's next steps, as of lastSeq
  private lists: { projects?: Project[]; schedules?: Schedule[]; accounts?: Account[] } = {};
  private dirtyLists = new Set<ListName>();
  // Project pictures (ICONS_API_VERSION): what the mirror has, projectId ->
  // picture name, read from it once; and whether the list has changed since
  // the pictures were last looked at.
  private pictures?: Map<string, string>;
  private picturesDue = true;
  // Shared threads' pictures (SHARE_API_VERSION): which threads are shared
  // as last marked; ones just shared, whose whole history is looked through;
  // ones no longer shared, whose pictures the mirror drops; pictures waiting
  // to go up; and what's up already, per thread, as "seq path".
  private sharedNow = new Map<string, boolean>();
  private imagesDue = new Set<string>();
  private imagesDrop = new Set<string>();
  private pendingImages: (ShareImage & { threadId: string })[] = [];
  private imagesUp = new Map<string, Set<string>>();
  private flushTimer?: TimerHandle;
  private heartbeatTimer?: TimerHandle;
  private presenceTimer?: TimerHandle;
  private sentAtMac?: boolean;
  private backendApiVersion?: number;
  private lastFlushAt = -Infinity;
  private flushing = false;
  private full = true; // the first write after start covers everything, then prunes and backfills
  private backoffMs = 0;
  private retryAt?: number;
  private lastError?: string;
  private lastLogged?: string;
  private lastSyncAt?: number;
  private written = 0;
  private messagesWritten = 0;
  // Commands.
  private unsubCommands?: () => void;
  private inFlight = new Set<string>();
  private applied = 0;
  private failed = 0;
  private commandError?: string;
  private commandsState: 'off' | 'on' | 'error' = 'off';
  private index?: ThreadIndex;

  constructor(deps: SyncDeps) {
    this.deps = deps;
    this.runnerId = deps.config.runnerId ?? 'runner';
    this.name = deps.config.name ?? defaultRunnerName();
    const { enabled, url } = deps.config;
    if (!enabled) this.off = 'sync.enabled is false';
    else if (!url) this.off = 'no sync.url in runner.json';
    else if (!deps.key) this.off = 'no secrets/convex-key';
    this.post = deps.post ?? (url ? convexPoster(url) : async () => undefined);
    this.upload = deps.upload ?? convexUploader();
    if (!this.off) this.subscriber = deps.subscriber ?? (url ? convexSubscriber(url) : undefined);
    if (!this.off && deps.home) {
      const subscriber = this.subscriber;
      this.index = new ThreadIndex({
        post: (kind, fn, args) => this.post(kind, fn, args),
        subscribe: subscriber ? (fn, args, onUpdate, onError) => subscriber.subscribe(fn, args, onUpdate, onError) : undefined,
        key: deps.key,
        runnerId: this.runnerId,
        home: deps.home,
        host: deps.runner,
        publish: deps.publish,
        clock: deps.clock,
        log: deps.log,
      });
    }
  }

  start(): void {
    if (this.off || this.running) return;
    this.running = true;
    this.unsub = this.deps.runner.onNotification((n) => this.onNotification(n));
    for (const t of this.deps.runner.list(ALL)) this.mark(t);
    this.lists = {
      projects: this.deps.runner.listProjects?.(),
      schedules: this.deps.schedules?.inBackend() ? undefined : this.deps.runner.listSchedules?.(),
      accounts: this.deps.runner.listAccounts?.(),
    };
    for (const name of ['projects', 'schedules', 'accounts'] as const) if (this.lists[name]) this.dirtyLists.add(name);
    this.full = true;
    this.scheduleFlush();
    this.heartbeat();
    void this.checkPresence();
    this.listenForCommands();
    this.deps.log.info('convex sync on', { url: this.deps.config.url, runnerId: this.runnerId, name: this.name, commands: Boolean(this.deps.commands) });
  }

  // A draining runner stops without a word: the new release writes
  // everything again under the same runnerId. A runner stopping for good
  // says bye, so the phone shows it offline now.
  async stop(opts: { bye?: boolean } = {}): Promise<void> {
    if (!this.running) return;
    this.running = false;
    this.unsub?.();
    this.unsubCommands?.();
    this.unsubCommands = undefined;
    this.commandsState = 'off';
    this.index?.stop();
    this.flushTimer?.cancel();
    this.heartbeatTimer?.cancel();
    this.presenceTimer?.cancel();
    this.presenceTimer = undefined;
    this.flushTimer = undefined;
    this.heartbeatTimer = undefined;
    await this.subscriber?.close();
    if (opts.bye) await this.post('mutation', 'sync:bye', { key: this.deps.key, runnerId: this.runnerId }).catch(() => {});
  }

  // Backends from before version.ts answer the heartbeat with null: version 0.
  private sawBackend(r: unknown): void {
    const v = typeof (r as { apiVersion?: unknown } | null)?.apiVersion === 'number' ? (r as { apiVersion: number }).apiVersion : 0;
    if (v === this.backendApiVersion) return;
    this.backendApiVersion = v;
    if (v < BACKEND_API_VERSION) {
      this.deps.log.warn('the convex backend is older than this runner', { backend: v, expected: BACKEND_API_VERSION, url: this.deps.config.url });
    }
    // Shared threads held back their share from an older backend (or
    // before the first heartbeat said which): they go again now.
    if (v >= SHARE_API_VERSION && this.running) {
      for (const t of this.deps.runner.list(ALL)) if (t.share || (t.woke && v >= WOKE_API_VERSION) || (t.asks?.length && v >= ASKS_API_VERSION)) this.mark(t);
      this.scheduleFlush();
    }
    // The pictures wait for the first heartbeat to say the backend takes them.
    if (v >= ICONS_API_VERSION && this.picturesDue) this.scheduleFlush();
  }

  status(): SyncStatus {
    if (this.off) return { state: 'off', reason: this.off };
    const s: SyncStatus = {
      state: this.lastError && this.retryAt !== undefined ? 'error' : 'ok',
      url: this.deps.config.url,
      runnerId: this.runnerId,
      name: this.name,
      threads: this.written,
      messages: this.messagesWritten,
      pending: this.dirty.size + this.removed.size + this.messages.length + this.dirtyLists.size,
      commands: { state: this.commandsState, applied: this.applied, failed: this.failed, ...(this.commandError ? { lastError: this.commandError } : {}) },
    };
    if (this.lastSyncAt !== undefined) s.lastSyncAt = new Date(this.lastSyncAt).toISOString();
    if (this.lastError) s.lastError = this.lastError;
    if (this.retryAt !== undefined) s.retryAt = new Date(this.retryAt).toISOString();
    if (this.backendApiVersion !== undefined) s.backend = { apiVersion: this.backendApiVersion, expected: BACKEND_API_VERSION };
    return s;
  }

  // ---- Devices (docs/protocol.md "Devices"): the phone tokens the Mac app
  // issues, lists and revokes through this runner. Each is one call to the
  // backend, outside the mirror's queue; nothing is kept here. The token
  // in issueToken's reply goes back to the caller and nowhere else: never
  // logged, never written.

  /** Why nothing can pair, or undefined while sync is on. */
  offReason(): string | undefined {
    return this.off;
  }

  /** The deployment's URL (`sync.url`), while sync is on. */
  url(): string | undefined {
    return this.off ? undefined : this.deps.config.url;
  }

  async issueToken(args: { kind: DeviceKind; name: string; days?: number }): Promise<{ id: string; token: string; expiresAt: string }> {
    this.mustBeOn();
    const r = (await this.backend('mutation', 'sync:issueToken', { key: this.deps.key, ...args })) as { id?: unknown; token?: unknown; expiresAt?: unknown } | null;
    if (!r || typeof r.id !== 'string' || typeof r.token !== 'string' || typeof r.expiresAt !== 'string') throw new Error('The backend gave no token back.');
    return { id: r.id, token: r.token, expiresAt: r.expiresAt };
  }

  async listTokens(): Promise<Device[]> {
    this.mustBeOn();
    const r = await this.backend('query', 'sync:listTokens', { key: this.deps.key });
    return Array.isArray(r) ? (r as Device[]) : [];
  }

  /** False when the backend has no token with that id. */
  async revokeToken(id: string): Promise<boolean> {
    this.mustBeOn();
    return (await this.backend('mutation', 'sync:revokeToken', { key: this.deps.key, id })) === true;
  }

  private mustBeOn(): void {
    if (this.off) throw new Error(`Your threads aren't mirrored to Convex (${this.off}), so there's nothing for a phone or browser to read. Run ./threadbear setup.`);
  }

  // A backend from before API 5 has none of the token functions: the
  // Convex HTTP API says it can't find them. Said in words the Settings
  // window can show, rather than the API's line about `npx convex dev`.
  private async backend(kind: 'mutation' | 'query', fn: string, args: Record<string, unknown>): Promise<unknown> {
    try {
      return await this.post(kind, fn, args);
    } catch (e) {
      const message = (e as Error)?.message ?? String(e);
      if (/could not find (public )?function/i.test(message)) {
        throw new Error('The Convex backend is older than this runner. It deploys with the runner\'s next update; try again in a few minutes.');
      }
      throw e;
    }
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

  // ------------------------------------------------------------ changes

  private onNotification(n: Notification): void {
    switch (n.method) {
      case 'thread.updated':
        this.mark(n.params.thread);
        this.scheduleFlush();
        break;
      case 'thread.deleted': {
        const id = n.params.threadId;
        this.dirty.delete(id);
        this.sent.delete(id);
        this.pending.delete(id);
        this.earliest.delete(id);
        this.nexts.delete(id);
        this.removed.add(id);
        this.scheduleFlush();
        break;
      }
      case 'thread.event':
        this.onEvent(n.params.threadId, n.params.event as PersistedEvent);
        break;
      case 'projects.updated':
        this.lists.projects = n.params.projects;
        this.dirtyLists.add('projects');
        this.picturesDue = true;
        this.scheduleFlush();
        break;
      case 'schedules.updated':
        // Ones that live in the backend are written there by the scheduler.
        if (this.deps.schedules?.inBackend()) break;
        this.lists.schedules = n.params.schedules;
        this.dirtyLists.add('schedules');
        this.scheduleFlush();
        break;
      case 'accounts.updated':
        this.lists.accounts = n.params.accounts;
        this.dirtyLists.add('accounts');
        this.scheduleFlush();
        break;
      default:
        break;
    }
  }

  // Text messages go up as they're persisted; an approval or question
  // the thread is waiting on goes on its row until it's resolved.
  private onEvent(threadId: string, e: PersistedEvent): void {
    if (typeof (e as { seq?: unknown }).seq !== 'number') return; // a delta
    // A shared thread's new pictures follow, unless its whole history is
    // about to be looked through anyway.
    if (this.sharedNow.get(threadId) && !this.imagesDue.has(threadId)) {
      const found = imagesInEvent(e);
      if (found.length) {
        this.pendingImages.push(...found.map((i) => ({ ...i, threadId })));
        this.scheduleFlush();
      }
    }
    const m = toMessageDoc(threadId, e);
    if (m) {
      this.messages.push(m);
      this.scheduleFlush();
      return;
    }
    if (e.type === 'approval.requested') {
      this.pending.set(threadId, { approvalId: e.approvalId, kind: 'approval', name: e.name, title: e.title, options: e.options, ...(inputSummary(e.input) ? { inputSummary: inputSummary(e.input) } : {}) });
    } else if (e.type === 'question.requested') {
      this.pending.set(threadId, { approvalId: e.approvalId, kind: 'question', questions: e.questions });
    } else if (e.type === 'approval.resolved') {
      if (this.pending.get(threadId)?.approvalId === e.approvalId) this.pending.delete(threadId);
    } else return;
    try {
      this.mark(this.deps.runner.get(threadId));
      this.scheduleFlush();
    } catch {
      // The thread went between the event and now; its row goes with it.
    }
  }

  // Only a change the phone would see makes a write.
  private mark(t: ThreadSummary): void {
    // A thread that isn't waiting any more lost its approval some other
    // way (the turn ended, the runner restarted); the row mustn't keep it.
    if (t.status === 'idle' || t.status === 'error' || t.status === 'stopped') this.pending.delete(t.id);
    this.noteShared(t);
    const doc = toThreadDoc(t, this.runnerId, this.deps.clock.now(), this.pending.get(t.id), this.earliestSeq(t), this.nextSteps(t));
    if (this.sent.get(t.id) === JSON.stringify(doc)) {
      this.dirty.delete(t.id);
      return;
    }
    this.dirty.set(t.id, doc);
  }

  // A thread just shared has its pictures looked for; one no longer shared
  // has them dropped. At start every shared thread is looked through (what's
  // up already is skipped), and one shared then stopped while the runner
  // was off has its pictures dropped.
  private noteShared(t: ThreadSummary): void {
    const shared = t.share?.access === 'link';
    const was = this.sharedNow.get(t.id);
    this.sharedNow.set(t.id, shared);
    if (shared && !was) {
      this.imagesDue.add(t.id);
      this.imagesDrop.delete(t.id);
    } else if (!shared && (was || (was === undefined && t.share))) {
      this.imagesDue.delete(t.id);
      this.imagesDrop.add(t.id);
      this.imagesUp.delete(t.id);
      this.pendingImages = this.pendingImages.filter((i) => i.threadId !== t.id);
    }
  }

  // A finished turn's suggested follow-ups (end_turn's `next`), for the
  // phone's done card: only while the thread is idle on a turn that said
  // it needs nothing, read from the end of its log once per lastSeq.
  private nextSteps(t: ThreadSummary): string[] | undefined {
    if (t.status !== 'idle' || t.needs !== 'nothing' || t.archivedAt) return undefined;
    const known = this.nexts.get(t.id);
    if (known && known.lastSeq === t.lastSeq) return known.next;
    let next: string[] | undefined;
    try {
      const { events } = this.deps.runner.events(t.id, { beforeSeq: t.lastSeq + 1, limit: 20 });
      for (let i = events.length - 1; i >= 0; i--) {
        const e = events[i]!;
        if (e.type === 'turn.completed') {
          if (e.next?.length) next = e.next;
          break;
        }
        // A message after the turn means it's no longer the last word.
        if (e.type === 'user.message' || e.type === 'turn.started') break;
      }
    } catch {
      return undefined;
    }
    this.nexts.set(t.id, { lastSeq: t.lastSeq, next });
    return next;
  }

  // The seq of the thread's first text message, read once from the start
  // of its log (a thread with no text yet is asked again next time).
  private earliestSeq(t: ThreadSummary): number | undefined {
    const known = this.earliest.get(t.id);
    if (typeof known === 'number') return known;
    if (known === null && t.lastSeq === 0) return undefined;
    let seq: number | undefined;
    try {
      const { events } = this.deps.runner.events(t.id, { afterSeq: 0, limit: 50 });
      seq = events.find((e) => e.type === 'user.message' || e.type === 'assistant.text')?.seq;
    } catch {
      return undefined;
    }
    this.earliest.set(t.id, seq ?? null);
    return seq;
  }

  private scheduleFlush(): void {
    if (!this.running || this.flushTimer) return;
    if (!this.dirty.size && !this.removed.size && !this.messages.length && !this.dirtyLists.size && !this.full && !this.imagesDue.size && !this.imagesDrop.size && !this.pendingImages.length) return;
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
    let messages = this.messages.splice(0);
    const lists = [...this.dirtyLists];
    this.dirty.clear();
    this.removed.clear();
    this.dirtyLists.clear();
    const key = this.deps.key;
    try {
      // What was written is what's remembered as sent, so a row whose
      // share or woke was held back from an older backend goes again once
      // it's new enough (sawBackend).
      const v = this.backendApiVersion ?? 0;
      for (let i = 0; i < docs.length; i += SYNC_BATCH) {
        const batch = docs.slice(i, i + SYNC_BATCH).map((d) => forBackend(d, v));
        await this.post('mutation', 'sync:upsertThreads', { key, threads: batch });
        for (const d of batch) this.sent.set(d.threadId, JSON.stringify(d));
        this.written += batch.length;
      }
      if (removed.length) await this.post('mutation', 'sync:removeThreads', { key, threadIds: removed });
      for (const name of lists) {
        const list = this.lists[name];
        if (!list) continue;
        if (name === 'schedules' && this.deps.schedules?.inBackend()) continue;
        const rows = name === 'projects' ? (list as Project[]).map(toProjectDoc) : name === 'schedules' ? (list as Schedule[]).map(toScheduleDoc) : (list as Account[]).map(toAccountDoc);
        await this.post('mutation', `sync:set${name[0]!.toUpperCase()}${name.slice(1)}`, { key, runnerId: this.runnerId, [name]: rows });
      }
      if (this.picturesDue && (this.backendApiVersion ?? 0) >= ICONS_API_VERSION) await this.sendPictures();
      if (this.full) {
        const keep = this.deps.runner.list(ALL).map((t) => t.id);
        await this.post('mutation', 'sync:prune', { key, runnerId: this.runnerId, keep });
        messages.unshift(...(await this.catchUp()));
        this.full = false;
      }
      const { docs: history, threadIds: filling } = this.histories();
      // A new thread's first messages are both live and its history: once each.
      const seen = new Set<string>();
      messages = [...history, ...messages].filter((m) => {
        const k = `${m.threadId}:${m.seq}`;
        if (seen.has(k)) return false;
        seen.add(k);
        return true;
      });
      await this.appendMessages(messages);
      this.markFilled(filling);
      if (v >= SHARE_API_VERSION) await this.sendShareImages();
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
      for (const name of lists) this.dirtyLists.add(name);
      this.messages.unshift(...messages.filter((m) => !this.messages.some((x) => x.threadId === m.threadId && x.seq === m.seq)));
      this.backoffMs = this.backoffMs ? Math.min(this.backoffMs * 2, BACKOFF_MAX_MS) : BACKOFF_MIN_MS;
      this.retryAt = this.deps.clock.now() + this.backoffMs;
      this.lastError = String((e as Error)?.message ?? e);
      if (this.lastError !== this.lastLogged) {
        this.lastLogged = this.lastError;
        this.deps.log.warn('convex sync failed; will retry', { error: this.lastError, pending: this.dirty.size + this.removed.size + this.messages.length, retryInMs: this.backoffMs });
      }
    } finally {
      this.flushing = false;
    }
    this.scheduleFlush();
  }

  // Each project's picture to file storage, once per picture: the mirror
  // says what it has (sync:projectIcons, read once), and only a project
  // whose picture is new or changed is uploaded. A picture that can't be
  // read or drawn is skipped with a warning (the phone shows the symbol or
  // a letter) and tried again when the projects next change; a failed
  // upload throws, so the flush retries with the others.
  private async sendPictures(): Promise<void> {
    const key = this.deps.key;
    if (!this.pictures) {
      const rows = (await this.post('query', 'sync:projectIcons', { key, runnerId: this.runnerId })) as { projectId: string; picture: string }[] | null;
      this.pictures = new Map((rows ?? []).map((r) => [r.projectId, r.picture]));
    }
    const projects = this.lists.projects ?? [];
    for (const p of projects) {
      const image = p.icon?.image;
      if (!image) {
        this.pictures.delete(p.id); // setProjects has dropped it from the mirror
        continue;
      }
      const picture = pictureName(image.path);
      if (this.pictures.get(p.id) === picture) continue;
      let file: { bytes: Uint8Array; mediaType: string } | undefined;
      try {
        file = await phonePicture(image.path, image.mediaType);
      } catch (e) {
        this.deps.log.warn('project picture not sent', { projectId: p.id, path: image.path, error: String((e as Error)?.message ?? e) });
        continue;
      }
      const url = (await this.post('mutation', 'sync:iconUploadUrl', { key })) as string;
      const storageId = await this.upload(url, file.bytes, file.mediaType);
      await this.post('mutation', 'sync:setProjectIcon', { key, runnerId: this.runnerId, projectId: p.id, picture, storageId, mediaType: file.mediaType });
      this.pictures.set(p.id, picture);
      this.deps.log.info('project picture sent', { projectId: p.id, picture, bytes: file.bytes.byteLength });
    }
    const keep = new Set(projects.map((p) => p.id));
    for (const id of [...this.pictures.keys()]) if (!keep.has(id)) this.pictures.delete(id);
    this.picturesDue = false;
  }

  // Shared threads' pictures: drops for threads no longer shared, a look
  // through the whole history of each one just shared, then the uploads.
  // Each step is forgotten only once done, so a failure is picked up by
  // the flush's retry. A file that's gone or too big is skipped with a line
  // in the log; the page shows that picture's alt text, or nothing.
  private async sendShareImages(): Promise<void> {
    const key = this.deps.key;
    for (const threadId of [...this.imagesDrop]) {
      await this.post('mutation', 'sync:dropShareImages', { key, threadId });
      this.imagesDrop.delete(threadId);
    }
    for (const threadId of [...this.imagesDue]) {
      let t: ThreadSummary;
      try {
        t = this.deps.runner.get(threadId);
      } catch {
        // Not here (yet): during a handover the draining runner's updates
        // come through for threads it still has. Forget it was seen, so
        // its update on coming across starts the look through again.
        this.imagesDue.delete(threadId);
        this.sharedNow.delete(threadId);
        continue;
      }
      const rows = (await this.post('query', 'sync:shareImages', { key, threadId })) as { seq: number; path: string }[] | null;
      this.imagesUp.set(threadId, new Set((rows ?? []).map((r) => `${r.seq} ${r.path}`)));
      this.pendingImages.push(...this.imagesOf(t).map((i) => ({ ...i, threadId })));
      this.imagesDue.delete(threadId);
    }
    while (this.pendingImages.length) {
      const img = this.pendingImages[0]!;
      const up = this.imagesUp.get(img.threadId) ?? new Set<string>();
      this.imagesUp.set(img.threadId, up);
      const id = `${img.seq} ${img.path}`;
      if (!up.has(id) && this.sharedNow.get(img.threadId)) {
        const file = readShareImage(img.path);
        if ('skip' in file) {
          this.deps.log.warn('shared picture not sent', { threadId: img.threadId, path: img.path, why: file.skip });
        } else {
          const url = (await this.post('mutation', 'sync:iconUploadUrl', { key })) as string;
          const storageId = await this.upload(url, file.bytes, img.mediaType);
          const { threadId, seq, path: file_, src, mediaType, width, height } = img;
          await this.post('mutation', 'sync:addShareImage', { key, threadId, seq, path: file_, ...(src ? { src } : {}), storageId, mediaType, ...(width ? { width } : {}), ...(height ? { height } : {}) });
        }
        up.add(id);
      }
      this.pendingImages.shift();
    }
  }

  // Every picture in a thread's history, read from its log a page at a time.
  private imagesOf(t: ThreadSummary): ShareImage[] {
    const out: ShareImage[] = [];
    let after = 0;
    while (t.lastSeq > after) {
      let events: PersistedEvent[];
      try {
        events = this.deps.runner.events(t.id, { afterSeq: after, limit: BACKFILL_EVENTS }).events;
      } catch {
        break;
      }
      const next = events.at(-1)?.seq ?? after;
      if (next <= after) break;
      for (const e of events) if (e.seq > after) out.push(...imagesInEvent(e));
      after = next;
    }
    return out;
  }

  private async appendMessages(all: MessageDoc[]): Promise<void> {
    // A backend from before API 2 can't take tool rows; it's deployed before
    // the runner, so this only matters when that deploy was skipped.
    const v = this.backendApiVersion;
    let messages = v !== undefined && v < 2 ? all.filter((m) => m.role !== 'tool') : all;
    // Before API 14 the validator has no `summary`; the bullets go as text.
    if (v === undefined || v < ASKS_API_VERSION) messages = messages.map((m) => (m.summary ? (({ summary, ...rest }) => rest)(m) : m));
    for (let i = 0; i < messages.length; i += MESSAGE_BATCH) {
      const batch = messages.slice(i, i + MESSAGE_BATCH);
      await this.post('mutation', 'sync:appendMessages', { key: this.deps.key, messages: batch });
      this.messagesWritten += batch.length;
    }
  }

  // At start, what's newer than the mirror's newest message, for threads
  // whose whole history is already up (the others are histories()' job).
  private async catchUp(): Promise<MessageDoc[]> {
    const filled = this.filledThreads();
    if (!filled.size) return [];
    const heads = (await this.post('query', 'sync:messageHeads', { key: this.deps.key, runnerId: this.runnerId })) as { threadId: string; lastSeq: number }[] | null;
    const have = new Map((heads ?? []).map((h) => [h.threadId, h.lastSeq]));
    const out: MessageDoc[] = [];
    for (const t of this.deps.runner.list(ALL)) {
      if (filled.has(t.id)) out.push(...this.messagesAfter(t, have.get(t.id) ?? 0));
    }
    return out;
  }

  // Each thread's whole history goes up once per deployment (text and tool
  // rows; until backend API 2 only the newest 20 text messages did), and
  // statePath records which threads are done. Checked on every flush rather
  // than only at start: a restart hands threads over from the old runner one
  // at a time, and one that wasn't here yet at start (or whose log couldn't
  // be read) is caught on a later flush. Writing a message twice is harmless.
  private histories(): { docs: MessageDoc[]; threadIds: string[] } {
    const filled = this.filledThreads();
    const docs: MessageDoc[] = [];
    const threadIds: string[] = [];
    for (const t of this.deps.runner.list(ALL)) {
      if (filled.has(t.id)) continue;
      const got = this.messagesAfter(t, 0, true);
      if (!got) continue;
      docs.push(...got);
      threadIds.push(t.id);
    }
    return { docs, threadIds };
  }

  // A thread's messages after a seq, read from its log a page at a time.
  // With strict, undefined when the log can't be read (so it isn't counted
  // as done); otherwise what could be read.
  private messagesAfter(t: ThreadSummary, after: number, strict: true): MessageDoc[] | undefined;
  private messagesAfter(t: ThreadSummary, after: number): MessageDoc[];
  private messagesAfter(t: ThreadSummary, after: number, strict = false): MessageDoc[] | undefined {
    const out: MessageDoc[] = [];
    while (t.lastSeq > after) {
      let events: PersistedEvent[];
      try {
        events = this.deps.runner.events(t.id, { afterSeq: after, limit: BACKFILL_EVENTS }).events;
      } catch {
        return strict ? undefined : out;
      }
      // Stops if a page doesn't move forward, so a log that disagrees with
      // the summary's lastSeq can't loop forever.
      const next = events.at(-1)?.seq ?? after;
      if (next <= after) break;
      const cuts = this.deps.runner.cuts?.(t.id) ?? [];
      for (const e of events) {
        if (e.seq <= after || cuts.some((c) => e.seq >= c.from && e.seq <= c.to)) continue;
        const m = toMessageDoc(t.id, e);
        if (m) out.push(m);
      }
      after = next;
    }
    return out;
  }

  // Which threads' whole history is up on this deployment, from statePath
  // ({ histories: { [url]: threadId[] } }); kept in memory once read.
  private filled?: Set<string>;

  private filledThreads(): Set<string> {
    if (this.filled) return this.filled;
    let ids: string[] = [];
    if (this.deps.statePath) {
      try {
        const state = JSON.parse(fs.readFileSync(this.deps.statePath, 'utf8')) as { histories?: Record<string, string[]> };
        ids = state.histories?.[this.deps.config.url ?? ''] ?? [];
      } catch {
        // none yet
      }
    }
    this.filled = new Set(ids);
    return this.filled;
  }

  // After the append that carried them went through.
  private markFilled(threadIds: string[]): void {
    if (!threadIds.length) return;
    const filled = this.filledThreads();
    for (const id of threadIds) filled.add(id);
    if (!this.deps.statePath) return;
    try {
      let state: { histories?: Record<string, string[]> } = {};
      try {
        state = JSON.parse(fs.readFileSync(this.deps.statePath, 'utf8'));
      } catch {
        // first write
      }
      // Only threads that still exist, so the file doesn't grow for ever.
      const live = new Set(this.deps.runner.list(ALL).map((t) => t.id));
      const histories = { ...(state.histories ?? {}), [this.deps.config.url ?? '']: [...filled].filter((id) => live.has(id)) };
      fs.writeFileSync(this.deps.statePath, JSON.stringify({ histories }, null, 2) + '\n');
    } catch (e) {
      this.deps.log.warn('could not record which histories are up', { error: String(e) });
    }
  }

  // Sends presence when it changes (and once at start); a failed send is
  // tried again on the next check.
  private async checkPresence(): Promise<void> {
    if (!this.running || !this.deps.presence) return;
    let atMac: boolean;
    try {
      atMac = await this.deps.presence();
    } catch {
      atMac = false;
    }
    // Stopped while the check ran (ioreg can take seconds on a busy Mac).
    if (!this.running) return;
    if (atMac !== this.sentAtMac) {
      void this.post('mutation', 'sync:setPresence', { key: this.deps.key, runnerId: this.runnerId, atMac }).then(
        () => {
          this.sentAtMac = atMac;
        },
        (e) => this.deps.log.debug('convex presence failed', { error: String(e) }),
      );
    }
    this.presenceTimer = this.deps.clock.setTimeout(() => void this.checkPresence(), PRESENCE_MS);
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
      ...(this.deps.config.icon && (this.backendApiVersion ?? 0) >= RUNNER_ICON_API_VERSION ? { icon: this.deps.config.icon } : {}),
      ...(this.deps.config.rpcUrl && (this.backendApiVersion ?? 0) >= THREAD_INDEX_API_VERSION ? { rpcUrl: this.deps.config.rpcUrl } : {}),
    };
    void this.post('mutation', 'sync:heartbeat', { key: this.deps.key, runner }).then(
      (r) => {
        this.sawBackend(r);
        if ((this.backendApiVersion ?? 0) >= SCHEDULES_API_VERSION && this.running) void this.deps.schedules?.attach(this.scheduleBackend());
        if ((this.backendApiVersion ?? 0) >= THREAD_INDEX_API_VERSION && this.running) this.index?.start();
      },
      (e) => {
        this.deps.log.debug('convex heartbeat failed', { error: String(e) });
      },
    );
    this.heartbeatTimer = this.deps.clock.setTimeout(() => this.heartbeat(), HEARTBEAT_MS);
  }

  /** remoteThreads.list: other runners' threads, empty with sync off. */
  remoteThreads(): RemoteThreads {
    return this.index?.list() ?? { runners: [], threads: [] };
  }

  // ------------------------------------------------------------ schedules

  private schedulesTable?: ScheduleBackend;

  // The backend's schedules table for the scheduler (SCHEDULES_API_VERSION).
  // `holder` names this runner process, so a claim taken by the release
  // that's draining isn't this one's.
  scheduleBackend(): ScheduleBackend {
    if (this.schedulesTable) return this.schedulesTable;
    const key = this.deps.key;
    const runnerId = this.runnerId;
    const holder = `${runnerId}:${process.pid}:${this.deps.startedAt}`;
    const call = (kind: 'mutation' | 'query', fn: string, args: Record<string, unknown>) => this.backend(kind, fn, { key, ...args });
    this.schedulesTable = {
      subscribe: (onRows, onError) => {
        if (!this.subscriber) {
          onError(new Error('sync is off'));
          return () => {};
        }
        return this.subscriber.subscribe('sync:schedules', { key }, (v) => onRows(Array.isArray(v) ? (v as StoredSchedule[]) : []), onError);
      },
      save: async (sc) => {
        await call('mutation', 'sync:saveSchedule', { schedule: toOwnedScheduleDoc(sc) });
      },
      remove: async (scheduleId) => {
        await call('mutation', 'sync:deleteSchedule', { scheduleId });
      },
      adopt: async (rows) => {
        await call('mutation', 'sync:adoptSchedules', { runnerId, schedules: rows.map(toOwnedScheduleDoc) });
      },
      claim: async (scheduleId, kind, expect) => (await call('mutation', 'sync:claimSchedule', { runnerId, scheduleId, holder, kind, expect })) === true,
      release: async (scheduleId) => {
        await call('mutation', 'sync:releaseSchedule', { scheduleId, holder });
      },
      ran: async (p) => {
        await call('mutation', 'sync:scheduleRan', { holder, ...p });
      },
      requestRun: async (scheduleId, at) => (await call('mutation', 'sync:requestScheduleRun', { scheduleId, at })) === true,
      runners: async () => {
        const rows = await call('query', 'sync:runnersList', {});
        return Array.isArray(rows)
          ? (rows as { runnerId: string; name: string; lastSeenAt: number; icon?: string }[]).map((r) => ({ id: r.runnerId, name: r.name, lastSeenAt: r.lastSeenAt, ...(r.icon ? { icon: r.icon } : {}) }))
          : [];
      },
    };
    return this.schedulesTable;
  }

  // ------------------------------------------------------------ commands

  private listenForCommands(): void {
    if (!this.deps.commands || !this.subscriber) return;
    try {
      this.unsubCommands = this.subscriber.subscribe(
        'sync:pendingCommands',
        { key: this.deps.key, runnerId: this.runnerId },
        (value) => {
          this.commandsState = 'on';
          void this.takeCommands(Array.isArray(value) ? (value as Command[]) : []);
        },
        (error) => {
          this.commandsState = 'error';
          this.commandError = String(error?.message ?? error);
          this.deps.log.warn('convex command subscription failed', { error: this.commandError });
        },
      );
      this.commandsState = 'on';
    } catch (e) {
      this.commandsState = 'error';
      this.commandError = String((e as Error)?.message ?? e);
      this.deps.log.warn('could not subscribe to convex commands', { error: this.commandError });
    }
  }

  // Each pending command once: takeCommand says no if another runner (or
  // an earlier update of the same list) already has it.
  private async takeCommands(commands: Command[]): Promise<void> {
    for (const c of commands) {
      if (!this.running || this.inFlight.has(c.commandId)) continue;
      this.inFlight.add(c.commandId);
      try {
        const taken = await this.post('mutation', 'sync:takeCommand', { key: this.deps.key, commandId: c.commandId });
        if (taken !== true) continue;
        let resultThreadId: string | undefined;
        let note: string | undefined;
        let ok = true;
        try {
          resultThreadId = await this.apply(c);
          this.applied++;
        } catch (e) {
          ok = false;
          note = String((e as Error)?.message ?? e);
          this.failed++;
          this.commandError = note;
          // The phone can still show a thread for a moment after it's
          // deleted: its command failing then is a race, not a problem.
          if ((e as { code?: unknown })?.code === ErrorCode.threadNotFound) this.deps.log.info('phone command for a thread that has gone', { kind: c.kind, threadId: c.threadId });
          else this.deps.log.warn('phone command failed', { kind: c.kind, threadId: c.threadId, error: note });
        }
        await this.post('mutation', 'sync:finishCommand', { key: this.deps.key, commandId: c.commandId, ok, ...(note ? { note } : {}), ...(resultThreadId ? { resultThreadId } : {}) });
      } catch (e) {
        // Couldn't take or finish it: the next update of the list brings
        // it round again if it's still pending.
        this.deps.log.debug('phone command not taken', { commandId: c.commandId, error: String(e) });
      } finally {
        this.inFlight.delete(c.commandId);
      }
    }
  }

  // Applies one command through the runner; returns the new thread's id
  // for a create or a quickAsk. Throws with a readable message for the phone.
  private async apply(c: Command): Promise<string | undefined> {
    const host = this.deps.commands!;
    const a = c.args ?? {};
    const threadId = c.threadId;
    const needThread = (): string => {
      if (!threadId) throw new Error('no thread');
      return threadId;
    };
    switch (c.kind) {
      case 'send': {
        if (typeof a.text !== 'string' || !a.text.trim()) throw new Error('nothing to send');
        await host.send(needThread(), a.text, [], { origin: 'phone', ...(phoneAnswers(a.answers) ? { answers: phoneAnswers(a.answers) } : {}) });
        return undefined;
      }
      case 'respond': {
        const decision = a.decision as ApprovalDecision;
        if (!['allow', 'allowAlways', 'deny', 'answered'].includes(decision)) throw new Error(`bad decision ${String(a.decision)}`);
        await host.respondApproval({
          threadId: needThread(),
          approvalId: String(a.approvalId),
          decision,
          ...(typeof a.message === 'string' ? { message: a.message } : {}),
          ...(a.answers && typeof a.answers === 'object' ? { answers: a.answers as Record<string, string> } : {}),
        });
        return undefined;
      }
      case 'update': {
        const id = needThread();
        if (a.snooze && typeof a.snooze === 'object') {
          const s = a.snooze as { until?: string; untilRestart?: boolean };
          await host.update({ threadId: id, snoozedUntil: s.untilRestart ? 'restart' : s.until ?? null });
        } else if (a.wake) await host.update({ threadId: id, snoozedUntil: null });
        else if (a.archive) await host.update({ threadId: id, archived: true });
        else if (a.unarchive) await host.update({ threadId: id, archived: false });
        else if (a.markSeen) await host.markSeen(id);
        else if (typeof a.title === 'string') await host.update({ threadId: id, title: a.title });
        else throw new Error('nothing to change');
        return undefined;
      }
      case 'create': {
        if (typeof a.text !== 'string' || !a.text.trim()) throw new Error('nothing to send');
        const { thread } = host.create({
          text: a.text,
          ...(typeof a.cwd === 'string' ? { cwd: a.cwd } : {}),
          ...(typeof a.accountId === 'string' ? { accountId: a.accountId } : {}),
          ...(typeof a.model === 'string' ? { model: a.model } : {}),
          origin: 'phone',
        });
        return thread.id;
      }
      case 'quickAsk': {
        // A quick ask the phone answered itself (API 9), kept as a thread.
        if (typeof a.question !== 'string' || !a.question.trim()) throw new Error('no question');
        if (typeof a.answer !== 'string' || !a.answer.trim()) throw new Error('no answer');
        const sources = Array.isArray(a.sources)
          ? (a.sources as unknown[])
              .filter((x): x is { title?: unknown; url: string } => typeof (x as { url?: unknown })?.url === 'string')
              .map((x) => ({ title: typeof x.title === 'string' ? x.title : x.url, url: x.url }))
          : [];
        const { thread } = host.quickAsk({
          question: a.question,
          answer: a.answer,
          sources,
          ...(typeof a.askedAt === 'number' ? { askedAt: a.askedAt } : {}),
        });
        return thread.id;
      }
      case 'share': {
        // The website's Stop sharing, Share again and New link (API 8).
        if (a.access !== 'off' && a.access !== 'link') throw new Error('access is "off" or "link"');
        await host.share(needThread(), { access: a.access, ...(a.newLink === true ? { newLink: true } : {}) });
        return undefined;
      }
      case 'page': {
        // An API 1 phone's "Load earlier messages": up to PAGE_SIZE text
        // messages before beforeSeq, marked as paged so its phone:thread
        // shows them for a day (the rows are all there already since API 2).
        const id = needThread();
        const before = Number(a.beforeSeq);
        if (!Number.isFinite(before) || before <= 1) throw new Error('nothing earlier');
        const { events } = this.deps.runner.events(id, { beforeSeq: before, limit: PAGE_EVENTS });
        const now = this.deps.clock.now();
        // Text only: it's for a phone from before API 2, which never shows tool rows.
        const cuts = this.deps.runner.cuts?.(id) ?? [];
        const page = events
          .filter((e) => !cuts.some((c) => e.seq >= c.from && e.seq <= c.to))
          .map((e) => toMessageDoc(id, e))
          .filter((m): m is MessageDoc => Boolean(m) && m!.role !== 'tool')
          .slice(-PAGE_SIZE)
          .map((m) => ({ ...m, pagedAt: now }));
        await this.appendMessages(page);
        return undefined;
      }
      default:
        throw new Error(`unknown command ${c.kind}`);
    }
  }
}
