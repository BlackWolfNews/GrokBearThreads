import crypto from 'node:crypto';
import { query as sdkQuery } from '@anthropic-ai/claude-agent-sdk';
import type { McpServerConfig, Options, PermissionResult, Query, SDKUserMessage, PermissionUpdate } from '@anthropic-ai/claude-agent-sdk';
import type { Account, PermissionMode, Question } from '../../protocol.ts';
import type { AgentAdapter, AgentSession, SessionSink, StartSessionOptions, UserInput } from '../types.ts';
import type { Logger } from '../../log.ts';
import { ClaudeNormalizer, fileContext } from './normalize.ts';
import { groupSpawner, type ProcessRegistry } from '../../proc.ts';
import { prepareImageForModel } from '../../media.ts';
import { toolTitle, truncateInput } from '../../tools.ts';
import { RUNNER_VERSION } from '../../config.ts';

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
  env.CLAUDE_AGENT_SDK_CLIENT_APP = `threadbare-runner/${RUNNER_VERSION}`;
  return env;
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
  // In-process MCP servers for a thread's session (the threadbare tools).
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
    const options: Options = {
      cwd: opts.cwd,
      pathToClaudeCodeExecutable: deps.claudePath,
      env: { ...cliEnv(opts.account), ...opts.env },
      settingSources: ['user', 'project', 'local'],
      systemPrompt: { type: 'preset', preset: 'claude_code' },
      includePartialMessages: true,
      thinking: { type: 'adaptive', display: 'summarized' },
      permissionMode: sdkPermissionMode(opts.permissionMode),
      // Always allowed so "Ask before edits" can be switched off mid-session.
      allowDangerouslySkipPermissions: true,
      canUseTool: (name, input, o) => this.canUseTool(name, input, o),
      abortController: this.abort,
      spawnClaudeCodeProcess: groupSpawner(deps.registry, deps.log, (line) => this.stderr(line), opts.threadId),
    };
    const servers = deps.mcpServersFor?.(opts.threadId);
    if (servers && Object.keys(servers).length) options.mcpServers = servers;
    if (opts.model) options.model = opts.model;
    if (opts.allowRules?.length) options.allowedTools = [...opts.allowRules];
    if (opts.resume) options.resume = opts.sessionId;
    else options.sessionId = opts.sessionId;
    const queryFn = deps.queryFn ?? sdkQuery;
    this.q = queryFn({ prompt: this.input, options });
    void this.pump();
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

  async interrupt(): Promise<void> {
    if (this.exited) return;
    await this.q.interrupt();
  }

  async setModel(model: string | undefined): Promise<void> {
    if (this.exited) return;
    await this.q.setModel(model);
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
