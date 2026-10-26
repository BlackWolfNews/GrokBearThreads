// The thread manager: owns threads, turns, the event log, approvals, idle
// release and snoozes. Providers plug in through AgentAdapter; the WebSocket
// server in rpc.ts is a thin layer over the public methods here.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import type {
  Account,
  AnyEvent,
  ApprovalDecision,
  DeltaBody,
  DeltaType,
  EventBody,
  ImageRef,
  InProgressItem,
  PermissionMode,
  PersistedEvent,
  Question,
  ThreadStatus,
  ThreadSummary,
} from './protocol.ts';
import { ErrorCode, LIMITS, PROTOCOL_VERSION, RpcError } from './protocol.ts';
import type {
  AgentAdapter,
  AgentSession,
  AdapterOutput,
  BackgroundTask,
  QuestionAnswer,
  QuestionRequest,
  SessionSink,
  ToolApprovalAnswer,
  ToolApprovalRequest,
  TurnResult,
} from './adapters/types.ts';
import type { ThreadRecord, ThreadStore, QueuedSend } from './store.ts';
import type { Clock, TimerHandle } from './clock.ts';
import type { Logger } from './log.ts';
import { threadEnv } from './restart.ts';
import type { AccountRegistry } from './accounts.ts';
import { RUNNER_VERSION, expandHome, paths, readRunnerJson, writeRunnerJson, type Config } from './config.ts';
import { copyImageInto, imageRefFor } from './media.ts';
import { isDirectory } from './fsutil.ts';

export type Notification =
  | { method: 'thread.updated'; params: { thread: ThreadSummary } }
  | { method: 'thread.event'; params: { threadId: string; event: AnyEvent } }
  | { method: 'runner.notice'; params: { level: 'info' | 'warning' | 'error'; message: string } };

type PendingApproval =
  | { approvalId: string; kind: 'tool'; resolve: (a: ToolApprovalAnswer) => void }
  | { approvalId: string; kind: 'question'; questions: Question[]; resolve: (a: QuestionAnswer) => void };

type Turn = {
  turnId: string;
  startedAt: number;
  interruptRequested: boolean;
  // Opened by the runner for work the CLI started itself (a background
  // shell or async subagent finished, or a background subagent asked for
  // approval). There's no user.message.
  auto?: boolean;
  cliStarted?: boolean; // the CLI is running a turn for it (not just an approval)
  interruptTimer?: TimerHandle;
};

type Runtime = {
  session?: AgentSession;
  generation: number;
  closing?: Promise<void>;
  releasedGen?: number; // generation of the session being released on purpose
  resumed: boolean; // the live session was started with resume
  retriedFresh: boolean;
  turn?: Turn;
  tasks: BackgroundTask[]; // background work the live CLI is running
  // Set when background work finished with no turn running: the CLI is
  // about to start a turn of its own to look at the result, and until it
  // does (or WAKE_GRACE_MS passes) the thread isn't idle.
  wakeTimer?: TimerHandle;
  activeAt: number; // last turn start or end, for picking which CLI to release
  approvals: Map<string, PendingApproval>;
  idleTimer?: TimerHandle;
  releaseWhenIdle: boolean;
  inProgress: Map<string, InProgressItem>;
  pendingDeltas: Map<string, { type: DeltaType; text: string }>;
  deltaTimer?: TimerHandle;
};

type ThreadState = { rec: ThreadRecord; rt: Runtime };

export type RunnerDeps = {
  config: Config;
  store: ThreadStore;
  adapters: Record<string, AgentAdapter>;
  accounts: Pick<AccountRegistry, 'list' | 'get'>;
  clock: Clock;
  log: Logger;
  // Coalesces summary saves and thread.updated; tests pass a synchronous one.
  defer?: (fn: () => void) => void;
};

const DELTA_INTERVAL_MS = 33; // at most ~30 delta flushes a second per thread
// An interrupted turn that the CLI hasn't ended by then is ended anyway, so
// a CLI that never answers can't leave a thread stuck as running.
const INTERRUPT_GRACE_MS = 10_000;
// How long notices from startup are shown to clients that connect later.
const STARTUP_NOTICE_MS = 10 * 60_000;
// How long a finished background task keeps the thread counted as busy
// while the CLI gets round to its own turn (usually well under a second).
const WAKE_GRACE_MS = 15_000;

export class Runner {
  private cfg: Config;
  private store: ThreadStore;
  private adapters: Record<string, AgentAdapter>;
  private accounts: Pick<AccountRegistry, 'list' | 'get'>;
  private clock: Clock;
  private log: Logger;
  private defer: (fn: () => void) => void;
  private threads = new Map<string, ThreadState>();
  private listeners = new Set<(n: Notification) => void>();
  private dirty = new Set<string>();
  private flushScheduled = false;
  private snoozeTimer?: TimerHandle;
  private stopping = false;
  private refusing?: string;
  private startedAt = 0;
  private startupNotices: { level: 'info' | 'warning' | 'error'; message: string }[] = [];

  constructor(deps: RunnerDeps) {
    this.cfg = deps.config;
    this.store = deps.store;
    this.adapters = deps.adapters;
    this.accounts = deps.accounts;
    this.clock = deps.clock;
    this.log = deps.log;
    this.defer = deps.defer ?? ((fn) => setImmediate(fn));
  }

  // ---------------------------------------------------------------- startup

  // Loads threads from disk. Threads that were mid-turn when the runner
  // stopped become `stopped`; approvals they were waiting on expire.
  start(): void {
    this.startedAt = this.clock.now();
    const { records, broken } = this.store.loadAll();
    for (const id of broken) {
      const rec = this.rebuild(id);
      if (rec) records.push(rec);
    }
    let stopped = 0;
    for (const rec of records) {
      // thread.json is saved a moment after the event it follows; the log
      // is the truth for seq.
      rec.lastSeq = this.store.log(rec.id).lastSeq;
      const st: ThreadState = { rec, rt: newRuntime(Date.parse(rec.lastActivityAt) || 0) };
      this.threads.set(rec.id, st);
      if (this.recover(st)) stopped++;
    }
    if (stopped) this.startupNotice('info', `${stopped === 1 ? 'A thread was' : `${stopped} threads were`} mid-turn when the runner stopped; send a message to carry on.`);
    this.flush();
    this.armSnoozeTimer();
    this.log.info('runner loaded threads', { count: this.threads.size });
  }

  // A thread folder whose thread.json can't be read: rebuild what can be
  // read from its events, rather than have it disappear. Settings that live
  // only in thread.json (folder, account, session) fall back to defaults,
  // and the next message starts a new session with a handoff note.
  private rebuild(id: string): ThreadRecord | undefined {
    const log = this.store.log(id);
    if (log.lastSeq === 0) return undefined;
    const events = log.read(1, log.lastSeq);
    const first = events[0];
    const last = events[events.length - 1];
    const firstMsg = events.find((e) => e.type === 'user.message');
    const lastText = [...events].reverse().find((e) => e.type === 'assistant.text');
    const lastStarted = [...events].reverse().find((e) => e.type === 'turn.started');
    const open = lastStarted && !events.some((e) => e.type === 'turn.completed' && e.turnId === lastStarted.turnId);
    const lastCompleted = [...events].reverse().find((e) => e.type === 'turn.completed');
    const accountId = this.defaultAccountId();
    const rec: ThreadRecord = {
      id,
      title: firstMsg && firstMsg.type === 'user.message' ? titleFrom(firstMsg.text) : 'Untitled',
      cwd: this.cfg.defaults.cwd,
      accountId,
      provider: 'claude',
      // Unknown, so the safer one.
      permissionMode: 'ask',
      status: open ? 'running' : 'idle',
      createdAt: first.ts,
      updatedAt: last.ts,
      lastActivityAt: last.ts,
      preview: lastText && lastText.type === 'assistant.text' ? oneLine(lastText.text, LIMITS.previewChars) : '',
      lastSeq: log.lastSeq,
      lastSeenSeq: log.lastSeq,
      nativeSessionId: crypto.randomUUID(),
      sessionUsed: false,
      lastTurnCompletedSeq: lastCompleted?.seq ?? 0,
      queue: [],
      pendingApprovals: [],
      handoff: { fromCwd: this.cfg.defaults.cwd, fromAccountId: accountId, rebuilt: true },
    };
    if (open && lastStarted) rec.turnId = lastStarted.turnId;
    this.log.warn('thread.json was unreadable; rebuilt it from the event log', { threadId: id });
    this.store.setAside(id);
    try {
      this.store.save(rec);
    } catch (e) {
      this.log.error('could not save a rebuilt thread', { threadId: id, error: String(e) });
    }
    const st: ThreadState = { rec, rt: newRuntime(0) };
    this.emit(st, {
      type: 'system.note',
      text: `This thread's settings couldn't be read, so its folder, account and permission mode were reset to ${rec.cwd}, ${accountId} and ask. The next message starts a new session.`,
    });
    return rec;
  }

  // Returns true if the thread was mid-turn.
  private recover(st: ThreadState): boolean {
    const { rec } = st;
    const midTurn = rec.status === 'starting' || rec.status === 'running' || rec.status === 'waiting';
    if (!midTurn && rec.pendingApprovals.length === 0 && rec.queue.length === 0) return false;
    // The turn may have ended on disk just before a crash stopped
    // thread.json being saved; then it only needs its status back.
    const ended = midTurn && rec.turnId ? this.findTurnCompleted(rec.id, rec.turnId) : undefined;
    for (const approvalId of rec.pendingApprovals) {
      if (ended) break;
      this.emit(st, { type: 'approval.resolved', approvalId, decision: 'expired', message: 'The runner restarted.' }, rec.turnId);
    }
    rec.pendingApprovals = [];
    if (midTurn && ended) {
      rec.lastTurnCompletedSeq = Math.max(rec.lastTurnCompletedSeq, ended.seq);
      rec.status = ended.type === 'turn.completed' && ended.outcome === 'failed' ? 'error' : 'idle';
      rec.turnId = undefined;
    } else if (midTurn) {
      if (rec.turnId) {
        const ev = this.emit(
          st,
          { type: 'turn.completed', turnId: rec.turnId, outcome: 'interrupted', durationMs: 0, error: 'The runner stopped during this turn.' },
          rec.turnId,
        );
        rec.lastTurnCompletedSeq = ev.seq;
      }
      rec.turnId = undefined;
      rec.status = 'stopped';
    }
    // A snoozed or archived thread holds its queue until it comes back, and
    // nothing sends it before then anyway, so a restart (planned or not)
    // leaves it for the wake-up to send. Anything else queued was cut off.
    if (rec.queue.length && !midTurn && this.bucket(rec) !== 'inbox') {
      this.markDirty(st);
      return false;
    }
    if (rec.queue.length) {
      const texts = rec.queue.map((q) => q.text).filter(Boolean);
      this.emit(st, {
        type: 'system.note',
        text: `The runner restarted before ${rec.queue.length === 1 ? 'a queued message was' : `${rec.queue.length} queued messages were`} sent:\n\n${texts.join('\n\n')}`,
      });
      rec.queue = [];
    }
    this.markDirty(st);
    return midTurn && !ended;
  }

  private findTurnCompleted(threadId: string, turnId: string): PersistedEvent | undefined {
    const log = this.store.log(threadId);
    return log
      .read(Math.max(1, log.lastSeq - 200), log.lastSeq)
      .reverse()
      .find((e) => e.type === 'turn.completed' && e.turnId === turnId);
  }

  // Called before the CLIs are killed. Turns in flight end the way startup
  // recovery would end them, rather than as failures when their CLI dies.
  async shutdown(): Promise<void> {
    this.stopping = true;
    this.snoozeTimer?.cancel();
    for (const st of this.threads.values()) {
      const { rt } = st;
      rt.idleTimer?.cancel();
      rt.deltaTimer?.cancel();
      rt.wakeTimer?.cancel();
      this.flushDeltas(st);
      // Output and exits from CLIs that are about to be killed no longer count.
      rt.generation++;
      if (rt.turn) this.stopTurn(st);
      // Killing the CLIs kills their background shells and subagents too.
      // Say so in the thread, as releaseSession does, or it would wait for
      // a result that never comes with nothing to say why.
      if (rt.tasks.length) {
        const what = rt.tasks.map((t) => t.description || t.type).join('; ');
        rt.tasks = [];
        try {
          this.emit(st, { type: 'system.note', text: `Stopped background work when the runner stopped: ${what}` });
        } catch (e) {
          this.log.error('could not save a note', { threadId: st.rec.id, error: String(e) });
        }
      }
    }
    this.flush();
  }

  // From the moment a restart begins until the runner exits, a new turn
  // would only be cut off straight away, so sends and new threads are
  // refused with a message saying to send again in a moment.
  refuseNewTurns(message: string): void {
    this.refusing = message;
  }

  private checkAccepting(): void {
    if (this.refusing) throw new RpcError(ErrorCode.busy, this.refusing);
  }

  // Threads whose CLI is running background shells or subagents. A restart
  // waits for them (restart.ts), since stopping the CLI stops them.
  backgroundWork(): { threadId: string; tasks: string[] }[] {
    const out: { threadId: string; tasks: string[] }[] = [];
    for (const st of this.threads.values()) {
      const tasks = st.rt.tasks.map((t) => t.description || t.type);
      if (st.rt.wakeTimer) tasks.push('a background task that just finished, which the agent is about to look at');
      if (tasks.length) out.push({ threadId: st.rec.id, tasks });
    }
    return out;
  }

  private stopTurn(st: ThreadState): void {
    const { rec, rt } = st;
    const turn = rt.turn!;
    this.persistInProgress(st, turn.turnId);
    this.expireApprovals(st, 'The runner stopped.');
    const ev = this.emit(
      st,
      {
        type: 'turn.completed',
        turnId: turn.turnId,
        outcome: 'interrupted',
        durationMs: Math.max(0, this.clock.now() - turn.startedAt),
        error: 'The runner stopped during this turn.',
      },
      turn.turnId,
    );
    turn.interruptTimer?.cancel();
    rt.turn = undefined;
    rec.turnId = undefined;
    rec.lastTurnCompletedSeq = ev.seq;
    rec.status = 'stopped';
    rec.lastActivityAt = this.isoNow();
    this.markDirty(st);
  }

  // Text that streamed but never got its complete frame is kept as what the
  // user saw.
  private persistInProgress(st: ThreadState, turnId: string): void {
    const { rt } = st;
    this.flushDeltas(st);
    for (const item of rt.inProgress.values()) {
      if (!item.text) continue;
      this.emit(
        st,
        item.type === 'assistant.text'
          ? { type: 'assistant.text', itemId: item.itemId, text: item.text }
          : { type: 'reasoning', itemId: item.itemId, text: item.text },
        turnId,
      );
    }
    rt.inProgress.clear();
  }

  // ------------------------------------------------------------- listeners

  onNotification(fn: (n: Notification) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private notify(n: Notification): void {
    for (const fn of this.listeners) {
      try {
        fn(n);
      } catch (e) {
        this.log.error('listener failed', { error: String(e) });
      }
    }
  }

  notice(level: 'info' | 'warning' | 'error', message: string): void {
    this.notify({ method: 'runner.notice', params: { level, message } });
  }

  // A notice about startup, also sent to clients that connect in the next
  // few minutes (the app is rarely connected while the runner starts).
  startupNotice(level: 'info' | 'warning' | 'error', message: string): void {
    this.startupNotices.push({ level, message });
    this.notice(level, message);
  }

  // Sent to each client after its hello.
  noticesForNewClient(): { level: 'info' | 'warning' | 'error'; message: string }[] {
    const out = this.clock.now() - this.startedAt < STARTUP_NOTICE_MS ? [...this.startupNotices] : [];
    if (!fs.existsSync(this.cfg.claudePath)) {
      out.push({ level: 'error', message: `The claude CLI isn't at ${this.cfg.claudePath}, so no turn can start. Install Claude Code, or set claudePath in runner.json.` });
    }
    return out;
  }

  // --------------------------------------------------------------- queries

  hello(): { runnerVersion: string; protocol: number; accounts: Account[]; defaults: { cwd: string; accountId: string } } {
    return {
      runnerVersion: RUNNER_VERSION,
      protocol: PROTOCOL_VERSION,
      accounts: this.accounts.list(),
      defaults: { cwd: this.cfg.defaults.cwd, accountId: this.defaultAccountId() },
    };
  }

  private defaultAccountId(): string {
    const accounts = this.accounts.list();
    const last = readRunnerJson(this.cfg.home).defaults?.accountId ?? this.cfg.defaults.accountId;
    if (last && accounts.some((a) => a.id === last)) return last;
    return accounts.find((a) => a.id === 'claude-main')?.id ?? accounts[0]?.id ?? 'claude-main';
  }

  list(include: ('inbox' | 'snoozed' | 'archived')[] = ['inbox']): ThreadSummary[] {
    const want = new Set(include);
    const out: ThreadSummary[] = [];
    for (const st of this.threads.values()) {
      if (want.has(this.bucket(st.rec))) out.push(this.summary(st));
    }
    return sortByActivity(out);
  }

  private bucket(rec: ThreadRecord): 'inbox' | 'snoozed' | 'archived' {
    if (rec.archivedAt) return 'archived';
    if (rec.snoozedUntil && Date.parse(rec.snoozedUntil) > this.clock.now()) return 'snoozed';
    return 'inbox';
  }

  search(query: string, limit = 50): ThreadSummary[] {
    const words = query.toLowerCase().split(/\s+/).filter(Boolean);
    const out: ThreadSummary[] = [];
    for (const st of this.threads.values()) {
      const hay = `${st.rec.title}\n${st.rec.preview}`.toLowerCase();
      if (words.every((w) => hay.includes(w))) out.push(this.summary(st));
    }
    return sortByActivity(out).slice(0, Math.max(0, Math.floor(limit)));
  }

  get(threadId: string): ThreadSummary {
    return this.summary(this.mustGet(threadId));
  }

  events(threadId: string, opts: { afterSeq?: number; beforeSeq?: number; limit?: number } = {}) {
    const st = this.mustGet(threadId);
    const log = this.store.log(threadId);
    const last = log.lastSeq;
    const limit = Math.min(Math.max(1, opts.limit ?? LIMITS.defaultEventsLimit), 10_000);
    let from: number;
    let to: number;
    if (opts.afterSeq !== undefined) {
      from = opts.afterSeq + 1;
      to = Math.min(last, opts.beforeSeq !== undefined ? opts.beforeSeq - 1 : last, from + limit - 1);
    } else if (opts.beforeSeq !== undefined) {
      to = Math.min(last, opts.beforeSeq - 1);
      from = Math.max(1, to - limit + 1);
    } else {
      to = last;
      from = Math.max(1, last - limit + 1);
    }
    const events = log.read(from, to);
    // Flush first so inProgress holds exactly what subscribers have seen.
    this.flushDeltas(st);
    return {
      events,
      firstSeq: events.length ? events[0].seq : 0,
      lastSeq: events.length ? events[events.length - 1].seq : last,
      inProgress: [...st.rt.inProgress.values()].filter((i) => i.text),
    };
  }

  // Backlog for a subscriber, read in the same tick it starts listening so
  // nothing falls between the replay and the live stream.
  backlog(threadId: string, afterSeq = 0): { events: PersistedEvent[]; inProgress: InProgressItem[] } {
    const st = this.mustGet(threadId);
    this.flushDeltas(st);
    const log = this.store.log(threadId);
    return {
      events: log.read(afterSeq + 1, log.lastSeq),
      inProgress: [...st.rt.inProgress.values()].filter((i) => i.text),
    };
  }

  // ------------------------------------------------------------- mutations

  create(params: {
    text: string;
    images?: ImageRef[];
    cwd?: string;
    accountId?: string;
    model?: string;
    permissionMode?: PermissionMode;
    title?: string;
  }): { thread: ThreadSummary; turnId: string } {
    this.checkAccepting();
    const accountId = params.accountId ?? this.defaultAccountId();
    if (!this.accounts.get(accountId)) throw new RpcError(ErrorCode.accountNotFound, `No account called ${accountId}`);
    // A blank folder means the default, not the runner's own folder.
    const cwd = path.resolve(expandHome(params.cwd?.trim() ? params.cwd.trim() : this.cfg.defaults.cwd));
    if (!isDirectory(cwd)) throw new RpcError(ErrorCode.badParams, `Folder not found: ${cwd}`);
    if (!params.text && !params.images?.length) throw new RpcError(ErrorCode.badParams, 'text or images required');
    checkImages(params.images ?? []);
    const now = this.isoNow();
    const id = crypto.randomUUID();
    const rec: ThreadRecord = {
      id,
      title: params.title?.trim() ? params.title.trim().slice(0, 200) : titleFrom(params.text),
      titleSet: Boolean(params.title?.trim()),
      cwd,
      accountId,
      provider: 'claude',
      permissionMode: params.permissionMode ?? 'full',
      status: 'idle',
      createdAt: now,
      updatedAt: now,
      lastActivityAt: now,
      preview: '',
      lastSeq: 0,
      lastSeenSeq: 0,
      nativeSessionId: crypto.randomUUID(),
      sessionUsed: false,
      lastTurnCompletedSeq: 0,
      queue: [],
      pendingApprovals: [],
    };
    if (params.model) rec.model = params.model;
    this.store.create(rec);
    const st: ThreadState = { rec, rt: newRuntime(this.clock.now()) };
    this.threads.set(id, st);
    this.rememberAccount(accountId);
    const turnId = this.sendTo(st, params.text ?? '', params.images ?? []);
    return { thread: this.summary(st), turnId };
  }

  // origin "runner" marks a message the runner sends by itself (restart.ts).
  send(threadId: string, text: string, images: ImageRef[] = [], opts: { origin?: 'runner' } = {}): { turnId: string } {
    const st = this.mustGet(threadId);
    this.checkAccepting();
    if (!text && images.length === 0) throw new RpcError(ErrorCode.badParams, 'text or images required');
    checkImages(images);
    return { turnId: this.sendTo(st, text, images, opts.origin) };
  }

  private sendTo(st: ThreadState, text: string, images: ImageRef[], origin?: 'runner'): string {
    const { rec, rt } = st;
    // Copy images into the thread's own media folder now, so a queued
    // message still works if inbox/ is cleaned before it's sent.
    const media = this.store.mediaDir(rec.id);
    const refs = images.map((img) => {
      if (!img?.path || !fs.existsSync(img.path)) throw new RpcError(ErrorCode.badParams, `Image not found: ${img?.path}`);
      if (path.dirname(img.path) === media) return imageRefFor(img.path, img.mediaType);
      try {
        return copyImageInto(media, img.path);
      } catch (e) {
        throw new RpcError(ErrorCode.badParams, (e as Error).message);
      }
    });
    // Sending to a snoozed or archived thread brings it back.
    if (rec.snoozedUntil || rec.archivedAt) {
      delete rec.snoozedUntil;
      delete rec.archivedAt;
      rt.releaseWhenIdle = false;
    }
    const turnId = crypto.randomUUID();
    const msg: QueuedSend = { turnId, text, images: refs };
    if (origin) msg.origin = origin;
    rec.lastActivityAt = this.isoNow();
    if (rt.turn || rec.queue.length) {
      // Behind a running turn, or behind messages that couldn't start
      // earlier: they go first.
      rec.queue.push(msg);
      this.markDirty(st);
      this.kickQueue(st);
      return turnId;
    }
    this.startTurn(st, msg);
    return turnId;
  }

  // Writes the turn's first events before changing any state, so if the
  // disk refuses (full, permissions) the thread is left as it was rather
  // than stuck on a turn that never started.
  private startTurn(st: ThreadState, msg: QueuedSend): void {
    const { rec, rt } = st;
    this.emit(st, { type: 'user.message', text: msg.text, images: msg.images, ...(msg.origin ? { origin: msg.origin } : {}) }, msg.turnId);
    try {
      this.emit(st, { type: 'turn.started', turnId: msg.turnId }, msg.turnId);
    } catch (e) {
      this.markDirty(st);
      throw e;
    }
    rt.idleTimer?.cancel();
    rt.idleTimer = undefined;
    rt.turn = { turnId: msg.turnId, startedAt: this.clock.now(), interruptRequested: false };
    rt.activeAt = this.clock.now();
    rec.turnId = msg.turnId;
    rec.lastActivityAt = this.isoNow();
    rec.status = rt.session && !rt.closing ? 'running' : 'starting';
    this.markDirty(st);
    this.deliver(st, msg).catch((e: unknown) => {
      this.log.error('could not start turn', { threadId: rec.id, error: String(e) });
      this.failTurn(st, e instanceof Error ? e.message : String(e));
    });
  }

  private async deliver(st: ThreadState, msg: QueuedSend): Promise<void> {
    const { rec, rt } = st;
    // A folder, account or settings change asked for a fresh CLI.
    if (rt.session && (rt.releaseWhenIdle || rec.handoff)) this.releaseSession(st);
    // Never two live CLIs on one session: wait for a releasing one to exit.
    while (rt.closing) await rt.closing;
    if (rt.turn?.turnId !== msg.turnId) return; // interrupted while waiting
    let text = msg.text;
    if (!rt.session) {
      const account = this.accounts.get(rec.accountId);
      if (!account) throw new Error(`Account ${rec.accountId} isn't available on this Mac.`);
      if (!isDirectory(rec.cwd)) throw new Error(`Folder not found: ${rec.cwd}`);
      if (rec.handoff) {
        text = this.handoffNote(st, account) + text;
        this.emit(st, { type: 'system.note', text: `Started a new session in ${rec.cwd} on ${account.title}.` }, msg.turnId);
        rec.nativeSessionId = crypto.randomUUID();
        rec.sessionUsed = false;
        rec.sessionCostTotal = 0;
        delete rec.handoff;
      } else if (rec.sessionUsed) {
        this.emit(st, { type: 'system.note', text: 'Resumed session' }, msg.turnId);
      }
      this.makeRoomForCli(st);
      this.startSession(st, account);
    }
    rt.session!.send({ id: msg.turnId, text, images: msg.images });
  }

  // Keeps the number of live CLIs at cfg.maxLive by releasing the one idle
  // the longest. CLIs with a turn, an approval, queued messages or
  // background work are never picked; if every other one is busy the cap
  // is passed rather than stopping work.
  private makeRoomForCli(starting: ThreadState): void {
    const live = [...this.threads.values()].filter((t) => t !== starting && t.rt.session && !t.rt.closing);
    if (live.length < this.cfg.maxLive) return;
    const idle = live
      .filter((t) => !t.rt.turn && t.rt.approvals.size === 0 && t.rec.queue.length === 0 && t.rt.tasks.length === 0)
      .sort((a, b) => a.rt.activeAt - b.rt.activeAt);
    for (const t of idle.slice(0, live.length - this.cfg.maxLive + 1)) {
      this.log.info('releasing the longest-idle CLI to stay under the cap', { threadId: t.rec.id, maxLive: this.cfg.maxLive });
      this.releaseSession(t);
    }
  }

  private startSession(st: ThreadState, account: Account): void {
    const { rec, rt } = st;
    const adapter = this.adapters[rec.provider];
    if (!adapter) throw new Error(`No adapter for ${rec.provider}`);
    if (!rec.nativeSessionId) rec.nativeSessionId = crypto.randomUUID();
    const gen = ++rt.generation;
    const resume = Boolean(rec.sessionUsed);
    const sink: SessionSink = {
      output: (o) => {
        if (rt.generation !== gen) return;
        try {
          this.onOutput(st, o);
        } catch (e) {
          // Most likely the disk (full, permissions). The CLI carries on;
          // say so rather than let the error look like a CLI crash.
          this.log.error('could not handle CLI output', { threadId: rec.id, kind: o.kind, error: String(e) });
          this.notice('error', `Couldn't save part of "${rec.title}": ${(e as Error).message}`);
        }
      },
      requestApproval: (req) => this.requestApproval(st, gen, req),
      requestQuestion: (req) => this.requestQuestion(st, gen, req),
      exited: (err) => this.onExited(st, gen, err),
    };
    rt.resumed = resume;
    rt.session = adapter.start(
      {
        threadId: rec.id,
        cwd: rec.cwd,
        account,
        model: rec.model,
        permissionMode: rec.permissionMode,
        sessionId: rec.nativeSessionId,
        resume,
        mediaDir: this.store.mediaDir(rec.id),
        blobsDir: this.store.blobsDir(rec.id),
        tmpDir: path.join(paths.run(this.cfg.home), 'tmp'),
        allowRules: rec.allowRules ?? [],
        env: threadEnv(rec.id, this.cfg.home),
      },
      sink,
    );
    this.log.info('session started', { threadId: rec.id, resume, accountId: account.id });
    this.markDirty(st);
  }

  private onOutput(st: ThreadState, o: AdapterOutput): void {
    const { rec, rt } = st;
    switch (o.kind) {
      case 'event': {
        const ev = o.event;
        if (ev.type === 'assistant.text' || ev.type === 'reasoning') {
          this.flushDeltas(st);
          rt.inProgress.delete(ev.itemId);
          rt.pendingDeltas.delete(ev.itemId);
        }
        if (ev.type === 'assistant.text') rec.preview = oneLine(ev.text, LIMITS.previewChars);
        this.emit(st, ev, rt.turn?.turnId);
        break;
      }
      case 'delta':
        this.addDelta(st, o.delta);
        break;
      case 'session':
        rec.nativeSessionId = o.nativeSessionId;
        rec.sessionUsed = true;
        if (rec.status === 'starting') rec.status = rt.approvals.size ? 'waiting' : 'running';
        this.markDirty(st);
        break;
      case 'context':
        rec.contextTokens = o.contextTokens;
        this.markDirty(st);
        break;
      case 'cliTurn':
        // The CLI started a turn of its own. Give it a turn in the thread so
        // its output isn't loose, the status says running, and the app
        // flags it when it ends. A message the runner already sent waits
        // in the CLI's queue; its turn takes this output too.
        if (!rt.turn) this.openCliTurn(st);
        rt.turn!.cliStarted = true;
        if (o.note) this.emit(st, { type: 'system.note', text: o.note }, rt.turn!.turnId);
        break;
      case 'tasks': {
        const ended = rt.tasks.some((t) => !o.tasks.some((n) => n.id === t.id));
        rt.tasks = o.tasks;
        // The CLI reports the list shrinking a moment before it starts the
        // turn that reads the result. A restart in between would lose that
        // turn, so the thread stays busy until it starts.
        if (ended && !rt.turn) {
          rt.wakeTimer?.cancel();
          rt.wakeTimer = this.clock.setTimeout(() => {
            rt.wakeTimer = undefined;
            this.markDirty(st);
          }, WAKE_GRACE_MS);
        }
        // No summary field changes, but a pending restart waits on
        // background work and re-checks on thread.updated.
        this.markDirty(st);
        // Background work keeps the CLI live; once it's done the idle
        // countdown starts again.
        if (o.tasks.length) {
          rt.idleTimer?.cancel();
          rt.idleTimer = undefined;
        } else if (!rt.turn) this.scheduleIdle(st);
        break;
      }
      case 'allowRules': {
        const rules = new Set(rec.allowRules ?? []);
        for (const r of o.rules) rules.add(r);
        rec.allowRules = [...rules];
        this.markDirty(st);
        break;
      }
      case 'result': {
        const r = o.result;
        const turn = rt.turn;
        // A turn the CLI ran by itself while this thread's own message was
        // still in its queue: the thread's turn goes on until that message
        // is answered.
        const other = r.answers !== undefined ? turn !== undefined && r.answers !== turn.turnId && !turn.auto : Boolean(r.own && turn && !turn.auto);
        if (other) {
          this.flushDeltas(st);
          rt.inProgress.clear();
          break;
        }
        this.completeTurn(st, r);
        break;
      }
    }
  }

  private openCliTurn(st: ThreadState): void {
    const { rec, rt } = st;
    rt.wakeTimer?.cancel();
    rt.wakeTimer = undefined;
    const turnId = crypto.randomUUID();
    this.emit(st, { type: 'turn.started', turnId }, turnId);
    rt.idleTimer?.cancel();
    rt.idleTimer = undefined;
    rt.turn = { turnId, startedAt: this.clock.now(), interruptRequested: false, auto: true };
    rt.activeAt = this.clock.now();
    rec.turnId = turnId;
    rec.status = rt.approvals.size ? 'waiting' : 'running';
    rec.lastActivityAt = this.isoNow();
    this.markDirty(st);
  }

  private completeTurn(st: ThreadState, r: TurnResult): void {
    const { rec, rt } = st;
    const turn = rt.turn;
    if (!turn) return;
    this.flushDeltas(st);
    rt.inProgress.clear();
    this.expireApprovals(st, 'The turn ended.');
    let turnCost: number | undefined;
    if (r.totalCostUsd !== undefined) {
      // total_cost_usd is a running total for the native session (resume
      // carries it on); a drop means the CLI started counting again.
      const prev = rec.sessionCostTotal ?? 0;
      turnCost = r.totalCostUsd >= prev ? r.totalCostUsd - prev : r.totalCostUsd;
      rec.sessionCostTotal = r.totalCostUsd;
      rec.costUsd = round6((rec.costUsd ?? 0) + turnCost);
      turnCost = round6(turnCost);
    }
    const outcome = turn.interruptRequested && r.outcome !== 'completed' ? 'interrupted' : r.outcome;
    if (outcome === 'failed' && r.error) this.emit(st, { type: 'error', message: r.error }, turn.turnId);
    const body: EventBody = {
      type: 'turn.completed',
      turnId: turn.turnId,
      outcome,
      durationMs: Math.max(0, this.clock.now() - turn.startedAt),
    };
    if (turnCost !== undefined) body.costUsd = turnCost;
    if (r.usage) body.usage = r.usage;
    if (outcome === 'failed' && r.error) body.error = r.error;
    const ev = this.emit(st, body, turn.turnId);
    this.endTurn(st, ev.seq, outcome === 'failed' ? 'error' : 'idle');
  }

  private endTurn(st: ThreadState, completedSeq: number, status: ThreadStatus): void {
    const { rec, rt } = st;
    rt.turn?.interruptTimer?.cancel();
    rt.turn = undefined;
    rt.activeAt = this.clock.now();
    rec.turnId = undefined;
    rec.lastTurnCompletedSeq = completedSeq;
    rec.status = status;
    rec.lastActivityAt = this.isoNow();
    this.markDirty(st);
    this.afterTurn(st);
  }

  // A turn that ended without a result from the CLI (spawn failure, crash).
  private failTurn(st: ThreadState, message: string): void {
    const { rec, rt } = st;
    const turn = rt.turn;
    if (!turn) return;
    this.persistInProgress(st, turn.turnId);
    this.expireApprovals(st, 'The turn ended.');
    const interrupted = turn.interruptRequested;
    if (!interrupted) this.emit(st, { type: 'error', message }, turn.turnId);
    const body: EventBody = {
      type: 'turn.completed',
      turnId: turn.turnId,
      outcome: interrupted ? 'interrupted' : 'failed',
      durationMs: Math.max(0, this.clock.now() - turn.startedAt),
    };
    if (!interrupted) body.error = message;
    const ev = this.emit(st, body, turn.turnId);
    this.endTurn(st, ev.seq, interrupted ? 'idle' : 'error');
  }

  private afterTurn(st: ThreadState): void {
    if (this.stopping) return;
    // A snoozed or archived thread keeps its queue until it comes back.
    if (this.bucket(st.rec) === 'inbox' && this.kickQueue(st)) return;
    this.scheduleIdle(st);
  }

  private onExited(st: ThreadState, gen: number, err?: Error): void {
    const { rec, rt } = st;
    if (rt.generation !== gen) return;
    rt.session = undefined;
    rt.tasks = [];
    rt.wakeTimer?.cancel();
    rt.wakeTimer = undefined;
    rt.idleTimer?.cancel();
    rt.idleTimer = undefined;
    this.log.info('session ended', { threadId: rec.id, error: err?.message });
    if (rt.releasedGen === gen) {
      // A CLI we asked to stop. A turn that is waiting for it to go starts
      // the next CLI once it has. A turn it had started by itself while
      // shutting down ends with it.
      rt.releasedGen = undefined;
      if (rt.turn?.auto) {
        rt.turn.interruptRequested = true;
        this.failTurn(st, 'The session was released.');
      }
      this.markDirty(st);
      return;
    }
    if (rt.turn) {
      // A resume can fail if the CLI never wrote the session's transcript
      // (it died before the first message). Start a fresh session once.
      if (err && rt.resumed && !rt.retriedFresh && /no conversation found/i.test(err.message) && rec.status === 'starting') {
        rt.retriedFresh = true;
        rec.sessionUsed = false;
        rec.nativeSessionId = crypto.randomUUID();
        rec.sessionCostTotal = 0;
        const account = this.accounts.get(rec.accountId);
        if (account && rt.turn) {
          this.emit(st, { type: 'system.note', text: "Couldn't resume the earlier session, so this is a new one." }, rt.turn.turnId);
          const turnId = rt.turn.turnId;
          const log = this.store.log(rec.id);
          const msg = log.read(Math.max(1, log.lastSeq - 50), log.lastSeq).reverse().find((e) => e.type === 'user.message' && e.turnId === turnId);
          if (msg && msg.type === 'user.message') {
            this.startSession(st, account);
            rt.session!.send({ id: turnId, text: msg.text, images: msg.images });
            return;
          }
        }
      }
      this.failTurn(st, err?.message || 'The CLI stopped unexpectedly.');
    } else {
      this.markDirty(st);
    }
  }

  interrupt(threadId: string): Record<string, never> {
    const st = this.mustGet(threadId);
    const { rt } = st;
    const turn = rt.turn;
    if (!turn) return {};
    turn.interruptRequested = true;
    this.expireApprovals(st, 'Interrupted.');
    const session = rt.session;
    // Nothing is running in the CLI for a turn that was only opened for a
    // background subagent's approval, so nothing would end it.
    if (!session || rt.closing || (turn.auto && !turn.cliStarted)) {
      this.failTurn(st, 'Interrupted.');
      return {};
    }
    turn.interruptTimer ??= this.clock.setTimeout(() => {
      if (rt.turn !== turn) return;
      this.log.warn('the CLI did not end an interrupted turn; ending it', { threadId });
      this.failTurn(st, 'Interrupted.');
    }, INTERRUPT_GRACE_MS);
    session.interrupt().catch((e: unknown) => {
      // Before the CLI has initialised there's nothing to interrupt; stop it.
      this.log.warn('interrupt failed, stopping the CLI', { threadId, error: String(e) });
      session.kill();
    });
    return {};
  }

  update(params: {
    threadId: string;
    title?: string;
    cwd?: string;
    accountId?: string;
    model?: string | null;
    permissionMode?: PermissionMode;
    snoozedUntil?: string | null;
    archived?: boolean;
  }): { thread: ThreadSummary } {
    const st = this.mustGet(params.threadId);
    const { rec, rt } = st;
    let release = false;
    let stop = false;
    if (params.title !== undefined) {
      rec.title = params.title.trim().slice(0, 200) || rec.title;
      rec.titleSet = true;
    }
    if (params.cwd !== undefined && !params.cwd.trim()) throw new RpcError(ErrorCode.badParams, 'cwd must not be blank');
    const newCwd = params.cwd !== undefined ? path.resolve(expandHome(params.cwd.trim())) : undefined;
    if (newCwd !== undefined && !isDirectory(newCwd)) throw new RpcError(ErrorCode.badParams, `Folder not found: ${newCwd}`);
    if (params.accountId !== undefined && !this.accounts.get(params.accountId)) {
      throw new RpcError(ErrorCode.accountNotFound, `No account called ${params.accountId}`);
    }
    const cwdChanged = newCwd !== undefined && newCwd !== rec.cwd;
    const accountChanged = params.accountId !== undefined && params.accountId !== rec.accountId;
    if (cwdChanged || accountChanged) {
      // Takes effect on the next turn as a new native session.
      if (rec.sessionUsed || rt.session) rec.handoff ??= { fromCwd: rec.cwd, fromAccountId: rec.accountId };
      if (newCwd !== undefined) rec.cwd = newCwd;
      if (params.accountId !== undefined) {
        rec.accountId = params.accountId;
        this.rememberAccount(params.accountId);
      }
      release = true;
    }
    if (params.model !== undefined) {
      const model = params.model || undefined;
      if (model !== rec.model) {
        if (model) rec.model = model;
        else delete rec.model;
        if (rt.session && !release) {
          rt.session.setModel(model).catch(() => {
            rt.releaseWhenIdle = true;
          });
        }
      }
    }
    if (params.permissionMode !== undefined && params.permissionMode !== rec.permissionMode) {
      rec.permissionMode = params.permissionMode;
      if (rt.session && !release) {
        rt.session.setPermissionMode(params.permissionMode).catch(() => {
          rt.releaseWhenIdle = true;
          if (!rt.turn) this.releaseSession(st);
        });
      }
    }
    if (params.snoozedUntil !== undefined) {
      if (params.snoozedUntil === null) delete rec.snoozedUntil;
      else {
        const t = Date.parse(params.snoozedUntil);
        if (Number.isNaN(t)) throw new RpcError(ErrorCode.badParams, 'snoozedUntil must be an ISO time');
        rec.snoozedUntil = new Date(t).toISOString();
        stop = true;
      }
      this.armSnoozeTimer();
    }
    if (params.archived !== undefined) {
      if (params.archived) {
        rec.archivedAt = this.isoNow();
        stop = true;
      } else delete rec.archivedAt;
    }
    if (!stop && this.bucket(rec) === 'inbox') this.kickQueue(st);
    if (stop) {
      // Snoozing or archiving stops the CLI: end any turn, then release.
      rt.releaseWhenIdle = true;
      if (rt.turn) this.interrupt(rec.id);
      else this.releaseSession(st);
    } else if (release) {
      rt.releaseWhenIdle = true;
      if (!rt.turn) this.releaseSession(st);
    }
    rec.updatedAt = this.isoNow();
    this.markDirty(st);
    return { thread: this.summary(st) };
  }

  markSeen(threadId: string, seq: number): { thread: ThreadSummary } {
    const st = this.mustGet(threadId);
    const { rec } = st;
    const last = Math.max(rec.lastSeq, this.store.log(threadId).lastSeq);
    rec.lastSeenSeq = Math.max(rec.lastSeenSeq, Math.min(Math.floor(seq), last));
    rec.forceUnread = false;
    this.markDirty(st);
    return { thread: this.summary(st) };
  }

  respondApproval(params: {
    threadId: string;
    approvalId: string;
    decision: ApprovalDecision;
    message?: string;
    answers?: Record<string, string>;
  }): Record<string, never> {
    const st = this.mustGet(params.threadId);
    const pending = st.rt.approvals.get(params.approvalId);
    if (!pending) throw new RpcError(ErrorCode.badParams, 'That approval is no longer pending.');
    if (pending.kind === 'question') {
      if (params.decision === 'answered') {
        const answers = matchAnswers(pending.questions, params.answers ?? {});
        if (!answers) throw new RpcError(ErrorCode.badParams, 'answers must cover every question');
        this.resolveApproval(st, pending.approvalId, 'answered', params.message);
        pending.resolve({ answers });
      } else if (params.decision === 'deny') {
        this.resolveApproval(st, pending.approvalId, 'deny', params.message);
        pending.resolve({ answers: null, message: params.message });
      } else {
        throw new RpcError(ErrorCode.badParams, 'A question takes "answered" or "deny".');
      }
    } else {
      if (params.decision !== 'allow' && params.decision !== 'allowAlways' && params.decision !== 'deny') {
        throw new RpcError(ErrorCode.badParams, 'An approval takes "allow", "allowAlways" or "deny".');
      }
      this.resolveApproval(st, pending.approvalId, params.decision, params.message);
      pending.resolve({ decision: params.decision, message: params.message });
    }
    return {};
  }

  importMedia(p: string): { image: ImageRef } {
    const src = path.resolve(expandHome(p));
    if (!fs.existsSync(src)) throw new RpcError(ErrorCode.badParams, `File not found: ${src}`);
    try {
      return { image: copyImageInto(paths.inbox(this.cfg.home), src) };
    } catch (e) {
      throw new RpcError(ErrorCode.badParams, (e as Error).message);
    }
  }

  // ------------------------------------------------------------- approvals

  // A request can come with no turn running: a background subagent keeps
  // working after the turn that started it ended. It gets a turn of its own
  // so the card is shown rather than the subagent being stopped.
  private turnForRequest(st: ThreadState, gen: number): boolean {
    const { rt } = st;
    if (rt.generation !== gen || rt.closing || this.stopping) return false;
    if (!rt.turn) this.openCliTurn(st);
    return true;
  }

  private requestApproval(st: ThreadState, gen: number, req: ToolApprovalRequest): Promise<ToolApprovalAnswer> {
    if (!this.turnForRequest(st, gen)) return Promise.resolve({ decision: 'expired' });
    const approvalId = crypto.randomUUID();
    const body: EventBody = {
      type: 'approval.requested',
      approvalId,
      name: req.name,
      title: req.title,
      input: req.input,
      options: req.canAlwaysAllow ? ['allow', 'allowAlways', 'deny'] : ['allow', 'deny'],
    };
    if (req.toolUseId) body.itemId = req.toolUseId;
    return new Promise((resolve) => {
      this.addApproval(st, { approvalId, kind: 'tool', resolve }, body, req.signal);
    });
  }

  private requestQuestion(st: ThreadState, gen: number, req: QuestionRequest): Promise<QuestionAnswer> {
    if (!this.turnForRequest(st, gen)) return Promise.resolve({ answers: null });
    const approvalId = crypto.randomUUID();
    const body: EventBody = { type: 'question.requested', approvalId, questions: req.questions };
    if (req.toolUseId) body.itemId = req.toolUseId;
    return new Promise((resolve) => {
      this.addApproval(st, { approvalId, kind: 'question', questions: req.questions, resolve }, body, req.signal);
    });
  }

  private addApproval(st: ThreadState, pending: PendingApproval, body: EventBody, signal: AbortSignal): void {
    const { rec, rt } = st;
    rt.approvals.set(pending.approvalId, pending);
    rec.pendingApprovals.push(pending.approvalId);
    this.emit(st, body, rt.turn?.turnId);
    rec.status = 'waiting';
    this.markDirty(st);
    signal.addEventListener('abort', () => this.expireApproval(st, pending.approvalId, 'Cancelled.'), { once: true });
  }

  private resolveApproval(st: ThreadState, approvalId: string, decision: ApprovalDecision, message?: string): void {
    const { rec, rt } = st;
    rt.approvals.delete(approvalId);
    rec.pendingApprovals = rec.pendingApprovals.filter((x) => x !== approvalId);
    const body: EventBody = { type: 'approval.resolved', approvalId, decision };
    if (message) body.message = message;
    this.emit(st, body, rt.turn?.turnId);
    if (rec.status === 'waiting' && rt.approvals.size === 0) rec.status = rt.turn ? 'running' : 'idle';
    this.markDirty(st);
  }

  private expireApproval(st: ThreadState, approvalId: string, message: string): void {
    const pending = st.rt.approvals.get(approvalId);
    if (!pending) return;
    this.resolveApproval(st, approvalId, 'expired', message);
    if (pending.kind === 'tool') pending.resolve({ decision: 'expired', message });
    else pending.resolve({ answers: null, message });
  }

  private expireApprovals(st: ThreadState, message: string): void {
    for (const id of [...st.rt.approvals.keys()]) this.expireApproval(st, id, message);
  }

  // ---------------------------------------------------------- idle release

  private scheduleIdle(st: ThreadState): void {
    const { rec, rt } = st;
    rt.idleTimer?.cancel();
    rt.idleTimer = undefined;
    if (!rt.session || rt.closing || rt.turn || rec.queue.length || rt.approvals.size) return;
    if (rt.releaseWhenIdle || this.bucket(rec) !== 'inbox') {
      this.releaseSession(st);
      return;
    }
    // A background shell or subagent is still working; the countdown starts
    // when it finishes.
    if (rt.tasks.length) return;
    rt.idleTimer = this.clock.setTimeout(() => {
      rt.idleTimer = undefined;
      if (!rt.turn && rec.queue.length === 0 && rt.tasks.length === 0) this.releaseSession(st);
    }, this.cfg.idleMs);
  }

  // Ends the CLI's input so it exits; the next send resumes the session.
  // Background work would keep the CLI alive (and could start a turn in a
  // thread that's just been snoozed), so if there is any it's stopped
  // straight away, with a note saying what was stopped.
  private releaseSession(st: ThreadState): void {
    const { rt, rec } = st;
    rt.idleTimer?.cancel();
    rt.idleTimer = undefined;
    if (!rt.session || rt.closing) return;
    const session = rt.session;
    const hard = rt.tasks.length > 0;
    if (hard) {
      const what = rt.tasks.map((t) => t.description || t.type).join('; ');
      try {
        this.emit(st, { type: 'system.note', text: `Stopped background work when the session was released: ${what}` }, rt.turn?.turnId);
      } catch (e) {
        this.log.error('could not save a note', { threadId: rec.id, error: String(e) });
      }
      rt.tasks = [];
    }
    rt.releaseWhenIdle = false;
    rt.releasedGen = rt.generation;
    this.log.info('releasing CLI', { threadId: rec.id, hard });
    rt.closing = session
      .end({ hard })
      .catch((e: unknown) => this.log.warn('release failed', { threadId: rec.id, error: String(e) }))
      .finally(() => {
        rt.closing = undefined;
        if (rt.session === session) {
          // The adapter didn't report an exit; treat it as gone.
          rt.session = undefined;
        }
        this.markDirty(st);
      });
  }

  // ----------------------------------------------------------------- snooze

  private armSnoozeTimer(): void {
    this.snoozeTimer?.cancel();
    this.snoozeTimer = undefined;
    if (this.stopping) return;
    const now = this.clock.now();
    let next = Infinity;
    for (const st of this.threads.values()) {
      if (!st.rec.snoozedUntil) continue;
      const t = Date.parse(st.rec.snoozedUntil);
      if (t <= now) this.wake(st);
      else next = Math.min(next, t);
    }
    if (next === Infinity) return;
    // Re-check at least hourly so long snoozes survive clock changes.
    this.snoozeTimer = this.clock.setTimeout(() => this.armSnoozeTimer(), Math.min(next - now, 3_600_000));
  }

  private wake(st: ThreadState): void {
    delete st.rec.snoozedUntil;
    st.rec.forceUnread = true;
    st.rec.updatedAt = this.isoNow();
    this.markDirty(st);
    this.kickQueue(st);
  }

  // Starts the next queued message if nothing is running. Returns true if
  // one started. One that can't be written (disk full) stays at the front.
  private kickQueue(st: ThreadState): boolean {
    if (st.rt.turn || st.rec.queue.length === 0 || this.stopping) return false;
    const next = st.rec.queue.shift()!;
    this.markDirty(st);
    try {
      this.startTurn(st, next);
      return true;
    } catch (e) {
      st.rec.queue.unshift(next);
      this.log.error('could not start a queued message', { threadId: st.rec.id, error: String(e) });
      this.notice('error', `Couldn't start a message in "${st.rec.title}": ${(e as Error).message}`);
      return false;
    }
  }

  // ---------------------------------------------------------------- events

  private emit(st: ThreadState, body: EventBody, turnId?: string): PersistedEvent {
    this.flushDeltas(st);
    const log = this.store.log(st.rec.id);
    const event = { seq: log.lastSeq + 1, ts: this.isoNow(), threadId: st.rec.id, ...(turnId ? { turnId } : {}), ...body } as PersistedEvent;
    log.append(event);
    st.rec.lastSeq = event.seq;
    st.rec.updatedAt = event.ts;
    this.markDirty(st);
    this.notify({ method: 'thread.event', params: { threadId: st.rec.id, event } });
    return event;
  }

  private addDelta(st: ThreadState, d: DeltaBody): void {
    const { rt } = st;
    if (d.type !== 'tool.output.delta') {
      const type = d.type === 'assistant.text.delta' ? 'assistant.text' : 'reasoning';
      const item = rt.inProgress.get(d.itemId) ?? { itemId: d.itemId, type, text: '' };
      item.text += d.text;
      rt.inProgress.set(d.itemId, item);
    }
    const pending = rt.pendingDeltas.get(d.itemId);
    if (pending) pending.text += d.text;
    else rt.pendingDeltas.set(d.itemId, { type: d.type, text: d.text });
    rt.deltaTimer ??= this.clock.setTimeout(() => {
      rt.deltaTimer = undefined;
      this.flushDeltas(st);
    }, DELTA_INTERVAL_MS);
  }

  // Sends coalesced deltas. Transient events carry the seq of the last
  // persisted event and don't consume a number.
  private flushDeltas(st: ThreadState): void {
    const { rt, rec } = st;
    rt.deltaTimer?.cancel();
    rt.deltaTimer = undefined;
    if (rt.pendingDeltas.size === 0) return;
    const seq = this.store.log(rec.id).lastSeq;
    const ts = this.isoNow();
    for (const [itemId, d] of rt.pendingDeltas) {
      const event = { seq, ts, threadId: rec.id, ...(rt.turn ? { turnId: rt.turn.turnId } : {}), type: d.type, itemId, text: d.text } as AnyEvent;
      this.notify({ method: 'thread.event', params: { threadId: rec.id, event } });
    }
    rt.pendingDeltas.clear();
  }

  // --------------------------------------------------------------- helpers

  private markDirty(st: ThreadState): void {
    this.dirty.add(st.rec.id);
    if (this.flushScheduled) return;
    this.flushScheduled = true;
    this.defer(() => this.flush());
  }

  // Saves changed thread.json files and sends thread.updated for them.
  flush(): void {
    this.flushScheduled = false;
    const ids = [...this.dirty];
    this.dirty.clear();
    for (const id of ids) {
      const st = this.threads.get(id);
      if (!st) continue;
      try {
        this.store.save(st.rec);
      } catch (e) {
        this.log.error('could not save thread', { threadId: id, error: String(e) });
      }
      this.notify({ method: 'thread.updated', params: { thread: this.summary(st) } });
    }
  }

  summary(st: ThreadState): ThreadSummary {
    const { rec, rt } = st;
    const running = rec.status === 'running' || rec.status === 'starting';
    const s: ThreadSummary = {
      id: rec.id,
      title: rec.title,
      cwd: rec.cwd,
      accountId: rec.accountId,
      provider: rec.provider,
      permissionMode: rec.permissionMode,
      status: rec.status,
      live: Boolean(rt.session),
      needsYou: rec.status === 'waiting' || Boolean(rec.forceUnread) || (!running && rec.lastTurnCompletedSeq > rec.lastSeenSeq),
      createdAt: rec.createdAt,
      updatedAt: rec.updatedAt,
      lastActivityAt: rec.lastActivityAt,
      preview: rec.preview,
      lastSeq: rec.lastSeq,
      lastSeenSeq: rec.lastSeenSeq,
    };
    if (rec.model) s.model = rec.model;
    if (rec.snoozedUntil) s.snoozedUntil = rec.snoozedUntil;
    if (rec.archivedAt) s.archivedAt = rec.archivedAt;
    if (rec.nativeSessionId && rec.sessionUsed) s.nativeSessionId = rec.nativeSessionId;
    if (rec.contextTokens !== undefined) s.contextTokens = rec.contextTokens;
    if (rec.costUsd !== undefined) s.costUsd = rec.costUsd;
    return s;
  }

  private mustGet(threadId: string): ThreadState {
    const st = typeof threadId === 'string' ? this.threads.get(threadId) : undefined;
    if (!st) throw new RpcError(ErrorCode.threadNotFound, `Thread not found: ${threadId}`);
    return st;
  }

  private rememberAccount(accountId: string): void {
    try {
      const json = readRunnerJson(this.cfg.home);
      if (json.defaults?.accountId === accountId) return;
      json.defaults = { ...json.defaults, accountId };
      writeRunnerJson(this.cfg.home, json);
    } catch (e) {
      this.log.warn('could not save default account', { error: String(e) });
    }
  }

  // A short note that gives a new native session the gist of the thread so
  // far, used when the folder or account changes.
  private handoffNote(st: ThreadState, account: Account): string {
    const { rec } = st;
    const from = rec.handoff!;
    const log = this.store.log(rec.id);
    const recent = log.read(Math.max(1, log.lastSeq - 200), log.lastSeq);
    const lines: string[] = [];
    let budget = 6000;
    for (const e of recent.reverse()) {
      // Skip the user message that started this turn; it follows the note.
      if (e.type === 'user.message' && e.turnId === rec.turnId) continue;
      if (e.type !== 'user.message' && e.type !== 'assistant.text') continue;
      const who = e.type === 'user.message' ? 'User' : 'Assistant';
      const text = e.text.length > 800 ? e.text.slice(0, 800) + '…' : e.text;
      const line = `${who}: ${text}`;
      if (line.length > budget) break;
      budget -= line.length;
      lines.unshift(line);
    }
    const fromAccount = this.accounts.get(from.fromAccountId)?.title ?? from.fromAccountId;
    if (from.rebuilt) {
      return (
        `[Threadbare handoff] This conversation's earlier session couldn't be found, so this is a fresh session in ${rec.cwd}. ` +
        `Recent messages, for context:\n\n${lines.join('\n\n') || '(none)'}\n\n[End of handoff. The new message follows.]\n\n`
      );
    }
    const moved =
      from.fromCwd !== rec.cwd && from.fromAccountId !== rec.accountId
        ? `from ${from.fromCwd} on ${fromAccount} to ${rec.cwd} on ${account.title}`
        : from.fromCwd !== rec.cwd
          ? `from ${from.fromCwd} to ${rec.cwd}`
          : `from the ${fromAccount} login to ${account.title}`;
    return (
      `[Threadbare handoff] This conversation moved ${moved}, so this is a fresh session. ` +
      `Recent messages, for context:\n\n${lines.join('\n\n') || '(none)'}\n\n[End of handoff. The new message follows.]\n\n`
    );
  }

  private isoNow(): string {
    return new Date(this.clock.now()).toISOString();
  }

  // Test and CLI helpers.
  threadIds(): string[] {
    return [...this.threads.keys()];
  }

  isLive(threadId: string): boolean {
    return Boolean(this.threads.get(threadId)?.rt.session);
  }

  hasIdleTimer(threadId: string): boolean {
    return Boolean(this.threads.get(threadId)?.rt.idleTimer);
  }

  status(threadId: string): ThreadStatus | undefined {
    return this.threads.get(threadId)?.rec.status;
  }

  // A note outside any turn (restart.ts: "Runner restarted: ...").
  note(threadId: string, text: string): void {
    this.emit(this.mustGet(threadId), { type: 'system.note', text });
  }
}

function checkImages(images: ImageRef[]): void {
  for (const img of images) {
    if (!img || typeof img.path !== 'string' || !fs.existsSync(img.path)) {
      throw new RpcError(ErrorCode.badParams, `Image not found: ${img?.path}`);
    }
  }
}

function newRuntime(activeAt: number): Runtime {
  return {
    generation: 0,
    resumed: false,
    retriedFresh: false,
    tasks: [],
    activeAt,
    approvals: new Map(),
    releaseWhenIdle: false,
    inProgress: new Map(),
    pendingDeltas: new Map(),
  };
}

function sortByActivity(list: ThreadSummary[]): ThreadSummary[] {
  return list.sort((a, b) => (a.lastActivityAt < b.lastActivityAt ? 1 : a.lastActivityAt > b.lastActivityAt ? -1 : 0));
}

export function titleFrom(text: string): string {
  const line = (text ?? '').split('\n').map((l) => l.trim()).find(Boolean) ?? '';
  if (!line) return 'Image';
  return line.length > LIMITS.titleChars ? line.slice(0, LIMITS.titleChars).trimEnd() : line;
}

export function oneLine(text: string, max: number): string {
  const s = text.replace(/\s+/g, ' ').trim();
  return s.length > max ? s.slice(0, max - 1).trimEnd() + '…' : s;
}

function round6(n: number): number {
  return Math.round(n * 1e6) / 1e6;
}

// Maps answers keyed by question text, header or index to question text,
// which is what the CLI's AskUserQuestion expects.
export function matchAnswers(questions: Question[], answers: Record<string, string>): Record<string, string> | null {
  const out: Record<string, string> = {};
  questions.forEach((q, i) => {
    const v = answers[q.question] ?? (q.header ? answers[q.header] : undefined) ?? answers[String(i)];
    if (typeof v === 'string') out[q.question] = v;
  });
  if (questions.length && Object.keys(out).length === 0) return null;
  return out;
}
