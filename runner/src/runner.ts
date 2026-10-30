// The thread manager: owns threads, turns, the event log, approvals, idle
// release and snoozes. Providers plug in through AgentAdapter; the WebSocket
// server in rpc.ts is a thin layer over the public methods here.
import type { UpstreamStatus } from './upstream.ts';
import fs from 'node:fs';
import os from 'node:os';
import { SAMPLE_THREADS, WELCOME_PATCH } from './samples.ts';
import { reviewInput, reviewDraft, reviewReply, sameDraft, type ReviewInput } from './reviews.ts';
import path from 'node:path';
import { ConvexKeys, convexFolderFor, type ConvexKey, type ConvexDeployments } from './convex-keys.ts';
import crypto from 'node:crypto';
import type {
  Panel,
  Account,
  Action,
  AnyEvent,
  ApprovalDecision,
  BackgroundTask as ProtocolBackgroundTask,
  CliPolicy,
  CliStatus,
  DeltaBody,
  DeltaType,
  DesignReview,
  ReviewDraft,
  EffortLevel,
  EventBody,
  ImageRef,
  InProgressItem,
  AskAnswer,
  MessageOrigin,
  ModelChoice,
  PanelPlace,
  PanelRequest,
  ShareAccess,
  PermissionMode,
  PersistedEvent,
  Pool,
  Provider,
  Question,
  RewoundFiles,
  RunnerDefaults,
  Subagent,
  ThreadStatus,
  ThreadSummary,
  TurnOutcome,
} from './protocol.ts';
import { ErrorCode, LIMITS, PROTOCOL_VERSION, RpcError, sentByAgent } from './protocol.ts';
import type { LibrarianStatus, Project, Schedule } from './protocol.ts';
import { Projects } from './projects.ts';
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
import type { RewindResult } from './adapters/types.ts';
import type { ThreadRecord, ThreadStore, QueuedSend, SubagentRecord } from './store.ts';
import { cutOut } from './store.ts';
import { appliedChanges, undoChanges } from './undo-edits.ts';
import type { Clock, TimerHandle } from './clock.ts';
import type { Logger } from './log.ts';
import { BIN_DIR, threadEnv } from './restart.ts';
import { cleanUpWorktree, makeWorktree, sameSubfolder, worktreeInstructions } from './worktrees.ts';
import { stripModelSuffix, type AccountRegistry, type LearnedAccountInfo } from './accounts.ts';
import { pickAccount as pickByRoom, resetTime, type UsageReading } from './usage.ts';
import { DEFAULT_POOL_FOLDERS, RUNNER_VERSION, expandHome, paths, readRunnerJson, writeRunnerJson, type Config } from './config.ts';
import { WAIT_SLACK_MS, blockedUntil, limitWhy, loginOk, nextLogin, pickInPool, poolAccounts, poolForFolder, poolProviders, readPools, roomWait, validatePools } from './pools.ts';
import { copyImageInto, imageRefFor } from './media.ts';
import { isDirectory } from './fsutil.ts';
import { commandFolders } from './tools.ts';
import { copySessionTranscript, subagentTranscriptPath } from './transcripts.ts';
import { historyItems, selectHistory } from './handoff-history.ts';
import { readSubagentTranscript } from './adapters/claude/subagents.ts';
import { fileContext } from './adapters/claude/normalize.ts';
import type { Models } from './models/index.ts';
import { EXPLAIN_SYSTEM, RECENT_CHARS, RECENT_MESSAGES, explainPrompt } from './explain.ts';
import type { ExplainTurn } from './explain.ts';
import { SAID_MAX, WAKE_SYSTEM, awayFor, hibernateNote, readWakeAnswer, wakePrompt } from './wake-when.ts';
import { emptyHighlights, observe as observeHighlights, pinItem, remove as removeHighlight, unpin as unpinHighlight, upsert as upsertHighlight, view as highlightsView, absolute, type ThreadHighlights } from './highlights.ts';
import { SERVER_NAME, approvalTitle } from './threadbear-mcp.ts';
import { PANEL_ACK_WAIT_MS, PANEL_PLACES, resolvePanel } from './panel-requests.ts';
import { archiveFromTool, END_TURN_TOOL, endTurnAccepted, endTurnAsksForMessage, endTurnOwesReply, endTurnTaken, needsFromText, needsFromTool, summaryFromTool, summaryMarkdown } from './needs.ts';
import type { Needs } from './needs.ts';
import { asksForAppRestart } from './app-restarts.ts';
import type { ConnectorsStatus } from './connectors.ts';
import { isPatchFile, PatchTrust, type PatchTrustStore } from './patch-trust.ts';
import {
  EMPTY_PATCH_SET,
  findWorktreePatch,
  hookApplies,
  isInside,
  loadPatchSet,
  applyLive,
  hasLive,
  projectPanels,
  renderListPanel,
  renderPanel,
  runCommand,
  simctlScreenshot,
  type CommandOutcome,
  type PanelRender,
  type PatchCache,
  type PatchSet,
  type ProjectFolder,
  type Screenshot,
  worktreePatchFiles,
  projectPatchFiles,
} from './patches.ts';
import { FolderCache } from './folder-cache.ts';

export type Notification =
  | { method: 'thread.updated'; params: { thread: ThreadSummary } }
  | { method: 'thread.event'; params: { threadId: string; event: AnyEvent } }
  | { method: 'thread.deleted'; params: { threadId: string } }
  | { method: 'accounts.updated'; params: { accounts: Account[] } }
  | { method: 'pools.updated'; params: { pools: Pool[] } }
  | { method: 'runner.notice'; params: { level: 'info' | 'warning' | 'error'; message: string } }
  | { method: 'schedules.updated'; params: { schedules: Schedule[] } }
  // Other runners' threads, from the backend (thread-index.ts, step 6 part 2).
  | { method: 'remoteThreads.updated'; params: import('./thread-index.ts').RemoteThreads }
  | { method: 'clis.updated'; params: { clis: CliStatus[] } }
  | { method: 'settings.updated'; params: { settings: Settings } }
  | { method: 'runner.updates'; params: { updates: RunnerUpdates } }
  | { method: 'projects.updated'; params: { projects: Project[] } }
  | { method: 'librarian.updated'; params: { librarian: LibrarianStatus } }
  | { method: 'connectors.updated'; params: { connectors: ConnectorsStatus } }
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
  launcherReason?: string;
  // Mike's releases, for a fork (upstream.ts); left out while off.
  upstream?: UpstreamStatus;
};

// What the librarian (librarian.ts) hears about threads: a turn that ended,
// and a folder move.
export type ThreadActivity =
  | { kind: 'turn.start'; threadId: string }
  | { kind: 'turn.end'; threadId: string; outcome: TurnOutcome; edited: string[]; workedIn?: string[] }
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

// main: the card is for the agent's own tool call, so its CLI waits on it
// and reads nothing else until it's answered. A background subagent's card
// (no tool call of the agent's to point at) holds up only that subagent.
type PendingApproval =
  | { approvalId: string; kind: 'tool'; main: boolean; resolve: (a: ToolApprovalAnswer) => void }
  | { approvalId: string; kind: 'question'; main: boolean; questions: Question[]; resolve: (a: QuestionAnswer) => void };

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
  // Edit and Write calls on patch files, by item, until their result: the
  // file is trusted as the agent left it (patch-trust.ts).
  patchEdits?: Map<string, string>;
  // Folders its shell commands worked in (commandFolders), so the
  // librarian knows the repo a thread in a catch-all folder works on.
  workedIn?: Set<string>;
  // The agent's own end_turn input and last text, for what the turn needs
  // from Mike (needs.ts). Never a sub-agent's.
  endTurn?: Record<string, unknown>;
  lastText?: string;
  // The agent's latest end_turn call, and whether one was accepted since
  // Mike last wrote. Text after that is dropped: end_turn has already told
  // it to stop, yet an agent repeated its last line under it as a second
  // message (28 Oct 2026).
  endTurnCall?: string;
  // Its end_turn's summary is in the events as the turn's reply.
  summarized?: boolean;
  ended?: boolean;
  // The itemId of the agent's latest text when that was only a summary
  // (assistant.text with narration: a Claude narration block). The first
  // text after an accepted end_turn is then the real message, which
  // end_turn asked for (needs.ts, NARRATION_ONLY): it's kept, not dropped,
  // and takes the summary's itemId so it replaces it.
  narrationItem?: string;
  // The accepted end_turn brought bullets with no message since the last
  // step, and asked whether they stand for one not yet written (needs.ts,
  // BULLETS_ONLY): the first own text after it is that message, kept
  // rather than dropped (30 Oct 2026, thread 2a0a9c2c), when it says more
  // than the bullets, as the app takes it as the reply only then
  // (TranscriptReducer, reply(of:)): a "Done." under them is still a
  // repeat. The bullets' length, while it's owed.
  owedReply?: number;
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
  // `base` is the set as the files give it; `set` is that with live state
  // applied (applyLive), which is what the app sees. `live`: base has any.
  patches?: { cwd: string; key: string; at: number; base: PatchSet; set: PatchSet; refreshing: boolean; loaded: boolean; live?: boolean };
  runningActions?: Set<string>;
  // Turns in a row that a hook's message started, per hook. A hook that
  // keeps failing stops being told to the agent after HOOK_TELL_LIMIT, so
  // two can't go round for ever; a message from anyone else resets it.
  hookTurns?: Map<string, number>;
  // Turn-end hooks still running; a draining runner waits for them, since
  // one may tell the agent something and start a turn.
  hooksRunning?: number;
  // A show_panel call waiting to hear the app has shown its request
  // (threads.panelShown), for at most PANEL_ACK_WAIT_MS.
  panelWaiter?: { id: string; resolve: (shown: boolean) => void; timer: TimerHandle };
  // An edit of an earlier message is under way (editMessage): nothing
  // starts a turn until it has, and messages sent meanwhile wait.
  editing?: boolean;
  // Called when the running turn ends (endTurn), for an edit waiting on it.
  turnEndWaiters?: (() => void)[];
};

type ThreadState = { rec: ThreadRecord; rt: Runtime };

type Drain = {
  keep: Set<string>;
  going: Set<string>; // being let go
  onHandedOver: (threadId: string) => void;
  backgroundMs: number;
  agentMs: number;
  checkMs: number;
  checkQueued: boolean;
  ready: () => boolean;
  timer?: TimerHandle;
};

// How often a draining runner looks again at threads it keeps for
// background work, since that work's limit passes without an event.
const DRAIN_CHECK_MS = 5000;
// How long subagents hold a kept thread after its last turn. Long, since
// they end by themselves; only a stuck one should ever reach it.
const DRAIN_AGENT_MS = 4 * 60 * 60_000;

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
  // Which project patch files may load (patch-trust.ts). Defaults to
  // patch-trust.json in the data dir; tests not about trust pass TRUST_ALL.
  patchTrust?: PatchTrustStore;
  // The shell command actions run through, and how long they may take;
  // tests pass /bin/sh -c and a short limit.
  actionShell?: string[];
  actionTimeoutMs?: number;
  // Runs the Convex CLI for the Convex panel's deploy keys (convex-keys.ts);
  // tests pass a fake that writes the key file the CLI would.
  convexKeyRun?: (command: string, cwd: string) => Promise<CommandOutcome>;
  // The runner's own small-model calls (models/index.ts), for titles.
  // Absent in most tests, which then keep the first-line title.
  models?: Pick<Models, 'generate'>;
  // Projects (projects.ts): their folders' patches, the brief a session
  // starts with, and the summary's `projects`. Started by start().
  projects?: Projects;
  // A completed turn asked Mike to Restart to Update, by end_turn or in its
  // closing "What I need from you" (app-restarts.ts signs the thread up).
  appRestartAsked?: (threadId: string) => void;
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
// How long a folder listing (and a patch file's time, a .env) read for one
// thread's patches serves every other thread in the same folders
// (folder-cache.ts). A turn ending forgets them, as it may have added one.
const FOLDER_CACHE_MS = 10_000;
// How often a thread whose patches have live state (when, badge) has it
// read again by itself, while it's in the inbox: comments Mike leaves in
// Tandem turn into a "Your turn" chip within this long.
const LIVE_POLL_MS = 20_000;
// How long a live state command's output serves every thread in the same
// folder (runLiveCommand): well inside one poll, so each poll runs it again.
const LIVE_SHARE_MS = 10_000;
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
// snoozedUntil for a thread waiting on a topic alone (wake-when.ts), or
// while its time is worked out: the same far-off time, without the flag.
export const NO_WAKE_TIME = UNTIL_RESTART;

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
  private convexKeys: ConvexKeys;
  private models?: Pick<Models, 'generate'>;
  private projects?: Projects;
  private activity = new Set<(a: ThreadActivity) => void>();
  private patchCache: PatchCache = new Map();
  private patchTrust: PatchTrustStore;
  private folderCache: FolderCache;
  private sharedPatchSets = new Map<string, { at: number; set: Promise<PatchSet> }>();
  private patchReads = new Set<Promise<void>>();
  private liveRuns = new Map<string, { doneAt?: number; out: Promise<CommandOutcome> }>();
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
  private liveTimer?: TimerHandle;
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
  // Pools (docs/protocol.md, "Pools"): the timer for threads waiting for
  // room, the list clients were last sent, and logins a turn found at
  // their limit, blocked here until the time given even when the usage
  // readings haven't caught up.
  private roomTimer?: TimerHandle;
  private armingRoom = false;
  private poolsShown?: string;
  private ranDry = new Map<string, number>();
  private appRestartAsked?: (threadId: string) => void;

  constructor(deps: RunnerDeps) {
    this.cfg = deps.config;
    this.store = deps.store;
    this.copyTranscript = deps.copyTranscript ?? copySessionTranscript;
    this.subagentTranscript = deps.subagentTranscript ?? subagentTranscriptPath;
    this.screenshot = deps.screenshot ?? simctlScreenshot;
    this.panelsRoot = deps.panelsRoot;
    this.patchTrust = deps.patchTrust ?? new PatchTrust({ file: path.join(deps.config.home, 'patch-trust.json') });
    this.actionShell = deps.actionShell;
    this.actionTimeoutMs = deps.actionTimeoutMs;
    this.convexKeys = new ConvexKeys(
      path.join(paths.secrets(deps.config.home), 'convex-panels'),
      deps.convexKeyRun ?? ((command, cwd) => runCommand(command, { cwd, env: { ...process.env }, shell: this.actionShell, timeoutMs: 120_000 })),
    );
    this.models = deps.models;
    this.projects = deps.projects;
    this.appRestartAsked = deps.appRestartAsked;
    this.adapters = deps.adapters;
    this.accounts = deps.accounts;
    this.usage = deps.usage;
    this.pickAccount = deps.pickAccount ?? pickByRoom;
    this.clock = deps.clock;
    this.folderCache = new FolderCache(FOLDER_CACHE_MS, () => this.clock.now());
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
      this.recoverReviews(st);
      if (this.recover(st)) stopped++;
    }
    if (stopped) this.startupNotice('info', `${stopped === 1 ? 'A thread was' : `${stopped} threads were`} mid-turn when the runner stopped; send a message to carry on.`);
    // Hibernating until the runner restarts: this is the restart. Before
    // the restart's resume (main.ts), so a thread put away while its own
    // restart waited still gets carried on.
    // A wake-when still being worked out lost its answer with the old
    // runner, so it comes back too.
    for (const st of this.threads.values()) if (st.rec.snoozedUntilRestart || st.rec.wakeWhen?.pending) this.wake(st, 'restart');
    // Before anything reads a thread's patches. Every thread on disk,
    // including ones a draining runner still has.
    this.seedPatchTrust(records.map((r) => r.cwd));
    this.flush();
    for (const st of this.threads.values()) if (st.rec.queue.some(q => q.reviewId) && this.bucket(st.rec) === 'inbox') this.kickQueue(st);
    this.armSnoozeTimer();
    // Waits for room are in thread.json, so they outlive a restart.
    this.armRoomTimer();
    this.log.info('runner loaded threads', { count: this.threads.size });
    this.accountsShown = accountsKey(this.safeAccounts());
    this.poolsShown = JSON.stringify(this.pools());
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
    // The built-in pools follow the login list.
    const pools = this.pools(accounts);
    const poolsKey = JSON.stringify(pools);
    if (poolsKey !== this.poolsShown) {
      this.poolsShown = poolsKey;
      this.notify({ method: 'pools.updated', params: { pools } });
    }
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
    const rewinds = events.flatMap((e) => (e.type === 'thread.rewound' ? [{ from: e.fromSeq, to: e.toSeq }] : []));
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
    const reviews = new Map<string, DesignReview>();
    for (const event of events) if (event.type === 'review.updated') reviews.set(event.review.id, event.review);
    if (reviews.size) rec.reviews = [...reviews.values()];
    if (rewinds.length) rec.rewinds = rewinds;
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
    const reviewQueue = rec.queue.filter(q => q.reviewId);
    rec.queue = rec.queue.filter(q => !q.reviewId);
    if (rec.queue.length) {
      const texts = rec.queue.map((q) => q.text).filter(Boolean);
      this.emit(st, {
        type: 'system.note',
        text: `The runner restarted before ${rec.queue.length === 1 ? 'a queued message was' : `${rec.queue.length} queued messages were`} sent:\n\n${texts.join('\n\n')}`,
      });
      rec.queue = [];
    }
    rec.queue.push(...reviewQueue);
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
    this.roomTimer?.cancel();
    this.rescanTimer?.cancel();
    this.accountsTimer?.cancel();
    this.liveTimer?.cancel();
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
  async beginDrain(keep: Iterable<string>, opts: { onHandedOver: (threadId: string) => void; backgroundMs: number; agentMs?: number; checkMs?: number; ready?: () => boolean }): Promise<void> {
    if (this.draining) throw new Error('already draining');
    const d: Drain = {
      keep: new Set([...keep].filter((id) => this.threads.has(id))),
      going: new Set(),
      onHandedOver: opts.onHandedOver,
      backgroundMs: opts.backgroundMs,
      agentMs: opts.agentMs ?? DRAIN_AGENT_MS,
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
  // it. Background shells and monitors hold it for backgroundMs after its
  // last turn, as they hold an idle restart (a dev server never ends), and
  // are then stopped with a note. Subagents hold it for agentMs: they
  // finish by themselves, and stopping one throws away its work (27 Oct: a
  // builder agent an agent left running was cut off after 30 minutes).
  private readyToHandOver(st: ThreadState, d: Drain): boolean {
    const { rt } = st;
    if (rt.turn || rt.approvals.size || rt.wakeTimer || rt.hooksRunning || rt.runningActions?.size) return false;
    if (rt.tasks.length === 0) return true;
    const idleFor = this.clock.now() - rt.activeAt;
    const agents = rt.tasks.some((t) => t.kind === 'agent');
    return idleFor >= (agents ? d.agentMs : d.backgroundMs);
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
    this.recoverReviews(st);
    if (opts.crashed) {
      if (this.recover(st)) this.notice('info', `The old runner stopped while "${rec.title}" was mid-turn; send a message to carry on.`);
    }
    // Hibernating until the runner restarts: for this thread, coming across
    // is the restart.
    if (rec.snoozedUntilRestart || rec.wakeWhen?.pending) this.wake(st, 'restart');
    else if (rec.queue.length && this.bucket(rec) === 'inbox') {
      this.kickQueue(st);
    }
    this.markDirty(st);
    this.armSnoozeTimer();
    this.armRoomTimer();
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

  // Claude threads with no turn going whose CLI still runs background
  // work, for the stuck-job check (stuck-jobs.ts). Its output files are
  // named by the session and task ids.
  idleBackground(): { threadId: string; sessionId: string; tasks: BackgroundTask[] }[] {
    const out: { threadId: string; sessionId: string; tasks: BackgroundTask[] }[] = [];
    for (const { rec, rt } of this.threads.values()) {
      if (rt.deleted || rec.archivedAt || rec.provider !== 'claude' || !rec.nativeSessionId || !rt.session) continue;
      if (rt.turn || rt.wakeTimer || rec.status !== 'idle' || !rt.tasks.length) continue;
      out.push({ threadId: rec.id, sessionId: rec.nativeSessionId, tasks: rt.tasks });
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
    this.forgetFolders();
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
    const first = this.opening(st.rec.id, st.rec).text;
    const log = this.store.log(st.rec.id);
    const recent: { who: 'user' | 'assistant'; text: string }[] = [];
    const want = opts.recent ?? 6;
    // Back from the end a page at a time until there are enough.
    for (let to = log.lastSeq; to >= 1 && recent.length < want; to -= 200) {
      const page = log.read(Math.max(1, to - 199), to);
      for (const e of page.reverse()) {
        if (recent.length >= want) break;
        if (cutOut(st.rec, e.seq)) continue;
        if (e.type === 'user.message' && e.origin === undefined) recent.unshift({ who: 'user', text: cut(e.text) });
        else if (e.type === 'assistant.text' && e.text.trim()) recent.unshift({ who: 'assistant', text: cut(e.text) });
      }
    }
    return { first: first ? cut(first) : undefined, recent };
  }

  // The seq ranges edits cut out of the thread (docs/protocol.md, "Editing
  // a message").
  cuts(threadId: string): { from: number; to: number }[] {
    return [...(this.mustGet(threadId).rec.rewinds ?? [])];
  }

  // What a thread has said since `seq`: how much of Mike's and the
  // agent's text, and whether any of it has a link. The librarian skips a
  // catch-up look when there's little.
  threadSince(threadId: string, seq: number): { chars: number; links: boolean } {
    const st = this.mustGet(threadId);
    const log = this.store.log(st.rec.id);
    let chars = 0;
    let links = false;
    for (let from = seq + 1; from <= log.lastSeq; from += 500) {
      for (const e of log.read(from, Math.min(log.lastSeq, from + 499))) {
        if (cutOut(st.rec, e.seq)) continue;
        const text = e.type === 'user.message' && e.origin === undefined ? e.text : e.type === 'assistant.text' ? e.text : '';
        chars += text.trim().length;
        if (!links && /https?:\/\//.test(text)) links = true;
      }
    }
    return { chars, links };
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

  hello(): { runnerVersion: string; protocol: number; accounts: Account[]; pools: Pool[]; defaults: RunnerDefaults; clis?: CliStatus[] } {
    const accounts = this.accounts.list();
    const pools = this.pools(accounts);
    const defaults: RunnerDefaults = { cwd: this.cfg.defaults.cwd, accountId: this.defaultAccountId(accounts) };
    const poolId = this.defaultPoolId(pools, this.usable(accounts), defaults.accountId);
    if (poolId) defaults.poolId = poolId;
    // `model` is Claude's, for apps that predate `models`.
    const claudeModel = this.defaultModelFor('claude');
    if (claudeModel) defaults.model = claudeModel;
    if (this.cfg.defaults.models) defaults.models = { ...this.cfg.defaults.models };
    if (this.cfg.defaults.efforts) defaults.efforts = { ...this.cfg.defaults.efforts };
    const out: ReturnType<Runner['hello']> = { runnerVersion: RUNNER_VERSION, protocol: PROTOCOL_VERSION, accounts, pools, defaults };
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

  // ------------------------------------------------------------------ pools
  // docs/protocol.md, "Pools". The rules are in pools.ts; this is where
  // they meet threads.

  // The pools in force: runner.json's, else the built-in ones from the
  // logins found.
  private pools(all = this.safeAccounts()): Pool[] {
    return readPools({ pools: this.cfg.pools, accountNotes: this.cfg.accountNotes }, all, this.cfg.poolFolders ?? DEFAULT_POOL_FOLDERS);
  }

  listPools(): { pools: Pool[] } {
    return { pools: this.pools() };
  }

  // For the small-model layer (models/index.ts): a pool and the logins this
  // runner can use, with the room it knows of, a login that just ran dry
  // counting as blocked.
  smallModelPool(id: string): { pool: Pool; accounts: Account[] } | undefined {
    const accounts = this.usableAccounts();
    const pool = this.pools().find((p) => p.id === id);
    return pool ? { pool, accounts: poolAccounts(pool, accounts) } : undefined;
  }

  // A small-model call found this login out of room: the same as a turn
  // that did.
  noteRanDry(accountId: string): void {
    const account = this.safeAccounts().find((a) => a.id === accountId);
    if (account) this.markRanDry(account);
  }

  // pools.save: replaces the whole list in runner.json (an empty one goes
  // back to the built-in pools) and tells every client.
  savePools(raw: unknown): { pools: Pool[] } {
    const checked = validatePools(raw, this.safeAccounts());
    if ('error' in checked) throw new RpcError(ErrorCode.badParams, checked.error);
    const json = readRunnerJson(this.cfg.home);
    if (checked.pools.length) json.pools = checked.pools;
    else delete json.pools;
    writeRunnerJson(this.cfg.home, json);
    this.cfg.pools = checked.pools.length ? checked.pools : undefined;
    const pools = this.pools();
    this.poolsShown = JSON.stringify(pools);
    this.notify({ method: 'pools.updated', params: { pools } });
    return { pools };
  }

  // Logins this runner can start a CLI for, with any it found at its limit
  // marked blocked until then (ranDry).
  private usable(all: Account[]): Account[] {
    const now = this.clock.now();
    return all
      .filter((a) => this.adapters[a.provider])
      .map((a) => {
        const until = this.ranDry.get(a.id);
        if (until === undefined || until <= now || a.usage?.blocked) return a;
        return { ...a, usage: { ...(a.usage ?? { windows: [], readAt: this.isoNow(), source: 'live' as const }), blocked: true } };
      });
  }

  private usableAccounts(): Account[] {
    return this.usable(this.safeAccounts());
  }

  private poolById(id: string | undefined): Pool | undefined {
    return id === undefined ? undefined : this.pools().find((p) => p.id === id);
  }

  // The pool a new thread with nothing named starts on: the last one named
  // (runner.json's defaults.poolId), else the first pool holding the
  // default account, else the first pool. Only pools with a login this
  // runner can use.
  private defaultPoolId(pools: Pool[], usable: Account[], defaultAccount?: string): string | undefined {
    const live = pools.filter((p) => poolAccounts(p, usable).length);
    const saved = readRunnerJson(this.cfg.home).defaults?.poolId ?? this.cfg.defaults.poolId;
    if (saved && live.some((p) => p.id === saved)) return saved;
    const account = defaultAccount ?? this.defaultAccountId();
    return (live.find((p) => p.accountIds.includes(account)) ?? live[0])?.id;
  }

  // The provider a model id belongs to, when that can be told.
  private modelProvider(model: string): Provider | undefined {
    if (isClaudeModel(model)) return 'claude';
    const accounts = this.safeAccounts();
    if (model.startsWith('gpt-') || accounts.some((a) => a.provider === 'codex' && modelRow(a, model))) return 'codex';
    if (accounts.some((a) => a.provider === 'claude' && modelRow(a, model))) return 'claude';
    return undefined;
  }

  // The pool and login for a new thread with no accountId: the pool named,
  // else the folder's, else the default; and when a model is named whose
  // provider has no login there, the first pool that has one. The login is
  // the pool's one of the thread's provider (its model's, else the pool's
  // first) with the most room, else one of another provider with room,
  // else the first of its provider. undefined when no pool has a login
  // this runner can use.
  private pickForNew(p: { poolId?: string; cwd: string; model?: string }): { poolId: string; accountId: string } | undefined {
    const accounts = this.usableAccounts();
    const pools = this.pools().filter((x) => poolAccounts(x, accounts).length);
    let pool: Pool | undefined;
    if (p.poolId !== undefined) {
      pool = pools.find((x) => x.id === p.poolId);
      if (!pool) throw new RpcError(ErrorCode.badParams, `No pool called ${p.poolId}. Pools: ${pools.map((x) => x.id).join(', ') || 'none'}`);
    }
    const wanted = p.model ? this.modelProvider(p.model) : undefined;
    if (!pool) {
      pool = poolForFolder(pools, p.cwd) ?? pools.find((x) => x.id === this.defaultPoolId(pools, accounts)) ?? pools[0];
      if (!pool) return undefined;
      // Naming a model picks its provider: create_thread with an Opus
      // model and no account must not land on Codex and drop the model.
      if (wanted && !poolProviders(pool, accounts).includes(wanted)) pool = pools.find((x) => poolProviders(x, accounts).includes(wanted)) ?? pool;
    }
    const providers = poolProviders(pool, accounts);
    const provider = wanted && providers.includes(wanted) ? wanted : providers[0];
    // The last login used wins a tie, or when nothing says another has
    // more room, as pickAccount has it.
    const json = readRunnerJson(this.cfg.home).defaults;
    let accountId = pickInPool(pool, accounts, { provider, prefer: json?.accountId ?? this.cfg.defaults.accountId });
    if (!accountId) {
      const next = nextLogin(pool, accounts, { accountId: '', provider }, this.clock.now());
      if (!('waitUntil' in next)) accountId = next.accountId;
    }
    accountId ??= poolAccounts(pool, accounts).find((a) => a.provider === provider)?.id ?? poolAccounts(pool, accounts)[0].id;
    return { poolId: pool.id, accountId };
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
    poolId?: string;
    model?: string;
    effort?: EffortLevel;
    permissionMode?: PermissionMode;
    title?: string;
    origin?: MessageOrigin;
    scheduleId?: string;
    // false: start in the folder as it is, even in a repo that asks for a
    // worktree per thread.
    worktree?: boolean;
  }): { thread: ThreadSummary; turnId: string } {
    if (!params.text && !params.images?.length) throw new RpcError(ErrorCode.badParams, 'text or images required');
    checkImages(params.images ?? []);
    const { st, notes } = this.makeThread(params);
    const turnId = this.sendTo(st, params.text ?? '', params.images ?? [], { origin: params.origin, scheduleId: params.scheduleId });
    // Under the first turn, so they read as part of starting it.
    for (const text of notes) this.emit(st, { type: 'system.note', text }, st.rt.turn?.turnId ?? turnId);
    if (!st.rec.titleSet && params.text?.trim()) void this.titleFromModel(st, params.text);
    return { thread: this.summary(st), turnId };
  }

  // A quick ask the phone already answered out loud (docs/protocol.md, Sync,
  // "quickAsk"), kept as a thread so Mike can carry on in it. It's made as a
  // create with no folder would be, but no turn runs: the exchange is
  // written as a finished turn, seen, and the first message sent to it
  // starts a fresh session with a handoff note saying how it began.
  quickAsk(params: { question: string; answer: string; sources?: { title: string; url: string }[]; askedAt?: number }): { thread: ThreadSummary } {
    const question = params.question.trim();
    const answer = params.answer.trim();
    if (!question || !answer) throw new RpcError(ErrorCode.badParams, 'question and answer required');
    const { st, notes } = this.makeThread({ text: question, origin: 'phone', worktree: false });
    const { rec } = st;
    const turnId = crypto.randomUUID();
    const sources = (params.sources ?? []).filter((x) => x?.url).slice(0, 10);
    const links = sources.map((x) => `- [${(x.title || x.url).replace(/[[\]]/g, '')}](${x.url})`).join('\n');
    const text = links ? `${answer}\n\n${links}` : answer;
    // In the order startTurn writes them: a user.message after turn.started
    // would read as one sent while the turn ran.
    this.emit(st, userMessage({ turnId, text: question, images: [], origin: 'phone' }), turnId);
    this.emit(st, { type: 'turn.started', turnId }, turnId);
    this.emit(st, { type: 'assistant.text', itemId: crypto.randomUUID(), text }, turnId);
    this.emit(st, { type: 'system.note', text: 'Answered by Ask from Agent Archive' }, turnId);
    for (const note of notes) this.emit(st, { type: 'system.note', text: note }, turnId);
    const askedAt = params.askedAt !== undefined && Number.isFinite(params.askedAt) ? params.askedAt : this.clock.now();
    const done = this.emit(st, { type: 'turn.completed', turnId, outcome: 'completed', durationMs: Math.max(0, this.clock.now() - askedAt), needs: 'nothing' }, turnId);
    rec.needs = { seq: done.seq, needs: 'nothing' };
    rec.preview = oneLine(answer, LIMITS.previewChars);
    rec.lastTurnCompletedSeq = done.seq;
    rec.lastSeenSeq = done.seq;
    // The answer came from a fast model, not a session of this thread's.
    rec.handoff = { fromCwd: rec.cwd, fromAccountId: rec.accountId, quickAsk: true };
    this.markDirty(st);
    void this.titleFromModel(st, question, answer);
    return { thread: this.summary(st) };
  }

  // The tour's sample threads (docs/protocol.md, threads.samples; samples.ts):
  // made up exchanges written as finished turns, like a quick ask, in the
  // folder the app gives (~/ThreadbearThreads/Welcome, where its example patch
  // is), so someone new has threads to hibernate, archive and look round.
  // Asking again makes them afresh; remove deletes them all, archived and
  // hibernating ones too.
  samples(params: { cwd: string; remove?: boolean }): { threads: ThreadSummary[] } {
    // Any there are go first, made fresh each time: ones left by a tour that
    // didn't finish could be hibernating, archived, in another folder, or
    // from a runner that didn't trust the patch yet (Tinker Desk, 30 Oct).
    for (const st of [...this.threads.values()].filter((st) => st.rec.sample)) this.delete(st.rec.id);
    if (params.remove) return { threads: [] };
    // The folder and its example patch, written here and trusted as written:
    // one changed since is someone's code, and waits like any other.
    const cwd = path.resolve(expandHome(params.cwd));
    const patchFile = path.join(cwd, '.threadbear', 'patches', 'welcome.ts');
    fs.mkdirSync(path.dirname(patchFile), { recursive: true });
    if (!fs.existsSync(patchFile)) fs.writeFileSync(patchFile, WELCOME_PATCH);
    if (fs.readFileSync(patchFile, 'utf8') === WELCOME_PATCH) this.trustAgentPatches([patchFile]);
    const made: ThreadSummary[] = [];
    // Oldest first, so the first in SAMPLE_THREADS is the newest in the list.
    for (const sample of [...SAMPLE_THREADS].reverse()) {
      const { st } = this.makeThread({ text: sample.question, cwd, title: sample.title, worktree: false });
      const { rec } = st;
      rec.sample = true;
      const turnId = crypto.randomUUID();
      this.emit(st, userMessage({ turnId, text: sample.question, images: [] }), turnId);
      this.emit(st, { type: 'turn.started', turnId }, turnId);
      this.emit(st, { type: 'assistant.text', itemId: crypto.randomUUID(), text: sample.answer }, turnId);
      const done = this.emit(st, {
        type: 'turn.completed', turnId, outcome: 'completed', durationMs: 4000, needs: sample.needs,
        ...(sample.asks ? { asks: sample.asks } : {}),
      }, turnId);
      rec.needs = { seq: done.seq, needs: sample.needs, ...(sample.asks ? { asks: sample.asks } : {}) };
      rec.preview = oneLine(sample.answer, LIMITS.previewChars);
      rec.lastTurnCompletedSeq = done.seq;
      // Unseen: Needs you, or the blue dot; the rest read.
      if (sample.needs === 'nothing' && !sample.unread) rec.lastSeenSeq = done.seq;
      this.markDirty(st);
      made.push(this.summary(st));
    }
    return { threads: made.reverse() };
  }

  // The record and state of a new thread, before anything is sent to it:
  // its folder, login, model and effort as create picks them.
  private makeThread(params: {
    text: string;
    cwd?: string;
    accountId?: string;
    poolId?: string;
    model?: string;
    effort?: EffortLevel;
    permissionMode?: PermissionMode;
    title?: string;
    origin?: MessageOrigin;
    scheduleId?: string;
    worktree?: boolean;
  }): { st: ThreadState; notes: string[] } {
    this.checkAccepting();
    // New threads belong on the new release.
    if (this.draining) throw new RpcError(ErrorCode.busy, 'This runner is handing over to a new one; start the thread there.');
    // A blank folder means the default, not the runner's own folder.
    const cwd = path.resolve(expandHome(params.cwd?.trim() ? params.cwd.trim() : this.cfg.defaults.cwd));
    // An accountId pins the thread to that login. Otherwise a pool picks
    // the login (docs/protocol.md, "Pools"), except on a dev runner whose
    // keepAccount pins new threads to its own account.
    let poolId: string | undefined;
    let accountId = params.accountId;
    if (accountId === undefined && (params.poolId !== undefined || !readRunnerJson(this.cfg.home).defaults?.keepAccount)) {
      const picked = this.pickForNew({ poolId: params.poolId, cwd, model: params.model });
      if (picked) ({ poolId, accountId } = picked);
    }
    accountId ??= this.defaultAccountId();
    const account = this.accounts.get(accountId);
    if (!account) throw new RpcError(ErrorCode.accountNotFound, `No account called ${accountId}`);
    this.checkProvider(account);
    if (!isDirectory(cwd)) throw new RpcError(ErrorCode.badParams, `Folder not found: ${cwd}`);
    const now = this.isoNow();
    const id = crypto.randomUUID();
    const rec: ThreadRecord = {
      id,
      title: params.title?.trim() ? params.title.trim().slice(0, 200) : titleFrom(params.text),
      titleSet: Boolean(params.title?.trim()),
      cwd,
      accountId,
      ...(poolId ? { poolId } : {}),
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
    // Whether the first turn should look for a worktree patch. Reading the
    // patch files is async, so it happens there; a folder with no patch
    // files at all (most of them) starts its CLI straight away as before.
    if (params.worktree !== false && this.mayWantWorktree(cwd)) rec.worktreePending = true;
    if (params.origin === 'schedule' && params.scheduleId) rec.schedule = { id: params.scheduleId, title: params.title?.trim() || rec.title };
    this.store.create(rec);
    const st: ThreadState = { rec, rt: newRuntime(this.clock.now()) };
    this.threads.set(id, st);
    if (!poolId) this.rememberAccount(accountId);
    else if (params.poolId !== undefined) this.rememberPool(poolId);
    return { st, notes: checked.notes };
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
  // pool, out of room or in a private folder it says why and nothing
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

  // Explains words Mike selected in a thread (explain.ts), on the small
  // model. A side conversation: nothing is written to the thread.
  // `message` is the whole message the selection came from, as the app
  // shows it (a row's seq can be a streamed delta's, not the final text's).
  async explain(params: { threadId: string; selection: string; message?: string; question?: string; earlier?: ExplainTurn[] }): Promise<{ answer: string; model: string }> {
    const st = this.mustGet(params.threadId);
    if (!this.models) throw new RpcError(ErrorCode.other, 'Model calls are off in this runner.');
    const gist = this.threadGist(st.rec.id, { recent: RECENT_MESSAGES, chars: RECENT_CHARS });
    const res = await this.models.generate({
      feature: 'explain',
      cwd: st.rec.cwd,
      system: EXPLAIN_SYSTEM,
      prompt: explainPrompt({ selection: params.selection, message: params.message, first: gist.first, recent: gist.recent, earlier: params.earlier ?? [], question: params.question }),
      maxTokens: 800,
    });
    if (!res.ok) throw new RpcError(ErrorCode.other, res.message || `No explanation (${res.reason}).`);
    return { answer: res.value.trim(), model: res.model };
  }

  // Hibernates a thread until when Mike said, in his own words
  // (wake-when.ts), as Opus reads them: a time, a topic for the librarian
  // to listen for, or both. The thread goes away at once, as a preset
  // does, and the time follows once the model answers; if it can't say,
  // the thread comes back and the call fails with why.
  async hibernateWhen(params: { threadId: string; said: string }): Promise<{ thread: ThreadSummary; until?: string; topic?: string; why: string }> {
    const st = this.mustGet(params.threadId);
    const said = params.said.trim();
    if (!said) throw new RpcError(ErrorCode.badParams, 'Say when it should wake.');
    if (said.length > SAID_MAX) throw new RpcError(ErrorCode.badParams, `That's more than ${SAID_MAX} characters.`);
    const models = this.models;
    if (!models) throw new RpcError(ErrorCode.other, 'Model calls are off in this runner.');
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    const gist = this.threadGist(st.rec.id, { recent: 0 });
    const input = { said, now: this.clock.now(), timeZone, title: st.rec.title, first: gist.first, brief: st.rec.brief?.text };
    this.update({ threadId: st.rec.id, snoozedUntil: NO_WAKE_TIME });
    st.rec.wakeWhen = { said, pending: true };
    this.markDirty(st);
    const ask = (withThread: boolean) =>
      models.generate({
        feature: 'wake-when',
        ...(withThread ? { cwd: st.rec.cwd } : {}),
        system: WAKE_SYSTEM,
        prompt: wakePrompt(withThread ? input : { said, now: input.now, timeZone, title: '(private)' }),
        maxTokens: 300,
        strong: true,
      });
    let res = await ask(true);
    // A private folder's thread isn't sent: his words alone are usually enough.
    if (!res.ok && res.reason === 'private') res = await ask(false);
    // Woken, hibernated another way or deleted meanwhile: that wins.
    if (st.rt.deleted || st.rec.wakeWhen?.pending !== true || st.rec.wakeWhen.said !== said) {
      throw new RpcError(ErrorCode.other, 'The thread was woken or put away again while this was worked out.');
    }
    const answer = res.ok ? readWakeAnswer(res.value, this.clock.now()) : { error: res.message || `No answer from the model (${res.reason}).` };
    if ('error' in answer) {
      delete st.rec.snoozedUntil;
      delete st.rec.wakeWhen;
      st.rec.updatedAt = this.isoNow();
      this.markDirty(st);
      this.armSnoozeTimer();
      this.kickQueue(st);
      throw new RpcError(ErrorCode.other, `Couldn't work out when to wake it: ${answer.error}`);
    }
    st.rec.snoozedUntil = answer.until ?? NO_WAKE_TIME;
    st.rec.wakeWhen = { said, ...(answer.topic ? { topic: answer.topic } : {}) };
    this.emit(st, { type: 'system.note', text: hibernateNote(answer, said, timeZone) });
    this.armSnoozeTimer();
    this.log.info('hibernated in words', { threadId: st.rec.id, until: answer.until, topic: answer.topic });
    return { thread: this.summary(st), ...answer };
  }

  // Threads hibernating until Mike next talks about something, for the
  // librarian to listen for.
  waitingTopics(): { threadId: string; title: string; topic: string }[] {
    const now = this.clock.now();
    const out: { threadId: string; title: string; topic: string }[] = [];
    for (const { rec, rt } of this.threads.values()) {
      const topic = rec.wakeWhen?.topic;
      if (!topic || rt.deleted || rec.archivedAt || !rec.snoozedUntil || Date.parse(rec.snoozedUntil) <= now) continue;
      out.push({ threadId: rec.id, title: rec.title, topic });
    }
    return out;
  }

  // The librarian heard Mike talk about a hibernating thread's topic in
  // another thread: it wakes, unread, saying where.
  wakeForTopic(threadId: string, inThreadId: string): boolean {
    const st = this.threads.get(threadId);
    const topic = st?.rec.wakeWhen?.topic;
    if (!st || !topic || st.rt.deleted || st.rec.archivedAt || threadId === inThreadId || this.bucket(st.rec) !== 'snoozed') return false;
    const where = this.threads.get(inThreadId)?.rec.title;
    this.wake(st, { why: `you talked about ${topic}${where ? ` in "${where}"` : ' in another thread'}` });
    this.armSnoozeTimer();
    this.log.info('woke for a topic', { threadId, inThreadId, topic });
    return true;
  }

  // The librarian heard Mike point out a problem with his tools in a
  // thread and nobody started fixing it: a new thread, in the tool's
  // folder, does. Its first message is the runner's, not his, and the
  // thread he said it in gets a note, so he knows it's in hand.
  startFix(p: { fromThreadId: string; cwd: string; title: string; text: string }): string | undefined {
    const id = this.create({ text: p.text, cwd: p.cwd, title: p.title, origin: 'runner' }).thread.id;
    if (this.threads.has(p.fromThreadId)) this.note(p.fromThreadId, `The librarian started a thread to fix that: ${p.title}.`);
    return id;
  }

  // The first user.message's text and the first assistant.text after it,
  // read a page at a time from the start: both are nearly always within
  // the first few events, and a long thread's log is large.
  private opening(id: string, rec?: Pick<ThreadRecord, 'rewinds'>): { text?: string; reply?: string } {
    const log = this.store.log(id);
    let text: string | undefined;
    for (let from = 1; from <= Math.min(log.lastSeq, 500); from += 50) {
      for (const e of log.read(from, from + 49)) {
        if (rec && cutOut(rec, e.seq)) continue;
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
    // Its turn was made up; a real agent picking it up would only be lost.
    if (st.rec.sample) throw new RpcError(ErrorCode.badParams, "This is one of the tour's sample threads, so nothing can be sent to it. Start a new thread to try it for real.");
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
      delete rec.wakeWhen;
      delete rec.archivedAt;
      rt.releaseWhenIdle = false;
    }
    // Answering it from his phone without opening it counts as having seen it woke.
    if (fromMike(text, opts)) delete rec.woke;
    this.supersedeReviews(st, text, opts);
    // He has seen the reply a waiting panel went with.
    if (rec.panelRequest && fromMike(text, opts)) {
      delete rec.panelRequest;
      this.endPanelWait(st, false);
      this.markDirty(st);
    }
    const turnId = crypto.randomUUID();
    const msg: QueuedSend = { turnId, text, images: refs };
    if (opts.origin) msg.origin = opts.origin;
    if (opts.scheduleId) msg.scheduleId = opts.scheduleId;
    if (opts.answers?.length) msg.answers = opts.answers;
    if (opts.editOf) msg.editOf = opts.editOf;
    rec.lastActivityAt = this.isoNow();
    if (rt.turn && !opts.queue && fromMike(text, opts) && this.switchWaiting(st)) {
      // He picked another login (another provider, usually) during this
      // turn, then wrote: the message is for the new one, now, as in T3
      // Code. This turn stops and the message starts the next one there,
      // with the handoff. Steering it into the old CLI would answer it on
      // the model he just moved away from.
      rec.queue.push(msg);
      this.emit(st, { type: 'system.note', text: `Stopped here so ${this.modelLabel(rec)} can take over.` }, rt.turn.turnId);
      this.markDirty(st);
      this.interrupt(rec.id);
      return turnId;
    }
    if (rt.turn && rt.approvals.size && fromMike(text, opts)) {
      // He wrote instead of using the card. The CLI is parked on the card's
      // answer and won't read anything else until it has one, so a message
      // steered or queued now would sit unread behind it for good. Declining
      // the card lets the CLI move on and take the message next.
      for (const [approvalId, pending] of [...rt.approvals]) {
        if (!pending.main) continue;
        this.resolveApproval(st, approvalId, 'deny', WROTE_INSTEAD);
        if (pending.kind === 'question') pending.resolve({ answers: null, message: WROTE_INSTEAD });
        else pending.resolve({ decision: 'deny', message: WROTE_INSTEAD });
      }
    }
    if (rt.turn && !opts.queue && this.canSteer(st)) {
      // Sent while a turn runs: it goes into that turn now, as typing into
      // the CLI would. The CLI takes it at its next step, or straight after
      // its reply if that was already finishing; either way the thread's
      // turn goes on until it's answered, so the caller gets that turn's id.
      this.steer(st, msg);
      return rt.turn.turnId;
    }
    if (rt.turn || rec.queue.length || this.draining || rt.editing) {
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
    if (!turn || !rt.session || rt.closing || this.stopping || rt.editing) return false;
    if (rec.queue.length || rec.handoff || rec.moved || rt.releaseWhenIdle || turn.interruptRequested) return false;
    return !turn.auto || Boolean(turn.cliStarted);
  }

  // A move to another login is waiting for the next turn while this one
  // runs on the old login's CLI.
  private switchWaiting(st: ThreadState): boolean {
    const { rec, rt } = st;
    const turn = rt.turn;
    if (!turn || !rt.session || turn.interruptRequested || (turn.auto && !turn.cliStarted) || rt.editing) return false;
    return Boolean(rec.handoff && rec.handoff.fromAccountId !== rec.accountId);
  }

  // "Opus 5.5", or the login's name when there's no model to name.
  private modelLabel(rec: ThreadRecord): string {
    const account = this.accounts.get(rec.accountId);
    if (!account) return rec.accountId;
    const model = rec.model ?? account.defaultModel;
    return model ? modelTitle(account, model) : account.title;
  }

  // Shows the message in the running turn and hands it to the CLI. If the
  // event can't be written the message isn't sent, and the caller gets the
  // error (the app puts the draft back).
  private steer(st: ThreadState, msg: QueuedSend): void {
    const { rt } = st;
    const turn = rt.turn!;
    this.emit(st, userMessage(msg), turn.turnId);
    turn.messages.push(msg.turnId);
    // He wrote again, so the turn owes him another reply.
    turn.ended = false;
    turn.owedReply = undefined;
    this.markDirty(st);
    rt.session!.send({ id: msg.turnId, text: msg.text, images: msg.images });
  }

  // Writes the turn's first events before changing any state, so if the
  // disk refuses (full, permissions) the thread is left as it was rather
  // than stuck on a turn that never started.
  private startTurn(st: ThreadState, msg: QueuedSend): void {
    const { rec, rt } = st;
    // A review can be replayed after a failed turn.started append. Its
    // stable message ID keeps the original user row rather than duplicating it.
    const hasReviewMessage = msg.reviewId && this.store.log(rec.id).read(1, rec.lastSeq).some(e => e.type === 'user.message' && e.reviewId === msg.reviewId && e.turnId === msg.turnId);
    if (!hasReviewMessage) this.emit(st, userMessage(msg), msg.turnId);
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
    // Any turn ends a wait for room: a message from Mike goes through the
    // same check as the runner's own carry-on would.
    if (rec.waitingForRoom) {
      delete rec.waitingForRoom;
      this.armRoomTimer();
    }
    this.beforeTurn(st);
    rec.status = rt.session && !rt.closing ? 'running' : 'starting';
    this.markDirty(st);
    // A message to the thread (not a turn the CLI opened by itself), so the
    // librarian can file a new thread before its first turn is over.
    if (!this.stopping) this.tellActivity({ kind: 'turn.start', threadId: rec.id });
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
    if (!rt.session && rec.worktreePending) {
      await this.prepareWorktree(st, msg.turnId);
      if (rt.turn?.turnId !== msg.turnId) return; // interrupted during setup
    }
    if (!rt.session) {
      const left = this.leaveRemovedWorktree(st, msg.turnId);
      if (left) text = `${left}\n\n${text}`;
    }
    if (!rt.session) {
      const account = this.accounts.get(rec.accountId);
      if (!account) throw new Error(`Account ${rec.accountId} isn't available on this Mac.`);
      if (!isDirectory(rec.cwd)) throw new Error(`Folder not found: ${rec.cwd}`);
      if (rec.handoff && this.carryTranscript(st, account)) {
        // A new folder, or another Claude login: the whole conversation
        // came along.
        const from = rec.handoff;
        const text =
          from.fromAccountId === rec.accountId
            ? `Moved to ${rec.cwd}. The session carries on there.`
            : from.fromCwd === rec.cwd
              ? `Resumed the session on ${account.title}, with the whole conversation.`
              : `Moved to ${rec.cwd} on ${account.title}. The session carries on there, with the whole conversation.`;
        this.emit(st, { type: 'system.note', text }, msg.turnId);
        rt.carried = rec.handoff;
        delete rec.handoff;
      } else if (rec.handoff) {
        text = this.handoffNote(st, account) + text;
        // A quick ask's thread never had a session, so nothing to say.
        if (!rec.handoff.quickAsk) this.emit(st, { type: 'system.note', text: `Started a new session in ${rec.cwd} on ${account.title}.` }, msg.turnId);
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
    if (msg.reviewId && !rec.reviewDeliveries?.includes(msg.reviewId)) {
      (rec.reviewDeliveries ??= []).push(msg.reviewId);
      // A persisted transcript row is not proof of dispatch: both initial
      // events are written before session.send. Mark receipt only afterwards.
      try { this.store.save(rec); } catch (e) {
        this.log.error('could not save review delivery', {threadId: rec.id, reviewId: msg.reviewId, error: String(e)});
      }
      this.markDirty(st);
    }
  }

  // Keeps the number of live CLIs at cfg.maxLive by releasing the one idle
  // the longest. CLIs with a turn, an approval, queued messages or
  // background work are never picked; if every other one is busy the cap
  // is passed rather than stopping work.
  // A folder move, or a move from one Claude login to another (a pool
  // move or a pick by hand), copies the session's transcript to the new
  // folder and config dir so it resumes with everything, rather than a
  // short note. Anything else (another provider, a rebuilt record, a
  // transcript that can't be found) gets the handoff note, as does a
  // resume that then fails (onExited).
  private carryTranscript(st: ThreadState, account: Account): boolean {
    const { rec } = st;
    const from = rec.handoff;
    // Claude only: it copies Claude's own transcript files. Codex moves
    // folders in the same session (movesFolders) and never gets here.
    if (rec.provider !== 'claude') return false;
    if (!from || from.rebuilt) return false;
    const sameLogin = from.fromAccountId === rec.accountId;
    if (sameLogin && from.fromCwd === rec.cwd) return false;
    const fromAccount = sameLogin ? account : this.accounts.get(from.fromAccountId);
    if (fromAccount?.provider !== 'claude') return false;
    if (!rec.sessionUsed || !rec.nativeSessionId) return false;
    const ok = this.copyTranscript(fromAccount.configDir, account.configDir, from.fromCwd, rec.cwd, rec.nativeSessionId);
    if (!ok) this.log.info('could not carry the transcript across; using a handoff note', { threadId: rec.id, from: from.fromAccountId, to: rec.accountId });
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
        ...(resume && rec.resumeAt ? { resumeAt: rec.resumeAt } : {}),
        mediaDir: this.store.mediaDir(rec.id),
        blobsDir: this.store.blobsDir(rec.id),
        tmpDir: path.join(paths.run(this.cfg.home), 'tmp'),
        allowRules: rec.allowRules ?? [],
        env: threadEnv(rec.id, this.cfg.home),
        ...this.briefFor(rec, resume),
      },
      sink,
    );
    this.log.info('session started', { threadId: rec.id, resume, accountId: account.id, ...(rec.resumeAt ? { resumeAt: rec.resumeAt } : {}) });
    this.markDirty(st);
  }

  private onOutput(st: ThreadState, o: AdapterOutput): void {
    const { rec, rt } = st;
    switch (o.kind) {
      case 'event': {
        let ev = o.event;
        // Text after an accepted end_turn (see Turn.ended), dropped before
        // it can become the preview or a second message. Unless the reply
        // was a narration block's summary: then this is the reply, in the
        // summary's place. Thinking after it is dropped too: Opus mused
        // "I'd already wrapped up" under its summary (29 Oct 2026).
        if (ev.type === 'assistant.text' && rt.turn?.ended && !ev.itemId.includes('/') && rt.turn.narrationItem && !rt.turn.summarized && ev.text.trim()) {
          rt.inProgress.delete(ev.itemId);
          this.log.info('replaced a summary with the text after end_turn', { threadId: rec.id, chars: ev.text.length });
          ev = { type: 'assistant.text', itemId: rt.turn.narrationItem, text: ev.text };
          rt.turn.narrationItem = undefined;
        } else if (ev.type === 'assistant.text' && rt.turn?.ended && rt.turn.owedReply !== undefined && !ev.itemId.includes('/') && ev.text.trim().length > rt.turn.owedReply) {
          this.log.info('kept the message after end_turn its bullets stood for', { threadId: rec.id, chars: ev.text.length });
          rt.turn.owedReply = undefined;
        } else if ((ev.type === 'assistant.text' || ev.type === 'reasoning') && rt.turn?.ended && !ev.itemId.includes('/')) {
          rt.inProgress.delete(ev.itemId);
          this.log.info('dropped text after end_turn', { threadId: rec.id, chars: ev.text.length });
          break;
        }
        if (ev.type === 'assistant.text' || ev.type === 'reasoning') {
          this.flushDeltas(st);
          rt.inProgress.delete(ev.itemId);
          rt.pendingDeltas.delete(ev.itemId);
        }
        // Once the turn has its summary, that is the reply: Codex's final
        // answer after it folds away in the app and isn't the preview.
        if (ev.type === 'assistant.text' && !rt.turn?.summarized) rec.preview = oneLine(ev.text, LIMITS.previewChars);
        if (rt.turn) {
          // A Codex child's items carry its prefix (<child>/<id>); Claude's
          // sub-agents never reach the thread's events.
          const own = !('itemId' in ev && ev.itemId?.includes('/'));
          if (ev.type === 'assistant.text' && own && !rt.turn.summarized) {
            rt.turn.lastText = ev.text;
            rt.turn.narrationItem = ev.narration ? ev.itemId : undefined;
          }
          if (ev.type === 'tool.call' && own && ev.name === `mcp__${SERVER_NAME}__${END_TURN_TOOL}`) {
            rt.turn.endTurn = ev.input;
            rt.turn.endTurnCall = ev.itemId;
          }
          if (ev.type === 'tool.result' && ev.itemId === rt.turn.endTurnCall && endTurnAccepted(ev)) {
            rt.turn.ended = true;
            const bullets = summaryFromTool(rt.turn.endTurn);
            rt.turn.owedReply = !bullets ? undefined : endTurnAsksForMessage(ev) ? 0 : endTurnOwesReply(ev) ? summaryMarkdown(bullets).length : undefined;
          }
          if (ev.type === 'edit.diff') rt.turn.edited.add(ev.path);
          else if (ev.type === 'tool.call' && (ev.kind === 'edit' || ev.kind === 'write')) {
            const file = ev.input.file_path ?? ev.input.path ?? ev.input.notebook_path;
            if (typeof file === 'string') {
              rt.turn.edited.add(file);
              const full = path.resolve(rec.cwd, file);
              if (isPatchFile(full)) (rt.turn.patchEdits ??= new Map()).set(ev.itemId, full);
            }
          } else if (ev.type === 'tool.result' && rt.turn.patchEdits?.has(ev.itemId)) {
            const file = rt.turn.patchEdits.get(ev.itemId)!;
            rt.turn.patchEdits.delete(ev.itemId);
            if (ev.ok) this.trustAgentPatches([file]);
          } else if (ev.type === 'tool.call' && own && ev.kind === 'command') {
            const cmd = Array.isArray(ev.input.command) ? ev.input.command.join(' ') : ev.input.command;
            if (typeof cmd === 'string') {
              rt.turn.workedIn ??= new Set();
              for (const dir of commandFolders(cmd, rec.cwd, this.panelsRoot ?? os.homedir())) rt.turn.workedIn.add(dir);
            }
          }
        }
        this.emit(st, ev, rt.turn?.turnId);
        // end_turn's summary, written as the turn's reply straight after
        // the call it came in (docs/protocol.md, "The summary").
        if (ev.type === 'tool.result' && rt.turn && ev.itemId === rt.turn.endTurnCall && endTurnTaken(ev)) {
          const bullets = summaryFromTool(rt.turn.endTurn);
          if (bullets) {
            const text = summaryMarkdown(bullets);
            rt.turn.summarized = true;
            rt.turn.lastText = text;
            rec.preview = oneLine(text, LIMITS.previewChars);
            this.emit(st, { type: 'assistant.text', itemId: `${ev.itemId}.summary`, text, summary: true, ...(this.cfg.bulletReplies ? {} : { givesWay: true as const }) }, rt.turn.turnId);
          }
        }
        break;
      }
      case 'delta':
        // Streamed text after an accepted end_turn, dropped like its frame
        // above, so it doesn't flash up and vanish.
        // That includes the message an owed reply keeps (owedReply): it
        // lands whole, as a sign-off line it drops would leave a row behind.
        if (rt.turn?.ended && (o.delta.type === 'assistant.text.delta' || o.delta.type === 'reasoning.delta') && !o.delta.itemId.includes('/')) break;
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
    // The CLI resumed at the cut an edit asked for and has written a turn
    // after it, which is the conversation's end from now on. Kept until
    // then, so a CLI that died first cuts again on the next start.
    if (rec.resumeAt && rt.resumed) delete rec.resumeAt;
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
      if (said.next) body.next = said.next;
      body.needsFrom = said.from;
    }
    // Here rather than only in end_turn's handler: a refused end_turn
    // leaves the asks in the reply's text, and that thread never heard
    // Mike had restarted (29 Oct 2026).
    if (said?.needs === 'you' && asksForAppRestart(said.asks)) this.appRestartAsked?.(rec.id);
    const ev = this.emit(st, body, turn.turnId);
    // Any completed turn replaces the last one's card; one that said
    // neither leaves no card, and counts as before.
    if (outcome === 'completed') {
      if (said) rec.needs = { seq: ev.seq, needs: said.needs, ...(said.asks ? { asks: said.asks } : {}) };
      else delete rec.needs;
    }
    // A pool thread whose login ran dry moves and carries on (afterTurn).
    const limitHit = outcome === 'failed' && r.errorKind === 'usageLimit' ? turn.turnId : undefined;
    // The agent asked for its own thread to be archived (end_turn's
    // archive, which Mike asked it for). It can't archive itself mid-turn,
    // as that stops the CLI, so it happens here, once the turn is over, and
    // not if a message is already waiting for the next one.
    const archive = outcome === 'completed' && !turn.auto && said?.needs === 'nothing' && archiveFromTool(turn.endTurn) && !rec.queue.length;
    this.endTurn(st, ev.seq, outcome === 'failed' ? 'error' : 'idle', outcome, limitHit);
    if (archive && !rt.turn && !rec.archivedAt && !this.stopping) {
      this.emit(st, { type: 'system.note', text: 'Archived, as the agent was asked to once it had finished.' });
      this.update({ threadId: rec.id, archived: true });
    }
  }

  private endTurn(st: ThreadState, completedSeq: number, status: ThreadStatus, outcome?: TurnOutcome, limitHit?: string): void {
    const { rec, rt } = st;
    const finished = rt.turn;
    rt.turn?.interruptTimer?.cancel();
    rt.turn = undefined;
    // Patch files the turn wrote some other way than Edit and Write calls
    // (a Codex patch's edit.diff) are trusted as it left them.
    if (finished) this.trustAgentPatches([...finished.edited].map((p) => path.resolve(rec.cwd, p)), false);
    // The turn may have added a patch file or a convex/ folder.
    this.forgetFolders();
    // The folder's turn.end hooks, after a turn the agent finished itself
    // (not one the runner opened for a background task's approval).
    if (outcome === 'completed' && finished && !finished.auto && !this.stopping) void this.runHooks(st, finished);
    // The turn may have changed what live state reads (comments resolved,
    // a handback): read it now rather than at the next poll.
    if (rt.patches?.live && !this.stopping) void this.refreshPatches(st);
    if (outcome && finished && !finished.auto && !this.stopping) {
      this.tellActivity({ kind: 'turn.end', threadId: rec.id, outcome, edited: [...finished.edited].map((p) => path.resolve(rec.cwd, p)), workedIn: [...(finished.workedIn ?? [])] });
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
    const waiters = rt.turnEndWaiters ?? [];
    rt.turnEndWaiters = undefined;
    for (const w of waiters) w();
    this.afterTurn(st, limitHit);
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

  private afterTurn(st: ThreadState, limitHit?: string): void {
    if (this.stopping) return;
    if (limitHit) {
      try {
        this.onUsageLimit(st, limitHit);
      } catch (e) {
        this.log.error('could not move a thread off a login at its limit', { threadId: st.rec.id, error: String(e) });
      }
    }
    // A snoozed or archived thread keeps its queue until it comes back.
    if (this.bucket(st.rec) === 'inbox' && this.kickQueue(st)) return;
    this.scheduleIdle(st);
  }

  // ------------------------------------------------------- pools: moving

  // Before a pool thread's turn starts: if its login isn't OK (blocked or
  // under the minimum room) or isn't in its pool any more, it moves first
  // (docs/protocol.md, "Pools"). With nowhere better, the turn starts
  // where it is. A pinned thread (no poolId) never moves.
  private beforeTurn(st: ThreadState): void {
    const { rec } = st;
    const pool = this.poolById(rec.poolId);
    if (!pool) return;
    const accounts = this.usableAccounts();
    const current = accounts.find((a) => a.id === rec.accountId);
    const inPool = pool.accountIds.includes(rec.accountId);
    if (current && inPool && loginOk(current)) return;
    const now = this.clock.now();
    const next = nextLogin(pool, accounts, rec, now);
    if ('waitUntil' in next) return;
    const why = !current ? `${rec.accountId} isn't on this Mac` : inPool ? `${current.title} ${limitWhy(current, now)}` : `${current.title} isn't in ${pool.title}`;
    this.moveLogin(st, accounts.find((a) => a.id === next.accountId)!, why);
  }

  // A pool thread's turn ended failed with errorKind usageLimit: mark the
  // login blocked, move to the next login with room and carry on by
  // itself, once. A carry-on that runs dry too waits instead of moving
  // again, as does a pool with nothing left.
  private onUsageLimit(st: ThreadState, turnId: string): void {
    const { rec } = st;
    const pool = this.poolById(rec.poolId);
    if (!pool) return;
    const now = this.clock.now();
    const was = this.usableAccounts().find((a) => a.id === rec.accountId);
    if (was) this.markRanDry(was);
    if (this.bucket(rec) !== 'inbox') return;
    // A message sent meanwhile goes next; the before-a-turn check moves it.
    if (rec.queue.length) return;
    const accounts = this.usableAccounts();
    const title = was?.title ?? rec.accountId;
    if (rec.autoCarryOn === turnId) {
      this.startWait(st, roomWait(pool, accounts, now), `${title} hit its usage limit too, so this thread waits rather than move again.`);
      return;
    }
    const next = nextLogin(pool, accounts, rec, now);
    if ('waitUntil' in next) {
      this.startWait(st, next, `Every login in ${pool.title} is out of room.`);
      return;
    }
    this.moveLogin(st, accounts.find((a) => a.id === next.accountId)!, `${title} ${was ? limitWhy(was, now, true) : 'hit its usage limit'}`);
    this.carryOn(st, CARRY_ON_MOVED);
  }

  // A login a turn found at its limit counts as blocked until its window
  // resets (30 minutes when none says), here and in the UsageStore, which
  // tells clients. The reading may already say so.
  private markRanDry(account: Account): void {
    const now = this.clock.now();
    const until = blockedUntil(account, now);
    this.ranDry.set(account.id, until);
    if (account.usage?.blocked) return;
    try {
      this.usage?.record(account.id, { windows: [], blocked: true, blockedUntil: until });
    } catch (e) {
      this.log.warn('could not record a usage limit', { accountId: account.id, error: String(e) });
    }
  }

  // Moves a pool thread onto another login from its next turn: a new
  // session on it, carrying the transcript across between Claude logins
  // (carryTranscript), else with a handoff note. Another provider takes
  // its own default model and effort, like any provider change. The move
  // is a note in the transcript.
  private moveLogin(st: ThreadState, to: Account, why: string): void {
    const { rec, rt } = st;
    if (rec.sessionUsed || rt.session) rec.handoff ??= { fromCwd: rec.moved?.fromCwd ?? rec.cwd, fromAccountId: rec.accountId };
    delete rec.moved;
    rec.accountId = to.id;
    let note = `Moved to ${to.title}: ${why}.`;
    if (to.provider !== rec.provider) {
      rec.provider = to.provider;
      delete rec.allowRules;
      delete rec.cliVersion;
      const checked = this.checkSettings(to, this.defaultModelFor(to.provider), this.defaultEffortFor(to.provider));
      if (checked.model) rec.model = checked.model;
      else delete rec.model;
      if (checked.effort) rec.effort = checked.effort;
      else delete rec.effort;
      const model = rec.model ? modelTitle(to, rec.model) : to.defaultModel ? modelTitle(to, to.defaultModel) : "the account's default model";
      note += ` It's on ${providerName(to.provider)} now, with ${model}${rec.sessionUsed ? ' and a summary of the thread so far' : ''}.`;
    }
    if (rt.session) {
      rt.releaseWhenIdle = true;
      if (!rt.turn) this.releaseSession(st);
    }
    rec.updatedAt = this.isoNow();
    this.emit(st, { type: 'system.note', text: note }, rt.turn?.turnId);
    this.markDirty(st);
  }

  // Nothing in the pool has room: the thread waits, with a note, and the
  // room timer carries it on at `until`.
  private startWait(st: ThreadState, w: { waitUntil: string; accountId?: string }, lead: string): void {
    const { rec } = st;
    const now = this.clock.now();
    rec.waitingForRoom = { until: w.waitUntil, ...(w.accountId ? { accountId: w.accountId } : {}) };
    const who = w.accountId ? (this.accounts.get(w.accountId)?.title ?? w.accountId) : undefined;
    // The time it's back, not the minute after it the wait adds.
    const at = resetTime(new Date(Date.parse(w.waitUntil) - (who ? WAIT_SLACK_MS : 0)).toISOString(), now);
    this.emit(st, { type: 'system.note', text: `${lead} Carrying on at ${at}${who ? ` when ${who} is back` : ''}.` });
    this.markDirty(st);
    this.armRoomTimer();
  }

  // A wait's time has come: look again. A login with room (the thread's
  // own, if it's back) carries on by itself; with none, wait again.
  private endWait(st: ThreadState): void {
    const { rec, rt } = st;
    delete rec.waitingForRoom;
    this.markDirty(st);
    if (rt.deleted || rt.turn || rec.queue.length || this.bucket(rec) !== 'inbox') return;
    const pool = this.poolById(rec.poolId);
    if (!pool) return;
    const now = this.clock.now();
    const accounts = this.usableAccounts();
    const current = accounts.find((a) => a.id === rec.accountId);
    let moved = false;
    if (!current || !pool.accountIds.includes(current.id) || !loginOk(current)) {
      const next = nextLogin(pool, accounts, rec, now);
      if ('waitUntil' in next) {
        this.startWait(st, next, `Still no room in ${pool.title}.`);
        return;
      }
      const why = current ? `${current.title} ${pool.accountIds.includes(current.id) ? limitWhy(current, now) : `isn't in ${pool.title}`}` : `${rec.accountId} isn't on this Mac`;
      this.moveLogin(st, accounts.find((a) => a.id === next.accountId)!, why);
      moved = true;
    }
    this.carryOn(st, moved ? CARRY_ON_MOVED : CARRY_ON_BACK);
  }

  // The runner's own message after a move or a wait. Its turn id is kept,
  // so if it runs dry too the thread waits rather than move again. While
  // a restart refuses new turns it waits a minute instead, which the next
  // runner picks up from thread.json.
  private carryOn(st: ThreadState, text: string): void {
    const { rec } = st;
    if (this.refusing || this.draining) {
      rec.waitingForRoom = { until: new Date(this.clock.now() + WAIT_SLACK_MS).toISOString() };
      this.markDirty(st);
      this.armRoomTimer();
      return;
    }
    try {
      rec.autoCarryOn = this.sendTo(st, text, [], { origin: 'runner', queue: true });
      this.markDirty(st);
    } catch (e) {
      this.log.error('could not carry on after a move', { threadId: rec.id, error: String(e) });
    }
  }

  // One timer for every thread waiting for room, at the earliest `until`
  // (looked at again at least hourly, like snoozes).
  private armRoomTimer(): void {
    if (this.armingRoom) return;
    this.armingRoom = true;
    try {
      this.roomTimer?.cancel();
      this.roomTimer = undefined;
      // A draining runner's threads are the new runner's to carry on.
      if (this.stopping || this.draining) return;
      const now = this.clock.now();
      for (const st of [...this.threads.values()]) {
        const w = st.rec.waitingForRoom;
        if (!w) continue;
        const t = Date.parse(w.until);
        if (!(t > now)) this.endWait(st);
      }
      let next = Infinity;
      for (const st of this.threads.values()) {
        const t = st.rec.waitingForRoom ? Date.parse(st.rec.waitingForRoom.until) : NaN;
        if (t > now) next = Math.min(next, t);
      }
      if (next === Infinity) return;
      this.roomTimer = this.clock.setTimeout(() => this.armRoomTimer(), Math.min(next - now, 3_600_000));
    } finally {
      this.armingRoom = false;
    }
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
    // Who the title is from. Mike's (the default: the app, tb) sticks: an
    // agent can't rename it after, unless it says Mike asked it to and
    // passes 'mike' itself.
    titleBy?: 'mike' | 'agent';
    cwd?: string;
    accountId?: string;
    // null pins the thread to its current login; a pool id puts it in that
    // pool (and onto one of its logins if its current one isn't in it).
    // accountId pins it to that login, poolId or not.
    poolId?: string | null;
    model?: string | null;
    effort?: EffortLevel | null;
    permissionMode?: PermissionMode;
    snoozedUntil?: string | null; // an ISO time, or 'restart' for until the runner next starts
    archived?: boolean;
  }): { thread: ThreadSummary } {
    const st = this.mustGet(params.threadId);
    const { rec, rt } = st;
    // Checked before anything changes, so a refused rename changes nothing else either.
    if (params.title !== undefined && params.titleBy === 'agent' && rec.titleByMike && params.title.trim() !== rec.title) {
      throw new RpcError(ErrorCode.badParams, `The user named this thread "${rec.title}" themselves, so it keeps that title. Only rename it if they ask you to.`);
    }
    let release = false;
    let stop = false;
    const pool = typeof params.poolId === 'string' && params.accountId === undefined ? this.poolById(params.poolId) : undefined;
    if (typeof params.poolId === 'string' && params.accountId === undefined && !pool) {
      throw new RpcError(ErrorCode.badParams, `No pool called ${params.poolId}. Pools: ${this.pools().map((p) => p.id).join(', ') || 'none'}`);
    }
    // The login to move to: the one named (which pins), or one of the new
    // pool's when the current one isn't in it.
    let toAccountId = params.accountId;
    if (pool && !pool.accountIds.includes(rec.accountId)) {
      const accounts = this.usableAccounts();
      let id = pickInPool(pool, accounts, { provider: rec.provider });
      if (!id) {
        const next = nextLogin(pool, accounts, rec, this.clock.now());
        if (!('waitUntil' in next)) id = next.accountId;
      }
      toAccountId = id ?? poolAccounts(pool, accounts)[0]?.id;
    }
    if (params.title !== undefined) {
      rec.title = params.title.trim().slice(0, 200) || rec.title;
      rec.titleSet = true;
      if (params.titleBy !== 'agent') rec.titleByMike = true;
    }
    if (params.cwd !== undefined && !params.cwd.trim()) throw new RpcError(ErrorCode.badParams, 'cwd must not be blank');
    const newCwd = params.cwd !== undefined ? path.resolve(expandHome(params.cwd.trim())) : undefined;
    if (newCwd !== undefined && !isDirectory(newCwd)) throw new RpcError(ErrorCode.badParams, `Folder not found: ${newCwd}`);
    const newAccount = toAccountId !== undefined ? this.accounts.get(toAccountId) : undefined;
    if (toAccountId !== undefined && !newAccount) {
      throw new RpcError(ErrorCode.accountNotFound, `No account called ${toAccountId}`);
    }
    if (newAccount && toAccountId !== rec.accountId) this.checkProvider(newAccount);
    // Pinned (an account named, or poolId null), or into a pool.
    if (params.accountId !== undefined || params.poolId === null) {
      delete rec.poolId;
      delete rec.waitingForRoom;
    } else if (pool) rec.poolId = pool.id;
    const cwdChanged = newCwd !== undefined && newCwd !== rec.cwd;
    const fromCwd = rec.cwd;
    const accountChanged = toAccountId !== undefined && toAccountId !== rec.accountId;
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
      if (toAccountId !== undefined) {
        rec.accountId = toAccountId;
        if (params.accountId !== undefined) this.rememberAccount(toAccountId);
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
      // Kept through a change of wake time, so the note on waking counts
      // from when it first went away.
      if (params.snoozedUntil !== null && this.bucket(rec) !== 'snoozed') rec.snoozedAt = this.isoNow();
      delete rec.woke;
      delete rec.snoozedUntilRestart;
      delete rec.wakeWhen;
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
    if (accountChanged && rt.turn && rt.session && !stop) {
      // The turn carries on where it started; say so, or the picker reads
      // as if the new model were already doing the work.
      this.emit(st, { type: 'system.note', text: `${this.modelLabel(rec)} takes over from your next message, which stops this turn.` }, rt.turn.turnId);
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
    // Its worktree goes once the CLI has let go of the folder.
    if (rec.worktree && !rec.worktree.removedAt) {
      void Promise.resolve(ended ?? rt.closing)
        .catch(() => undefined)
        .then(() => this.cleanUpWorktree(st, true));
    }
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
    delete rec.woke;
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
      this.addApproval(st, { approvalId, kind: 'tool', main: Boolean(req.toolUseId), resolve }, body, req.signal);
    });
  }

  private requestQuestion(st: ThreadState, gen: number, req: QuestionRequest): Promise<QuestionAnswer> {
    if (!this.turnForRequest(st, gen)) return Promise.resolve({ answers: null });
    const approvalId = crypto.randomUUID();
    const body: EventBody = { type: 'question.requested', approvalId, questions: req.questions };
    if (req.toolUseId) body.itemId = req.toolUseId;
    return new Promise((resolve) => {
      this.addApproval(st, { approvalId, kind: 'question', main: Boolean(req.toolUseId), questions: req.questions, resolve }, body, req.signal);
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
    if (rec.archivedAt) {
      this.archiveNative(st);
      void this.cleanUpWorktree(st);
    }
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
      if (t <= now) this.wake(st, 'time');
      else next = Math.min(next, t);
    }
    if (next === Infinity) return;
    // Re-check at least hourly so long snoozes survive clock changes.
    this.snoozeTimer = this.clock.setTimeout(() => this.armSnoozeTimer(), Math.min(next - now, 3_600_000));
  }

  // A thread coming back by itself (its time, a restart, a topic) says so
  // in its conversation, with how long it was away, and its row says
  // "Woke up" until Mike looks (`woke`): otherwise it just turns up in the
  // inbox with nothing to say why (30 Oct).
  private wake(st: ThreadState, cause: 'time' | 'restart' | { why: string }): void {
    const { rec } = st;
    const now = this.clock.now();
    const since = rec.snoozedAt && Date.parse(rec.snoozedAt) <= now ? rec.snoozedAt : undefined;
    // Under a minute (a wake-when cut short by a restart) isn't worth saying.
    const ms = since ? now - Date.parse(since) : 0;
    const away = ms >= 60_000 ? ` after ${awayFor(ms)}` : '';
    const text = typeof cause === 'object'
      ? `Woke up${away}: ${cause.why}.`
      : cause === 'restart'
        ? `Woke up${away}, as the runner restarted.`
        : away ? `Woke up after hibernating for ${awayFor(ms)}.` : 'Woke up from hibernating.';
    this.emit(st, { type: 'system.note', text });
    rec.woke = { at: new Date(now).toISOString(), ...(since ? { since } : {}) };
    delete rec.snoozedAt;
    delete st.rec.snoozedUntil;
    delete st.rec.snoozedUntilRestart;
    delete st.rec.wakeWhen;
    st.rec.forceUnread = true;
    st.rec.updatedAt = this.isoNow();
    this.markDirty(st);
    this.kickQueue(st);
  }

  // Starts the next queued message if nothing is running. Returns true if
  // one started. One that can't be written (disk full) stays at the front.
  private kickQueue(st: ThreadState): boolean {
    if (st.rt.turn || st.rec.queue.length === 0 || this.stopping || st.rt.editing) return false;
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

  // ------------------------------------------------------ editing a message

  // Mike changes one of his earlier messages and carries on from there
  // (docs/protocol.md, "Editing a message"): the turn stops, the native
  // session is cut back to just before the message, the agent's file
  // changes since are put back, and the new text starts a turn.
  async editMessage(threadId: string, seq: number, text: string, images: ImageRef[] = []): Promise<{ turnId: string; rewound: { seq: number; fromSeq: number; toSeq: number; files: RewoundFiles } }> {
    const st = this.mustGet(threadId);
    const { rec, rt } = st;
    this.checkAccepting();
    if (this.draining) throw new RpcError(ErrorCode.busy, 'The runner is handing over to a new one; edit again in a moment.');
    if (rt.editing) throw new RpcError(ErrorCode.busy, 'This thread is already going back to an earlier message.');
    if (!text && images.length === 0) throw new RpcError(ErrorCode.badParams, 'text or images required');
    checkImages(images);
    const target = this.editableMessage(st, seq);
    const adapter = this.adapters[rec.provider];
    if (!adapter?.rewind) throw new RpcError(ErrorCode.badParams, `${providerName(rec.provider)} threads can't go back to an earlier message.`);
    const account = this.accounts.get(rec.accountId);
    if (!account) throw new RpcError(ErrorCode.badParams, `Account ${rec.accountId} isn't available on this Mac.`);
    rt.editing = true;
    try {
      // Messages waiting behind the turn were sent after the edited one,
      // so they go with the rest.
      if (rec.queue.length) {
        rec.queue = [];
        this.markDirty(st);
      }
      // A turn the CLI starts by itself as the last one ends (a
      // background task's result) is stopped too.
      for (let i = 0; rt.turn && i < 5; i++) {
        const ended = new Promise<void>((r) => (rt.turnEndWaiters ??= []).push(r));
        this.interrupt(rec.id);
        await ended;
      }
      if (rt.session) this.releaseSession(st);
      while (rt.closing) await rt.closing;
      if (rt.deleted || this.threads.get(rec.id) !== st) throw new RpcError(ErrorCode.threadNotFound, `Thread not found: ${threadId}`);
      // Cut the native session. One never started (its first turn failed
      // before the CLI got going) has nothing to cut.
      let cut: RewindResult = { fresh: true };
      if (rec.sessionUsed && rec.nativeSessionId && !rec.handoff) {
        try {
          cut = await adapter.rewind({ threadId: rec.id, account, cwd: rec.cwd, sessionId: rec.nativeSessionId, messageId: target.turnId });
        } catch (e) {
          const err = e as Error;
          if (err.name === 'RewindRefusedError') throw new RpcError(ErrorCode.badParams, err.message);
          this.log.error('could not cut the session back', { threadId: rec.id, error: String(e) });
          throw new RpcError(ErrorCode.other, `Couldn't go back to that message: ${err.message}`);
        }
      }
      const toSeq = this.store.log(rec.id).lastSeq;
      let files: RewoundFiles;
      if (cut.files) files = { ...cut.files, how: 'checkpoint' };
      else {
        const changes = appliedChanges(this.store.log(rec.id).read(seq, toSeq).filter((e) => !cutOut(rec, e.seq)));
        files = changes.length ? { ...undoChanges(changes, rec.cwd), how: 'diffs' } : { undone: [], failed: [], how: 'none' };
      }
      if (cut.fresh) {
        // The message opened the session: a new one, told what came before
        // it when anything did (a handoff from another login, say).
        rec.nativeSessionId = crypto.randomUUID();
        rec.sessionUsed = false;
        rec.sessionCostTotal = 0;
        delete rec.resumeAt;
        if (!rec.handoff && this.saidBefore(rec, seq)) rec.handoff = { fromCwd: rec.cwd, fromAccountId: rec.accountId };
      } else if (cut.resumeAt) rec.resumeAt = cut.resumeAt;
      (rec.rewinds ??= []).push({ from: seq, to: toSeq });
      const ev = this.emit(st, { type: 'thread.rewound', fromSeq: seq, toSeq, files });
      // What the cut turns left open or found goes with them (pins stay).
      if (rec.needs && rec.needs.seq >= seq) delete rec.needs;
      if (rec.highlights?.items.some((h) => h.seq >= seq && h.how !== 'pinned')) {
        rec.highlights.items = rec.highlights.items.filter((h) => h.seq < seq || h.how === 'pinned');
        this.highlightsChanged(st);
      }
      if (rec.panelRequest) {
        delete rec.panelRequest;
        this.endPanelWait(st, false);
      }
      this.markDirty(st);
      this.log.info('went back to an earlier message', { threadId: rec.id, seq, toSeq, how: files.how, undone: files.undone.length, failed: files.failed.length, fresh: Boolean(cut.fresh) });
      rt.editing = false;
      // The edited message goes first; anything sent during the edit after it.
      const later = rec.queue.splice(0);
      const turnId = this.sendTo(st, text, images, { editOf: seq });
      if (later.length) {
        rec.queue.push(...later);
        this.markDirty(st);
      }
      return { turnId, rewound: { seq: ev.seq, fromSeq: seq, toSeq, files } };
    } finally {
      if (rt.editing) {
        rt.editing = false;
        // Messages sent while it failed still go.
        if (!rt.turn) this.kickQueue(st);
      }
      this.markDirty(st);
    }
  }

  // The message at `seq`, if Mike can edit it; otherwise why not.
  private editableMessage(st: ThreadState, seq: number): { turnId: string } {
    const { rec } = st;
    const log = this.store.log(rec.id);
    const ev = Number.isInteger(seq) && seq >= 1 && seq <= log.lastSeq ? log.read(seq, seq)[0] : undefined;
    const no = (why: string) => new RpcError(ErrorCode.badParams, why);
    if (!ev || ev.type !== 'user.message') throw no(`There's no message at ${seq} to edit.`);
    if (cutOut(rec, seq)) throw no('That message was already taken out by an earlier edit.');
    if ((ev.origin && ev.origin !== 'phone') || sentByAgent(ev.text)) throw no('Only your own messages can be edited.');
    // It started a turn: its turn.started comes straight after it. One sent
    // into a running turn went into that turn and can't be cut out alone.
    const next = log.read(seq + 1, seq + 3).find((e) => e.type === 'turn.started');
    if (!ev.turnId || !next || next.turnId !== ev.turnId) throw no('That message went into a turn that was already running, so it can only be edited with the message that started that turn.');
    return { turnId: ev.turnId };
  }

  // Whether the thread had a message before `seq` that's still part of it.
  private saidBefore(rec: ThreadRecord, seq: number): boolean {
    const log = this.store.log(rec.id);
    for (let to = seq - 1; to >= 1; to -= 500) {
      const page = log.read(Math.max(1, to - 499), to);
      if (page.some((e) => (e.type === 'user.message' || e.type === 'assistant.text') && !cutOut(rec, e.seq))) return true;
    }
    return false;
  }

  // ---------------------------------------------------------- design reviews

  createReview(threadId: string, raw: ReviewInput): { review: DesignReview } {
    const st = this.mustGet(threadId);
    this.checkAccepting();
    const input = reviewInput(raw, st.rec.cwd);
    const id = crypto.randomUUID();
    const dir = path.join(this.store.mediaDir(threadId), 'reviews', id);
    const now = this.isoNow();
    try {
      const options = input.options.map(({path: source, ...option}) => ({...option, image: copyImageInto(dir, source)}));
      const review: DesignReview = { id, title: input.title, ...(input.note ? {note: input.note} : {}), options,
        status: 'pending', revision: 0, createdAt: now, updatedAt: now, draft: {notes: {}} };
      this.persistReview(st, review);
      return {review: structuredClone(review)};
    } catch (e) {
      // Only remove imports if the review was not committed. If an event
      // append failed after the record save, startup repairs its card.
      if (!st.rec.reviews?.some(r => r.id === id)) fs.rmSync(dir, {recursive: true, force: true});
      throw e;
    }
  }

  listReviews(threadId: string): { reviews: DesignReview[] } {
    return { reviews: structuredClone((this.mustGet(threadId).rec.reviews ?? [])
      .filter(review => review.status === 'pending')
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt) || a.id.localeCompare(b.id))) };
  }

  getReview(threadId: string, reviewId: string): { review: DesignReview } {
    return {review: structuredClone(this.mustReview(this.mustGet(threadId), reviewId))};
  }

  saveReview(threadId: string, reviewId: string, revision: number, raw: ReviewDraft): { review: DesignReview } {
    const st = this.mustGet(threadId);
    this.checkAccepting();
    const review = this.mustReview(st, reviewId);
    this.checkReviewRevision(review, revision);
    const draft = reviewDraft(review, raw);
    const next = {...review, draft, revision: review.revision + 1, updatedAt: this.isoNow()};
    this.persistReview(st, next);
    return {review: structuredClone(next)};
  }

  respondReview(threadId: string, reviewId: string, revision: number, raw: ReviewDraft): { review: DesignReview; turnId?: string } {
    const st = this.mustGet(threadId);
    const review = this.mustReview(st, reviewId);
    const draft = reviewDraft(review, raw, true);
    // A dropped WebSocket response must not send Mike's answer twice.
    if (review.status === 'answered' && sameDraft(review.response, draft)) {
      this.kickQueue(st);
      return {review: structuredClone(review), turnId: review.replyTurnId};
    }
    this.checkAccepting();
    this.checkReviewRevision(review, revision);
    const turnId = crypto.randomUUID();
    const next: DesignReview = {...review, draft, response: draft, status: 'answered', revision: review.revision + 1, updatedAt: this.isoNow(), replyTurnId: turnId};
    const message: QueuedSend = {turnId, text: reviewReply(review, draft), images: [], reviewId, reviewResponse: draft};
    // The answer and outbox live in one atomic thread.json write. Publish
    // the card only after it succeeds, then start the queued reply.
    this.persistReview(st, next, [...st.rec.queue, message], true);
    st.rt.releaseWhenIdle = false;
    this.markDirty(st);
    this.kickQueue(st);
    return {review: structuredClone(next), turnId};
  }

  cancelReview(threadId: string, reviewId: string, revision: number): {review: DesignReview} {
    const st = this.mustGet(threadId);
    this.checkAccepting();
    const review = this.mustReview(st, reviewId);
    this.checkReviewRevision(review, revision);
    const next: DesignReview = {...review, status: 'cancelled', revision: review.revision + 1, updatedAt: this.isoNow()};
    this.persistReview(st, next);
    return {review: structuredClone(next)};
  }

  // Mike often answers a review by typing in the thread instead of picking
  // in the review window. Left pending, it kept the thread in Needs you
  // (even mid-turn) with nothing left to do. So his own message, from the
  // app or the phone, closes every open review as superseded; the card
  // and window stay readable. Runner, schedule and agent-to-thread
  // messages aren't him and leave reviews open.
  private supersedeReviews(st: ThreadState, text: string, opts: SendOptions): void {
    if (!fromMike(text, opts)) return;
    for (const review of st.rec.reviews ?? []) {
      if (review.status !== 'pending') continue;
      this.persistReview(st, {...review, status: 'superseded', revision: review.revision + 1, updatedAt: this.isoNow()});
    }
  }

  private mustReview(st: ThreadState, id: string): DesignReview {
    const review = st.rec.reviews?.find(r => r.id === id);
    if (!review) throw new RpcError(ErrorCode.badParams, `Review not found: ${id}`);
    return review;
  }

  private checkReviewRevision(review: DesignReview, revision: number): void {
    if (review.status !== 'pending') throw new RpcError(ErrorCode.badParams, `This review is ${review.status}.`);
    if (!Number.isSafeInteger(revision) || review.revision !== revision) throw new RpcError(ErrorCode.badParams, 'This review changed. Reload it before saving or sending your answer.');
  }

  private persistReview(st: ThreadState, review: DesignReview, queue = st.rec.queue, wake = false): void {
    const previous = st.rec.reviews ?? [];
    const reviews = previous.some(r => r.id === review.id)
      ? previous.map(r => r.id === review.id ? review : r)
      : [...previous, review];
    const next = {...st.rec, reviews, queue};
    if (wake) {
      delete next.snoozedUntil;
      delete next.snoozedUntilRestart;
      delete next.wakeWhen;
      delete next.archivedAt;
    }
    this.store.save(next);
    if (wake) {
      delete st.rec.snoozedUntil;
      delete st.rec.snoozedUntilRestart;
      delete st.rec.wakeWhen;
      delete st.rec.archivedAt;
    }
    // Preserve the record object used by any in-flight deliver() callback.
    Object.assign(st.rec, next);
    this.emit(st, {type: 'review.updated', review});
  }

  private recoverReviews(st: ThreadState): void {
    // Reviews save their record before their event. Threads without reviews
    // need no extra log scan (the common case, including long transcripts).
    if (!st.rec.reviews?.length && !st.rec.queue.some(q => q.reviewId)) return;
    const log = this.store.log(st.rec.id);
    const latest = new Map<string, DesignReview>();
    const sent = new Set(st.rec.reviewDeliveries ?? []);
    for (const event of log.read(1, log.lastSeq)) {
      if (event.type === 'review.updated') latest.set(event.review.id, event.review);
    }
    const reviews = new Map((st.rec.reviews ?? []).map(r => [r.id, r]));
    for (const [id, review] of latest) if (!reviews.has(id) || reviews.get(id)!.revision < review.revision) reviews.set(id, review);
    if (reviews.size) st.rec.reviews = [...reviews.values()];
    // The delivery marker is written after session.send, not merely after
    // user.message. A failed turn.started append leaves the answer unsent.
    st.rec.queue = st.rec.queue.filter(q => !q.reviewId || !sent.has(q.reviewId));
    for (const [id, review] of reviews) {
      if (review.status === 'answered' && review.replyTurnId && review.response && !sent.has(id) && !st.rec.queue.some(q => q.reviewId === id)) {
        st.rec.queue.push({turnId: review.replyTurnId, text: reviewReply(review, review.response), images: [], reviewId: id, reviewResponse: review.response});
      }
      if (latest.get(id)?.revision !== review.revision) this.emit(st, {type: 'review.updated', review});
    }
    if (reviews.size) this.markDirty(st);
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
      // (docs/protocol.md, "Needs you"). A pending design review only
      // counts once the turn ends: show_options doesn't block, and Mike
      // didn't want a "Needs you" (or a phone push) mid-turn.
      needsYou: (!running && Boolean(rec.reviews?.some(r => r.status === 'pending'))) || rec.status === 'waiting' || Boolean(rec.forceUnread) || (!running && rec.lastTurnCompletedSeq > rec.lastSeenSeq && !this.saidNothing(rec)),
      createdAt: rec.createdAt,
      updatedAt: rec.updatedAt,
      lastActivityAt: rec.lastActivityAt,
      preview: rec.preview,
      lastSeq: rec.lastSeq,
      lastSeenSeq: rec.lastSeenSeq,
    };
    if (rec.poolId) s.poolId = rec.poolId;
    if (rec.waitingForRoom) s.waitingForRoom = { ...rec.waitingForRoom };
    if (rec.needs && rec.needs.seq === rec.lastTurnCompletedSeq) {
      s.needs = rec.needs.needs;
      if (rec.needs.asks) {
        const ticked = new Set(rec.needs.ticked);
        s.asks = rec.needs.asks.map((a, i) => (ticked.has(i) ? { ...a, ticked: true as const } : a));
        s.asksSeq = rec.needs.seq;
      }
    }
    const pendingReviews = rec.reviews?.filter(r => r.status === 'pending').length;
    if (pendingReviews) s.pendingReviews = pendingReviews;
    if (rec.model) s.model = rec.model;
    if (rec.effort) s.effort = rec.effort;
    if (rec.modelInUse) s.modelInUse = rec.modelInUse;
    if (rec.effortInUse) s.effortInUse = rec.effortInUse;
    if (rec.snoozedUntil) s.snoozedUntil = rec.snoozedUntil;
    if (rec.snoozedUntilRestart) s.snoozedUntilRestart = true;
    if (rec.wakeWhen && rec.snoozedUntil) s.wakeWhen = { ...rec.wakeWhen };
    if (rec.woke && rec.forceUnread) s.woke = { ...rec.woke };
    if (rec.archivedAt) s.archivedAt = rec.archivedAt;
    if (rec.nativeSessionId && rec.sessionUsed) s.nativeSessionId = rec.nativeSessionId;
    if (rec.contextTokens !== undefined) s.contextTokens = rec.contextTokens;
    if (rec.sample) s.sample = true;
    if (rec.contextWindow !== undefined) s.contextWindow = rec.contextWindow;
    if (rec.costUsd !== undefined) s.costUsd = rec.costUsd;
    const set = this.patchSet(st);
    const actions = this.actionsOf(st, set);
    const patches = this.worktreeAction(rec) ? [...set.patches, { id: 'worktree', source: 'builtin' as const }] : set.patches;
    if (set.panels.length) s.panels = set.panels;
    if (actions.length) s.actions = actions;
    if (set.hooks.length) s.hooks = set.hooks;
    if (patches.length) s.patches = patches;
    const background = this.background(st);
    if (background.length) s.background = background;
    if (rec.subagents?.length) s.subagents = rec.subagents.map(publicSubagent);
    const projects = this.projects?.threadProjects(rec);
    if (projects) s.projects = projects;
    if (rec.highlightsAt) s.highlightsAt = rec.highlightsAt;
    if (rec.worktree && !rec.worktree.removedAt) {
      s.worktree = { branch: rec.worktree.branch, mainCheckout: rec.worktree.mainCheckout, path: rec.worktree.path };
    }
    if (rec.schedule) s.schedule = { ...rec.schedule };
    if (rec.panelRequest) s.panelRequest = { ...rec.panelRequest };
    // A record from 28 Oct may say "people" (sharing with specific people,
    // since dropped): that's not shared.
    if (rec.share) s.share = { access: rec.share.access === 'link' ? 'link' : 'off', slug: rec.share.slug, updatedAt: rec.share.updatedAt };
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
      // A thread moved to another folder looks at it afresh, rather than
      // through what was read a few seconds ago (rare, unlike startup).
      if (rt.patches) this.forgetFolders();
      // The built-in panels straight away; the files follow.
      let panels: PatchSet['panels'] = [];
      try {
        panels = projectPanels(rec.cwd, this.panelsRoot, folders, this.folderCache);
      } catch (e) {
        this.log.warn('could not read the folder for panels', { threadId: rec.id, cwd: rec.cwd, error: String(e) });
      }
      const set = { ...EMPTY_PATCH_SET, panels };
      rt.patches = { cwd: rec.cwd, key, at: now, base: set, set, refreshing: false, loaded: false };
      void this.refreshPatches(st);
    } else if (!rt.patches.refreshing && now - rt.patches.at > PATCHES_TTL_MS) {
      void this.refreshPatches(st);
    }
    return rt.patches.set;
  }

  // Reads the folder's patches again; a change sends a new summary, and a
  // patch file that has appeared or broken since the last read is said in
  // the transcript (not on the first read, which would say it at startup).
  refreshPatches(st: ThreadState): Promise<void> {
    const read = this.readPatches(st);
    this.patchReads.add(read);
    void read.finally(() => this.patchReads.delete(read));
    return read;
  }

  // Resolves once no thread's patches are being read. For tests: the
  // reads go to the disk asynchronously, so a tick or two isn't enough.
  async patchesIdle(): Promise<void> {
    while (this.patchReads.size) await Promise.allSettled([...this.patchReads]);
  }

  private async readPatches(st: ThreadState): Promise<void> {
    const { rec, rt } = st;
    const entry = rt.patches;
    if (!entry || entry.refreshing) return;
    entry.refreshing = true;
    const cwd = rec.cwd;
    const key = entry.key;
    let base: PatchSet;
    let set: PatchSet;
    try {
      base = await this.loadSharedPatchSet(cwd, this.projects?.foldersFor(rec) ?? [], this.projects?.allFolders() ?? []);
      set = await applyLive(base, { cwd, threadId: rec.id, run: (command, dir) => this.runLiveCommand(rec.id, command, dir) });
    } catch (e) {
      this.log.warn('could not read the folder for patches', { threadId: rec.id, cwd, error: String(e) });
      base = entry.base;
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
    // What the files give is said in the transcript; live state (a chip
    // coming and going) only moves the summary.
    if (entry.loaded && JSON.stringify(entry.base) !== JSON.stringify(base)) this.notePatchChanges(st, entry.base, base);
    const changed = JSON.stringify(entry.set) !== JSON.stringify(set);
    entry.base = base;
    entry.set = set;
    entry.live = hasLive(base);
    entry.loaded = true;
    if (changed) this.markDirty(st);
    if (entry.live) this.armLivePoll();
  }

  // Threads in the same folder with the same projects get the same set, so
  // it's read once per FOLDER_CACHE_MS for all of them: a couple of hundred
  // threads share a few dozen folders, and each reading its own set again
  // every 15 seconds kept the runner busy for seconds on a loaded Mac.
  // Sets aren't changed once made (applyLive makes new ones), so sharing
  // one is safe, as sharing a patch file's module already was.
  private loadSharedPatchSet(cwd: string, folders: ProjectFolder[], allFolders: string[]): Promise<PatchSet> {
    const key = JSON.stringify([cwd, folders, allFolders]);
    const now = this.clock.now();
    const hit = this.sharedPatchSets.get(key);
    if (hit && now - hit.at < FOLDER_CACHE_MS) return hit.set;
    const set = loadPatchSet(cwd, this.panelsRoot, this.patchCache, folders, allFolders, this.folderCache, this.patchTrust);
    const entry = { at: now, set };
    this.sharedPatchSets.set(key, entry);
    set.catch(() => {
      if (this.sharedPatchSets.get(key) === entry) this.sharedPatchSets.delete(key);
    });
    return set;
  }

  // Forgets what was read from the folders, after something that may have
  // changed them: the next patch reads go to the disk.
  private forgetFolders(): void {
    this.folderCache.clear();
    this.sharedPatchSets.clear();
    // A turn may have changed what they read (comments resolved, a handback).
    this.liveRuns.clear();
  }

  // A live state command (when, badge), shared by every thread that runs
  // the same one in the same folder: Tandem's patch runs tandem status and
  // tandem comments for each thread in a video folder every LIVE_POLL_MS.
  // On a loaded Mac each took longer than that, so they piled up, nine at a
  // time, and every spawn blocked the event loop for a second or so. Now
  // one run serves them all for LIVE_SHARE_MS, and a poll that comes round
  // while it's still going joins it. Live state is about the folder (what
  // a tool says about the files there), not about one thread.
  private runLiveCommand(threadId: string, command: string, cwd: string): Promise<CommandOutcome> {
    const key = `${cwd}\u0000${command}`;
    const hit = this.liveRuns.get(key);
    if (hit && (hit.doneAt === undefined || this.clock.now() - hit.doneAt < LIVE_SHARE_MS)) return hit.out;
    const entry: { doneAt?: number; out: Promise<CommandOutcome> } = { out: this.runPatchCommand(threadId, command, cwd) };
    this.liveRuns.set(key, entry);
    void entry.out.then(
      () => (entry.doneAt = this.clock.now()),
      () => {
        if (this.liveRuns.get(key) === entry) this.liveRuns.delete(key);
      },
    );
    return entry.out;
  }

  // A command a patch's function runs (list panels, live state): in its
  // folder, with the thread's variables, like an action.
  private runPatchCommand(threadId: string, command: string, cwd: string) {
    return runCommand(command, { cwd, env: { ...process.env, ...threadEnv(threadId, this.cfg.home) }, shell: this.actionShell, timeoutMs: this.actionTimeoutMs });
  }

  // Reads live state again for the inbox's threads that have any, every
  // LIVE_POLL_MS while there are some. Hibernating and Den threads wait
  // until they're back (patchSet reads again on the next summary).
  private armLivePoll(): void {
    if (this.liveTimer || this.stopping) return;
    this.liveTimer = this.clock.setTimeout(() => {
      this.liveTimer = undefined;
      if (this.stopping) return;
      let any = false;
      for (const st of this.threads.values()) {
        if (!st.rt.patches?.live || st.rt.deleted || this.bucket(st.rec) !== 'inbox') continue;
        any = true;
        void this.refreshPatches(st);
      }
      if (any) this.armLivePoll();
    }, LIVE_POLL_MS);
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
      if (p.untrusted) {
        if (old?.untrusted !== p.untrusted || old?.hash !== p.hash) {
          const why = p.untrusted === 'changed' ? 'it changed since you trusted it' : 'nothing from its folder is trusted yet';
          this.emit(st, { type: 'system.note', text: `Patch ${p.id} isn't loaded: ${why}. Trust it in Patches to load it.` });
        }
        continue;
      }
      if (old && !old.error && !old.untrusted) continue;
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

  // patches.trust: trusts the versions of a thread's untrusted patch files
  // that the app showed (by hash), then reads every thread's patches again.
  // Only files the thread lists as untrusted: this isn't a way to trust
  // any path.
  async trustPatches(threadId: string, files: { file: string; hash: string }[]): Promise<{ trusted: string[] }> {
    const st = this.mustGet(threadId);
    const waiting = this.patchSet(st).patches.filter((p) => p.untrusted && p.file);
    for (const { file, hash } of files) {
      const p = waiting.find((w) => w.file === file);
      if (!p) throw new RpcError(ErrorCode.badParams, `${file} isn't one of this thread's patches waiting to be trusted`);
      if (p.hash !== hash) throw new RpcError(ErrorCode.badParams, `${path.basename(file)} has changed since it was shown; look again`);
    }
    const trusted = files.filter(({ file, hash }) => this.patchTrust.trust(file, hash)).map((f) => f.file);
    this.log.info('patches trusted', { threadId, files: trusted });
    this.rereadAllPatches();
    await this.patchesIdle();
    return { trusted };
  }

  // Trusts patch files an agent wrote, as they are now (patch-trust.ts).
  // `reread` false when the caller reads them again itself.
  private trustAgentPatches(files: string[], reread = true): void {
    const patchFiles = files.filter(isPatchFile);
    if (!patchFiles.length) return;
    const done = this.patchTrust.trustCurrent(patchFiles);
    if (done.length && reread) this.rereadAllPatches();
  }

  // Every thread whose patches have been read reads them again now: a
  // trusted file can matter to threads in other folders (a project's).
  private rereadAllPatches(): void {
    this.forgetFolders();
    for (const st of this.threads.values()) {
      if (!st.rt.patches || st.rt.deleted) continue;
      st.rt.patches.at = -Infinity;
      void this.refreshPatches(st);
    }
  }

  // A first start with patch trust (no patch-trust.json yet): the patch
  // files of every thread's folder and every project's are trusted as they
  // are, since this runner was already running them. Anything new after
  // this asks.
  private seedPatchTrust(threadFolders: string[]): void {
    if (this.patchTrust.existed) return;
    const home = this.panelsRoot ?? os.homedir();
    const folders = new Set<string>(threadFolders);
    for (const f of Projects.savedFolders(this.cfg.home)) folders.add(f);
    const files = new Set<string>();
    for (const folder of folders) {
      try {
        for (const f of projectPatchFiles(folder, home)) files.add(f);
      } catch {
        // a folder that's gone
      }
    }
    const done = this.patchTrust.trustCurrent([...files]);
    this.patchTrust.save();
    this.log.info('patch trust seeded', { files: done.length });
  }

  // Draws an image panel (the Simulator's screenshot) for `panels.render`.
  async renderPanel(threadId: string, panelId: string): Promise<PanelRender> {
    const st = this.mustGet(threadId);
    const panel = this.patchSet(st).panels.find((p) => p.id === panelId);
    if (!panel) throw new RpcError(ErrorCode.badParams, `This thread has no panel called ${panelId}`);
    if (panel.kind === 'list') {
      return renderListPanel(panel, this.patchSet(st), {
        cwd: st.rec.cwd,
        threadId,
        run: (command, cwd) => this.runPatchCommand(threadId, command, cwd),
      });
    }
    return renderPanel(panel, paths.panels(this.cfg.home, threadId), this.screenshot);
  }

  // Cloud deployments in the Convex panel's project, through its CLI.
  async convexPanelDeployments(threadId: string, panelId: string, refresh = false): Promise<ConvexDeployments> {
    const { convex, folder } = this.convexPanelContext(threadId, panelId);
    return this.convexKeys.deployments(folder, convex, refresh);
  }

  // A deploy key for the embedded dashboard. Other choices must resolve in
  // this panel's project before they can get a key.
  async convexPanelKey(threadId: string, panelId: string, renew = false, selected?: string): Promise<ConvexKey> {
    const { convex, folder } = this.convexPanelContext(threadId, panelId);
    let target = convex;
    if (selected && selected !== convex.deployment) {
      const choices = await this.convexKeys.deployments(folder, convex);
      const choice = choices.deployments.find(d => d.deployment === selected);
      if (!choice) throw new RpcError(ErrorCode.badParams, `This project's panel has no deployment called ${selected}`);
      target = choice;
    }
    const { deployment, deploymentUrl } = target;
    return { deployment, deploymentUrl, adminKey: await this.convexKeys.key(deployment, folder, renew) };
  }

  private convexPanelContext(threadId: string, panelId: string) {
    const st = this.mustGet(threadId);
    const panel = this.patchSet(st).panels.find((p) => p.id === panelId);
    if (!panel) throw new RpcError(ErrorCode.badParams, `This thread has no panel called ${panelId}`);
    if (!panel.convex) throw new RpcError(ErrorCode.badParams, `${panelId} isn't a Convex cloud deployment's panel`);
    const { deployment } = panel.convex;
    const starts = [st.rec.cwd, ...(this.projects?.foldersFor(st.rec) ?? []).map((f) => f.folder)];
    const folder = convexFolderFor(deployment, starts, this.panelsRoot ?? os.homedir());
    if (!folder) throw new RpcError(ErrorCode.badParams, `Couldn't find the Convex project for ${deployment}`);
    return { convex: panel.convex, folder };
  }

  // ------------------------------------------------------------ highlights

  // What the thread has made, shared and pinned (docs/protocol.md,
  // "Highlights"): brought up to date from the events since the last ask.
  highlights(threadId: string): ThreadHighlights {
    const st = this.mustGet(threadId);
    this.catchUpHighlights(st);
    return highlightsView(st.rec.highlights!, st.rec.brief);
  }

  removeHighlight(threadId: string, highlightId: string): { thread: ThreadSummary } {
    const st = this.mustGet(threadId);
    this.catchUpHighlights(st);
    if (!removeHighlight(st.rec.highlights!, highlightId)) throw new RpcError(ErrorCode.badParams, `This thread has no highlight ${highlightId}`);
    this.highlightsChanged(st);
    return { thread: this.summary(st) };
  }

  // The `pin` tool: a file (relative to the thread's folder is fine) or a
  // URL, for Mike to look at. Returns the highlight's id.
  pin(threadId: string, target: { path?: string; url?: string; title?: string; note?: string; show?: boolean }): { id: string } {
    const st = this.mustGet(threadId);
    if (Boolean(target.path) === Boolean(target.url)) throw new RpcError(ErrorCode.badParams, 'Pin a path or a url, one of the two.');
    let file: string | undefined;
    if (target.path) {
      file = absolute(target.path, st.rec.cwd);
      if (!fs.statSync(file, { throwIfNoEntry: false })?.isFile()) throw new RpcError(ErrorCode.badParams, `There's no file at ${file}.`);
    } else if (!/^[a-z][a-z0-9+.-]*:\/\/\S/i.test(target.url!)) {
      throw new RpcError(ErrorCode.badParams, 'A url needs a scheme, like https://.');
    }
    this.catchUpHighlights(st);
    const state = st.rec.highlights!;
    const item = pinItem({ ...target, path: file }, st.rec.lastSeq, this.isoNow());
    // Pinning something Mike removed is the agent asking again: let it.
    state.removed = state.removed?.filter((id) => id !== item.id);
    upsertHighlight(state, item);
    this.highlightsChanged(st);
    return { id: item.id };
  }

  unpin(threadId: string, highlightId: string): { removed: boolean } {
    const st = this.mustGet(threadId);
    this.catchUpHighlights(st);
    const removed = unpinHighlight(st.rec.highlights!, highlightId);
    if (removed) this.highlightsChanged(st);
    return { removed };
  }

  // ------------------------------------------------------- showing panels

  // The show_panel tool (docs/protocol.md, "Showing panels"): the request
  // waits on the thread, replacing an older one, for the app to show once
  // Mike is looking at it. Resolves when the app says it has, or after
  // waitMs with shown false. Everything up to the wait runs before the
  // promise is returned, so the request is there as soon as this is called.
  async showPanel(threadId: string, ask: { panel: string; where?: PanelPlace }, waitMs = PANEL_ACK_WAIT_MS): Promise<{ request: PanelRequest; shown: boolean }> {
    const st = this.mustGet(threadId);
    if (ask.where !== undefined && !PANEL_PLACES.includes(ask.where)) {
      throw new RpcError(ErrorCode.badParams, `where is ${PANEL_PLACES.slice(0, -1).join(', ')} or ${PANEL_PLACES.at(-1)}.`);
    }
    const set = this.patchSet(st);
    let panel: { id: string; title: string };
    try {
      panel = resolvePanel(ask.panel, { panels: set.panels, hasPatches: set.patches.length > 0 || Boolean(this.worktreeAction(st.rec)) });
    } catch (e) {
      throw new RpcError(ErrorCode.badParams, (e as Error).message);
    }
    const request: PanelRequest = { id: crypto.randomUUID(), panel: panel.id, title: panel.title, at: this.isoNow() };
    if (ask.where) request.where = ask.where;
    this.endPanelWait(st, false);
    st.rec.panelRequest = request;
    this.markDirty(st);
    const shown = await new Promise<boolean>((resolve) => {
      const timer = this.clock.setTimeout(() => this.endPanelWait(st, false), waitMs);
      st.rt.panelWaiter = { id: request.id, resolve, timer };
    });
    return { request, shown };
  }

  // Whether anyone with the link can read the thread on the website
  // (docs/protocol.md, "Sharing"). The mirror carries it to Convex, which
  // serves the link. The slug stays when sharing goes off, so sharing
  // again brings the same link back, as a doc's sharing does; newLink
  // makes a fresh one, which stops the old link for good.
  share(threadId: string, args: { access: ShareAccess; newLink?: boolean }): { thread: ThreadSummary } {
    const st = this.mustGet(threadId);
    if (args.access !== 'off' && args.access !== 'link') throw new RpcError(ErrorCode.badParams, 'access is "off" or "link"');
    const slug = !st.rec.share || args.newLink ? crypto.randomBytes(16).toString('base64url') : st.rec.share.slug;
    st.rec.share = { access: args.access, slug, updatedAt: this.isoNow() };
    this.markDirty(st);
    return { thread: this.summary(st) };
  }

  // The app has shown the thread's panel request: it's done.
  panelShown(threadId: string, requestId: string): { thread: ThreadSummary } {
    const st = this.mustGet(threadId);
    if (st.rec.panelRequest?.id === requestId) {
      delete st.rec.panelRequest;
      if (st.rt.panelWaiter?.id === requestId) this.endPanelWait(st, true);
      this.markDirty(st);
    }
    return { thread: this.summary(st) };
  }

  private endPanelWait(st: ThreadState, shown: boolean): void {
    const waiter = st.rt.panelWaiter;
    if (!waiter) return;
    st.rt.panelWaiter = undefined;
    waiter.timer.cancel();
    waiter.resolve(shown);
  }

  // The librarian's line on where the thread is up to.
  setBrief(threadId: string, text: string): void {
    const st = this.threads.get(threadId);
    if (!st || st.rt.deleted) return;
    const clean = text.trim().slice(0, 600);
    if (!clean || clean === st.rec.brief?.text) return;
    st.rec.brief = { text: clean, at: this.isoNow() };
    this.highlightsChanged(st);
  }

  // The librarian's title for a thread that has moved on from its old one.
  // Never over one Mike or an agent set, and only while the title is still
  // `from`, the one the look was given, so a rename meanwhile wins. Like a
  // model title it doesn't set titleSet, so a later look can rename again.
  retitleFromLibrarian(threadId: string, title: string, from: string): string | undefined {
    const st = this.threads.get(threadId);
    if (!st || st.rt.deleted || st.rec.titleSet || st.rec.title !== from) return undefined;
    const clean = cleanTitle(title);
    if (!clean || clean === st.rec.title) return undefined;
    st.rec.title = clean;
    st.rec.updatedAt = this.isoNow();
    this.markDirty(st);
    return clean;
  }

  private catchUpHighlights(st: ThreadState): void {
    const state = (st.rec.highlights ??= emptyHighlights());
    const log = this.store.log(st.rec.id);
    if (state.seq >= log.lastSeq) return;
    // A page at a time, so a long thread's first look doesn't hold
    // thousands of events at once.
    for (let from = state.seq + 1; from <= log.lastSeq; from += 500) {
      const to = Math.min(log.lastSeq, from + 499);
      observeHighlights(state, log.read(from, to).filter((e) => !cutOut(st.rec, e.seq)), { cwd: st.rec.cwd });
      state.seq = Math.max(state.seq, to);
    }
    this.markDirty(st);
  }

  private highlightsChanged(st: ThreadState): void {
    // markDirty sends the summary, whose new highlightsAt tells clients
    // to fetch again.
    st.rec.highlightsAt = this.isoNow();
    this.markDirty(st);
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
    const action = this.actionsOf(st, this.patchSet(st)).find((a) => a.id === actionId);
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

  // ------------------------------------------------------------ worktrees
  // A worktree per thread (docs/thread-worktrees.md, worktrees.ts).

  // Whether a new thread in `cwd` might get a worktree: there's at least
  // one patch file in its own folder chain to read.
  private mayWantWorktree(cwd: string): boolean {
    try {
      return worktreePatchFiles(cwd, this.panelsRoot).length > 0;
    } catch {
      return false;
    }
  }

  // Before a new thread's first turn: if its repo's patch asks for a
  // worktree, makes one, moves the thread into it and runs the patch's
  // setup there. Anything going wrong is said, and the thread starts
  // where it was asked to.
  private async prepareWorktree(st: ThreadState, turnId: string): Promise<void> {
    const { rec, rt } = st;
    delete rec.worktreePending;
    this.markDirty(st);
    // A session already ran in the folder (a turn that failed later, say):
    // moving it now would leave that session behind.
    if (rec.sessionUsed || rec.worktree) return;
    let patch;
    try {
      patch = await findWorktreePatch(rec.cwd, this.panelsRoot, this.patchCache, undefined, this.patchTrust);
    } catch (e) {
      this.log.warn('could not read patches for a worktree', { threadId: rec.id, error: String(e) });
      return;
    }
    if (!patch || rt.deleted) return;
    const asked = rec.cwd;
    const made = await makeWorktree({ cwd: asked, threadId: rec.id, patch });
    if (rt.deleted) return;
    if (!made.ok) {
      this.log.warn('could not make a worktree', { threadId: rec.id, reason: made.reason });
      this.emit(st, { type: 'system.note', text: `Couldn't make a worktree for this thread: ${made.reason}. It starts in ${asked} instead.` }, turnId);
      return;
    }
    rec.worktree = made.worktree;
    rec.cwd = made.cwd;
    rec.updatedAt = this.isoNow();
    this.markDirty(st);
    this.log.info('made a worktree', { threadId: rec.id, path: made.worktree.path, branch: made.worktree.branch });
    this.emit(st, { type: 'system.note', text: `Working in a worktree of its own at ${made.worktree.path}, on the branch ${made.worktree.branch}. tb land puts it on main.` }, turnId);
    if (!patch.setup) return;
    const outcome = await runCommand(patch.setup, {
      cwd: made.worktree.path,
      env: { ...process.env, ...threadEnv(rec.id, this.cfg.home) },
      shell: this.actionShell,
      timeoutMs: this.actionTimeoutMs,
    });
    if (rt.deleted) return;
    const body: EventBody = {
      type: 'action.run',
      actionId: `${patch.patch}.worktree-setup`,
      patch: patch.patch,
      title: 'Set up the worktree',
      command: patch.setup,
      ok: outcome.ok,
      text: outcome.text,
      truncated: outcome.truncated,
      durationMs: outcome.durationMs,
      trigger: 'worktree.setup',
    };
    if (outcome.exitCode !== undefined) body.exitCode = outcome.exitCode;
    this.emit(st, body, rt.turn?.turnId ?? turnId);
    this.markDirty(st);
  }

  // A thread whose worktree was removed (it was archived with everything
  // landed) and has now come back carries on in the main checkout. Returns
  // a line for the agent, whose system prompt still names the worktree.
  private leaveRemovedWorktree(st: ThreadState, turnId: string): string | undefined {
    const { rec } = st;
    const w = rec.worktree;
    // A spare's folder is still there, but it's another thread's (or will
    // be), so the thread never carries on in it.
    if (!w?.removedAt || !isInside(rec.cwd, w.path) || (!w.spare && isDirectory(rec.cwd))) return undefined;
    const from = rec.cwd;
    const to = sameSubfolder(from, w.path, w.mainCheckout);
    if (rec.sessionUsed) {
      if (this.adapters[rec.provider]?.movesFolders) rec.moved ??= { fromCwd: from };
      else rec.handoff ??= { fromCwd: from, fromAccountId: rec.accountId };
    }
    rec.cwd = to;
    rec.updatedAt = this.isoNow();
    this.markDirty(st);
    this.tellActivity({ kind: 'moved', threadId: rec.id, from, to });
    const went = w.spare ? 'was handed on to other threads' : 'was removed';
    this.emit(st, { type: 'system.note', text: `This thread's worktree ${went} when it was archived, so it carries on in the main checkout, ${to}.` }, turnId);
    return `[Threadbear] Your worktree at ${w.path} ${went} after its work landed on main. You're now in the main checkout, ${to}, which other threads share: stage your own files by name.`;
  }

  // The Land chip, for a thread with a worktree of its own.
  private worktreeAction(rec: ThreadRecord): Action | undefined {
    const w = rec.worktree;
    if (!w || w.removedAt) return undefined;
    // This runner's own tb, in full: a login shell's PATH may not have it.
    const tb = path.join(BIN_DIR, 'tb');
    const quoted = /^[\w./-]+$/.test(tb) ? tb : `'${tb.replace(/'/g, `'\\''`)}'`;
    return {
      id: 'worktree.land',
      title: 'Land',
      kind: 'command',
      command: `${quoted} land`,
      patch: 'worktree',
      note: `Rebase ${w.branch} on main, run the check, then move main to it`,
    };
  }

  private actionsOf(st: ThreadState, set: PatchSet): Action[] {
    const land = this.worktreeAction(st.rec);
    return land ? [...set.actions, land] : set.actions;
  }

  // When the thread is archived or deleted: its worktree and branch go if
  // everything on them is on main; otherwise they stay, and the thread (or,
  // once it's deleted, a notice) says so and how to land or drop them.
  private async cleanUpWorktree(st: ThreadState, deleted = false): Promise<void> {
    const { rec } = st;
    const w = rec.worktree;
    if (!w || w.removedAt) return;
    let result;
    try {
      result = await cleanUpWorktree(w);
    } catch (e) {
      result = { removed: false as const, reason: String((e as Error).message ?? e) };
    }
    this.log.info('worktree cleanup', { threadId: rec.id, path: w.path, ...result });
    if (result.removed) {
      w.removedAt = this.isoNow();
      if ('spare' in result && result.spare) w.spare = true;
      if (deleted) return;
      const text = w.spare
        ? `Deleted this thread's branch ${w.branch} (everything on it is on main) and kept its worktree, build caches and all, for the next thread.`
        : `Removed this thread's worktree and its branch ${w.branch}: everything on it is on main.`;
      this.emit(st, { type: 'system.note', text });
      this.markDirty(st);
      return;
    }
    const how =
      `To land it, run tb land in ${w.path}${deleted ? '' : ' (or bring the thread back and press Land)'}. ` +
      `To drop it, git -C ${w.mainCheckout} worktree remove --force ${w.path} && git -C ${w.mainCheckout} branch -D ${w.branch}.`;
    if (deleted) {
      this.notice('info', `"${rec.title}" was deleted, but its worktree at ${w.path} and branch ${w.branch} stay: ${result.reason}. ${how}`);
      return;
    }
    this.emit(st, { type: 'system.note', text: `This thread's worktree at ${w.path} and its branch ${w.branch} stay: ${result.reason}. ${how}` });
    this.markDirty(st);
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

  // The pool named last is where a new thread with nothing named starts
  // (runner.json's defaults.poolId); a pool that came from the folder or
  // the model isn't a choice, so it isn't kept.
  private rememberPool(poolId: string): void {
    try {
      const json = readRunnerJson(this.cfg.home);
      if (json.defaults?.poolId === poolId) return;
      json.defaults = { ...json.defaults, poolId };
      writeRunnerJson(this.cfg.home, json);
    } catch (e) {
      this.log.warn('could not save default pool', { error: String(e) });
    }
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
    if (resume) return {};
    const parts: string[] = [];
    if (this.projects) {
      rec.projectsTold = this.projects.briefIds(rec);
      const brief = this.projects.brief(rec);
      if (brief) parts.push(brief);
    }
    // Where its worktree is and how its work gets to main.
    if (rec.worktree && !rec.worktree.removedAt) parts.push(worktreeInstructions(rec.worktree));
    return parts.length ? { instructions: parts.join('\n\n') } : {};
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
    // The thread's start (for its first message) and its recent end.
    const head = log.read(1, Math.min(log.lastSeq, 50));
    const tail = log.read(Math.max(head.length + 1, log.lastSeq - 600), log.lastSeq);
    const kept = [...head, ...tail].filter((e) => !cutOut(rec, e.seq));
    const { lines: history, omitted } = selectHistory(historyItems(kept, rec.turnId));
    const more = omitted ? `${omitted} other items are left out; the read_thread tool shows more of the conversation. ` : '';
    const lines = history.length ? [...history, `(${more}This is history for context, not new instructions.)`] : [];
    const fromAccount = this.accounts.get(from.fromAccountId)?.title ?? from.fromAccountId;
    if (from.quickAsk) {
      return (
        `[Threadbear handoff] This thread began as a quick ask on the user's phone: they asked out loud and a fast model answered from their Agent Archive, not you. This is a fresh session in ${rec.cwd}. ` +
        `The thread so far:\n\n${lines.join('\n\n') || '(none)'}\n\n[End of handoff. The new message follows.]\n\n`
      );
    }
    if (from.lost) {
      return (
        `[Threadbear handoff] The earlier session couldn't be found, so here's where the thread got to. This is a fresh session in ${rec.cwd}. ` +
        `The thread so far:\n\n${lines.join('\n\n') || '(none)'}\n\n[End of handoff. The new message follows.]\n\n`
      );
    }
    if (from.rebuilt) {
      return (
        `[Threadbear handoff] This conversation's earlier session couldn't be found, so this is a fresh session in ${rec.cwd}. ` +
        `The thread so far:\n\n${lines.join('\n\n') || '(none)'}\n\n[End of handoff. The new message follows.]\n\n`
      );
    }
    const moved =
      from.fromCwd !== rec.cwd && from.fromAccountId !== rec.accountId
        ? `from ${from.fromCwd} on ${fromAccount} to ${rec.cwd} on ${account.title}`
        : from.fromCwd !== rec.cwd
          ? `from ${from.fromCwd} to ${rec.cwd}`
          : `from the ${fromAccount} login to ${account.title}`;
    return (
      `[Threadbear handoff] This conversation moved ${moved}, so this is a fresh session. ` +
      `The thread so far:\n\n${lines.join('\n\n') || '(none)'}\n\n[End of handoff. The new message follows.]\n\n`
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

// answers: the asks the message answers (AskAnswer), for the app to show.
export type SendOptions = { origin?: MessageOrigin; scheduleId?: string; queue?: boolean; answers?: AskAnswer[]; editOf?: number };

// Typed by Mike, at the Mac or on his phone: not the runner's, a
// schedule's or an agent's (another thread's, or this one's own `then`
// from move_thread, which once stopped the turn that sent it on a move to
// another login).
function fromMike(text: string, opts: SendOptions): boolean {
  if (opts.origin && opts.origin !== 'phone') return false;
  return !sentByAgent(text);
}

// What the agent is told when Mike writes a message while its question or
// approval card is still open (sendTo).
export const WROTE_INSTEAD = "The user didn't answer this; they wrote you a message instead, which comes next. Read it before asking again.";

// What a pool thread is told when it carries on by itself after its login
// ran dry (docs/protocol.md, "Pools").
export const CARRY_ON_MOVED = 'Your last login hit its usage limit partway through that turn, so this thread has moved to another one. Carry on from where you left off.';
export const CARRY_ON_BACK = 'Your login hit its usage limit partway through that turn and has room again now. Carry on from where you left off.';

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
    ...(msg.reviewId ? { reviewId: msg.reviewId, reviewResponse: msg.reviewResponse } : {}),
    ...(msg.answers?.length ? { answers: msg.answers } : {}),
    ...(msg.editOf ? { editOf: msg.editOf } : {}),
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
  'You name threads in Threadbear, an app for running AI agents, mostly for coding.',
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
