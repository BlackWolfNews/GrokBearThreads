import crypto from 'node:crypto';
import os from 'node:os';
import { query as sdkQuery } from '@anthropic-ai/claude-agent-sdk';
import type { HookInput, McpServerConfig, ModelInfo, Options, PermissionResult, Query, SDKUserMessage, PermissionUpdate } from '@anthropic-ai/claude-agent-sdk';
import type { Account, EffortLevel, ModelChoice, PermissionMode, Question } from '../../protocol.ts';
import { isEffortLevel } from '../../protocol.ts';
import fs from 'node:fs';
import type { AgentAdapter, AgentSession, RewindRequest, RewindResult, SessionSink, StartSessionOptions, UserInput } from '../types.ts';
import { RewindRefusedError } from '../types.ts';
import { cutPointBefore, sessionTranscriptPath } from '../../transcripts.ts';
import type { Logger } from '../../log.ts';
import { ClaudeNormalizer, fileContext } from './normalize.ts';
import { groupSpawner, type ProcessRegistry } from '../../proc.ts';
import { prepareImageForModel } from '../../media.ts';
import { toolTitle, truncateInput } from '../../tools.ts';
import { RUNNER_VERSION } from '../../config.ts';
import { stripModelSuffix } from '../../accounts.ts';
import { END_TURN_FULL_NAME } from '../../needs.ts';

// Variables a parent Claude Code session sets for its own children. If the
// runner was started from inside one (tests, a terminal in T3), they would
// make the CLI think it's nested, so they're dropped.
const INHERITED_SESSION_VARS = [
  'CLAUDECODE',
  'CLAUDE_CODE_ENTRYPOINT',
  'CLAUDE_CODE_CHILD_SESSION',
  'CLAUDE_CODE_EXECPATH',
  'CLAUDE_CODE_MESSAGING_SOCKET',
  'CLAUDE_CODE_MESSAGING_TOKEN',
  'CLAUDE_CODE_SESSION_ATTENDED',
  'CLAUDE_CODE_SESSION_ID',
  'CLAUDE_CODE_SSE_PORT',
  'CLAUDE_PID',
  'CLAUDE_EFFORT',
  'CLAUDE_AGENT_SDK_VERSION',
  'AI_AGENT',
];

export function cliEnv(account: Account, base: NodeJS.ProcessEnv = process.env): Record<string, string | undefined> {
  const env: Record<string, string | undefined> = { ...base };
  for (const k of INHERITED_SESSION_VARS) delete env[k];
  if (account.id === 'claude-main') delete env.CLAUDE_CONFIG_DIR;
  else env.CLAUDE_CONFIG_DIR = account.configDir;
  env.CLAUDE_AGENT_SDK_CLIENT_APP = `threadbear-runner/${RUNNER_VERSION}`;
  return env;
}

// The MCP tools whose successful result ends a turn, for the CLI's
// CLAUDE_CODE_TERMINAL_MCP_TOOLS (2.1.312; older CLIs ignore it). Without
// it, a model that stops after a tool result with no text (end_turn is the
// last thing in every turn, and the model obeys "no more text") is nudged
// with "[Your previous response had no visible output. Please continue and
// produce a user-visible response.]" and writes a throwaway "I've marked
// this thread as done" under the real answer: 47 of the 52 such nudges in
// Mike's local CLI transcripts followed an end_turn (28 Oct 2026). Named
// there, end_turn's result lets the empty reply end the turn quietly. Any
// names already in the variable stay.
export function terminalMcpTools(base: string | undefined): string {
  const names = (base ?? '').split(',').map((s) => s.trim()).filter(Boolean);
  if (!names.includes(END_TURN_FULL_NAME)) names.push(END_TURN_FULL_NAME);
  return names.join(',');
}

export function sdkPermissionMode(mode: PermissionMode): 'bypassPermissions' | 'default' {
  return mode === 'full' ? 'bypassPermissions' : 'default';
}

// Streaming input for query(): the runner pushes one user message per turn
// and ends it to let the CLI exit.
class InputQueue implements AsyncIterable<SDKUserMessage> {
  private items: SDKUserMessage[] = [];
  private wake: (() => void) | null = null;
  private ended = false;

  push(m: SDKUserMessage): void {
    if (this.ended) throw new Error('input already ended');
    this.items.push(m);
    this.wake?.();
  }

  end(): void {
    this.ended = true;
    this.wake?.();
  }

  get isEnded(): boolean {
    return this.ended;
  }

  async *[Symbol.asyncIterator](): AsyncIterator<SDKUserMessage> {
    for (;;) {
      while (this.items.length) yield this.items.shift()!;
      if (this.ended) return;
      await new Promise<void>((r) => (this.wake = r));
      this.wake = null;
    }
  }
}

export type ClaudeAdapterDeps = {
  claudePath: string;
  registry: ProcessRegistry;
  log: Logger;
  queryFn?: typeof sdkQuery;
  // In-process MCP servers for a thread's session (the threadbear tools).
  mcpServersFor?: (threadId: string) => Record<string, McpServerConfig>;
  // Tools that ask Mike even in a thread with full access.
  alwaysAsk?: Set<string>;
};

export class ClaudeAdapter implements AgentAdapter {
  readonly provider = 'claude';
  private deps: ClaudeAdapterDeps;

  constructor(deps: ClaudeAdapterDeps) {
    this.deps = deps;
  }

  start(opts: StartSessionOptions, sink: SessionSink): AgentSession {
    const s = new ClaudeSession(opts, sink, this.deps);
    s.start();
    return s;
  }

  // Asks the account's CLI what its model picker offers. Starting the CLI
  // with no prompt is enough: it answers initialize without a turn (under
  // a second, no tokens), and is closed straight after.
  async models(account: Account): Promise<ModelChoice[]> {
    const { deps } = this;
    const never = { async *[Symbol.asyncIterator]() { await new Promise<never>(() => {}); } } as AsyncIterable<SDKUserMessage>;
    const abort = new AbortController();
    const options: Options = {
      cwd: os.homedir(),
      pathToClaudeCodeExecutable: deps.claudePath,
      env: cliEnv(account),
      settingSources: ['user', 'project', 'local'],
      tools: [],
      abortController: abort,
      spawnClaudeCodeProcess: groupSpawner(deps.registry, deps.log, () => {}, `models:${account.id}`),
    };
    const queryFn = deps.queryFn ?? sdkQuery;
    const q = queryFn({ prompt: never, options });
    try {
      const init = await q.initializationResult();
      return modelChoices(init.models ?? []);
    } finally {
      try {
        q.close();
      } catch {
        // already closed
      }
      abort.abort();
    }
  }

  // An edit of an earlier message (docs/protocol.md, "Editing a message").
  // The conversation is cut by the next start (resumeAt); here the
  // transcript says where, and a CLI started on the session with no turn
  // rewinds the files its checkpoints cover to how they were when the
  // message arrived. The SDK keys checkpoints by the message's uuid, which
  // is the runner's id for it.
  async rewind(req: RewindRequest): Promise<RewindResult> {
    const file = sessionTranscriptPath(req.account.configDir, req.cwd, req.sessionId);
    const cut = file ? cutPointBefore(fs.readFileSync(file, 'utf8'), req.messageId) : null;
    if (!cut) throw new RewindRefusedError("This message isn't in the thread's current session (it has moved to another login or folder since), so it can't be edited.");
    const files = await this.rewindFiles(req);
    return { ...(cut.first ? { fresh: true } : { resumeAt: cut.resumeAt }), ...(files ? { files } : {}) };
  }

  private async rewindFiles(req: RewindRequest): Promise<RewindResult['files']> {
    const { deps } = this;
    const never = { async *[Symbol.asyncIterator]() { await new Promise<never>(() => {}); } } as AsyncIterable<SDKUserMessage>;
    const abort = new AbortController();
    const options: Options = {
      cwd: req.cwd,
      pathToClaudeCodeExecutable: deps.claudePath,
      env: cliEnv(req.account),
      // No settings: nothing runs but the rewind, hooks included.
      settingSources: [],
      tools: [],
      resume: req.sessionId,
      enableFileCheckpointing: true,
      abortController: abort,
      spawnClaudeCodeProcess: groupSpawner(deps.registry, deps.log, () => {}, `rewind:${req.threadId}`),
    };
    const q = (deps.queryFn ?? sdkQuery)({ prompt: never, options });
    try {
      await q.initializationResult();
      // The dry run lists what will change; the real one doesn't.
      const plan = await q.rewindFiles(req.messageId, { dryRun: true });
      if (!plan.canRewind) {
        // No checkpoint for it: a session from before checkpoints were on.
        deps.log.info('no file checkpoint to rewind to', { threadId: req.threadId, error: plan.error });
        return undefined;
      }
      const done = await q.rewindFiles(req.messageId);
      if (!done.canRewind) return { undone: [], failed: (plan.filesChanged ?? []).map((p) => ({ path: p, reason: done.error || "Couldn't put it back." })) };
      const failed = done.skippedLinks ? [{ path: `${done.skippedLinks} linked file${done.skippedLinks === 1 ? '' : 's'}`, reason: 'Left alone, as it is a link.' }] : [];
      return { undone: plan.filesChanged ?? [], failed };
    } catch (e) {
      deps.log.warn('could not rewind files', { threadId: req.threadId, error: String(e) });
      return undefined;
    } finally {
      try {
        q.close();
      } catch {
        // already closed
      }
      abort.abort();
    }
  }
}

// The CLI's rows as the protocol's ModelChoice. The "default" row stands
// for whatever the CLI would pick, which the account's settings can
// override, so it's left out: the runner works the default out itself.
export function modelChoices(rows: ModelInfo[]): ModelChoice[] {
  const out: ModelChoice[] = [];
  for (const row of rows) {
    if (!row || typeof row.value !== 'string' || !row.value || row.value === 'default') continue;
    const choice: ModelChoice = {
      id: row.value,
      model: typeof row.resolvedModel === 'string' && row.resolvedModel ? row.resolvedModel : stripModelSuffix(row.value),
      title: typeof row.displayName === 'string' && row.displayName ? row.displayName : row.value,
    };
    if (typeof row.description === 'string' && row.description) choice.description = row.description;
    if (row.supportsEffort && Array.isArray(row.supportedEffortLevels)) {
      const levels = row.supportedEffortLevels.filter(isEffortLevel);
      if (levels.length) choice.effortLevels = levels;
    }
    out.push(choice);
  }
  return out;
}

class ClaudeSession implements AgentSession {
  private opts: StartSessionOptions;
  private sink: SessionSink;
  private deps: ClaudeAdapterDeps;
  private input = new InputQueue();
  private q!: Query;
  private abort = new AbortController();
  private normalizer: ClaudeNormalizer;
  private mode: PermissionMode;
  private exited = false;
  private exitPromise: Promise<void>;
  private resolveExit!: () => void;
  private stderrTail: string[] = [];
  private seenTools = new Set<string>();
  private toolWaiters = new Map<string, (() => void)[]>();

  constructor(opts: StartSessionOptions, sink: SessionSink, deps: ClaudeAdapterDeps) {
    this.opts = opts;
    this.sink = sink;
    this.deps = deps;
    this.mode = opts.permissionMode;
    this.normalizer = new ClaudeNormalizer(fileContext(opts.cwd, opts.mediaDir, opts.blobsDir));
    this.exitPromise = new Promise((r) => (this.resolveExit = r));
  }

  start(): void {
    const { opts, deps } = this;
    const env = cliEnv(opts.account);
    const options: Options = {
      cwd: opts.cwd,
      pathToClaudeCodeExecutable: deps.claudePath,
      env: { ...env, CLAUDE_CODE_TERMINAL_MCP_TOOLS: terminalMcpTools(env.CLAUDE_CODE_TERMINAL_MCP_TOOLS), ...opts.env },
      settingSources: ['user', 'project', 'local'],
      systemPrompt: { type: 'preset', preset: 'claude_code', ...(opts.instructions ? { append: opts.instructions } : {}) },
      includePartialMessages: true,
      thinking: { type: 'adaptive', display: 'summarized' },
      // Backups of the files the session's tools change, so an edit of an
      // earlier message can put them back (rewind below).
      enableFileCheckpointing: true,
      permissionMode: sdkPermissionMode(opts.permissionMode),
      // Always allowed so "Ask before edits" can be switched off mid-session.
      allowDangerouslySkipPermissions: true,
      canUseTool: (name, input, o) => this.canUseTool(name, input, o),
      // The CLI says which effort level a turn ran at (after its own
      // defaults and any downgrade) only through hooks; Stop fires once a
      // turn, and is the cheapest place to read it.
      hooks: { Stop: [{ hooks: [(input) => this.onStop(input)] }] },
      abortController: this.abort,
      spawnClaudeCodeProcess: groupSpawner(deps.registry, deps.log, (line) => this.stderr(line), opts.threadId),
    };
    const servers = deps.mcpServersFor?.(opts.threadId);
    if (servers && Object.keys(servers).length) options.mcpServers = servers;
    if (opts.model) options.model = opts.model;
    const effort = claudeEffort(opts.effort);
    if (effort) options.effort = effort;
    if (opts.allowRules?.length) options.allowedTools = [...opts.allowRules];
    if (opts.resume) {
      options.resume = opts.sessionId;
      if (opts.resumeAt) options.resumeSessionAt = opts.resumeAt;
    } else options.sessionId = opts.sessionId;
    const queryFn = deps.queryFn ?? sdkQuery;
    this.q = queryFn({ prompt: this.input, options });
    void this.pump();
  }

  private async onStop(input: HookInput): Promise<Record<string, never>> {
    const level = (input as { effort?: { level?: unknown } }).effort?.level;
    if (isEffortLevel(level)) this.sink.output({ kind: 'effort', level });
    return {};
  }

  private stderr(line: string): void {
    if (!line.trim()) return;
    this.stderrTail.push(line);
    if (this.stderrTail.length > 20) this.stderrTail.shift();
    this.deps.log.debug('cli stderr', { threadId: this.opts.threadId, line: line.slice(0, 500) });
  }

  private async pump(): Promise<void> {
    let error: Error | undefined;
    try {
      for await (const msg of this.q) {
        for (const out of this.normalizer.handle(msg as Record<string, unknown>)) {
          this.sink.output(out);
          if (out.kind === 'event' && out.event.type === 'tool.call') this.markToolSeen(out.event.itemId);
        }
      }
    } catch (e) {
      error = e instanceof Error ? e : new Error(String(e));
      const tail = this.stderrTail.filter((l) => !/enterprise policy/i.test(l)).slice(-5).join('\n');
      if (tail && !error.message.includes(tail)) error = new Error(`${error.message}\n${tail}`);
    } finally {
      this.exited = true;
      for (const ws of this.toolWaiters.values()) ws.forEach((w) => w());
      this.toolWaiters.clear();
      this.resolveExit();
      this.sink.exited(error);
    }
  }

  private markToolSeen(id: string): void {
    this.seenTools.add(id);
    const ws = this.toolWaiters.get(id);
    if (ws) {
      this.toolWaiters.delete(id);
      ws.forEach((w) => w());
    }
  }

  // The SDK can call canUseTool before the assistant frame carrying the
  // tool_use has come out of the message iterator. Waiting for it keeps the
  // event order tool.call -> edit.diff -> approval.requested.
  private waitForTool(id: string | undefined, ms: number): Promise<void> {
    if (!id || this.seenTools.has(id) || this.exited) return Promise.resolve();
    return new Promise((resolve) => {
      const t = setTimeout(resolve, ms);
      const list = this.toolWaiters.get(id) ?? [];
      list.push(() => {
        clearTimeout(t);
        resolve();
      });
      this.toolWaiters.set(id, list);
    });
  }

  private async canUseTool(
    name: string,
    input: Record<string, unknown>,
    o: { signal: AbortSignal; suggestions?: PermissionUpdate[]; toolUseID: string; title?: string; suppressAlwaysAllowRule?: boolean; agentID?: string },
  ): Promise<PermissionResult> {
    // A subagent's tool calls stay inside its Agent call (the normaliser
    // drops them), so there's no tool.call to wait for or point at.
    const sub = Boolean(o.agentID);
    const itemId = sub ? undefined : o.toolUseID;
    if (!sub) await this.waitForTool(o.toolUseID, 2000);
    if (name === 'AskUserQuestion') {
      const questions = normaliseQuestions(input.questions);
      const ans = await this.sink.requestQuestion({ toolUseId: itemId, questions, signal: o.signal });
      if (ans.answers) return { behavior: 'allow', updatedInput: { ...input, answers: ans.answers }, toolUseID: o.toolUseID };
      return { behavior: 'deny', message: ans.message || 'The user dismissed the question without answering.', toolUseID: o.toolUseID };
    }
    if (this.mode === 'full' && !this.deps.alwaysAsk?.has(name)) return { behavior: 'allow', updatedInput: input, toolUseID: o.toolUseID };
    if (!sub) for (const out of this.normalizer.beforeApproval(o.toolUseID, name, input)) this.sink.output(out);
    const ans = await this.sink.requestApproval({
      toolUseId: itemId,
      name,
      title: toolTitle(name, input, this.opts.cwd),
      input: truncateInput(input),
      // "Always allow" would defeat a tool that's meant to ask every time.
      canAlwaysAllow: !o.suppressAlwaysAllowRule && !this.deps.alwaysAsk?.has(name),
      signal: o.signal,
    });
    switch (ans.decision) {
      case 'allow':
        return { behavior: 'allow', updatedInput: input, toolUseID: o.toolUseID, decisionClassification: 'user_temporary' };
      case 'allowAlways': {
        const { updates, rules } = alwaysAllow(name, o.suggestions);
        this.sink.output({ kind: 'allowRules', rules });
        return {
          behavior: 'allow',
          updatedInput: input,
          updatedPermissions: updates,
          toolUseID: o.toolUseID,
          decisionClassification: 'user_permanent',
        };
      }
      case 'expired':
        return { behavior: 'deny', message: ans.message || 'The request expired.', interrupt: true, toolUseID: o.toolUseID };
      default:
        return {
          behavior: 'deny',
          message: ans.message || 'The user denied this. Ask them how to proceed.',
          toolUseID: o.toolUseID,
          decisionClassification: 'user_reject',
        };
    }
  }

  send(input: UserInput): void {
    this.normalizer.sent();
    const content: Record<string, unknown>[] = [];
    for (const img of input.images) {
      const { data, mediaType } = prepareImageForModel(img, this.opts.tmpDir);
      content.push({ type: 'image', source: { type: 'base64', media_type: mediaType, data: data.toString('base64') } });
    }
    if (input.text || content.length === 0) content.push({ type: 'text', text: input.text });
    this.input.push({
      type: 'user',
      message: { role: 'user', content: content.length === 1 && content[0].type === 'text' ? input.text : (content as never) },
      parent_tool_use_id: null,
      // The SDK treats a message with no origin as unattributed; this one
      // is Mike typing in the app, so say so.
      origin: { kind: 'human' },
      // With a uuid the CLI reports command_lifecycle frames for the
      // message, which is how its own turns are told apart from this one.
      uuid: input.id ?? crypto.randomUUID(),
    } as SDKUserMessage);
  }

  // Stop means stop: a message pushed in while the turn ran and still
  // waiting in the CLI's queue is cancelled too, or the CLI would answer
  // it as a turn of its own straight after. (The SDK's types don't name
  // the option yet; the CLI advertises it as interrupt_cancel_queued_v1.)
  async interrupt(): Promise<void> {
    if (this.exited) return;
    await (this.q.interrupt as (opts?: { cancelQueued?: boolean }) => Promise<unknown>)({ cancelQueued: true });
  }

  async setModel(model: string | undefined): Promise<void> {
    if (this.exited) return;
    await this.q.setModel(model);
  }

  // Flag settings sit above the settings files for this session only, so
  // null puts the level back to the model's own without touching Mike's
  // settings.json.
  async setEffort(effort: EffortLevel | undefined): Promise<void> {
    if (this.exited) return;
    await this.q.applyFlagSettings({ effortLevel: claudeEffort(effort) ?? null });
  }

  async setPermissionMode(mode: PermissionMode): Promise<void> {
    if (this.exited) return;
    await this.q.setPermissionMode(sdkPermissionMode(mode));
    this.mode = mode;
  }

  async end(opts: { hard?: boolean } = {}): Promise<void> {
    if (opts.hard && !this.exited) {
      this.kill();
      await this.exitPromise;
      return;
    }
    if (!this.input.isEnded) this.input.end();
    const timeout = new Promise<'timeout'>((r) => setTimeout(() => r('timeout'), 15_000).unref());
    if ((await Promise.race([this.exitPromise, timeout])) === 'timeout') {
      this.deps.log.warn('CLI did not exit after its input ended; killing it', { threadId: this.opts.threadId });
      this.kill();
      await this.exitPromise;
    }
  }

  kill(): void {
    try {
      this.q.close();
    } catch {
      // already closed
    }
    this.abort.abort();
  }
}

// "Always allow" keeps the CLI's suggested allow rules for this thread
// only. Suggestions can also switch the session's permission mode (to
// acceptEdits, say) or save rules in the project's .claude folder, which
// would change more than the user agreed to and outlive the thread, so
// those are dropped and every rule is session-scoped. The runner keeps the
// rules on the thread and passes them back as allowedTools after a resume.
export function alwaysAllow(name: string, suggestions: PermissionUpdate[] | undefined): { updates: PermissionUpdate[]; rules: string[] } {
  const updates: PermissionUpdate[] = [];
  const rules: string[] = [];
  for (const s of suggestions ?? []) {
    if (s.type === 'addRules' && s.behavior === 'allow' && s.rules.length) {
      updates.push({ ...s, destination: 'session' });
      rules.push(...s.rules.map(ruleString));
    } else if (s.type === 'addDirectories') {
      updates.push({ ...s, destination: 'session' });
    }
  }
  if (rules.length === 0) {
    updates.push({ type: 'addRules', rules: [{ toolName: name }], behavior: 'allow', destination: 'session' });
    rules.push(name);
  }
  return { updates, rules };
}

function ruleString(r: { toolName: string; ruleContent?: string }): string {
  return r.ruleContent ? `${r.toolName}(${r.ruleContent})` : r.toolName;
}

function normaliseQuestions(raw: unknown): Question[] {
  if (!Array.isArray(raw)) return [];
  return (raw as Record<string, unknown>[]).map((q) => {
    const out: Question = {
      question: String(q.question ?? ''),
      multiSelect: Boolean(q.multiSelect),
      options: Array.isArray(q.options)
        ? (q.options as Record<string, unknown>[]).map((o) => {
            const opt: { label: string; description?: string } = { label: String(o.label ?? '') };
            if (typeof o.description === 'string') opt.description = o.description;
            return opt;
          })
        : [],
    };
    if (typeof q.header === 'string') out.header = q.header;
    return out;
  });
}

// Codex's 'ultra' has no Claude equivalent. The runner drops it from Claude
// threads with a note before it gets here; this keeps the SDK from seeing it
// if one slips through.
function claudeEffort(effort: EffortLevel | undefined): Exclude<EffortLevel, 'ultra'> | undefined {
  return effort === 'ultra' ? undefined : effort;
}
