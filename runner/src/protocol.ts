// Types for the runner protocol. docs/protocol.md is the contract; keep this
// file in step with it. Both sides ignore unknown fields, so extra internal
// fields never leak out: summaries are built explicitly by toSummary().

export const PROTOCOL_VERSION = 1;

export type Provider = 'claude';
export type PermissionMode = 'full' | 'ask';
export type EffortLevel = 'low' | 'medium' | 'high' | 'xhigh' | 'max';
export const EFFORT_LEVELS: readonly EffortLevel[] = ['low', 'medium', 'high', 'xhigh', 'max'];

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
};

export type Account = {
  id: string;
  provider: Provider;
  title: string;
  configDir: string;
  // The full id a thread with no model runs on, once known (the account's
  // settings, corrected by the first turn seen); and the CLI's model list.
  defaultModel?: string;
  models?: ModelChoice[];
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
  costUsd?: number;
};

export type ImageRef = {
  path: string;
  mediaType: string;
  width?: number;
  height?: number;
};

export type ToolKind = 'command' | 'read' | 'edit' | 'write' | 'search' | 'web' | 'mcp' | 'task' | 'todo' | 'other';

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
      costUsd?: number;
      usage?: Record<string, unknown>;
      error?: string;
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
