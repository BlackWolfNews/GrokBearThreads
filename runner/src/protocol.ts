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
  note?: string;
};

// A patch that applies to a thread's folder and where it came from.
export type PatchSource = 'builtin' | 'home' | 'project';
export type PatchInfo = {
  id: string;
  source: PatchSource;
  file?: string; // the module, for home and project patches
  error?: string; // set when the file couldn't be loaded; it then gives nothing
};

// A panel a patch gives a thread (docs/protocol.md, "Panels"). The runner
// works them out from the thread's folder; nothing is persisted.
export type PanelKind = 'url' | 'image';
export type Panel = {
  id: string; // unique within the thread, e.g. "convex.dashboard"
  title: string; // the tab's label
  kind: PanelKind;
  url?: string; // kind "url": what the panel shows and what Open in browser opens
  patch: string; // the patch it came from: "convex", "xcode"
  note?: string; // one line about it: the deployment name, the booted device
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
  | { type: 'user.message'; text: string; images: ImageRef[]; origin?: MessageOrigin; scheduleId?: string }
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
      trigger?: HookTrigger; // set when a hook ran it, absent for a chip or tb run
    };

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
