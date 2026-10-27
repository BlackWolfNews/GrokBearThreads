// The seam between the runner and a provider CLI. The runner owns threads,
// turns, persistence and the protocol; an adapter only drives one CLI
// process per live thread and reports normalised output. Codex will be a
// second implementation of AgentAdapter.
import type { Account, BackgroundKind, DeltaBody, EffortLevel, EventBody, ImageRef, ModelChoice, PermissionMode, Question, TurnOutcome } from '../protocol.ts';

export type StartSessionOptions = {
  threadId: string;
  cwd: string;
  account: Account;
  model?: string;
  effort?: EffortLevel; // undefined: the model's own level
  permissionMode: PermissionMode;
  // Native session id. With resume=false it's pre-assigned to a brand new
  // session; with resume=true the CLI loads that session's transcript.
  sessionId: string;
  resume: boolean;
  mediaDir: string; // images from tool results are saved here
  blobsDir: string; // tool output over 64 KB is saved here
  tmpDir: string;
  // Permission rules the user chose "Always allow" for in this thread, in
  // the CLI's rule syntax ("Bash(npm test)", "Write"). Applied on start so
  // they outlast an idle release.
  allowRules?: string[];
  // Added to the CLI's environment (THREADBARE_THREAD_ID and friends), so
  // the commands it runs know which thread they belong to.
  env?: Record<string, string>;
};

export type TurnResult = {
  outcome: TurnOutcome;
  // The CLI ran this turn by itself (a background task or subagent
  // finished) rather than to answer a message the runner sent.
  own?: boolean;
  // The id (UserInput.id) of the message this turn answered, when the CLI
  // says (command_lifecycle frames). With a message folded into the turn
  // part way (sent while it ran), this is the last one folded in.
  answers?: string;
  // Every message this turn answered, in the order the CLI took them:
  // messages sent close together that ran as one turn, then any folded in
  // while it ran. Absent from CLIs that don't report it (then `answers`).
  answered?: string[];
  // Messages still waiting in the CLI's queue when this result was
  // produced, when the CLI reports it: it runs them next, without being
  // sent anything.
  queuedTurns?: number;
  durationMs: number;
  totalCostUsd?: number; // provider's running total for the native session
  usage?: Record<string, unknown>;
  error?: string;
};

export type AdapterOutput =
  | { kind: 'event'; event: EventBody }
  | { kind: 'delta'; delta: DeltaBody }
  | { kind: 'session'; nativeSessionId: string; model?: string }
  // The effort level the CLI applied to the turn that just ended.
  | { kind: 'effort'; level: EffortLevel }
  | { kind: 'context'; contextTokens: number }
  // The CLI started a turn of its own; `note` says why, when it's known.
  | { kind: 'cliTurn'; note?: string }
  // Background work the CLI is running (shells, async subagents). Replaces
  // the previous list.
  | { kind: 'tasks'; tasks: BackgroundTask[] }
  // "Always allow" rules to keep for this thread.
  | { kind: 'allowRules'; rules: string[] }
  | { kind: 'result'; result: TurnResult };

// A background shell or subagent the CLI reports. `type` is the CLI's own
// name for it (Claude: local_bash, local_agent, ...), `kind` the protocol's.
export type BackgroundTask = { id: string; type: string; kind: BackgroundKind; description: string };

export type ToolApprovalRequest = {
  toolUseId?: string; // left out for a subagent's tools, which have no tool.call
  name: string;
  title: string;
  input: Record<string, unknown>;
  canAlwaysAllow: boolean;
  signal: AbortSignal;
};

export type ToolApprovalAnswer = { decision: 'allow' | 'allowAlways' | 'deny' | 'expired'; message?: string };

export type QuestionRequest = {
  toolUseId?: string;
  questions: Question[];
  signal: AbortSignal;
};

// answers: question text -> chosen label(s); null when dismissed or expired.
export type QuestionAnswer = { answers: Record<string, string> | null; message?: string };

export interface SessionSink {
  output(o: AdapterOutput): void;
  requestApproval(req: ToolApprovalRequest): Promise<ToolApprovalAnswer>;
  requestQuestion(req: QuestionRequest): Promise<QuestionAnswer>;
  // The CLI process is gone (input ended, crashed or killed).
  exited(error?: Error): void;
}

// id is the runner's turnId; the CLI echoes it so its turns can be told
// apart from ones it starts by itself.
export type UserInput = { id?: string; text: string; images: ImageRef[] };

export interface AgentSession {
  // Starts one turn. The runner never calls this while a turn is running.
  send(input: UserInput): void;
  interrupt(): Promise<void>;
  setModel(model: string | undefined): Promise<void>;
  setEffort(effort: EffortLevel | undefined): Promise<void>;
  setPermissionMode(mode: PermissionMode): Promise<void>;
  // Ends the input so the CLI finishes and exits. Resolves once it has.
  // With hard set it stops the CLI straight away instead (background work
  // it is waiting for would otherwise keep it alive).
  end(opts?: { hard?: boolean }): Promise<void>;
  // Hard stop: kills the CLI's process group.
  kill(): void;
}

export interface AgentAdapter {
  readonly provider: string;
  start(opts: StartSessionOptions, sink: SessionSink): AgentSession;
  // What the account's CLI offers as models, without starting a turn.
  // Optional: a provider without a picker leaves it out.
  models?(account: Account): Promise<ModelChoice[]>;
}
