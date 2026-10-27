// The thread manager: owns threads, turns, the event log, approvals, idle
// release and snoozes. Providers plug in through AgentAdapter; the WebSocket
// server in rpc.ts is a thin layer over the public methods here.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import type {
  Panel,
  Account,
  AnyEvent,
  ApprovalDecision,
  BackgroundTask as ProtocolBackgroundTask,
  CliPolicy,
  CliStatus,
  DeltaBody,
  DeltaType,
  EffortLevel,
  EventBody,
  ImageRef,
  InProgressItem,
  MessageOrigin,
  ModelChoice,
  PermissionMode,
  PersistedEvent,
  Provider,
  Question,
  RunnerDefaults,
  Subagent,
  ThreadStatus,
  ThreadSummary,
  TurnOutcome,
} from './protocol.ts';
import { ErrorCode, LIMITS, PROTOCOL_VERSION, RpcError } from './protocol.ts';
import type { LibrarianStatus, Project, Schedule } from './protocol.ts';
import type { Projects } from './projects.ts';
import type { Settings } from './settings.ts';
import type {
  AgentAdapter,
  AgentSession,
  AdapterOutput,
  BackgroundTask,
  QuestionAnswer,
  QuestionRequest,
  SessionSink,
  SubagentUpdate,
  ToolApprovalAnswer,
  ToolApprovalRequest,
  TurnResult,
} from './adapters/types.ts';
import { SessionNotFoundError } from './adapters/types.ts';
import type { ThreadRecord, ThreadStore, QueuedSend, SubagentRecord } from './store.ts';
import type { Clock, TimerHandle } from './clock.ts';
import type { Logger } from './log.ts';
import { threadEnv } from './restart.ts';
import { stripModelSuffix, type AccountRegistry, type LearnedAccountInfo } from './accounts.ts';
import { pickAccount as pickByRoom, type UsageReading } from './usage.ts';
import { RUNNER_VERSION, expandHome, paths, readRunnerJson, writeRunnerJson, type Config } from './config.ts';
import { copyImageInto, imageRefFor } from './media.ts';
import { isDirectory } from './fsutil.ts';
import { copySessionTranscript, subagentTranscriptPath } from './transcripts.ts';
import { readSubagentTranscript } from './adapters/claude/subagents.ts';
import { fileContext } from './adapters/claude/normalize.ts';
import type { Models } from './models/index.ts';
import { SERVER_NAME, approvalTitle } from './threadbare-mcp.ts';
import { END_TURN_TOOL, needsFromText, needsFromTool } from './needs.ts';
import type { Needs } from './needs.ts';
import {
  EMPTY_PATCH_SET,
  hookApplies,
  loadPatchSet,
  projectPanels,
  renderPanel,
  runCommand,
  simctlScreenshot,
  type PanelRender,
  type PatchCache,
  type PatchSet,
  type Screenshot,
} from './patches.ts';

export type Notification =
  | { method: 'thread.updated'; params: { thread: ThreadSummary } }
  | { method: 'thread.event'; params: { threadId: string; event: AnyEvent } }
  | { method: 'thread.deleted'; params: { threadId: string } }
  | { method: 'accounts.updated'; params: { accounts: Account[] } }
  | { method: 'runner.notice'; params: { level: 'info' | 'warning' | 'error'; message: string } }
  | { method: 'schedules.updated'; params: { schedules: Schedule[] } }
  | { method: 'clis.updated'; params: { clis: CliStatus[] } }
  | { method: 'settings.updated'; params: { settings: Settings } }
  | { method: 'runner.updates'; params: { updates: RunnerUpdates } }
  | { method: 'projects.updated'; params: { projects: Project[] } }
  | { method: 'librarian.updated'; params: { librarian: LibrarianStatus } }
  // Only from a draining runner, to the primary (handover.ts).
  | { method: 'drain.handedOver'; params: { threadId: string } }
  | { method: 'drain.usage'; params: { accountId: string; reading: UsageReading } };

// hello's `updates` and runner.updates (docs/protocol.md, "Runner updates").
export type RunnerUpdates = {
  state: 'off' | 'idle' | 'checking' | 'building' | 'waiting' | 'failed';
  commit?: string;
  subject?: string;
  reason?: string;
  oldRunners: { version: string; threads: string[] }[];
  launcherChanged?: true;
};

// What the librarian (librarian.ts) hears about threads: a turn that ended,
// and a folder move.
export type ThreadActivity =
  | { kind: 'turn.end'; threadId: string; outcome: TurnOutcome; edited: string[] }
  | { kind: 'moved'; threadId: string; from: string; to: string };

// The seams to D's and E's modules (usage.ts, updates/), as far as the
// runner uses them. They're structural so tests can pass small fakes.

// D's UsageStore, as the runner uses it: a session's `limits` output goes
// to record().
export type UsageSink = {
  record(accountId: string, reading: UsageReading): void;
  // Fired when what it knows changes enough to tell clients (UsageStore's
  // onChange). The runner then sends accounts.updated through its throttle.
  onChange?(fn: (accountIds: string[]) => void): () => void;
};

// E's CliUpdates, as the runner and rpc.ts use it.
export type CliControl = {
  list(): CliStatus[];
  check(p?: Provider): CliStatus[];
  update(p: Provider, o?: { version?: string; force?: boolean }): CliStatus[];
  setPolicy(p: Provider, policy: CliPolicy): CliStatus[];
  onChange(fn: (clis: CliStatus[]) => void): () => void;
  // Whether a session on `version` got going (its CLI reported a version)
  // or died before it did, for the "failed to start twice" warning.
  sessionStarted?(p: Provider, version: string | undefined, ok: boolean): void;
};

// What E's CliUpdates calls back into (its constructor's `hooks`).
export type CliHooks = {
  restartPending(): boolean;
  releaseIdle(p: Provider, keepVersion: string): void;
  versionsInUse(p: Provider): { version: string; threadIds: string[] }[];
  codexBinariesInUse(): string[];
};

// usage.ts's pickAccount: the account a thread made without one starts on.
export type AccountPicker = (accounts: Account[], lastUsedId: string | undefined) => string | undefined;

// AccountRegistry, plus the onChange D adds (fired when a rescan finds a
// different list).
export type AccountSource = Pick<AccountRegistry, 'list' | 'get' | 'learn'> & { onChange?(fn: () => void): () => void };

// The Codex adapter reports the binaries its live processes run, so E only
// deletes version folders nothing uses. Not on AgentAdapter, since only
// Codex has it.
type BinaryReporter = { binariesInUse?(): string[] };

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
  // Ids of the messages the CLI has yet to answer for this turn: the one
  // that started it (none for a turn the CLI started itself), then any
  // sent while it ran, which go straight into the CLI. The turn ends when
  // the CLI has answered them all.
  messages: string[];
  // Files the turn edited or wrote (edit.diff paths, Write and Edit calls),
  // for hooks that run only after a change to certain files.
  edited: Set<string>;
  // The agent's own end_turn input and last text, for what the turn needs
  // from Mike (needs.ts). Never a sub-agent's.
  endTurn?: Record<string, unknown>;
  lastText?: string;
};

type Runtime = {
  session?: AgentSession;
  generation: number;
  closing?: Promise<void>;
  releasedGen?: number; // generation of the session being released on purpose
  resumed: boolean; // the live session was started with resume
  retriedFresh: boolean;
  // Where the live session's transcript was carried from, if it moved
  // folder; used only if resuming the copy fails.
  carried?: ThreadRecord['handoff'];
  deleted?: boolean; // anything the old CLI still reports is dropped
  turn?: Turn;
  tasks: BackgroundTask[]; // background work the live CLI is running
  // The version of the CLI running the live session, from its cliVersion
  // output (Codex reports it; Claude doesn't yet).
  cliVersion?: string;
  // A CLI update came in while this session ran on the old version: it's
  // released the next time it's idle (no turn, approval, queued message,
  // background work or wake grace), and the next message resumes on the
  // new one. Background work is never stopped for it.
  versionMove?: boolean;
  // The installed version when the live session was started (what E says
  // new sessions start on), and whether it has got going since.
  startVersion?: string;
  started?: boolean;
  // Archived here while its CLI was live: archived in the CLI's own app
  // once that CLI has exited, so a second process never touches the thread
  // while the live one still has it loaded.
  archivePending?: boolean;
  // Background work that ended and whose result the CLI hasn't started a
  // turn to read yet. Shown as `finished` in the summary's background list
  // while wakeTimer runs; cleared when that turn starts or the grace ends.
  finished: BackgroundTask[];
  // Set when background work finished with no turn running: the CLI is
  // about to start a turn of its own to look at the result, and until it
  // does (or WAKE_GRACE_MS passes) the thread isn't idle.
  wakeTimer?: TimerHandle;
  // Background work finished while a turn was running. If the model was
  // already writing its last message, the CLI holds the notification and
  // starts a turn of its own after the result, so the wake grace starts
  // when the turn ends.
  taskEndedInTurn?: boolean;
  activeAt: number; // last turn start or end, for picking which CLI to release
  approvals: Map<string, PendingApproval>;
  idleTimer?: TimerHandle;
  releaseWhenIdle: boolean;
  inProgress: Map<string, InProgressItem>;
  pendingDeltas: Map<string, { type: DeltaType; text: string }>;
  deltaTimer?: TimerHandle;
  // What the folder's patches give the thread (patches.ts). Read again in
  // the background when the folder changes or PATCHES_TTL_MS has passed,
  // and a new summary goes out if anything differs, so a `convex dev` that
  // has just written .env.local, or a patch file the agent has just
  // written, shows up within seconds. Until the first read finishes the
  // built-in panels stand in.
  patches?: { cwd: string; key: string; at: number; set: PatchSet; refreshing: boolean; loaded: boolean };
  runningActions?: Set<string>;
  // Turns in a row that a hook's message started, per hook. A hook that
  // keeps failing stops being told to the agent after HOOK_TELL_LIMIT, so
  // two can't go round for ever; a message from anyone else resets it.
  hookTurns?: Map<string, number>;
  // Turn-end hooks still running; a draining runner waits for them, since
  // one may tell the agent something and start a turn.
  hooksRunning?: number;
};

type ThreadState = { rec: ThreadRecord; rt: Runtime };

type Drain = {
  keep: Set<string>;
  going: Set<string>; // being let go
  onHandedOver: (threadId: string) => void;
  backgroundMs: number;
  checkMs: number;
  checkQueued: boolean;
  ready: () => boolean;
  timer?: TimerHandle;
};

// How often a draining runner looks again at threads it keeps for
// background work, since that work's limit passes without an event.
const DRAIN_CHECK_MS = 5000;

export type RunnerDeps = {
  config: Config;
  store: ThreadStore;
  adapters: Record<string, AgentAdapter>;
  accounts: AccountSource;
  // D's UsageStore: live readings go to it, and its changes reach clients.
  usage?: UsageSink;
  // Which account a thread made without one starts on; usage.ts's
  // pickAccount (the most room) unless a test swaps it.
  pickAccount?: AccountPicker;
  clock: Clock;
  log: Logger;
  // Coalesces summary saves and thread.updated; tests pass a synchronous one.
  defer?: (fn: () => void) => void;
  // Copies a Claude session's transcript to another folder (transcripts.ts);
  // tests swap it out.
  copyTranscript?: typeof copySessionTranscript;
  // Where a sub-agent's transcript is (transcripts.ts); tests point it at a fixture.
  subagentTranscript?: typeof subagentTranscriptPath;
  // Takes the Simulator panel's screenshot (patches.ts); tests pass a fake.
  screenshot?: Screenshot;
  // Where patches stop being looked for up the folder tree (the home folder).
  panelsRoot?: string;
  // The shell command actions run through, and how long they may take;
  // tests pass /bin/sh -c and a short limit.
  actionShell?: string[];
  actionTimeoutMs?: number;
  // The runner's own small-model calls (models/index.ts), for titles.
  // Absent in most tests, which then keep the first-line title.
  models?: Pick<Models, 'generate'>;
  // Projects (projects.ts): their folders' patches, the brief a session
  // starts with, and the summary's `projects`. Started by start().
  projects?: Projects;
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
// How long a thread's patches are kept before the folder is read again.
const PATCHES_TTL_MS = 15_000;
// How often the account list is read again, so a new login is noticed
// (and its models asked for) without a client asking.
const ACCOUNT_RESCAN_MS = 10_000;
// accounts.updated: the first change goes out at once, then at most one
// this often, always ending on the latest list.
const ACCOUNTS_THROTTLE_MS = 5_000;
// How many turns in a row one hook may start with its result.
const HOOK_TELL_LIMIT = 2;
// How much of a hook's output goes to the agent (the transcript has it all).
const HOOK_TELL_CHARS = 8000;
// snoozedUntil for a thread hibernating until the runner next starts: far
// enough off that everything reading snoozedUntil (the lists, the resume
// after a restart, a client older than snoozedUntilRestart) sees it as
// snoozed, and start() wakes it long before.
export const UNTIL_RESTART = '9999-12-31T00:00:00.000Z';

export class Runner {
  private cfg: Config;
  private store: ThreadStore;
  private adapters: Record<string, AgentAdapter>;
  private accounts: AccountSource;
  private usage?: UsageSink;
  private pickAccount: AccountPicker;
  private clis?: CliControl;
  private clock: Clock;
  private log: Logger;
  private defer: (fn: () => void) => void;
  private copyTranscript: typeof copySessionTranscript;
  private subagentTranscript: typeof subagentTranscriptPath;
  private screenshot: Screenshot;
  private panelsRoot?: string;
  private actionShell?: string[];
  private actionTimeoutMs?: number;
  private models?: Pick<Models, 'generate'>;
  private projects?: Projects;
  private activity = new Set<(a: ThreadActivity) => void>();
  private patchCache: PatchCache = new Map();
  private threads = new Map<string, ThreadState>();
  private listeners = new Set<(n: Notification) => void>();
  private dirty = new Set<string>();
  private flushScheduled = false;
  private snoozeTimer?: TimerHandle;
  private stopping = false;
  // Set while this runner drains after a handover (docs/protocol.md,
  // "Handovers"): the threads it still keeps, and who hears when one goes.
  private draining?: Drain;
  private refusing?: string;
  private startedAt = 0;
  private startupNotices: { level: 'info' | 'warning' | 'error'; message: string }[] = [];
  // Accounts whose CLI has been asked for its models (or is being asked).
  private probed = new Set<string>();
  private rescanTimer?: TimerHandle;
  private accountsTimer?: TimerHandle;
  private accountsSentAt = -Infinity;
  private accountsShown?: string; // the last list clients were sent (or got in hello's time)
  // E's last Codex status, to notice an update activating (or a first
  // copy arriving where there was none) as against E working out what's
  // installed when it starts.
  private codexVersion?: string;
  private codexMissing = false;
  // The version E last asked sessions to move to, per provider.
  private wantedVersion: Partial<Record<Provider, string>> = {};
  private unsubs: (() => void)[] = [];

  constructor(deps: RunnerDeps) {
    this.cfg = deps.config;
    this.store = deps.store;
    this.copyTranscript = deps.copyTranscript ?? copySessionTranscript;
    this.subagentTranscript = deps.subagentTranscript ?? subagentTranscriptPath;
    this.screenshot = deps.screenshot ?? simctlScreenshot;
    this.panelsRoot = deps.panelsRoot;
    this.actionShell = deps.actionShell;
    this.actionTimeoutMs = deps.actionTimeoutMs;
    this.models = deps.models;
    this.projects = deps.projects;
    this.adapters = deps.adapters;
    this.accounts = deps.accounts;
    this.usage = deps.usage;
    this.pickAccount = deps.pickAccount ?? pickByRoom;
    this.clock = deps.clock;
    this.log = deps.log;
    this.defer = deps.defer ?? ((fn) => setImmediate(fn));
  }

  // ---------------------------------------------------------------- startup

  // Loads threads from disk. Threads that were mid-turn when the runner
  // stopped become `stopped`; approvals they were waiting on expire.
  //
  // `skip` are threads a draining runner still has (a handover): they stay
  // on disk untouched until it hands them over and adopt() loads them.
  start(opts: { skip?: ReadonlySet<string> } = {}): void {
    this.startedAt = this.clock.now();
    const { records, broken } = this.store.loadAll();
    for (const id of broken) {
      if (opts.skip?.has(id)) continue;
      const rec = this.rebuild(id);
      if (rec) records.push(rec);
    }
    let stopped = 0;
    for (const rec of records) {
      if (opts.skip?.has(rec.id)) continue;
      // thread.json is saved a moment after the event it follows; the log
      // is the truth for seq.
      rec.lastSeq = this.store.log(rec.id).lastSeq;
      const st: ThreadState = { rec, rt: newRuntime(Date.parse(rec.lastActivityAt) || 0) };
      this.threads.set(rec.id, st);
      if (this.recover(st)) stopped++;
    }
    if (stopped) this.startupNotice('info', `${stopped === 1 ? 'A thread was' : `${stopped} threads were`} mid-turn when the runner stopped; send a message to carry on.`);
    // Hibernating until the runner restarts: this is the restart. Before
    // the restart's resume (main.ts), so a thread put away while its own
    // restart waited still gets carried on.
    for (const st of this.threads.values()) if (st.rec.snoozedUntilRestart) this.wake(st);
    this.flush();
    this.armSnoozeTimer();
    this.log.info('runner loaded threads', { count: this.threads.size });
    this.accountsShown = accountsKey(this.safeAccounts());
    void this.probeModels();
    // Usage readings and a rescan that finds another list both reach
    // clients through the same throttle as what the probes learn.
    if (this.usage?.onChange) this.unsubs.push(this.usage.onChange(() => this.accountsChanged()));
    if (this.accounts.onChange) this.unsubs.push(this.accounts.onChange(() => this.accountsChanged()));
    this.armRescan();
  }

  // Asks each account's CLI for its model list, one account at a time so
  // startup doesn't spawn three CLIs at once. Clients hear through
  // accounts.updated; a failure just leaves the list unknown. `only` picks
  // some accounts: a login that has just appeared, or every Codex account
  // after a Codex update (a new version can change the list).
  async probeModels(only?: (a: Account) => boolean): Promise<void> {
    const targets = this.safeAccounts().filter((a) => !only || only(a));
    for (const a of targets) this.probed.add(a.id);
    for (const account of targets) {
      if (this.stopping) return;
      const adapter = this.adapters[account.provider];
      if (!adapter?.models) continue;
      try {
        const models = await adapter.models(account);
        this.learnAccount(account.id, { models });
      } catch (e) {
        this.log.warn('could not read the model list', { accountId: account.id, error: String(e) });
      }
    }
  }

  private learnAccount(accountId: string, info: LearnedAccountInfo): void {
    if (!this.accounts.learn(accountId, info)) return;
    this.accountsChanged();
  }

  private safeAccounts(): Account[] {
    try {
      return this.accounts.list();
    } catch (e) {
      this.log.warn('could not list the accounts', { error: String(e) });
      return [];
    }
  }

  // Reads the account list again every ACCOUNT_RESCAN_MS, so a login added
  // in Token Stats shows up in the app (and gets its models asked for)
  // without a reconnect.
  private armRescan(): void {
    this.rescanTimer?.cancel();
    this.rescanTimer = this.clock.setTimeout(() => {
      this.rescanTimer = undefined;
      if (this.stopping) return;
      this.rescanAccounts();
      this.armRescan();
    }, ACCOUNT_RESCAN_MS);
  }

  rescanAccounts(): void {
    const list = this.safeAccounts();
    const fresh = new Set(list.filter((a) => !this.probed.has(a.id)).map((a) => a.id));
    if (fresh.size) void this.probeModels((a) => fresh.has(a.id));
    if (accountsKey(list) !== this.accountsShown) this.accountsChanged();
  }

  // accounts.updated, level-triggered: the first change goes out at once,
  // then at most one every ACCOUNTS_THROTTLE_MS, read when it goes so it's
  // always the latest list.
  private accountsChanged(): void {
    if (this.accountsTimer || this.stopping) return;
    const wait = this.accountsSentAt + ACCOUNTS_THROTTLE_MS - this.clock.now();
    if (wait <= 0) {
      this.sendAccounts();
      return;
    }
    this.accountsTimer = this.clock.setTimeout(() => {
      this.accountsTimer = undefined;
      if (!this.stopping) this.sendAccounts();
    }, wait);
  }

  private sendAccounts(): void {
    const accounts = this.safeAccounts();
    const key = accountsKey(accounts);
    // A change that went back to what clients already have isn't news.
    if (key === this.accountsShown) return;
    this.accountsShown = key;
    this.accountsSentAt = this.clock.now();
    this.notify({ method: 'accounts.updated', params: { accounts } });
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
      // The account's own, so a Codex default never starts the Claude CLI
      // with CLAUDE_CONFIG_DIR=~/.codex.
      provider: this.accounts.get(accountId)?.provider ?? 'claude',
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
    // A sub-agent can't outlive the runner that started its CLI.
    this.stopSubagents(st);
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
    // leaves it for the wake-up to send. That includes a snooze that ended
    // while the runner was down: start() wakes it straight after loading.
    // Anything else queued was cut off.
    if (rec.queue.length && !midTurn && (rec.snoozedUntil !== undefined || rec.archivedAt !== undefined)) {
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
    this.rescanTimer?.cancel();
    this.accountsTimer?.cancel();
    for (const off of this.unsubs.splice(0)) off();
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
      rt.finished = [];
      this.stopSubagents(st);
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

  // ------------------------------------------------------------- handovers
  // docs/protocol.md, "Handovers".

  // This runner is handing over to a new release. `keep` are the busy
  // threads it goes on running; every other thread is let go now (an idle
  // CLI exits, and the new runner resumes it by session id). Resolves once
  // those CLIs have gone, so the new runner never resumes a session beside
  // its old CLI. Each kept thread is let go in turn once nothing would be
  // cut short, and onHandedOver hears its id after its thread.json is saved.
  //
  // `ready` says whether the new runner is there to hear about one (it has
  // connected); until it is, threads stay here, and recheckHandovers() looks
  // again once it does.
  async beginDrain(keep: Iterable<string>, opts: { onHandedOver: (threadId: string) => void; backgroundMs: number; checkMs?: number; ready?: () => boolean }): Promise<void> {
    if (this.draining) throw new Error('already draining');
    const d: Drain = {
      keep: new Set([...keep].filter((id) => this.threads.has(id))),
      going: new Set(),
      onHandedOver: opts.onHandedOver,
      backgroundMs: opts.backgroundMs,
      checkMs: opts.checkMs ?? DRAIN_CHECK_MS,
      checkQueued: false,
      ready: opts.ready ?? (() => true),
    };
    this.draining = d;
    // Accounts are the primary's to watch now.
    this.rescanTimer?.cancel();
    this.accountsTimer?.cancel();
    await Promise.all([...this.threads.values()].filter((st) => !d.keep.has(st.rec.id)).map((st) => this.letGo(st)));
    this.log.info('let go of the idle threads', { keeps: [...d.keep] });
    this.checkHandovers();
  }

  // The threads a draining runner still has; undefined when not draining.
  keeping(): string[] | undefined {
    return this.draining ? [...this.draining.keep] : undefined;
  }

  // Whether this runner has the thread (a draining one lets them go).
  has(threadId: string): boolean {
    return this.threads.has(threadId);
  }

  recheckHandovers(): void {
    this.queueHandoverCheck();
  }

  private queueHandoverCheck(): void {
    const d = this.draining;
    if (!d || d.checkQueued) return;
    d.checkQueued = true;
    this.defer(() => {
      d.checkQueued = false;
      this.checkHandovers();
    });
  }

  private checkHandovers(): void {
    const d = this.draining;
    if (!d || this.stopping) return;
    d.timer?.cancel();
    d.timer = undefined;
    for (const id of d.ready() ? [...d.keep] : []) {
      const st = this.threads.get(id);
      if (!st) {
        // Deleted while kept.
        d.keep.delete(id);
        continue;
      }
      if (d.going.has(id) || !this.readyToHandOver(st, d)) continue;
      d.going.add(id);
      void this.letGo(st).then(
        () => {
          d.going.delete(id);
          d.keep.delete(id);
          this.log.info('handed a thread over', { threadId: id, left: d.keep.size });
          d.onHandedOver(id);
        },
        (e: unknown) => {
          d.going.delete(id);
          this.log.error('could not hand a thread over', { threadId: id, error: String(e) });
        },
      );
    }
    // Background work's limit passes without anything else happening.
    if (d.keep.size > d.going.size) d.timer = this.clock.setTimeout(() => this.checkHandovers(), d.checkMs);
  }

  // Nothing would be cut short by letting it go now: no turn, approval or
  // question, wake grace, turn-end hook or action. Queued messages go with
  // it. Background work holds it for backgroundMs after its last turn, as
  // it holds an idle restart, and is then stopped with a note.
  private readyToHandOver(st: ThreadState, d: Drain): boolean {
    const { rt } = st;
    if (rt.turn || rt.approvals.size || rt.wakeTimer || rt.hooksRunning || rt.runningActions?.size) return false;
    return rt.tasks.length === 0 || this.clock.now() - rt.activeAt >= d.backgroundMs;
  }

  // Lets go of a thread for good: its CLI exits (background work, if any,
  // is stopped with a note), its record is saved, and anything the old CLI
  // still reports goes nowhere.
  private async letGo(st: ThreadState): Promise<void> {
    const { rt, rec } = st;
    rt.idleTimer?.cancel();
    rt.idleTimer = undefined;
    this.flushDeltas(st);
    if (rt.session && !rt.closing) this.releaseSession(st);
    if (rt.closing) await rt.closing;
    rt.deltaTimer?.cancel();
    rt.wakeTimer?.cancel();
    rt.generation++;
    this.store.save(rec);
    rt.deleted = true;
    this.dirty.delete(rec.id);
    this.threads.delete(rec.id);
    this.store.forget(rec.id);
  }

  // Loads a thread a draining runner has handed over and carries on with
  // it: messages queued while it was busy there start now. `crashed`: the
  // draining runner died with it, so it's recovered as after a crash (a
  // turn in flight ends as stopped).
  adopt(threadId: string, opts: { crashed?: boolean } = {}): ThreadSummary | undefined {
    const had = this.threads.get(threadId);
    if (had) return this.summary(had);
    this.store.forget(threadId);
    const rec = this.store.load(threadId) ?? this.rebuild(threadId);
    if (!rec) {
      this.log.warn('a handed-over thread is gone', { threadId });
      return undefined;
    }
    rec.lastSeq = this.store.log(rec.id).lastSeq;
    const st: ThreadState = { rec, rt: newRuntime(Date.parse(rec.lastActivityAt) || 0) };
    this.threads.set(rec.id, st);
    if (opts.crashed) {
      if (this.recover(st)) this.notice('info', `The old runner stopped while "${rec.title}" was mid-turn; send a message to carry on.`);
    }
    // Hibernating until the runner restarts: for this thread, coming across
    // is the restart.
    if (rec.snoozedUntilRestart) this.wake(st);
    else if (!opts.crashed && rec.queue.length && this.bucket(rec) === 'inbox') {
      this.kickQueue(st);
    }
    this.markDirty(st);
    this.armSnoozeTimer();
    this.log.info('adopted a thread', { threadId, crashed: Boolean(opts.crashed), queued: rec.queue.length });
    return this.summary(st);
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
      const tasks = this.background(st).map((t) => (t.finished ? `${t.description || 'a background task'} (just finished, which the agent is about to look at)` : t.description || 'a background task'));
      if (tasks.length) out.push({ threadId: st.rec.id, tasks });
    }
    return out;
  }

  // The summary's background list: what the CLI is still running, then
  // (while the wake grace runs) what just finished and is about to be read.
  private background(st: ThreadState): ProtocolBackgroundTask[] {
    const { rt } = st;
    const out: ProtocolBackgroundTask[] = rt.tasks.map((t) => ({ kind: t.kind, description: t.description || t.type }));
    if (rt.wakeTimer) {
      // A grace with nothing recorded as finished (a task list the CLI
      // replaced wholesale) still says a result is on its way.
      const finished = rt.finished.length ? rt.finished : [{ id: '', type: 'task', kind: 'other' as const, description: '' }];
      for (const t of finished) out.push({ kind: t.kind, description: t.description || (t.type === 'task' ? '' : t.type), finished: true });
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

  // For the runner's neighbours (schedules.ts) to tell every client.
  publish(n: Notification): void {
    this.notify(n);
  }

  // Turn ends and folder moves, for the librarian.
  onThreadActivity(fn: (a: ThreadActivity) => void): () => void {
    this.activity.add(fn);
    return () => this.activity.delete(fn);
  }

  private tellActivity(a: ThreadActivity): void {
    for (const fn of this.activity) {
      try {
        fn(a);
      } catch (e) {
        this.log.error('activity listener failed', { error: String(e) });
      }
    }
  }

  // ---------------------------------------------------- for projects.ts

  // Every thread's record, put away ones included. Read only.
  threadRecords(): ThreadRecord[] {
    return [...this.threads.values()].filter((t) => !t.rt.deleted).map((t) => t.rec);
  }

  // A thread id from a full id or unique prefix; -32004 otherwise.
  resolveThread(idOrPrefix: string): string {
    const t = typeof idOrPrefix === 'string' && idOrPrefix ? this.findThread(idOrPrefix) : undefined;
    if (!t) throw new RpcError(ErrorCode.threadNotFound, `Thread not found: ${idOrPrefix}`);
    return t.id;
  }

  // Changes a thread's record for projects.ts, saves it and sends its
  // summary; `note` goes in the transcript. The agent hears about a new
  // project with its next message (projectNews).
  editThread(threadId: string, edit: (rec: ThreadRecord) => void, say: { note?: string } = {}): ThreadSummary {
    const st = this.mustGet(threadId);
    edit(st.rec);
    if (say.note) this.emit(st, { type: 'system.note', text: say.note }, st.rt.turn?.turnId);
    this.markDirty(st);
    return this.summary(st);
  }

  // Sends these threads' summaries again; their patches are read again on
  // the way, since a project's folders may have changed.
  touchThreads(threadIds: string[]): void {
    for (const id of threadIds) {
      const st = this.threads.get(id);
      if (!st) continue;
      if (st.rt.patches) st.rt.patches.at = -Infinity;
      this.markDirty(st);
    }
  }

  // The first user message and the last few messages of a thread, as plain
  // text, for the librarian.
  threadGist(threadId: string, opts: { recent?: number; chars?: number } = {}): { first?: string; recent: { who: 'user' | 'assistant'; text: string }[] } {
    const st = this.mustGet(threadId);
    const chars = opts.chars ?? 600;
    const cut = (t: string) => (t.length > chars ? t.slice(0, chars) + '…' : t);
    const first = this.opening(st.rec.id).text;
    const log = this.store.log(st.rec.id);
    const recent: { who: 'user' | 'assistant'; text: string }[] = [];
    const want = opts.recent ?? 6;
    // Back from the end a page at a time until there are enough.
    for (let to = log.lastSeq; to >= 1 && recent.length < want; to -= 200) {
      const page = log.read(Math.max(1, to - 199), to);
      for (const e of page.reverse()) {
        if (recent.length >= want) break;
        if (e.type === 'user.message' && e.origin === undefined) recent.unshift({ who: 'user', text: cut(e.text) });
        else if (e.type === 'assistant.text' && e.text.trim()) recent.unshift({ who: 'assistant', text: cut(e.text) });
      }
    }
    return { first: first ? cut(first) : undefined, recent };
  }

  private notify(n: Notification): void {
    // A kept thread's summary changing can be it becoming free to go.
    if (this.draining && n.method === 'thread.updated') this.queueHandoverCheck();
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

  hello(): { runnerVersion: string; protocol: number; accounts: Account[]; defaults: RunnerDefaults; clis?: CliStatus[] } {
    const accounts = this.accounts.list();
    const defaults: RunnerDefaults = { cwd: this.cfg.defaults.cwd, accountId: this.defaultAccountId(accounts) };
    // `model` is Claude's, for apps that predate `models`.
    const claudeModel = this.defaultModelFor('claude');
    if (claudeModel) defaults.model = claudeModel;
    if (this.cfg.defaults.models) defaults.models = { ...this.cfg.defaults.models };
    if (this.cfg.defaults.efforts) defaults.efforts = { ...this.cfg.defaults.efforts };
    const out: ReturnType<Runner['hello']> = { runnerVersion: RUNNER_VERSION, protocol: PROTOCOL_VERSION, accounts, defaults };
    const clis = this.cliList();
    if (clis) out.clis = clis;
    return out;
  }

  // The account a thread made without one starts on (tb new, create_thread,
  // schedules) and hello's defaults.accountId: the one with the most room
  // among the last-used account's provider (usage.ts, pickAccount), worked
  // out again each time so it follows usage. Without usage it's the last
  // one used.
  private defaultAccountId(all = this.accounts.list()): string {
    // Only accounts this runner can start a CLI for.
    const accounts = all.filter((a) => this.adapters[a.provider]);
    const json = readRunnerJson(this.cfg.home).defaults;
    const saved = json?.accountId ?? this.cfg.defaults.accountId;
    const last = saved && accounts.some((a) => a.id === saved) ? saved : (accounts.find((a) => a.id === 'claude-main')?.id ?? accounts[0]?.id);
    if (json?.keepAccount && last) return last;
    let picked: string | undefined;
    try {
      picked = this.pickAccount(accounts, last);
    } catch (e) {
      this.log.warn('could not pick an account', { error: String(e) });
    }
    if (picked && accounts.some((a) => a.id === picked)) return picked;
    return last ?? 'claude-main';
  }

  // What a thread on this provider gets when it names no model: the
  // runner's default for that provider, or for Claude the older single
  // default. Undefined means the account's own.
  private defaultModelFor(provider: Provider): string | undefined {
    return this.cfg.defaults.models?.[provider] ?? (provider === 'claude' ? this.cfg.defaults.model : undefined);
  }

  private defaultEffortFor(provider: Provider): EffortLevel | undefined {
    return this.cfg.defaults.efforts?.[provider];
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

  // What a sub-agent has done so far, from the CLI's transcript of it.
  subagent(threadId: string, subagentId: string): { subagent?: Subagent; events: PersistedEvent[] } {
    const { rec } = this.mustGet(threadId);
    const known = rec.subagents?.find((a) => a.id === subagentId);
    const cwd = known?.cwd ?? rec.cwd;
    const account = this.accounts.get(known?.accountId ?? rec.accountId);
    const sessionId = known?.sessionId ?? rec.nativeSessionId;
    const file = account && sessionId ? this.subagentTranscript(account.configDir, cwd, sessionId, subagentId) : null;
    if (!file) throw new RpcError(ErrorCode.subagentNotFound, `There's no record of sub-agent ${subagentId} in this thread`);
    const ctx = fileContext(cwd, this.store.mediaDir(rec.id), path.join(this.store.blobsDir(rec.id), 'subagents'));
    let read: ReturnType<typeof readSubagentTranscript>;
    try {
      read = readSubagentTranscript(file, ctx);
    } catch (e) {
      throw new RpcError(ErrorCode.subagentNotFound, `Couldn't read sub-agent ${subagentId}'s transcript: ${String(e)}`);
    }
    const now = this.isoNow();
    const events = read.map((e, i) => ({ seq: i + 1, ts: e.ts ?? now, threadId, ...e.body }) as PersistedEvent);
    return known ? { subagent: publicSubagent(known), events } : { events };
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
    effort?: EffortLevel;
    permissionMode?: PermissionMode;
    title?: string;
    origin?: MessageOrigin;
    scheduleId?: string;
  }): { thread: ThreadSummary; turnId: string } {
    this.checkAccepting();
    // New threads belong on the new release.
    if (this.draining) throw new RpcError(ErrorCode.busy, 'This runner is handing over to a new one; start the thread there.');
    const accountId = params.accountId ?? this.defaultAccountId();
    const account = this.accounts.get(accountId);
    if (!account) throw new RpcError(ErrorCode.accountNotFound, `No account called ${accountId}`);
    this.checkProvider(account);
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
      provider: account.provider,
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
    const checked = this.checkSettings(account, params.model || this.defaultModelFor(account.provider), params.effort ?? this.defaultEffortFor(account.provider));
    if (checked.model) rec.model = checked.model;
    if (checked.effort) rec.effort = checked.effort;
    this.store.create(rec);
    const st: ThreadState = { rec, rt: newRuntime(this.clock.now()) };
    this.threads.set(id, st);
    this.rememberAccount(accountId);
    const turnId = this.sendTo(st, params.text ?? '', params.images ?? [], { origin: params.origin, scheduleId: params.scheduleId });
    // Under the first turn, so they read as part of starting it.
    for (const text of checked.notes) this.emit(st, { type: 'system.note', text }, st.rt.turn?.turnId ?? turnId);
    if (!rec.titleSet && params.text?.trim()) void this.titleFromModel(st, params.text);
    return { thread: this.summary(st), turnId };
  }

  // An account whose CLI this runner can't drive (a Codex login found
  // before the Codex adapter is wired) is refused up front, rather than
  // making a thread whose first turn can only fail.
  private checkProvider(account: Account): void {
    if (!this.adapters[account.provider]) {
      throw new RpcError(ErrorCode.badParams, `This runner can't run ${providerName(account.provider)} threads yet, so ${account.id} can't be used.`);
    }
  }

  // Checks a model and effort against the account's provider (protocol,
  // "Models and effort across providers"). A model of the other provider,
  // or a Codex id the account doesn't list, gives way to the provider's
  // default; an effort the model doesn't offer is dropped. Each says so in
  // a note rather than failing the call, since an older app always sends a
  // model and can't get past an error.
  private checkSettings(account: Account, model: string | undefined, effort: EffortLevel | undefined): { model?: string; effort?: EffortLevel; notes: string[] } {
    const notes: string[] = [];
    const provider = account.provider;
    if (model && !this.modelFits(account, model)) {
      const replacement = this.defaultModelFor(provider);
      const fallback = replacement && this.modelFits(account, replacement) ? replacement : undefined;
      const uses = fallback ? modelTitle(account, fallback) : account.defaultModel ? modelTitle(account, account.defaultModel) : "the account's default model";
      notes.push(`${model} isn't a ${providerName(provider)} model, so this thread uses ${uses}.`);
      model = fallback;
    }
    if (effort) {
      const row = modelRow(account, model ?? account.defaultModel);
      const offered = (e: EffortLevel) => !(provider === 'claude' && e === 'ultra') && (!row?.effortLevels || row.effortLevels.includes(e));
      if (!offered(effort)) {
        const fallback = this.defaultEffortFor(provider);
        const next = fallback && fallback !== effort && offered(fallback) ? fallback : undefined;
        const why = provider === 'claude' && effort === 'ultra' ? `${effortTitle(effort)} effort is Codex only` : `${row ? row.title : 'This model'} doesn't offer ${effortTitle(effort)} effort`;
        notes.push(`${why}, so this thread uses ${next ? `${effortTitle(next)} effort` : "the model's own level"}.`);
        effort = next;
      }
    }
    return { ...(model ? { model } : {}), ...(effort ? { effort } : {}), notes };
  }

  // Whether a thread on this account can run this model id. Codex: one the
  // account lists, or before the list is known anything starting gpt-.
  // Claude: anything but a Codex id, unless the account itself lists it.
  private modelFits(account: Account, model: string): boolean {
    if (modelRow(account, model)) return true;
    if (account.provider === 'codex') return !account.models?.length && model.startsWith('gpt-');
    if (isClaudeModel(model)) return true;
    const codexIds = this.safeAccounts().filter((a) => a.provider === 'codex').some((a) => modelRow(a, model));
    return !model.startsWith('gpt-') && !codexIds;
  }

  // Asks a small model for a better title than the first line. Without a
  // key, in a private folder or over budget it says why and nothing
  // changes. A title set meanwhile (by Mike or an agent) wins.
  // `reply`, the start of the agent's first answer, is there when an older
  // thread is named (retitle): a terse first message like "Explain thread
  // count" means little without it.
  private async titleFromModel(st: ThreadState, text: string, reply?: string): Promise<{ title: string } | { reason: string }> {
    if (!this.models) return { reason: 'Model calls are off in this runner.' };
    const before = st.rec.title;
    const res = await this.models.generate({
      feature: 'titles',
      cwd: st.rec.cwd,
      system: TITLE_PROMPT,
      prompt: reply ? `Message:\n${text.slice(0, 4000)}\n\nStart of the reply:\n${reply.slice(0, 1000)}` : `Message:\n${text.slice(0, 4000)}`,
      // Room for Haiku to think first: at 30 it sometimes ran out before
      // writing a word. A long answer is turned down by cleanTitle anyway.
      maxTokens: 300,
    });
    if (!res.ok) return { reason: res.message };
    if (st.rt.deleted) return { reason: 'Deleted meanwhile.' };
    if (st.rec.titleSet || st.rec.title !== before) return { reason: 'Renamed meanwhile.' };
    const title = cleanTitle(res.value);
    if (!title) return { reason: 'The model gave no title.' };
    st.rec.title = title;
    st.rec.updatedAt = this.isoNow();
    this.markDirty(st);
    return { title };
  }

  // Names the threads that started before there was a key (or whose call
  // failed): the ones still titled with their first message's first line
  // and never named by anyone. A model title doesn't set titleSet, so the
  // first-line check is what keeps those from being asked again. Given
  // threadIds, it names those whatever their title, so a poor model title
  // can be asked for again; one named by hand still stays.
  async retitle(params: { dryRun?: boolean; threadIds?: string[] }): Promise<{ threads: { threadId: string; from: string; to?: string; reason?: string }[] }> {
    const picked = params.threadIds?.map((id) => this.mustGet(id));
    const due: { st: ThreadState; text: string; reply?: string }[] = [];
    for (const st of picked ?? this.threads.values()) {
      if (st.rec.titleSet) continue;
      const { text, reply } = this.opening(st.rec.id);
      const line = text?.split('\n').map((l) => l.trim()).find(Boolean);
      // titleFrom cut it at some length; an older runner may have cut it elsewhere.
      if (line && (picked || (st.rec.title && line.startsWith(st.rec.title)))) due.push({ st, text: text!, reply });
    }
    const threads = await Promise.all(
      due.map(async ({ st, text, reply }) => {
        const from = st.rec.title;
        if (params.dryRun) return { threadId: st.rec.id, from };
        const r = await this.titleFromModel(st, text, reply);
        return 'title' in r ? { threadId: st.rec.id, from, to: r.title } : { threadId: st.rec.id, from, reason: r.reason };
      }),
    );
    this.log.info('retitle', { dryRun: Boolean(params.dryRun), found: threads.length, named: threads.filter((t) => t.to).length });
    return { threads };
  }

  // The first user.message's text and the first assistant.text after it,
  // read a page at a time from the start: both are nearly always within
  // the first few events, and a long thread's log is large.
  private opening(id: string): { text?: string; reply?: string } {
    const log = this.store.log(id);
    let text: string | undefined;
    for (let from = 1; from <= Math.min(log.lastSeq, 500); from += 50) {
      for (const e of log.read(from, from + 49)) {
        if (text === undefined && e.type === 'user.message') text = e.text;
        else if (text !== undefined && e.type === 'assistant.text' && e.text.trim()) return { text, reply: e.text };
      }
    }
    return { text };
  }

  // origin "runner" marks a message the runner sends by itself (restart.ts),
  // "schedule" one a schedule sent (schedules.ts). `queue` keeps it out of a
  // running turn: it waits and starts its own.
  send(threadId: string, text: string, images: ImageRef[] = [], opts: SendOptions = {}): { turnId: string } {
    const st = this.mustGet(threadId);
    this.checkAccepting();
    // A thread a draining runner is letting go of is about to be the new
    // runner's; a message queued here now would be lost on the way.
    if (this.draining && !this.draining.keep.has(threadId)) throw new RpcError(ErrorCode.busy, 'The runner is handing over to a new one; send again in a moment.');
    if (!text && images.length === 0) throw new RpcError(ErrorCode.badParams, 'text or images required');
    checkImages(images);
    return { turnId: this.sendTo(st, text, images, opts) };
  }

  private sendTo(st: ThreadState, text: string, images: ImageRef[], opts: SendOptions = {}): string {
    const { rec, rt } = st;
    if (opts.origin !== 'runner') rt.hookTurns = undefined;
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
      delete rec.snoozedUntilRestart;
      delete rec.archivedAt;
      rt.releaseWhenIdle = false;
    }
    const turnId = crypto.randomUUID();
    const msg: QueuedSend = { turnId, text, images: refs };
    if (opts.origin) msg.origin = opts.origin;
    if (opts.scheduleId) msg.scheduleId = opts.scheduleId;
    rec.lastActivityAt = this.isoNow();
    if (rt.turn && !opts.queue && this.canSteer(st)) {
      // Sent while a turn runs: it goes into that turn now, as typing into
      // the CLI would. The CLI takes it at its next step, or straight after
      // its reply if that was already finishing; either way the thread's
      // turn goes on until it's answered, so the caller gets that turn's id.
      this.steer(st, msg);
      return rt.turn.turnId;
    }
    if (rt.turn || rec.queue.length || this.draining) {
      // Behind a running turn, or behind messages that couldn't start
      // earlier: they go first. On a draining runner a thread with no turn
      // is about to move across, and the message goes with it.
      rec.queue.push(msg);
      this.markDirty(st);
      this.kickQueue(st);
      return turnId;
    }
    this.startTurn(st, msg);
    return turnId;
  }

  // A message sent during a turn can go into it only while the CLI is
  // there to take it and nothing is set to change under it: not while a
  // CLI is still starting or leaving, not behind messages already waiting,
  // not once a move or a fresh CLI is due on the next turn (the message is
  // meant for that), not after Stop was pressed (the CLI would cancel it
  // with the rest), and not into a turn opened only for a background
  // subagent's approval, where there's no CLI turn to join.
  private canSteer(st: ThreadState): boolean {
    const { rec, rt } = st;
    const turn = rt.turn;
    if (!turn || !rt.session || rt.closing || this.stopping) return false;
    if (rec.queue.length || rec.handoff || rec.moved || rt.releaseWhenIdle || turn.interruptRequested) return false;
    return !turn.auto || Boolean(turn.cliStarted);
  }

  // Shows the message in the running turn and hands it to the CLI. If the
  // event can't be written the message isn't sent, and the caller gets the
  // error (the app puts the draft back).
  private steer(st: ThreadState, msg: QueuedSend): void {
    const { rt } = st;
    const turn = rt.turn!;
    this.emit(st, userMessage(msg), turn.turnId);
    turn.messages.push(msg.turnId);
    this.markDirty(st);
    rt.session!.send({ id: msg.turnId, text: msg.text, images: msg.images });
  }

  // Writes the turn's first events before changing any state, so if the
  // disk refuses (full, permissions) the thread is left as it was rather
  // than stuck on a turn that never started.
  private startTurn(st: ThreadState, msg: QueuedSend): void {
    const { rec, rt } = st;
    this.emit(st, userMessage(msg), msg.turnId);
    try {
      this.emit(st, { type: 'turn.started', turnId: msg.turnId }, msg.turnId);
    } catch (e) {
      this.markDirty(st);
      throw e;
    }
    rt.idleTimer?.cancel();
    rt.idleTimer = undefined;
    rt.turn = { turnId: msg.turnId, startedAt: this.clock.now(), interruptRequested: false, messages: [msg.turnId], edited: new Set() };
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
    // A folder, account or settings change asked for a fresh CLI, or a CLI
    // update came in since this one started.
    if (rt.session && (rt.releaseWhenIdle || rec.handoff || (rt.versionMove && rt.tasks.length === 0))) this.releaseSession(st);
    // Never two live CLIs on one session: wait for a releasing one to exit.
    while (rt.closing) await rt.closing;
    if (rt.turn?.turnId !== msg.turnId) return; // interrupted while waiting
    let text = msg.text;
    if (!rt.session) {
      const account = this.accounts.get(rec.accountId);
      if (!account) throw new Error(`Account ${rec.accountId} isn't available on this Mac.`);
      if (!isDirectory(rec.cwd)) throw new Error(`Folder not found: ${rec.cwd}`);
      if (rec.handoff && this.carryTranscript(st, account)) {
        // Same login, new folder: the whole conversation came along.
        this.emit(st, { type: 'system.note', text: `Moved to ${rec.cwd}. The session carries on there.` }, msg.turnId);
        rt.carried = rec.handoff;
        delete rec.handoff;
      } else if (rec.handoff) {
        text = this.handoffNote(st, account) + text;
        this.emit(st, { type: 'system.note', text: `Started a new session in ${rec.cwd} on ${account.title}.` }, msg.turnId);
        rec.nativeSessionId = crypto.randomUUID();
        rec.sessionUsed = false;
        rec.sessionCostTotal = 0;
        delete rec.handoff;
      } else if (rec.sessionUsed && !rec.moved) {
        this.emit(st, { type: 'system.note', text: 'Resumed session' }, msg.turnId);
      }
      this.makeRoomForCli(st);
      this.startSession(st, account);
    }
    // Projects the session hasn't been told about: one it was put in while
    // live, or since it last ran. A fresh session got them as instructions.
    const news = this.projectNews(rec);
    if (news) text = `${news}\n\n${text}`;
    if (rec.moved) {
      // A CLI that moves folders itself: the live session got setCwd, or a
      // released one resumes in the new folder (startSession passes it).
      this.emit(st, { type: 'system.note', text: `Moved to ${rec.cwd}. The session carries on there.` }, msg.turnId);
      delete rec.moved;
    }
    rt.session!.send({ id: msg.turnId, text, images: msg.images });
  }

  // Keeps the number of live CLIs at cfg.maxLive by releasing the one idle
  // the longest. CLIs with a turn, an approval, queued messages or
  // background work are never picked; if every other one is busy the cap
  // is passed rather than stopping work.
  // A folder move on the same login copies the session's transcript to the
  // new folder so it resumes with everything, rather than a short note.
  // Anything else (a new login, a rebuilt record, a transcript that can't
  // be found) gets the handoff note.
  private carryTranscript(st: ThreadState, account: Account): boolean {
    const { rec } = st;
    const from = rec.handoff;
    // Claude only: it copies Claude's own transcript files. Codex moves
    // folders in the same session (movesFolders) and never gets here.
    if (rec.provider !== 'claude') return false;
    if (!from || from.rebuilt || from.fromAccountId !== rec.accountId || from.fromCwd === rec.cwd) return false;
    if (!rec.sessionUsed || !rec.nativeSessionId) return false;
    const ok = this.copyTranscript(account.configDir, from.fromCwd, rec.cwd, rec.nativeSessionId);
    if (!ok) this.log.info('could not carry the transcript to the new folder; using a handoff note', { threadId: rec.id });
    return ok;
  }

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
    if (!adapter) throw new Error(`This runner can't run ${providerName(rec.provider)} threads.`);
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
    rt.cliVersion = undefined;
    rt.versionMove = false;
    rt.started = false;
    rt.startVersion = this.cliList()?.find((c) => c.provider === rec.provider)?.installedVersion;
    rt.session = adapter.start(
      {
        threadId: rec.id,
        cwd: rec.cwd,
        account,
        model: rec.model,
        effort: rec.effort,
        permissionMode: rec.permissionMode,
        sessionId: rec.nativeSessionId,
        resume,
        mediaDir: this.store.mediaDir(rec.id),
        blobsDir: this.store.blobsDir(rec.id),
        tmpDir: path.join(paths.run(this.cfg.home), 'tmp'),
        allowRules: rec.allowRules ?? [],
        env: threadEnv(rec.id, this.cfg.home),
        ...this.briefFor(rec, resume),
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
        if (rt.turn) {
          // A Codex child's items carry its prefix (<child>/<id>); Claude's
          // sub-agents never reach the thread's events.
          const own = !('itemId' in ev && ev.itemId?.includes('/'));
          if (ev.type === 'assistant.text' && own) rt.turn.lastText = ev.text;
          if (ev.type === 'tool.call' && own && ev.name === `mcp__${SERVER_NAME}__${END_TURN_TOOL}`) rt.turn.endTurn = ev.input;
          if (ev.type === 'edit.diff') rt.turn.edited.add(ev.path);
          else if (ev.type === 'tool.call' && (ev.kind === 'edit' || ev.kind === 'write')) {
            const file = ev.input.file_path ?? ev.input.path ?? ev.input.notebook_path;
            if (typeof file === 'string') rt.turn.edited.add(file);
          }
        }
        this.emit(st, ev, rt.turn?.turnId);
        break;
      }
      case 'delta':
        this.addDelta(st, o.delta);
        break;
      case 'session':
        rec.nativeSessionId = o.nativeSessionId;
        rec.sessionUsed = true;
        // This session is there, so a later one that can't be found gets
        // its own fresh start.
        rt.retriedFresh = false;
        if (rec.status === 'starting') rec.status = rt.approvals.size ? 'waiting' : 'running';
        if (o.model) {
          rec.modelInUse = o.model;
          // A thread with no model of its own shows what the account's
          // default really is, which the settings alone can only guess.
          if (!rec.model) this.learnAccount(rec.accountId, { defaultModel: o.model });
        }
        this.markDirty(st);
        break;
      case 'effort':
        if (rec.effortInUse !== o.level) {
          rec.effortInUse = o.level;
          this.markDirty(st);
        }
        break;
      case 'context':
        rec.contextTokens = o.contextTokens;
        if (o.contextWindow !== undefined) rec.contextWindow = o.contextWindow;
        this.markDirty(st);
        break;
      case 'limits':
        // The account's usage lives in D's UsageStore, which tells clients
        // through accounts.updated when it matters.
        try {
          this.usage?.record(rec.accountId, {
            windows: o.windows,
            ...(o.blocked !== undefined ? { blocked: o.blocked } : {}),
            ...(o.email ? { email: o.email } : {}),
            ...(o.plan ? { plan: o.plan } : {}),
          });
        } catch (e) {
          this.log.warn('could not record a usage reading', { accountId: rec.accountId, error: String(e) });
        }
        break;
      case 'cliVersion': {
        rt.cliVersion = o.version;
        if (!rt.started) {
          rt.started = true;
          this.tellStarted(rec.provider, o.version, true);
        }
        if (rec.cliVersion && rec.cliVersion !== o.version) {
          this.emit(st, { type: 'system.note', text: `${cliName(rec.provider)} ${o.version} from this turn on (was ${rec.cliVersion})` }, rt.turn?.turnId);
        }
        if (rec.cliVersion !== o.version) {
          rec.cliVersion = o.version;
          this.markDirty(st);
        }
        // Started on the version an update wants: nothing to move.
        if (this.wantedVersion[rec.provider] === o.version) rt.versionMove = false;
        break;
      }
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
        const endedTasks = rt.tasks.filter((t) => !o.tasks.some((n) => n.id === t.id));
        // Claude starts a turn of its own to read a finished task's result;
        // Codex doesn't (wakesAfterTasks: false), so there it would only
        // look busy for WAKE_GRACE_MS for nothing.
        const wakes = this.adapters[rec.provider]?.wakesAfterTasks !== false;
        const ended = endedTasks.length > 0 && wakes;
        rt.tasks = o.tasks;
        if (wakes) rt.finished.push(...endedTasks);
        // The CLI reports the list shrinking a moment before it starts the
        // turn that reads the result. A restart in between would lose that
        // turn, so the thread stays busy until it starts.
        if (ended && !rt.turn) this.startWakeGrace(st);
        else if (ended) rt.taskEndedInTurn = true;
        // The summary's background list changed: the app shows it, and a
        // pending restart waits on background work and re-checks on
        // thread.updated.
        this.markDirty(st);
        // Background work keeps the CLI live; once it's done the idle
        // countdown starts again.
        if (o.tasks.length) {
          rt.idleTimer?.cancel();
          rt.idleTimer = undefined;
        } else if (!rt.turn) this.scheduleIdle(st);
        break;
      }
      case 'subagent':
        this.updateSubagent(st, o.update);
        break;
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
        if (!turn) break;
        // Which of this turn's messages the CLI's turn answered. The CLI
        // lists them in sending order, so everything up to the last one
        // named went with it. A CLI without lifecycle frames can only say
        // whether the turn was its own; if not, it answered the one at the
        // front.
        const named = r.answered ?? (r.answers !== undefined ? [r.answers] : r.own ? [] : turn.messages.slice(0, 1));
        const last = Math.max(-1, ...named.map((id) => turn.messages.indexOf(id)));
        if (last >= 0) turn.messages.splice(0, last + 1);
        if (turn.messages.length && r.queuedTurns === 0) {
          // The CLI has nothing left to run, so a message sent during the
          // turn went nowhere (an error ended its queue). Say so rather than
          // wait for an answer that won't come.
          turn.messages = [];
          this.emit(st, { type: 'system.note', text: 'A message sent during this turn was dropped by the CLI. Send it again.' }, turn.turnId);
        }
        // Still something to answer: a turn the CLI ran by itself while
        // this thread's message waited in its queue, or a message sent
        // during the turn that the CLI runs next. The thread's turn goes on
        // until the CLI has answered everything, unless Stop cancelled the
        // rest. A failure in between is shown where it happened.
        if (turn.messages.length && !turn.interruptRequested) {
          this.flushDeltas(st);
          rt.inProgress.clear();
          if (r.outcome === 'failed' && r.error) this.emit(st, { type: 'error', message: r.error }, turn.turnId);
          break;
        }
        this.completeTurn(st, r);
        break;
      }
    }
  }

  private startWakeGrace(st: ThreadState): void {
    const { rt } = st;
    rt.wakeTimer?.cancel();
    rt.wakeTimer = this.clock.setTimeout(() => {
      rt.wakeTimer = undefined;
      rt.finished = [];
      this.markDirty(st);
      // A version move was waiting for the grace to end.
      if (rt.versionMove && !rt.turn) this.scheduleIdle(st);
    }, WAKE_GRACE_MS);
  }

  private openCliTurn(st: ThreadState): void {
    const { rec, rt } = st;
    rt.wakeTimer?.cancel();
    rt.wakeTimer = undefined;
    rt.finished = [];
    const turnId = crypto.randomUUID();
    this.emit(st, { type: 'turn.started', turnId }, turnId);
    rt.idleTimer?.cancel();
    rt.idleTimer = undefined;
    rt.turn = { turnId, startedAt: this.clock.now(), interruptRequested: false, auto: true, messages: [], edited: new Set() };
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
    // Why it failed (a limit, a full context, the login), so the app can
    // offer the fix without reading the message.
    if (outcome === 'failed' && r.errorKind) body.errorKind = r.errorKind;
    // What it needs from Mike: its end_turn call, else its closing "What I
    // need from you". Only a turn it finished; a stopped one says nothing.
    const said = outcome === 'completed' ? turnNeeds(turn) : undefined;
    if (said) {
      body.needs = said.needs;
      if (said.asks) body.asks = said.asks;
      body.needsFrom = said.from;
    }
    const ev = this.emit(st, body, turn.turnId);
    // Any completed turn replaces the last one's card; one that said
    // neither leaves no card, and counts as before.
    if (outcome === 'completed') {
      if (said) rec.needs = { seq: ev.seq, needs: said.needs, ...(said.asks ? { asks: said.asks } : {}) };
      else delete rec.needs;
    }
    this.endTurn(st, ev.seq, outcome === 'failed' ? 'error' : 'idle', outcome);
  }

  private endTurn(st: ThreadState, completedSeq: number, status: ThreadStatus, outcome?: TurnOutcome): void {
    const { rec, rt } = st;
    const finished = rt.turn;
    rt.turn?.interruptTimer?.cancel();
    rt.turn = undefined;
    // The folder's turn.end hooks, after a turn the agent finished itself
    // (not one the runner opened for a background task's approval).
    if (outcome === 'completed' && finished && !finished.auto && !this.stopping) void this.runHooks(st, finished);
    if (outcome && finished && !finished.auto && !this.stopping) {
      this.tellActivity({ kind: 'turn.end', threadId: rec.id, outcome, edited: [...finished.edited].map((p) => path.resolve(rec.cwd, p)) });
    }
    if (rt.taskEndedInTurn) {
      rt.taskEndedInTurn = false;
      // Only while the CLI is there to start that turn.
      if (rt.session && !rt.closing && !this.stopping) this.startWakeGrace(st);
    }
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
    // A CLI that died before it got going, other than one asked to stop or
    // one whose session to resume was missing (the CLI itself was fine).
    const missing = err && (err instanceof SessionNotFoundError || err.name === 'SessionNotFoundError' || /no conversation found/i.test(err.message));
    if (err && !rt.started && !missing && rt.releasedGen !== gen) this.tellStarted(rec.provider, rt.startVersion, false);
    rt.session = undefined;
    rt.tasks = [];
    rt.finished = [];
    rt.taskEndedInTurn = false;
    // Its sub-agents went with it.
    this.stopSubagents(st);
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
      // The session to resume doesn't exist. For Claude that only ever
      // meant the CLI died before its first message (it never wrote the
      // transcript); for Codex it also covers a thread deleted in Codex's
      // own app, a missing rollout or a moved CODEX_HOME, part way through
      // a conversation. Start a fresh session once.
      const notFound = err && (err instanceof SessionNotFoundError || err.name === 'SessionNotFoundError' || (/no conversation found/i.test(err.message) && rec.status === 'starting'));
      if (notFound && rt.resumed && !rt.retriedFresh) {
        rt.retriedFresh = true;
        rec.sessionUsed = false;
        rec.nativeSessionId = crypto.randomUUID();
        rec.sessionCostTotal = 0;
        delete rec.cliVersion;
        const account = this.accounts.get(rec.accountId);
        if (account && rt.turn) {
          this.emit(st, { type: 'system.note', text: "Couldn't resume the earlier session, so this is a new one." }, rt.turn.turnId);
          const turn = rt.turn;
          const log = this.store.log(rec.id);
          const msgs = log.read(Math.max(1, log.lastSeq - 200), log.lastSeq).filter((e) => e.type === 'user.message' && e.turnId === turn.turnId);
          const first = msgs[0];
          if (first && first.type === 'user.message') {
            // The fresh session starts knowing where the thread got to: a
            // transcript carried to a new folder that wouldn't resume gets
            // the move's note, any other thread with earlier turns the
            // not-found one.
            let text = first.text;
            const earlier = rec.lastTurnCompletedSeq > 0;
            if (rt.carried || earlier) {
              rec.handoff = rt.carried ?? { fromCwd: rec.cwd, fromAccountId: rec.accountId, lost: true };
              text = this.handoffNote(st, account) + text;
              delete rec.handoff;
            }
            rt.carried = undefined;
            this.startSession(st, account);
            rt.session!.send({ id: turn.turnId, text, images: first.images });
            // Messages sent into the turn before the CLI went go again, in
            // order, matched to their ids when the counts agree.
            if (msgs.length === turn.messages.length) {
              msgs.slice(1).forEach((m, i) => {
                if (m.type === 'user.message') rt.session!.send({ id: turn.messages[i + 1], text: m.text, images: m.images });
              });
            }
            return;
          }
        }
      }
      this.failTurn(st, err?.message || 'The CLI stopped unexpectedly.');
    } else {
      this.markDirty(st);
    }
    // A CLI that exited by itself (not released) may have been all an
    // archive was waiting for.
    this.archiveWhenGone(st);
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
    effort?: EffortLevel | null;
    permissionMode?: PermissionMode;
    snoozedUntil?: string | null; // an ISO time, or 'restart' for until the runner next starts
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
    const newAccount = params.accountId !== undefined ? this.accounts.get(params.accountId) : undefined;
    if (params.accountId !== undefined && !newAccount) {
      throw new RpcError(ErrorCode.accountNotFound, `No account called ${params.accountId}`);
    }
    if (newAccount && params.accountId !== rec.accountId) this.checkProvider(newAccount);
    const cwdChanged = newCwd !== undefined && newCwd !== rec.cwd;
    const fromCwd = rec.cwd;
    const accountChanged = params.accountId !== undefined && params.accountId !== rec.accountId;
    const providerChanged = accountChanged && newAccount!.provider !== rec.provider;
    const adapter = this.adapters[rec.provider];
    // Changes a CLI that applies settings from its next turn only (Codex)
    // can't take into a turn that's running; the thread says so.
    const nextTurn: string[] = [];
    const sayNextTurn = () => Boolean(rt.turn) && Boolean(adapter?.settingsApplyNextTurn) && !release;
    if (cwdChanged && !accountChanged && !rec.handoff && adapter?.movesFolders) {
      // Same account on a CLI that moves folders itself: the same session
      // carries on in the new folder from its next turn, with no
      // transcript copy and no handoff. A live session is told now; a
      // released one gets the folder when it resumes.
      if (rec.sessionUsed || rt.session) rec.moved ??= { fromCwd: rec.cwd };
      rec.cwd = newCwd!;
      if (rec.moved?.fromCwd === rec.cwd) delete rec.moved;
      const session = rt.session;
      if (session && !rt.closing) {
        const fallback = () => {
          // Couldn't move the live session: a fresh CLI resumes there.
          rt.releaseWhenIdle = true;
          if (!rt.turn) this.releaseSession(st);
        };
        if (session.setCwd) session.setCwd(rec.cwd).catch(fallback);
        else fallback();
      }
      if (sayNextTurn()) nextTurn.push(`The move to ${rec.cwd}`);
    } else if (cwdChanged || accountChanged) {
      // Takes effect on the next turn as a new native session.
      if (rec.sessionUsed || rt.session) rec.handoff ??= { fromCwd: rec.moved?.fromCwd ?? rec.cwd, fromAccountId: rec.accountId };
      delete rec.moved;
      if (newCwd !== undefined) rec.cwd = newCwd;
      if (params.accountId !== undefined) {
        rec.accountId = params.accountId;
        this.rememberAccount(params.accountId);
      }
      release = true;
    }
    if (cwdChanged) this.tellActivity({ kind: 'moved', threadId: rec.id, from: fromCwd, to: rec.cwd });
    // The account the settings are checked against, after any change.
    const account = newAccount ?? this.accounts.get(rec.accountId);
    let model = rec.model;
    let effort = rec.effort;
    let touched = false;
    if (providerChanged) {
      // Another provider's CLI: its own defaults (unless this call sets
      // them), and none of the old CLI's "Always allow" rules, which are in
      // its own syntax.
      rec.provider = newAccount!.provider;
      delete rec.allowRules;
      delete rec.cliVersion;
      model = this.defaultModelFor(rec.provider);
      effort = this.defaultEffortFor(rec.provider);
      touched = true;
    }
    if (params.model !== undefined) {
      model = params.model || undefined;
      touched = true;
    }
    if (params.effort !== undefined) {
      effort = params.effort || undefined;
      touched = true;
    }
    if (touched && account) {
      const checked = this.checkSettings(account, model, effort);
      model = checked.model;
      effort = checked.effort;
      for (const text of checked.notes) this.emit(st, { type: 'system.note', text }, rt.turn?.turnId);
    }
    if (model !== rec.model) {
      if (model) rec.model = model;
      else delete rec.model;
      if (rt.session && !release) {
        rt.session.setModel(model).catch(() => {
          rt.releaseWhenIdle = true;
        });
        if (sayNextTurn()) nextTurn.push(model ? (account ? modelTitle(account, model) : model) : 'The default model');
      }
    }
    if (effort !== rec.effort) {
      if (effort) rec.effort = effort;
      else delete rec.effort;
      if (rt.session && !release) {
        rt.session.setEffort(effort).catch(() => {
          rt.releaseWhenIdle = true;
        });
        if (sayNextTurn()) nextTurn.push(effort ? `${effortTitle(effort)} effort` : "The model's own effort level");
      }
    }
    if (params.permissionMode !== undefined && params.permissionMode !== rec.permissionMode) {
      rec.permissionMode = params.permissionMode;
      if (rt.session && !release) {
        rt.session.setPermissionMode(params.permissionMode).catch(() => {
          rt.releaseWhenIdle = true;
          if (!rt.turn) this.releaseSession(st);
        });
        if (sayNextTurn()) nextTurn.push(params.permissionMode === 'ask' ? 'Ask before edits' : 'Full access');
      }
    }
    if (nextTurn.length) {
      this.emit(
        st,
        { type: 'system.note', text: `${joinWords(nextTurn)} ${nextTurn.length === 1 ? 'applies' : 'apply'} from the next turn. This turn carries on as it started.` },
        rt.turn?.turnId,
      );
    }
    if (params.snoozedUntil !== undefined) {
      delete rec.snoozedUntilRestart;
      if (params.snoozedUntil === null) delete rec.snoozedUntil;
      else if (params.snoozedUntil === 'restart') {
        rec.snoozedUntil = UNTIL_RESTART;
        rec.snoozedUntilRestart = true;
        stop = true;
      } else {
        const t = Date.parse(params.snoozedUntil);
        if (Number.isNaN(t)) throw new RpcError(ErrorCode.badParams, 'snoozedUntil must be an ISO time or "restart"');
        rec.snoozedUntil = new Date(t).toISOString();
        stop = true;
      }
      this.armSnoozeTimer();
    }
    let archiving = false;
    if (params.archived !== undefined) {
      if (params.archived) {
        archiving = !rec.archivedAt;
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
    // Archived here, archived in the CLI's own app too (Codex Desktop's
    // list), once the session has let go of it: a turn is interrupted
    // first, then released, so that can take a moment. Resuming unarchives.
    if (archiving) {
      rt.archivePending = true;
      this.archiveWhenGone(st);
    }
    rec.updatedAt = this.isoNow();
    this.markDirty(st);
    return { thread: this.summary(st) };
  }

  // Stops the thread's CLI, moves its folder to trash/ in the data dir (so
  // a mistake can be undone by hand) and forgets it.
  delete(threadId: string): Record<string, never> {
    const st = this.mustGet(threadId);
    const { rec, rt } = st;
    rt.deleted = true;
    this.threads.delete(threadId);
    this.dirty.delete(threadId);
    rt.idleTimer?.cancel();
    rt.deltaTimer?.cancel();
    rt.wakeTimer?.cancel();
    rt.turn?.interruptTimer?.cancel();
    // Bumping the generation makes everything the old CLI still reports
    // (output, approvals, its exit) go nowhere.
    rt.generation++;
    for (const [, p] of rt.approvals) {
      if (p.kind === 'tool') p.resolve({ decision: 'expired', message: 'The thread was deleted.' });
      else p.resolve({ answers: null, message: 'The thread was deleted.' });
    }
    rt.approvals.clear();
    const session = rt.session;
    rt.session = undefined;
    const ended = session?.end({ hard: true }).catch((e: unknown) => this.log.warn('stopping a deleted thread failed', { threadId, error: String(e) }));
    this.archiveNative(st, ended ?? rt.closing);
    this.store.trash(threadId, this.clock.now());
    this.log.info('thread deleted', { threadId, title: rec.title });
    this.armSnoozeTimer();
    this.notify({ method: 'thread.deleted', params: { threadId } });
    return {};
  }

  // Ticks one of the open card's asks. Nothing goes to the agent: ticks are
  // Mike's own list, and a reply is his to write.
  tickAsk(threadId: string, asksSeq: number, index: number, ticked: boolean): { thread: ThreadSummary } {
    const st = this.mustGet(threadId);
    const { rec } = st;
    const card = rec.needs;
    if (!card?.asks || card.seq !== asksSeq || card.seq !== rec.lastTurnCompletedSeq) throw new RpcError(ErrorCode.badParams, "That isn't the thread's open card of asks.");
    if (!Number.isInteger(index) || index < 0 || index >= card.asks.length) throw new RpcError(ErrorCode.badParams, 'No such ask.');
    const set = new Set(card.ticked);
    if (ticked) set.add(index);
    else set.delete(index);
    card.ticked = [...set].sort((a, b) => a - b);
    // Ticking means Mike is looking at it, so the tick doesn't make the
    // thread unread.
    const caughtUp = rec.lastSeenSeq >= rec.lastSeq;
    const ev = this.emit(st, { type: 'asks.ticked', asksSeq, ticked: card.ticked });
    if (caughtUp) rec.lastSeenSeq = ev.seq;
    this.markDirty(st);
    return { thread: this.summary(st) };
  }

  private saidNothing(rec: ThreadRecord): boolean {
    return rec.needs?.needs === 'nothing' && rec.needs.seq === rec.lastTurnCompletedSeq;
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
      title: approvalTitle(req.name, req.input, (q) => this.findThread(q)) ?? req.title,
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
    // A CLI update is waiting for this session to be idle. Never at the
    // cost of background work, or of the turn the CLI is about to start to
    // read a finished task's result.
    if (rt.versionMove && rt.tasks.length === 0 && !rt.wakeTimer) {
      this.log.info('releasing a CLI on an old version', { threadId: rec.id, version: rt.cliVersion, wanted: this.wantedVersion[rec.provider] });
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
    rt.finished = [];
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
        this.archiveWhenGone(st);
      });
  }

  // ------------------------------------------------------------ CLI updates

  // The hooks E's CliUpdates calls (restartPending comes from the
  // Restarter, in main.ts).
  cliHooks(restartPending: () => boolean): CliHooks {
    return {
      restartPending,
      releaseIdle: (p, v) => this.releaseIdle(p, v),
      versionsInUse: (p) => this.versionsInUse(p),
      codexBinariesInUse: () => this.codexBinariesInUse(),
    };
  }

  // A new version of a provider's CLI is in place. Live sessions on another
  // version are released now if they're idle, with the soft release (so
  // background work is never stopped by an update), and the rest as soon
  // as they are (scheduleIdle). The next message resumes on the new one.
  releaseIdle(provider: Provider, keepVersion: string): void {
    this.wantedVersion[provider] = keepVersion;
    for (const st of this.threads.values()) {
      const { rec, rt } = st;
      if (rec.provider !== provider || !rt.session || rt.closing) continue;
      if (rt.cliVersion === keepVersion) {
        rt.versionMove = false;
        continue;
      }
      rt.versionMove = true;
      if (this.idleForUpdate(st)) {
        this.log.info('releasing an idle CLI for an update', { threadId: rec.id, version: rt.cliVersion, wanted: keepVersion });
        this.releaseSession(st);
      }
    }
  }

  // Nothing would be cut short by releasing it: no turn (starting, running
  // or interrupting), approval or question, queued message, background
  // work or wake grace, and not already due to go.
  private idleForUpdate(st: ThreadState): boolean {
    const { rec, rt } = st;
    return !rt.turn && rt.approvals.size === 0 && rec.queue.length === 0 && rt.tasks.length === 0 && !rt.wakeTimer && !rt.releaseWhenIdle;
  }

  // Which versions of a provider's CLI the live sessions run, from their
  // cliVersion outputs.
  versionsInUse(provider: Provider): { version: string; threadIds: string[] }[] {
    const by = new Map<string, string[]>();
    for (const { rec, rt } of this.threads.values()) {
      if (rec.provider !== provider || !rt.session || !rt.cliVersion) continue;
      by.set(rt.cliVersion, [...(by.get(rt.cliVersion) ?? []), rec.id]);
    }
    return [...by].map(([version, threadIds]) => ({ version, threadIds }));
  }

  // The Codex binaries live processes run, so E only deletes version
  // folders nothing uses.
  codexBinariesInUse(): string[] {
    const codex = this.adapters.codex as (AgentAdapter & BinaryReporter) | undefined;
    try {
      return codex?.binariesInUse?.() ?? [];
    } catch (e) {
      this.log.warn('could not list the Codex binaries in use', { error: String(e) });
      return [];
    }
  }

  // E's CliUpdates: hello and clis.updated carry its statuses, and a Codex
  // update that activates asks every Codex account for its models again.
  attachClis(clis: CliControl): void {
    this.clis = clis;
    const codex = this.cliList()?.find((c) => c.provider === 'codex');
    this.codexVersion = codex?.installedVersion;
    this.codexMissing = codex?.status === 'missing';
    this.unsubs.push(clis.onChange((list) => this.clisChanged(list)));
  }

  private cliList(): CliStatus[] | undefined {
    if (!this.clis) return undefined;
    try {
      return this.clis.list();
    } catch (e) {
      this.log.warn('could not read the CLI statuses', { error: String(e) });
      return undefined;
    }
  }

  private tellStarted(p: Provider, version: string | undefined, ok: boolean): void {
    try {
      this.clis?.sessionStarted?.(p, version, ok);
    } catch (e) {
      this.log.warn('could not report a session start', { error: String(e) });
    }
  }

  private clisChanged(list: CliStatus[]): void {
    this.notify({ method: 'clis.updated', params: { clis: list } });
    const codex = list.find((c) => c.provider === 'codex');
    const version = codex?.installedVersion;
    if (version && version !== this.codexVersion) {
      const changed = this.codexVersion !== undefined || this.codexMissing;
      this.codexVersion = version;
      if (changed && !this.stopping) void this.probeModels((a) => a.provider === 'codex');
    }
    this.codexMissing = codex?.status === 'missing';
  }

  // Runs a pending archive once no CLI has the session: none live and none
  // closing. Skipped if the thread came back meanwhile.
  private archiveWhenGone(st: ThreadState): void {
    const { rec, rt } = st;
    if (!rt.archivePending || rt.session || rt.closing || rt.deleted) return;
    rt.archivePending = false;
    if (rec.archivedAt) this.archiveNative(st);
  }

  // Archives the native session in the CLI's own app (Codex Desktop) when
  // the thread is archived or deleted here, once `after` (the session
  // letting go) has settled. Best effort.
  private archiveNative(st: ThreadState, after?: Promise<unknown>): void {
    const { rec } = st;
    const adapter = this.adapters[rec.provider];
    if (!adapter?.archive || !rec.sessionUsed || !rec.nativeSessionId) return;
    const account = this.accounts.get(rec.accountId);
    if (!account) return;
    const nativeId = rec.nativeSessionId;
    const threadId = rec.id;
    void Promise.resolve(after)
      .catch(() => undefined)
      .then(() => adapter.archive!(account, nativeId))
      .catch((e: unknown) => this.log.warn('could not archive the session in the CLI', { threadId, nativeSessionId: nativeId, error: String(e) }));
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
    delete st.rec.snoozedUntilRestart;
    st.rec.forceUnread = true;
    st.rec.updatedAt = this.isoNow();
    this.markDirty(st);
    this.kickQueue(st);
  }

  // Starts the next queued message if nothing is running. Returns true if
  // one started. One that can't be written (disk full) stays at the front.
  private kickQueue(st: ThreadState): boolean {
    if (st.rt.turn || st.rec.queue.length === 0 || this.stopping) return false;
    // A draining runner hands a thread over with its queue rather than
    // start another turn on the old release; the primary starts it.
    if (this.draining) {
      this.queueHandoverCheck();
      return false;
    }
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
    if (st.rt.deleted) throw new Error('The thread was deleted.');
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

  // A sub-agent started or changed (AdapterOutput 'subagent').
  private updateSubagent(st: ThreadState, u: SubagentUpdate): void {
    const { rec } = st;
    const list = (rec.subagents ??= []);
    let a = list.find((x) => x.id === u.id);
    if (!a) {
      // An update for one the list doesn't have (a resumed CLI reporting a
      // sub-agent from before) still gets a row.
      a = { id: u.id, description: '', status: 'running', background: false, startedAt: this.isoNow(), accountId: rec.accountId, cwd: rec.cwd };
      if (rec.nativeSessionId) a.sessionId = rec.nativeSessionId;
      list.push(a);
      // Keep the newest SUBAGENTS_KEPT, dropping finished ones first.
      while (list.length > SUBAGENTS_KEPT) {
        const i = list.findIndex((x) => x.status !== 'running');
        list.splice(i >= 0 ? i : 0, 1);
      }
    }
    if (u.itemId) a.itemId = u.itemId;
    if (u.parentId) a.parentId = u.parentId;
    if (u.description) a.description = u.description;
    if (u.agentType) a.agentType = u.agentType;
    if (u.background) a.background = true;
    if (u.toolUses !== undefined) a.toolUses = u.toolUses;
    if (u.summary) a.summary = u.summary;
    if (u.status) {
      if (u.status !== 'running' && a.status === 'running') a.endedAt = this.isoNow();
      a.status = u.status;
    }
    if (a.status !== 'running') delete a.activity;
    else if (u.activity) a.activity = u.activity;
    this.markDirty(st);
  }

  // Marks the thread's running sub-agents stopped once the CLI running them
  // has gone.
  private stopSubagents(st: ThreadState): void {
    let any = false;
    for (const a of st.rec.subagents ?? []) {
      if (a.status !== 'running') continue;
      a.status = 'stopped';
      a.endedAt = this.isoNow();
      delete a.activity;
      any = true;
    }
    if (any) this.markDirty(st);
  }

  private markDirty(st: ThreadState): void {
    if (st.rt.deleted) return;
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
      // A finished turn that said it needs nothing isn't waiting on Mike
      // (docs/protocol.md, "Needs you").
      needsYou: rec.status === 'waiting' || Boolean(rec.forceUnread) || (!running && rec.lastTurnCompletedSeq > rec.lastSeenSeq && !this.saidNothing(rec)),
      createdAt: rec.createdAt,
      updatedAt: rec.updatedAt,
      lastActivityAt: rec.lastActivityAt,
      preview: rec.preview,
      lastSeq: rec.lastSeq,
      lastSeenSeq: rec.lastSeenSeq,
    };
    if (rec.needs && rec.needs.seq === rec.lastTurnCompletedSeq) {
      s.needs = rec.needs.needs;
      if (rec.needs.asks) {
        const ticked = new Set(rec.needs.ticked);
        s.asks = rec.needs.asks.map((a, i) => (ticked.has(i) ? { ...a, ticked: true as const } : a));
        s.asksSeq = rec.needs.seq;
      }
    }
    if (rec.model) s.model = rec.model;
    if (rec.effort) s.effort = rec.effort;
    if (rec.modelInUse) s.modelInUse = rec.modelInUse;
    if (rec.effortInUse) s.effortInUse = rec.effortInUse;
    if (rec.snoozedUntil) s.snoozedUntil = rec.snoozedUntil;
    if (rec.snoozedUntilRestart) s.snoozedUntilRestart = true;
    if (rec.archivedAt) s.archivedAt = rec.archivedAt;
    if (rec.nativeSessionId && rec.sessionUsed) s.nativeSessionId = rec.nativeSessionId;
    if (rec.contextTokens !== undefined) s.contextTokens = rec.contextTokens;
    if (rec.contextWindow !== undefined) s.contextWindow = rec.contextWindow;
    if (rec.costUsd !== undefined) s.costUsd = rec.costUsd;
    const set = this.patchSet(st);
    if (set.panels.length) s.panels = set.panels;
    if (set.actions.length) s.actions = set.actions;
    if (set.hooks.length) s.hooks = set.hooks;
    if (set.patches.length) s.patches = set.patches;
    const background = this.background(st);
    if (background.length) s.background = background;
    if (rec.subagents?.length) s.subagents = rec.subagents.map(publicSubagent);
    const projects = this.projects?.threadProjects(rec);
    if (projects) s.projects = projects;
    return s;
  }

  // What the thread's folder gives it (see Runtime.patches): the last set
  // read, with a fresh read started when it's stale.
  private patchSet(st: ThreadState): PatchSet {
    const { rec, rt } = st;
    const now = this.clock.now();
    const folders = this.projects?.foldersFor(rec) ?? [];
    const key = JSON.stringify([rec.cwd, folders]);
    if (rt.patches && rt.patches.cwd === rec.cwd && rt.patches.key !== key) {
      // Same folder, different projects: keep showing what there is while
      // the new set loads, rather than flashing the panels away.
      rt.patches.key = key;
      rt.patches.at = -Infinity;
    }
    if (!rt.patches || rt.patches.cwd !== rec.cwd) {
      // The built-in panels straight away; the files follow.
      let panels: PatchSet['panels'] = [];
      try {
        panels = projectPanels(rec.cwd, this.panelsRoot, folders);
      } catch (e) {
        this.log.warn('could not read the folder for panels', { threadId: rec.id, cwd: rec.cwd, error: String(e) });
      }
      rt.patches = { cwd: rec.cwd, key, at: now, set: { ...EMPTY_PATCH_SET, panels }, refreshing: false, loaded: false };
      void this.refreshPatches(st);
    } else if (!rt.patches.refreshing && now - rt.patches.at > PATCHES_TTL_MS) {
      void this.refreshPatches(st);
    }
    return rt.patches.set;
  }

  // Reads the folder's patches again; a change sends a new summary, and a
  // patch file that has appeared or broken since the last read is said in
  // the transcript (not on the first read, which would say it at startup).
  async refreshPatches(st: ThreadState): Promise<void> {
    const { rec, rt } = st;
    const entry = rt.patches;
    if (!entry || entry.refreshing) return;
    entry.refreshing = true;
    const cwd = rec.cwd;
    const key = entry.key;
    let set: PatchSet;
    try {
      set = await loadPatchSet(cwd, this.panelsRoot, this.patchCache, this.projects?.foldersFor(rec) ?? []);
    } catch (e) {
      this.log.warn('could not read the folder for patches', { threadId: rec.id, cwd, error: String(e) });
      set = entry.set;
    }
    entry.refreshing = false;
    entry.at = this.clock.now();
    // The folder moved on meanwhile: the next summary starts over.
    if (rt.patches !== entry || rec.cwd !== cwd || rt.deleted) return;
    // The projects changed meanwhile: read again.
    if (entry.key !== key) {
      entry.at = -Infinity;
      this.markDirty(st);
      return;
    }
    const before = entry.set;
    const changed = JSON.stringify(before) !== JSON.stringify(set);
    if (entry.loaded && changed) this.notePatchChanges(st, before, set);
    entry.set = set;
    entry.loaded = true;
    if (changed) this.markDirty(st);
  }

  private notePatchChanges(st: ThreadState, before: PatchSet, after: PatchSet): void {
    const was = new Map(before.patches.map((p) => [p.id + '@' + p.source, p]));
    for (const p of after.patches) {
      if (p.source === 'builtin') continue;
      const old = was.get(p.id + '@' + p.source);
      if (p.error) {
        if (old?.error !== p.error) this.emit(st, { type: 'system.note', text: `Patch ${p.id} couldn't load: ${p.error}` });
        continue;
      }
      if (old && !old.error) continue;
      const gives: string[] = [];
      const actions = after.actions.filter((a) => a.patch === p.id).map((a) => a.title);
      const panels = after.panels.filter((x) => x.patch === p.id).map((x) => x.title);
      const hooks = after.hooks.filter((x) => x.patch === p.id).map((x) => x.title);
      if (actions.length) gives.push(`${actions.length === 1 ? 'action' : 'actions'} ${actions.join(', ')}`);
      if (panels.length) gives.push(`${panels.length === 1 ? 'panel' : 'panels'} ${panels.join(', ')}`);
      if (hooks.length) gives.push(`${hooks.length === 1 ? 'hook' : 'hooks'} ${hooks.join(', ')}`);
      this.emit(st, { type: 'system.note', text: `Patch ${p.id} ${old ? 'loads again' : 'added'}: ${gives.join(', ') || 'nothing yet'}.` });
    }
  }

  // Draws an image panel (the Simulator's screenshot) for `panels.render`.
  async renderPanel(threadId: string, panelId: string): Promise<PanelRender> {
    const st = this.mustGet(threadId);
    const panel = this.patchSet(st).panels.find((p) => p.id === panelId);
    if (!panel) throw new RpcError(ErrorCode.badParams, `This thread has no panel called ${panelId}`);
    return renderPanel(panel, paths.panels(this.cfg.home, threadId), this.screenshot);
  }

  // Runs the folder's turn.end hooks for a turn that just completed: each
  // command's output goes into the transcript as an action.run, and when
  // the hook's `tell` says so (failures by default), to the agent as a
  // message from the runner, which starts a turn. A hook whose turn fails
  // the same way again is told HOOK_TELL_LIMIT times, then only posted.
  private async runHooks(st: ThreadState, turn: Turn): Promise<void> {
    const hooks = this.patchSet(st).hooks.filter((h) => h.on === 'turn.end' && hookApplies(h, turn.edited, st.rec.cwd));
    if (!hooks.length) return;
    st.rt.hooksRunning = (st.rt.hooksRunning ?? 0) + 1;
    try {
      await this.runHookList(st, hooks);
    } finally {
      st.rt.hooksRunning--;
      if (this.draining) this.queueHandoverCheck();
    }
  }

  private async runHookList(st: ThreadState, hooks: PatchSet['hooks']): Promise<void> {
    for (const hook of hooks) {
      if (st.rt.deleted || this.stopping) return;
      const outcome = await runCommand(hook.command, {
        cwd: hook.folder ?? st.rec.cwd,
        env: { ...process.env, ...threadEnv(st.rec.id, this.cfg.home) },
        shell: this.actionShell,
        timeoutMs: this.actionTimeoutMs,
      });
      if (st.rt.deleted || this.stopping) return;
      const body: EventBody = {
        type: 'action.run',
        actionId: hook.id,
        patch: hook.patch,
        title: hook.title,
        command: hook.command,
        ok: outcome.ok,
        text: outcome.text,
        truncated: outcome.truncated,
        durationMs: outcome.durationMs,
        trigger: 'turn.end',
      };
      if (outcome.exitCode !== undefined) body.exitCode = outcome.exitCode;
      this.emit(st, body, st.rt.turn?.turnId);
      this.markDirty(st);
      const tell = hook.tell === 'always' || (hook.tell === 'failures' && !outcome.ok);
      if (!tell) continue;
      const counts = (st.rt.hookTurns ??= new Map());
      const sofar = counts.get(hook.id) ?? 0;
      if (sofar >= HOOK_TELL_LIMIT) {
        this.log.info('hook result not told again', { threadId: st.rec.id, hook: hook.id, times: sofar });
        continue;
      }
      counts.set(hook.id, sofar + 1);
      const shown = outcome.text.length > HOOK_TELL_CHARS ? outcome.text.slice(-HOOK_TELL_CHARS) : outcome.text;
      const verdict = outcome.ok ? 'passed' : `failed${outcome.exitCode !== undefined ? ` (exit ${outcome.exitCode})` : ''}`;
      const text =
        `[Threadbear hook] ${hook.title} (patch ${hook.patch}) ran after your turn and ${verdict}:\n\n` +
        '```\n' + (shown.trim() || '(no output)') + '\n```\n\n' +
        (outcome.ok ? 'Nothing to do unless something above surprises you.' : 'If this is from your change, fix it; if not, say so and carry on.');
      try {
        this.sendTo(st, text, [], { origin: 'runner' });
      } catch (e) {
        this.log.warn('could not tell the agent a hook result', { threadId: st.rec.id, hook: hook.id, error: String(e) });
      }
    }
  }

  // Runs an action for `actions.run`: a prompt action is a message to the
  // thread; a command action runs in its folder, and what it printed goes
  // into the transcript as an action.run event. One run of an action at a
  // time per thread.
  async runAction(threadId: string, actionId: string): Promise<{ turnId?: string; ok?: boolean; exitCode?: number; durationMs?: number; seq?: number }> {
    const st = this.mustGet(threadId);
    const action = this.patchSet(st).actions.find((a) => a.id === actionId);
    if (!action) throw new RpcError(ErrorCode.badParams, `This thread has no action called ${actionId}`);
    if (action.kind === 'prompt') return this.send(threadId, action.prompt ?? '');
    const running = (st.rt.runningActions ??= new Set());
    if (running.has(actionId)) throw new RpcError(ErrorCode.busy, `${action.title} is already running.`);
    running.add(actionId);
    try {
      const outcome = await runCommand(action.command ?? '', {
        cwd: action.folder ?? st.rec.cwd,
        env: { ...process.env, ...threadEnv(threadId, this.cfg.home) },
        shell: this.actionShell,
        timeoutMs: this.actionTimeoutMs,
      });
      if (st.rt.deleted) return { ok: outcome.ok, exitCode: outcome.exitCode, durationMs: outcome.durationMs };
      const body: EventBody = {
        type: 'action.run',
        actionId,
        patch: action.patch,
        title: action.title,
        command: action.command ?? '',
        ok: outcome.ok,
        text: outcome.text,
        truncated: outcome.truncated,
        durationMs: outcome.durationMs,
      };
      if (outcome.exitCode !== undefined) body.exitCode = outcome.exitCode;
      const event = this.emit(st, body, st.rt.turn?.turnId);
      st.rec.lastActivityAt = this.isoNow();
      this.markDirty(st);
      return { ok: outcome.ok, exitCode: outcome.exitCode, durationMs: outcome.durationMs, seq: event.seq };
    } finally {
      running.delete(actionId);
    }
  }

  // A thread by full id or unique prefix, for titles; undefined if unclear.
  private findThread(q: string): ThreadSummary | undefined {
    const exact = this.threads.get(q);
    if (exact) return this.summary(exact);
    const hits = [...this.threads.values()].filter((t) => t.rec.id.startsWith(q));
    return hits.length === 1 ? this.summary(hits[0]) : undefined;
  }

  private mustGet(threadId: string): ThreadState {
    const st = typeof threadId === 'string' ? this.threads.get(threadId) : undefined;
    if (!st) throw new RpcError(ErrorCode.threadNotFound, `Thread not found: ${threadId}`);
    return st;
  }

  private rememberAccount(accountId: string): void {
    try {
      const json = readRunnerJson(this.cfg.home);
      // keepAccount pins the default (a dev runner's claude-3): using
      // another account once mustn't move it.
      if (json.defaults?.keepAccount || json.defaults?.accountId === accountId) return;
      json.defaults = { ...json.defaults, accountId };
      writeRunnerJson(this.cfg.home, json);
    } catch (e) {
      this.log.warn('could not save default account', { error: String(e) });
    }
  }

  // What a starting session is told about the thread's projects. Only a
  // fresh session: Claude Code keeps a resumed session's system prompt and
  // ignores an appended one, so a resume hears through projectNews.
  private briefFor(rec: ThreadRecord, resume: boolean): { instructions?: string } {
    if (!this.projects || resume) return {};
    rec.projectsTold = this.projects.briefIds(rec);
    const brief = this.projects.brief(rec);
    return brief ? { instructions: brief } : {};
  }

  // The thread's projects its session hasn't been told about, as lines to
  // put before its next message, or undefined. A thread whose session
  // predates projects (never told anything) gets the whole brief.
  private projectNews(rec: ThreadRecord): string | undefined {
    if (!this.projects) return undefined;
    const ids = this.projects.briefIds(rec);
    const told = rec.projectsTold;
    const fresh = ids.filter((id) => !told?.includes(id));
    rec.projectsTold = ids;
    if (!fresh.length) return undefined;
    return told === undefined ? this.projects.brief(rec) : this.projects.joinedLines(fresh);
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
    if (from.lost) {
      return (
        `[Threadbare handoff] The earlier session couldn't be found, so here's where the thread got to. This is a fresh session in ${rec.cwd}. ` +
        `Recent messages, for context:\n\n${lines.join('\n\n') || '(none)'}\n\n[End of handoff. The new message follows.]\n\n`
      );
    }
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

export type SendOptions = { origin?: MessageOrigin; scheduleId?: string; queue?: boolean };

// How many sub-agents a thread keeps in its summary.
const SUBAGENTS_KEPT = 20;

function publicSubagent(a: SubagentRecord): Subagent {
  const { sessionId: _s, cwd: _c, accountId: _a, ...rest } = a;
  return rest;
}

function userMessage(msg: QueuedSend): EventBody {
  return {
    type: 'user.message',
    text: msg.text,
    images: msg.images,
    ...(msg.origin ? { origin: msg.origin } : {}),
    ...(msg.scheduleId ? { scheduleId: msg.scheduleId } : {}),
  };
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
    finished: [],
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

// What the runner asks a small model for a thread's title. The examples
// do more than the rules: without them Haiku drifts into Title Case and
// sometimes describes the naming job itself.
const TITLE_PROMPT = [
  'You name threads in Threadbare, an app for running AI agents, mostly for coding.',
  'Reply with the title only: 2 to 6 words saying what the thread is about.',
  'Sentence case: a capital for the first word and for names only. No quotes, no full stop, no dashes, no emoji.',
  'Never mention titles, threads or the person asking.',
  '',
  'Message: can you look at why the upload test keeps failing on CI',
  'Title: Fix the flaky upload test on CI',
  '',
  'Message: Hey, does the runner keep running even if we restart the UI?',
  'Title: Does the runner outlive the app',
  '',
  'Message: hello there',
  'Title: Hello',
].join('\n');

// A model's title, tidied: first line, no wrapping quotes or full stop,
// nothing after a dash. One that runs long (rambling, or cut off by the
// token limit) is no title at all, so the first line stays.
export function cleanTitle(text: string): string {
  let t = (text ?? '').split('\n').map((l) => l.trim()).find(Boolean) ?? '';
  t = t.replace(/^(title:\s*)/i, '').split(/\s[—–-]\s/)[0];
  t = t.replace(/^\*+|\*+$/g, '').trim();
  // Quotes only when they wrap the whole title; ones inside it stay.
  if (/^(["'`]).*\1$/.test(t)) t = t.slice(1, -1);
  t = t.replace(/\.$/, '').trim();
  if (t.length > LIMITS.titleChars || t.split(/\s+/).length > 10) return '';
  return t;
}

// What a completed turn needs from Mike: its end_turn call, then its last
// text's "What I need from you" section, else nothing said.
function turnNeeds(turn: Turn): (Needs & { from: 'tool' | 'text' }) | undefined {
  const tool = turn.endTurn && needsFromTool(turn.endTurn);
  if (tool) return { ...tool, from: 'tool' };
  const text = turn.lastText && needsFromText(turn.lastText);
  return text ? { ...text, from: 'text' } : undefined;
}

export function oneLine(text: string, max: number): string {
  const s = text.replace(/\s+/g, ' ').trim();
  return s.length > max ? s.slice(0, max - 1).trimEnd() + '…' : s;
}

// A provider's name in notes.
function providerName(p: Provider): string {
  return p === 'codex' ? 'Codex' : 'Claude';
}

function cliName(p: Provider): string {
  return p === 'codex' ? 'Codex' : 'Claude Code';
}

// Claude's own ids: its aliases, and anything starting claude- (with or
// without a [1m] suffix).
export function isClaudeModel(id: string): boolean {
  const bare = stripModelSuffix(id).toLowerCase();
  return ['opus', 'sonnet', 'haiku', 'default', 'opusplan'].includes(bare) || bare.startsWith('claude-');
}

// The account's row for a model id, matched by picker id or full id.
function modelRow(account: Account, model: string | undefined): ModelChoice | undefined {
  if (!model) return undefined;
  return account.models?.find((m) => m.id === model || m.model === model);
}

function modelTitle(account: Account, model: string): string {
  return modelRow(account, model)?.title ?? model;
}

const EFFORT_TITLES: Record<EffortLevel, string> = { low: 'Low', medium: 'Medium', high: 'High', xhigh: 'Extra high', max: 'Max', ultra: 'Ultra' };

function effortTitle(e: EffortLevel): string {
  return EFFORT_TITLES[e] ?? e;
}

// "A", "A and B", "A, B and C".
function joinWords(words: string[]): string {
  return words.length <= 1 ? (words[0] ?? '') : `${words.slice(0, -1).join(', ')} and ${words.at(-1)}`;
}

// What clients were last told about the accounts, to tell a real change
// from a rescan that found the same list.
function accountsKey(accounts: Account[]): string {
  return JSON.stringify(accounts);
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
