// Grok Build, through `grok agent stdio` (the Agent Client Protocol over
// newline-delimited JSON-RPC). One process per live thread.
//
// What this does: start or resume a session, send a prompt, stream the
// reply and the tool calls, answer a tool-permission request with the same
// card the other adapters use, and give the thread Threadbear's own tools.
// Grok spawns mcp-bridge.mjs; the handlers run here, and an end_turn call
// is recorded as mcp__threadbear__end_turn so the runner can build the card.
//
// Images are named in the prompt text, not sent as image blocks. A folder
// change starts a new session with a handoff, the same as a CLI that cannot
// move. Rewind is not implemented.
import { spawn, type ChildProcess } from 'node:child_process';
import readline from 'node:readline';
import type { Logger } from '../../log.ts';
import type { ProcessRegistry } from '../../proc.ts';
import { SERVER_NAME } from '../../threadbear-mcp.ts';
import { toolTitle, truncateInput } from '../../tools.ts';
import type { EffortLevel, ImageRef, PermissionMode, ToolKind } from '../../protocol.ts';
import {
  SessionNotFoundError,
  type AdapterOutput,
  type AgentAdapter,
  type AgentSession,
  type SessionSink,
  type StartSessionOptions,
  type ToolApprovalAnswer,
  type UserInput,
} from '../types.ts';
import { GrokToolServer, grokMcpServer, type GrokTool } from './tools.ts';

const quiet: Logger = { info() {}, warn() {}, error() {}, debug() {} };

export type GrokAdapterDeps = {
  grokPath: string;
  registry?: ProcessRegistry;
  log?: Logger;
  // Replaces `grok agent … stdio` in tests. `command` is spawned with `args`.
  command?: string;
  args?: string[];
  // Threadbear's tools for this thread, and the MCP server instructions
  // that tell Grok to end every turn with end_turn. Absent: no tools.
  toolsFor?: (threadId: string) => GrokTool[];
  instructionsFor?: (threadId: string) => string;
};

type RpcMsg = {
  jsonrpc?: string;
  id?: number;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: { code?: number; message?: string };
};

export class GrokAdapter implements AgentAdapter {
  readonly provider = 'grok' as const;
  // A Grok session is tied to the folder it was opened in.
  readonly movesFolders = false;
  readonly settingsApplyNextTurn = true;
  // Grok does not start a turn of its own when a background task ends.
  readonly wakesAfterTasks = false;

  private deps: GrokAdapterDeps;

  constructor(deps: GrokAdapterDeps) {
    this.deps = deps;
  }

  start(opts: StartSessionOptions, sink: SessionSink): AgentSession {
    if (opts.confined) throw new Error("Grok isn't started inside Threadbear's sandbox.");
    return new GrokSession(opts, sink, this.deps);
  }
}

class GrokSession implements AgentSession {
  private child?: ChildProcess;
  private pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  private nextId = 1;
  private sessionId?: string;
  private ready: Promise<void>;
  private failed?: Error;
  private closed = false;
  private queue: UserInput[] = [];
  private sending = false;
  private textItem = 0;
  private mode: PermissionMode;
  private model?: string;
  private effort?: EffortLevel;
  private log: Logger;
  private rules: Set<string>;
  private tools?: GrokToolServer;
  private toolNames = new Set<string>();
  private suppressed = new Set<string>();
  private toolSeq = 0;

  private opts: StartSessionOptions;
  private sink: SessionSink;
  private deps: GrokAdapterDeps;

  constructor(opts: StartSessionOptions, sink: SessionSink, deps: GrokAdapterDeps) {
    this.opts = opts;
    this.sink = sink;
    this.deps = deps;
    this.mode = opts.permissionMode;
    this.model = opts.model;
    this.effort = opts.effort;
    this.rules = new Set(opts.allowRules ?? []);
    this.log = deps.log ?? quiet;
    this.ready = this.open();
  }

  private async open(): Promise<void> {
    const command = this.deps.command ?? this.deps.grokPath;
    const args = this.deps.args ?? grokArgs(this.opts);
    let child: ChildProcess;
    try {
      const defs = this.deps.toolsFor?.(this.opts.threadId) ?? [];
      if (defs.length) {
        const server = new GrokToolServer(defs, this.deps.instructionsFor?.(this.opts.threadId) ?? '', {
          requestApproval: (req) => this.sink.requestApproval(req),
          cwd: () => this.opts.cwd,
          mode: () => this.mode,
          rules: () => this.rules,
          addRules: (rules) => this.addRules(rules),
          onCall: (name, input) => this.noteCall(name, input),
          onResult: (itemId, ok, text) => this.noteResult(itemId, ok, text),
        });
        await server.listen();
        this.tools = server;
        this.toolNames = server.names();
      }
      child = spawn(command, args, {
        cwd: this.opts.cwd,
        env: { ...process.env, ...this.opts.env },
        stdio: ['pipe', 'pipe', 'pipe'],
        detached: true,
      });
    } catch (e) {
      this.fail(e as Error);
      return;
    }
    this.child = child;
    if (child.pid) this.deps.registry?.add(child.pid, command);
    child.on('error', (e) => this.fail(e));
    child.stderr?.on('data', (buf: Buffer) => {
      const line = buf.toString('utf8').trim();
      if (line) this.log.debug('grok stderr', { threadId: this.opts.threadId, line: line.slice(0, 400) });
    });
    child.on('exit', (code, signal) => {
      if (child.pid) this.deps.registry?.remove(child.pid);
      if (this.closed) return;
      this.fail(new Error(signal ? `grok exited on ${signal}` : `grok exited ${code ?? 'with no code'}`));
    });
    const rl = readline.createInterface({ input: child.stdout! });
    rl.on('line', (line) => this.onLine(line));
    const mcpServers = this.tools ? [grokMcpServer(this.tools.socketPath)] : [];
    try {
      const init = (await this.request('initialize', {
        protocolVersion: 1,
        clientInfo: { name: 'GrokBearThreads', version: '0.0.0' },
        clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
      }, 15_000)) as { agentInfo?: { version?: string }; _meta?: { agentVersion?: string } };
      // The live CLI puts its version on `_meta.agentVersion`. The stand-in
      // used to send `agentInfo.version`; either one counts.
      const version = init?.agentInfo?.version || init?._meta?.agentVersion;
      if (version) this.sink.output({ kind: 'cliVersion', version });
      const meta = sessionMeta(this.mode, this.opts.instructions, Boolean(this.tools));
      if (this.opts.resume) {
        try {
          const loaded = (await this.request('session/load', {
            sessionId: this.opts.sessionId,
            cwd: this.opts.cwd,
            mcpServers,
            ...(meta ? { _meta: meta } : {}),
          }, 20_000)) as { sessionId?: string };
          this.sessionId = loaded.sessionId ?? this.opts.sessionId;
        } catch (e) {
          const msg = (e as Error).message;
          if (/not found|no such session|unknown session/i.test(msg)) throw new SessionNotFoundError(msg);
          throw e;
        }
      } else {
        const created = (await this.request('session/new', {
          cwd: this.opts.cwd,
          mcpServers,
          ...(meta ? { _meta: meta } : {}),
        }, 20_000)) as { sessionId?: string };
        if (!created.sessionId) throw new Error('grok session/new returned no sessionId');
        this.sessionId = created.sessionId;
      }
      this.sink.output({ kind: 'session', nativeSessionId: this.sessionId!, ...(this.model ? { model: this.model } : {}) });
    } catch (e) {
      this.fail(e as Error);
    }
  }

  send(input: UserInput): void {
    this.queue.push(input);
    void this.pump();
  }

  private async pump(): Promise<void> {
    if (this.sending) return;
    this.sending = true;
    try {
      await this.ready;
      while (this.queue.length && !this.failed && !this.closed) {
        const input = this.queue.shift()!;
        await this.prompt(input);
      }
    } finally {
      this.sending = false;
    }
  }

  private async prompt(input: UserInput): Promise<void> {
    const started = Date.now();
    this.textItem += 1;
    const text = promptText(input.text, input.images, this.mode);
    let stopReason = 'end_turn';
    try {
      const result = (await this.request('session/prompt', {
        sessionId: this.sessionId,
        prompt: [{ type: 'text', text }],
      })) as { stopReason?: string };
      if (result?.stopReason) stopReason = result.stopReason;
      this.sink.output({
        kind: 'result',
        result: {
          outcome: stopReason === 'cancelled' ? 'interrupted' : 'completed',
          answers: input.id,
          durationMs: Date.now() - started,
        },
      });
    } catch (e) {
      if (this.closed) return;
      const message = (e as Error).message;
      this.sink.output({
        kind: 'result',
        result: {
          outcome: 'failed',
          answers: input.id,
          durationMs: Date.now() - started,
          error: message,
          ...( /auth|sign in|not logged/i.test(message) ? { errorKind: 'auth' as const } : {}),
        },
      });
    }
  }

  async interrupt(): Promise<void> {
    if (!this.sessionId || this.closed) return;
    this.notify('session/cancel', { sessionId: this.sessionId });
  }

  async setModel(model: string | undefined): Promise<void> {
    this.model = model;
    if (!this.sessionId || !model) return;
    await this.setOption('model', model);
  }

  async setEffort(effort: EffortLevel | undefined): Promise<void> {
    this.effort = effort;
    if (!this.sessionId || !effort) return;
    await this.setOption('reasoning_effort', effort === 'ultra' ? 'max' : effort);
  }

  async setPermissionMode(mode: PermissionMode): Promise<void> {
    // yolo and auto are fixed when the process starts. The next session
    // (a resume, or a new one after this process ends) picks the new mode up.
    this.mode = mode;
  }

  async end(): Promise<void> {
    this.closed = true;
    this.tools?.close();
    this.child?.stdin?.end();
    await this.killWait();
  }

  kill(): void {
    this.closed = true;
    this.tools?.close();
    this.killChild();
  }

  // The process group, so a bridge Grok spawned for this thread goes too.
  private killChild(): void {
    const pid = this.child?.pid;
    if (!pid) return;
    try {
      process.kill(-pid, 'SIGTERM');
    } catch {
      try { this.child?.kill('SIGTERM'); } catch { /* already gone */ }
    }
  }

  private async killWait(): Promise<void> {
    if (!this.child || this.child.exitCode !== null) return;
    this.kill();
    await new Promise<void>((resolve) => {
      const t = setTimeout(resolve, 2000);
      this.child?.once('exit', () => {
        clearTimeout(t);
        resolve();
      });
    });
  }

  private async setOption(configId: string, value: string): Promise<void> {
    try {
      await this.request('session/set_config_option', { sessionId: this.sessionId, configId, value }, 10_000);
    } catch (e) {
      this.log.info('grok ignored a setting', { threadId: this.opts.threadId, configId, error: (e as Error).message });
    }
  }

  private request(method: string, params: unknown, timeoutMs?: number): Promise<unknown> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = timeoutMs
        ? setTimeout(() => {
            this.pending.delete(id);
            reject(new Error(`grok ${method} timed out`));
          }, timeoutMs)
        : undefined;
      this.pending.set(id, {
        resolve: (v) => {
          if (timer) clearTimeout(timer);
          resolve(v);
        },
        reject: (e) => {
          if (timer) clearTimeout(timer);
          reject(e);
        },
      });
      this.write({ jsonrpc: '2.0', id, method, params });
    });
  }

  private notify(method: string, params: unknown): void {
    this.write({ jsonrpc: '2.0', method, params });
  }

  private write(msg: unknown): void {
    this.child?.stdin?.write(`${JSON.stringify(msg)}\n`);
  }

  private onLine(line: string): void {
    let msg: RpcMsg;
    try {
      msg = JSON.parse(line) as RpcMsg;
    } catch {
      return;
    }
    if (msg.id !== undefined && msg.method) {
      void this.answer(msg.id, msg.method, msg.params);
      return;
    }
    if (msg.id !== undefined) {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      if (msg.error) p.reject(new Error(msg.error.message || `grok error ${msg.error.code ?? ''}`));
      else p.resolve(msg.result);
      return;
    }
    if (msg.method === 'session/update' || msg.method === 'x.ai/session/update') this.onUpdate(msg.params);
  }

  private async answer(id: number, method: string, params: unknown): Promise<void> {
    try {
      const result = method === 'session/request_permission' ? await this.permission(params) : { outcome: { outcome: 'cancelled' } };
      this.write({ jsonrpc: '2.0', id, result });
    } catch (e) {
      this.write({ jsonrpc: '2.0', id, error: { code: -32000, message: (e as Error).message } });
    }
  }

  private async permission(params: unknown): Promise<unknown> {
    const p = (params ?? {}) as {
      toolCall?: { toolCallId?: string; title?: string; kind?: string; rawInput?: Record<string, unknown> };
      options?: { optionId?: string; kind?: string; name?: string }[];
    };
    const call = p.toolCall ?? {};
    const options = p.options ?? [];
    const answer: ToolApprovalAnswer = await this.sink.requestApproval({
      toolUseId: call.toolCallId,
      name: call.kind || 'tool',
      title: call.title || call.kind || 'Tool',
      input: call.rawInput ?? {},
      canAlwaysAllow: options.some((o) => o.kind === 'allow_always'),
      signal: new AbortController().signal,
    });
    if (answer.decision === 'deny' || answer.decision === 'expired') {
      return { outcome: { outcome: 'cancelled' } };
    }
    const want = answer.decision === 'allowAlways' ? 'allow_always' : 'allow_once';
    const chosen = options.find((o) => o.kind === want) ?? options.find((o) => o.kind === 'allow_once') ?? options[0];
    if (!chosen?.optionId) return { outcome: { outcome: 'cancelled' } };
    return { outcome: { outcome: 'selected', optionId: chosen.optionId } };
  }

  private onUpdate(params: unknown): void {
    const update = (params as { update?: Record<string, unknown> } | undefined)?.update;
    if (!update) return;
    const kind = update.sessionUpdate;
    if (kind === 'agent_message_chunk' || kind === 'agent_thought_chunk') {
      const text = (update.content as { text?: string } | undefined)?.text ?? '';
      if (!text) return;
      const itemId = `${kind === 'agent_message_chunk' ? 'msg' : 'thought'}:${this.textItem}`;
      this.sink.output({
        kind: 'delta',
        delta: { type: kind === 'agent_message_chunk' ? 'assistant.text.delta' : 'reasoning.delta', itemId, text },
      });
      return;
    }
    if (kind === 'tool_call' || kind === 'tool_call_update') {
      const reported = update.toolCallId === undefined || update.toolCallId === null ? '' : String(update.toolCallId);
      // The bridge already recorded a Threadbear tool. Grok's own copy of
      // that call would be a second end_turn, and the card would move.
      if (this.threadbearUpdate(update) || (reported !== '' && this.suppressed.has(reported))) {
        if (reported) this.suppressed.add(reported);
        return;
      }
      const id = reported || 'tool';
      const name = String(update.title ?? update.kind ?? 'tool');
      if (kind === 'tool_call') {
        this.sink.output({
          kind: 'event',
          event: {
            type: 'tool.call',
            itemId: id,
            name,
            kind: toolKind(String(update.kind ?? '')),
            title: name,
            input: (update.rawInput as Record<string, unknown>) ?? {},
          },
        });
      } else if (update.status === 'completed' || update.status === 'failed') {
        const text = typeof update.rawOutput === 'string' ? update.rawOutput : '';
        this.sink.output({
          kind: 'event',
          event: { type: 'tool.result', itemId: id, ok: update.status === 'completed', text, truncated: false, images: [] },
        });
      }
    }
  }

  private addRules(rules: string[]): void {
    for (const rule of rules) this.rules.add(rule);
    this.sink.output({ kind: 'allowRules', rules });
  }

  private noteCall(name: string, args: Record<string, unknown>): { itemId: string } {
    this.toolSeq += 1;
    const itemId = `tb-${name}-${this.toolSeq}`;
    const full = `mcp__${SERVER_NAME}__${name}`;
    this.sink.output({
      kind: 'event',
      event: { type: 'tool.call', itemId, name: full, kind: 'mcp', title: toolTitle(full, args, this.opts.cwd), input: truncateInput(args) },
    });
    return { itemId };
  }

  private noteResult(itemId: string, ok: boolean, text: string): void {
    this.sink.output({
      kind: 'event',
      event: { type: 'tool.result', itemId, ok, text, truncated: false, images: [] },
    });
  }

  // Grok's notice of a tool our bridge is already running. Matched on the
  // tool's own name, since the notice's title is not a fixed string.
  private threadbearUpdate(update: Record<string, unknown>): boolean {
    if (!this.toolNames.size) return false;
    const bits: string[] = [];
    for (const key of ['title', 'name', 'toolName']) {
      const value = update[key];
      if (typeof value === 'string') bits.push(value);
    }
    const meta = update._meta;
    if (meta && typeof meta === 'object') {
      const record = meta as Record<string, unknown>;
      for (const key of ['tool', 'name', 'toolName']) {
        if (typeof record[key] === 'string') bits.push(record[key] as string);
      }
    }
    // Live Grok reaches an MCP tool by calling its own use_tool first, with
    // the tool name in rawInput. That row is the same call the bridge records.
    const raw = update.rawInput;
    if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
      const record = raw as Record<string, unknown>;
      for (const key of ['tool_name', 'name', 'toolName']) {
        if (typeof record[key] === 'string') bits.push(record[key] as string);
      }
    }
    for (const bit of bits) {
      if (this.toolNames.has(bit)) return true;
      for (const name of this.toolNames) {
        if (
          bit === `mcp__${SERVER_NAME}__${name}` ||
          bit === `${SERVER_NAME}__${name}` ||
          bit === `${SERVER_NAME}: ${name}` ||
          bit === `${SERVER_NAME}.${name}` ||
          bit === `${SERVER_NAME}/${name}`
        ) return true;
      }
    }
    return false;
  }

  private fail(e: Error): void {
    this.tools?.close();
    if (this.failed || this.closed) return;
    this.failed = e;
    // Stop the process. Its pipes would keep the runner waiting.
    this.killChild();
    for (const p of this.pending.values()) p.reject(e);
    this.pending.clear();
    this.sink.exited(e);
  }
}

function grokArgs(opts: StartSessionOptions): string[] {
  const args = ['agent'];
  if (opts.permissionMode === 'full') args.push('--always-approve');
  if (opts.model) args.push('--model', opts.model);
  args.push('--no-leader', 'stdio');
  return args;
}

function sessionMeta(mode: PermissionMode, instructions: string | undefined, withTools: boolean): Record<string, unknown> | undefined {
  const meta: Record<string, unknown> = {};
  if (mode === 'full') meta.yoloMode = true;
  if (mode === 'auto') meta.autoMode = true;
  const lines: string[] = [];
  if (mode === 'plan') lines.push('Plan only. Do not edit files or run commands that change anything until the plan is approved.');
  if (instructions) lines.push(instructions);
  if (withTools) lines.push('End every turn by calling the threadbear tool end_turn. That call is what finishes the turn for the user; a message alone does not.');
  if (lines.length) meta.rules = lines.join('\n\n');
  return Object.keys(meta).length ? meta : undefined;
}

function promptText(text: string, images: ImageRef[], mode: PermissionMode): string {
  const parts = [text];
  if (mode === 'plan') parts.unshift('Plan only. Do not edit files or run commands that change anything.');
  for (const image of images) parts.push(`(Attached image, not sent as a picture: ${image.path})`);
  return parts.filter(Boolean).join('\n\n');
}

function toolKind(kind: string): ToolKind {
  switch (kind) {
    case 'execute':
    case 'command':
      return 'command';
    case 'read':
      return 'read';
    case 'edit':
      return 'edit';
    case 'write':
    case 'delete':
      return 'write';
    case 'search':
      return 'search';
    case 'fetch':
    case 'web':
      return 'web';
    default:
      return 'other';
  }
}
