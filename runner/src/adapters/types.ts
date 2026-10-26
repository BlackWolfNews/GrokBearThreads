// The seam between the runner and a provider CLI. The runner owns threads,
// turns, persistence and the protocol; an adapter only drives one CLI
// process per live thread and reports normalised output. Codex will be a
// second implementation of AgentAdapter.
import type { Account, DeltaBody, EventBody, ImageRef, PermissionMode, Question, TurnOutcome } from '../protocol.ts';

export type StartSessionOptions = {
  threadId: string;
  cwd: string;
  account: Account;
  model?: string;
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
};

export type TurnResult = {
  outcome: TurnOutcome;
  // The CLI ran this turn by itself (a background task or subagent
  // finished) rather than to answer a message the runner sent.
  own?: boolean;
  // The id (UserInput.id) of the message this turn answered, when the CLI
  // says (command_lifecycle frames).
  answers?: string;
  durationMs: number;
  totalCostUsd?: number; // provider's running total for the native session
  usage?: Record<string, unknown>;
  error?: string;
};

export type AdapterOutput =
  | { kind: 'event'; event: EventBody }
  | { kind: 'delta'; delta: DeltaBody }
  | { kind: 'session'; nativeSessionId: string; model?: string }
  | { kind: 'context'; contextTokens: number }
  // The CLI started a turn of its own; `note` says why, when it's known.
  | { kind: 'cliTurn'; note?: string }
  // Background work the CLI is running (shells, async subagents). Replaces
  // the previous list.
  | { kind: 'tasks'; tasks: BackgroundTask[] }
  // "Always allow" rules to keep for this thread.
  | { kind: 'allowRules'; rules: string[] }
  | { kind: 'result'; result: TurnResult };

export type BackgroundTask = { id: string; type: string; description: string };

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
}
