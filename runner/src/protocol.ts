// Types for the runner protocol. docs/protocol.md is the contract; keep this
// file in step with it. Both sides ignore unknown fields, so extra internal
// fields never leak out: summaries are built explicitly by toSummary().

export const PROTOCOL_VERSION = 1;

export type Provider = 'claude' | 'codex';
export const PROVIDERS: readonly Provider[] = ['claude', 'codex'];

export function isProvider(v: unknown): v is Provider {
  return typeof v === 'string' && (PROVIDERS as readonly string[]).includes(v);
}

export type PermissionMode = 'full' | 'ask';
// 'ultra' is Codex's multi-agent level; Claude never offers it.
export type EffortLevel = 'low' | 'medium' | 'high' | 'xhigh' | 'max' | 'ultra';
export const EFFORT_LEVELS: readonly EffortLevel[] = ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'];

export function isEffortLevel(v: unknown): v is EffortLevel {
  return typeof v === 'string' && (EFFORT_LEVELS as readonly string[]).includes(v);
}

// One row of a CLI's model picker: `id` is what to send as a thread's model,
// `model` the full id it runs as.
export type ModelChoice = {
  id: string;
  model: string;
  title: string;
  description?: string;
  effortLevels?: EffortLevel[];
  defaultEffort?: EffortLevel; // the model's own level, when the CLI says (Codex)
};

export type UsageWindowKind = 'five_hour' | 'weekly' | 'weekly_model' | 'daily' | 'monthly' | 'allowance' | 'other';

export type UsageWindow = {
  kind: UsageWindowKind;
  title: string; // "5-hour", "Weekly", "Weekly Fable", "$250 allowance"
  remainingPercent: number; // 0 to 100, may be fractional
  resetsAt?: string;
  detail?: string; // "$132.79 left"
};

export type AccountUsage = {
  windows: UsageWindow[];
  readAt: string; // when the newest reading in it was taken
  source: 'tokenStats' | 'live';
  stale?: boolean; // Token Stats has gone quiet and there's no live reading since
  blocked?: boolean; // the provider says this login is at its limit
  notice?: string; // Token Stats' own note
};

export type Account = {
  id: string;
  provider: Provider;
  // Codex titles start "Codex · " so an app that only shows title can tell
  // codex-main from a Claude login with the same email.
  title: string;
  configDir: string;
  // The full id a thread with no model runs on, once known (the account's
  // settings, corrected by the first turn seen); and the CLI's model list.
  defaultModel?: string;
  models?: ModelChoice[];
  defaultEffort?: EffortLevel; // the account's own level; absent: each model's
  email?: string;
  plan?: string;
  note?: string; // from runner.json's accountNotes ("Convex work only")
  usage?: AccountUsage;
};

export type CliPolicy = 'auto' | 'notify' | 'off';
export const CLI_POLICIES: readonly CliPolicy[] = ['auto', 'notify', 'off'];

export type CliUpdateState = 'waiting' | 'running' | 'succeeded' | 'unchanged' | 'failed';

export type CliStatus = {
  provider: Provider;
  path: string; // the binary new sessions start
  // Codex: Threadbear's own copies; Claude: its own installer; 'none' when
  // codexPath is set by hand and never updated.
  managedBy: 'threadbear' | 'cli' | 'none';
  installedVersion?: string;
  latestVersion?: string;
  status: 'current' | 'behind' | 'held' | 'unknown' | 'missing';
  policy: CliPolicy;
  inUse: { version: string; threadIds: string[] }[];
  previousVersion?: string; // Codex: the kept version "Go back" returns to
  checkedAt?: string;
  hold?: { version: string; reason: string; missing?: string[] };
  update?: {
    state: CliUpdateState;
    targetVersion?: string;
    waitingFor?: string[];
    finishedAt?: string;
    message?: string;
  };
};

// A named, ordered list of logins of any provider (docs/protocol.md,
// "Pools"). A thread in a pool runs each turn on whichever of its logins
// has room; the order of accountIds only decides which provider comes
// first.
export type Pool = {
  id: string; // "claude", "codex", "convex", or a slug Mike made
  title: string; // "Claude"
  accountIds: string[]; // in order; may mix providers
  folders?: string[]; // ~ allowed; a new thread under one starts here
  builtIn?: boolean; // from the code default, not runner.json
};

// Set on a pool thread while every login in its pool is out of room; it
// carries on by itself at `until`. accountId is the login it's waiting on.
export type WaitingForRoom = { until: string; accountId?: string };

// hello's `defaults`. `model` is Claude's, kept for apps that predate
// `models`.
export type RunnerDefaults = {
  cwd: string;
  accountId: string;
  // The pool a new thread with nothing named starts on (folder-blind: the
  // app applies a pool's folders itself).
  poolId?: string;
  model?: string;
  models?: Partial<Record<Provider, string>>;
  efforts?: Partial<Record<Provider, EffortLevel>>;
};

export type ThreadStatus = 'idle' | 'starting' | 'running' | 'waiting' | 'error' | 'stopped';

export type ThreadSummary = {
  id: string;
  title: string;
  cwd: string;
  accountId: string;
  poolId?: string; // absent: pinned to accountId
  waitingForRoom?: WaitingForRoom;
  provider: Provider;
  model?: string;
  effort?: EffortLevel;
  modelInUse?: string;
  effortInUse?: EffortLevel;
  permissionMode: PermissionMode;
  status: ThreadStatus;
  live: boolean;
  needsYou: boolean;
  // What the last completed turn said it needs from Mike, and its open
  // asks (docs/protocol.md, "Needs you").
  needs?: NeedsWho;
  asks?: OpenAsk[];
  asksSeq?: number;
  pendingReviews?: number;
  createdAt: string;
  updatedAt: string;
  lastActivityAt: string;
  snoozedUntil?: string;
  snoozedUntilRestart?: boolean; // hibernating until the runner next starts
  onOldRunner?: boolean; // finishing a turn on a runner that handed over (Handovers)
  archivedAt?: string;
  preview: string;
  lastSeq: number;
  lastSeenSeq: number;
  nativeSessionId?: string;
  contextTokens?: number;
  contextWindow?: number; // the model's window, when the CLI reports it
  costUsd?: number;
  panels?: Panel[]; // absent when the folder has none
  actions?: Action[]; // likewise
  hooks?: Hook[]; // likewise
  patches?: PatchInfo[]; // the patches that apply to the folder, built in and the project's; absent when none
  // Background sub-agents and shell jobs the live CLI is still running
  // (and ones just finished whose result it's about to read). Absent when
  // there's none.
  background?: BackgroundTask[];
  // The sub-agents the agent has started, newest 20, oldest first. Absent
  // when it has started none.
  subagents?: Subagent[];
  // The projects the thread is in, oldest first. Absent when none.
  projects?: ThreadProject[];
  // When its highlights last changed other than by a new event (a pin, a
  // removal, the librarian's brief): a client fetches threads.highlights
  // again when this or lastSeq moves.
  highlightsAt?: string;
  // Its own git worktree (docs/thread-worktrees.md). Absent when it has
  // none, or once that was removed.
  worktree?: ThreadWorktree;
  // The schedule that started it (docs/protocol.md, "Schedules"). Absent
  // for a thread a person or an agent started.
  schedule?: ThreadSchedule;
};

export type ThreadWorktree = { branch: string; mainCheckout: string; path: string };

// The schedule's title as it was when it started the thread.
export type ThreadSchedule = { id: string; title: string };

// Projects (docs/protocol.md, "Projects"): a grouping above folders that
// carries goals, state and notes forward, made by the librarian, agents or
// Mike.
export type ProjectMaker = 'mike' | 'agent' | 'librarian';

export type ThreadProject = {
  id: string;
  title: string;
  by: ProjectMaker;
  pinned?: boolean; // the librarian won't take it out
  at: string;
};

export type Project = {
  id: string;
  title: string;
  folders: string[];
  goals: string;
  state: string;
  notes: string;
  createdBy: ProjectMaker;
  createdByThread?: string;
  createdAt: string;
  updatedAt: string;
  stateUpdatedAt?: string;
  archived?: boolean;
  icon?: ProjectIcon;
  threadCount: number;
  lastActivityAt?: string;
};

// What a project shows as its icon: a picture found in its folders (or
// chosen), else an SF Symbol. Absent until the librarian has found one.
export type ProjectIcon = {
  image?: ImageRef; // a copy in the runner's data dir, at most 256 px
  symbol?: string; // an SF Symbol name, when there's no picture
  from?: string; // the file the picture was copied from
  // librarian: found by itself and kept up to date; mike or agent: chosen,
  // and left alone until set back to automatic.
  by: ProjectMaker;
  updatedAt: string;
};

export type LibrarianReason = 'first-turn' | 'new-folder' | 'moved' | 'catch-up' | 'asked';

export type LibrarianJob = {
  threadId: string;
  threadTitle: string;
  reason: LibrarianReason;
  why: string;
  dueAt: string;
};

export type LibrarianOutcome = 'joined' | 'created' | 'updated' | 'left' | 'nothing' | 'skipped' | 'failed';

export type LibrarianEntry = {
  id: string;
  at: string;
  threadId: string;
  threadTitle: string;
  reason: LibrarianReason;
  outcome: LibrarianOutcome;
  text: string;
  projectIds?: string[];
  costUsd?: number;
};

export type LibrarianStatus = {
  state: 'idle' | 'working' | 'paused' | 'off';
  reason?: string;
  paused: boolean;
  current?: LibrarianJob & { startedAt: string };
  queue: LibrarianJob[];
  recent: LibrarianEntry[];
  looksToday: number;
  spentTodayUsd: number;
};

export type SubagentStatus = 'running' | 'completed' | 'failed' | 'stopped';

// A sub-agent the thread's agent started, followed from the CLI's task
// events. threads.subagent reads what it did from the CLI's own record.
export type Subagent = {
  id: string; // the CLI's task id, which also names its transcript
  itemId?: string; // the tool.call that started it
  parentId?: string; // the sub-agent that started this one
  description: string;
  agentType?: string;
  status: SubagentStatus;
  background: boolean;
  activity?: string; // while running: what it's doing now
  summary?: string; // once finished: what it reported, one line
  toolUses?: number;
  startedAt: string;
  endedAt?: string;
};

// An action a patch gives a thread: a chip above the composer that runs a
// command in the thread's folder (its output goes into the transcript as an
// action.run event) or sends a canned prompt.
export type ActionKind = 'command' | 'prompt';
export type Action = {
  id: string; // "<patch>.<slug of the title>"
  title: string;
  kind: ActionKind;
  command?: string; // kind "command"
  prompt?: string; // kind "prompt"
  patch: string;
  folder?: string; // where the command runs; absent: the thread's folder
  projectId?: string; // the project whose folder gave it
  note?: string;
};

// A hook a patch gives a thread: a command the runner runs by itself when
// something happens (for now, when a turn completes), posted into the
// transcript like an action, and told to the agent as a new message when
// `tell` says so.
export type HookTrigger = 'turn.end';
export type HookTell = 'failures' | 'always' | 'never';
export type Hook = {
  id: string; // "<patch>.<slug of the title>"
  title: string;
  on: HookTrigger;
  command: string;
  edited?: string; // only after a turn that edited a file matching this glob (relative to the folder)
  tell: HookTell; // when the result goes to the agent as a message
  patch: string;
  folder?: string; // as Action's; only edits inside it count
  projectId?: string;
  note?: string;
};

// A patch that applies to a thread's folder and where it came from.
export type PatchSource = 'builtin' | 'home' | 'project';
export type PatchInfo = {
  id: string;
  source: PatchSource;
  file?: string; // the module, for home and project patches
  folder?: string; // the folder it applies from
  projectId?: string; // set when it came from a project's folder
  error?: string; // set when the file couldn't be loaded; it then gives nothing
};

// A panel a patch gives a thread (docs/protocol.md, "Panels"). The runner
// works them out from the thread's folder; nothing is persisted.
export type PanelKind = 'url' | 'image' | 'list';
export type Panel = {
  id: string; // unique within the thread, e.g. "convex.dashboard"
  title: string; // the tab's label
  kind: PanelKind;
  url?: string; // kind "url": what the panel shows and what Open in browser opens
  icon?: string; // an SF Symbol name for its button on the app's right-hand rail
  patch: string; // the patch it came from: "convex", "xcode"
  projectId?: string;
  note?: string; // one line about it: the deployment name, the booted device
};

// One row of a `list` panel, as its patch's `items` function returns it.
export type PanelItem = {
  title: string;
  detail?: string;
  url?: string;
  path?: string;
  icon?: string;
  tone?: 'attention' | 'failed' | 'done';
};

export type BackgroundKind = 'agent' | 'shell' | 'monitor' | 'other';

export type BackgroundTask = {
  kind: BackgroundKind;
  description: string;
  finished?: boolean;
};

// "2 sub-agents, 1 shell job in the background" for tb list's flags; '' with none.
export function backgroundFlag(tasks: BackgroundTask[] | undefined): string {
  if (!tasks?.length) return '';
  const running = tasks.filter((t) => !t.finished);
  const count = (kind: string, one: string, many: string): string => {
    const n = running.filter((t) => t.kind === kind).length;
    return n === 0 ? '' : n === 1 ? `1 ${one}` : `${n} ${many}`;
  };
  const parts = [count('agent', 'sub-agent', 'sub-agents'), count('shell', 'shell job', 'shell jobs'), count('monitor', 'monitor', 'monitors'), count('other', 'background task', 'background tasks')].filter(Boolean);
  const finished = tasks.length - running.length;
  if (finished) parts.push(`${finished} just finished`);
  return parts.join(', ') + (running.length ? ' in the background' : '');
}


export type ImageRef = {
  path: string;
  mediaType: string;
  width?: number;
  height?: number;
};

// 'image' is image generation.
export type ToolKind = 'command' | 'read' | 'edit' | 'write' | 'search' | 'web' | 'mcp' | 'task' | 'todo' | 'image' | 'other';

export type Hunk = {
  oldStart: number;
  oldLines: number;
  newStart: number;
  newLines: number;
  lines: string[];
};

export type PlanEntry = { text: string; status: 'pending' | 'in_progress' | 'completed' };

export type ApprovalOption = 'allow' | 'allowAlways' | 'deny';
export type ApprovalDecision = 'allow' | 'allowAlways' | 'deny' | 'answered' | 'expired';

export type Question = {
  question: string;
  header?: string;
  multiSelect: boolean;
  options: { label: string; description?: string }[];
};

export type TurnOutcome = 'completed' | 'interrupted' | 'failed';

// Why a failed turn failed, when it's known, so a client can offer the fix
// (another account, a new thread, signing in) without reading `error`.
export type TurnErrorKind = 'usageLimit' | 'contextWindow' | 'auth';

// turn.completed's `usage`, per provider.
export type ClaudeTurnUsage = { inputTokens: number; outputTokens: number; cacheReadTokens: number; cacheWriteTokens: number };
export type CodexTurnUsage = {
  inputTokens: number;
  cachedInputTokens: number;
  cacheWriteTokens?: number;
  outputTokens: number;
  reasoningTokens: number;
};

export type ReviewDraft = { pickedId?: string; notes: Record<string, string> };

export type DesignReview = {
  id: string;
  title: string;
  note?: string;
  options: { id: string; title: string; note?: string; reference?: boolean; image: ImageRef }[];
  status: 'pending' | 'answered' | 'cancelled';
  revision: number;
  createdAt: string;
  updatedAt: string;
  draft: ReviewDraft;
  response?: ReviewDraft;
  replyTurnId?: string;
};

// Persisted event bodies, without the envelope.
export type EventBody =
  | { type: 'review.updated'; review: DesignReview }
  // origin is set only on messages the runner sent by itself (the resume
  // after a restart).
  | { type: 'user.message'; text: string; images: ImageRef[]; origin?: MessageOrigin; scheduleId?: string; reviewId?: string; reviewResponse?: ReviewDraft }
  | { type: 'assistant.text'; itemId: string; text: string }
  | { type: 'reasoning'; itemId: string; text: string }
  | { type: 'tool.call'; itemId: string; name: string; kind: ToolKind; title: string; input: Record<string, unknown> }
  | {
      type: 'tool.result';
      itemId: string;
      ok: boolean;
      text: string;
      truncated: boolean;
      blobPath?: string;
      images: ImageRef[];
    }
  // One per file: a repeated path on the same itemId replaces that file's
  // diff, a new path adds one.
  | { type: 'edit.diff'; itemId: string; path: string; hunks: Hunk[] }
  | {
      type: 'approval.requested';
      approvalId: string;
      itemId?: string;
      name: string;
      title: string;
      input: Record<string, unknown>;
      options: ApprovalOption[];
    }
  | { type: 'question.requested'; approvalId: string; itemId?: string; questions: Question[] }
  | { type: 'approval.resolved'; approvalId: string; decision: ApprovalDecision; message?: string }
  | { type: 'plan.updated'; entries: PlanEntry[] }
  | { type: 'turn.started'; turnId: string }
  | {
      type: 'turn.completed';
      turnId: string;
      outcome: TurnOutcome;
      durationMs: number;
      costUsd?: number; // Codex turns have none
      usage?: ClaudeTurnUsage | CodexTurnUsage | Record<string, unknown>;
      error?: string;
      errorKind?: TurnErrorKind;
      needs?: NeedsWho;
      asks?: Ask[];
      needsFrom?: 'tool' | 'text';
    }
  // The ticks on a card of asks, the whole set each time. Outside any turn.
  | { type: 'asks.ticked'; asksSeq: number; ticked: number[] }
  | { type: 'system.note'; text: string }
  | { type: 'error'; message: string }
  // A command action that ran (patches.ts): its output, truncated like a
  // tool result. Outside any turn.
  | {
      type: 'action.run';
      actionId: string;
      patch: string;
      title: string;
      command: string;
      ok: boolean;
      exitCode?: number;
      text: string;
      truncated: boolean;
      durationMs: number;
      trigger?: HookTrigger | 'worktree.setup'; // set when a hook or a new worktree's setup ran it, absent for a chip or tb run
    };

export type DeltaType = 'assistant.text.delta' | 'reasoning.delta' | 'tool.output.delta';
export type DeltaBody = { type: DeltaType; itemId: string; text: string };

export type Envelope = {
  seq: number;
  ts: string;
  threadId: string;
  turnId?: string;
};

// What a finished turn needs from Mike (docs/protocol.md, "Needs you").
export type NeedsWho = 'you' | 'nothing';
export type Ask = { action: string; where?: string; reply?: string };
export type OpenAsk = Ask & { ticked?: true };

export type PersistedEvent = Envelope & EventBody;
export type TransientEvent = Envelope & DeltaBody;
export type AnyEvent = PersistedEvent | TransientEvent;

export const PERSISTED_TYPES = new Set<string>([
  'review.updated',
  'user.message',
  'assistant.text',
  'reasoning',
  'tool.call',
  'tool.result',
  'edit.diff',
  'approval.requested',
  'question.requested',
  'approval.resolved',
  'plan.updated',
  'turn.started',
  'turn.completed',
  'asks.ticked',
  'system.note',
  'error',
  'action.run',
]);

export const TRANSIENT_TYPES = new Set<string>(['assistant.text.delta', 'reasoning.delta', 'tool.output.delta']);

export type InProgressItem = { itemId: string; type: 'assistant.text' | 'reasoning'; text: string };

// JSON-RPC error codes from docs/protocol.md.
// A message sent at a set time, once (at) or over and over (cron). See
// "Schedules" in docs/protocol.md.
export type Schedule = {
  id: string;
  title: string;
  text: string;
  at?: string;
  cron?: string;
  timezone?: string;
  whenText: string;
  threadId?: string;
  cwd?: string;
  accountId?: string;
  model?: string;
  effort?: EffortLevel;
  permissionMode?: PermissionMode;
  paused: boolean;
  createdAt: string;
  updatedAt: string;
  createdBy?: string;
  nextRunAt?: string;
  finishedAt?: string;
  runs: number;
  lastRun?: { at: string; outcome: 'sent' | 'skipped' | 'failed'; threadId?: string; note?: string };
};

// Who sent a message when it wasn't a person or a client: the runner by
// itself (the resume after a restart), or a schedule (schedules.ts).
export type MessageOrigin = 'runner' | 'schedule';

export const ErrorCode = {
  parseError: -32700,
  invalidRequest: -32600,
  methodNotFound: -32601,
  badParams: -32602,
  threadNotFound: -32004,
  scheduleNotFound: -32005,
  subagentNotFound: -32006,
  projectNotFound: -32007,
  accountNotFound: -32010,
  busy: -32020,
  moved: -32030, // a draining runner has handed the thread over (Handovers)
  other: -32000,
} as const;

export class RpcError extends Error {
  code: number;
  data?: unknown;
  constructor(code: number, message: string, data?: unknown) {
    super(message);
    this.code = code;
    this.data = data;
  }
}

export const LIMITS = {
  toolInputString: 16 * 1024,
  toolResultText: 64 * 1024,
  previewChars: 140,
  titleChars: 60,
  defaultEventsLimit: 500,
};
