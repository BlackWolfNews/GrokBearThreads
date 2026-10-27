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
  // Codex: Threadbare's own copies; Claude: its own installer; 'none' when
  // codexPath is set by hand and never updated.
  managedBy: 'threadbare' | 'cli' | 'none';
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

// hello's `defaults`. `model` is Claude's, kept for apps that predate
// `models`.
export type RunnerDefaults = {
  cwd: string;
  accountId: string;
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
  provider: Provider;
  model?: string;
  effort?: EffortLevel;
  modelInUse?: string;
  effortInUse?: EffortLevel;
  permissionMode: PermissionMode;
  status: ThreadStatus;
  live: boolean;
  needsYou: boolean;
  createdAt: string;
  updatedAt: string;
  lastActivityAt: string;
  snoozedUntil?: string;
  archivedAt?: string;
  preview: string;
  lastSeq: number;
  lastSeenSeq: number;
  nativeSessionId?: string;
  contextTokens?: number;
  contextWindow?: number; // the model's window, when the CLI reports it
  costUsd?: number;
};

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

// Persisted event bodies, without the envelope.
export type EventBody =
  // origin is set only on messages the runner sent by itself (the resume
  // after a restart).
  | { type: 'user.message'; text: string; images: ImageRef[]; origin?: 'runner' }
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
    }
  | { type: 'system.note'; text: string }
  | { type: 'error'; message: string };

export type DeltaType = 'assistant.text.delta' | 'reasoning.delta' | 'tool.output.delta';
export type DeltaBody = { type: DeltaType; itemId: string; text: string };

export type Envelope = {
  seq: number;
  ts: string;
  threadId: string;
  turnId?: string;
};

export type PersistedEvent = Envelope & EventBody;
export type TransientEvent = Envelope & DeltaBody;
export type AnyEvent = PersistedEvent | TransientEvent;

export const PERSISTED_TYPES = new Set<string>([
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
  'system.note',
  'error',
]);

export const TRANSIENT_TYPES = new Set<string>(['assistant.text.delta', 'reasoning.delta', 'tool.output.delta']);

export type InProgressItem = { itemId: string; type: 'assistant.text' | 'reasoning'; text: string };

// JSON-RPC error codes from docs/protocol.md.
export const ErrorCode = {
  parseError: -32700,
  invalidRequest: -32600,
  methodNotFound: -32601,
  badParams: -32602,
  threadNotFound: -32004,
  accountNotFound: -32010,
  busy: -32020,
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
