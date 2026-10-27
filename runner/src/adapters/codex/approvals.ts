// The requests Codex sends to the runner: approvals, questions, MCP
// elicitations, Threadbare tool calls and the clock. This owns the pending
// map, the decision mapping, serverRequest/resolved and the "Always allow"
// rules. Every request gets an answer: a card, a rule, or a refusal at once.
import type { Question } from '../../protocol.ts';
import type { Logger } from '../../log.ts';
import { displayPath, truncateInput } from '../../tools.ts';
import type { QuestionAnswer, QuestionRequest, ToolApprovalAnswer, ToolApprovalRequest } from '../types.ts';
import type {
  ApplyPatchApprovalParams,
  CommandExecutionRequestApprovalParams,
  DynamicToolCallParams,
  DynamicToolCallResponse,
  ElicitationProperty,
  ExecCommandApprovalParams,
  FileChangeRequestApprovalParams,
  McpServerElicitationRequestParams,
  PermissionsRequestApprovalParams,
  RequestId,
  ToolRequestUserInputParams,
} from './types.ts';

// ---- Refusals, for a request no session is there to answer

export type Reply = { result: unknown } | { error: { code: number; message: string } };

export function refusal(method: string): Reply {
  switch (method) {
    case 'item/commandExecution/requestApproval':
    case 'item/fileChange/requestApproval':
      return { result: { decision: 'cancel' } };
    case 'execCommandApproval':
    case 'applyPatchApproval':
      return { result: { decision: 'abort' } };
    case 'item/permissions/requestApproval':
      return { result: { permissions: {}, scope: 'turn' } };
    case 'mcpServer/elicitation/request':
      return { result: { action: 'decline', content: null, _meta: null } };
    default:
      return { error: { code: -32601, message: `Threadbare doesn't handle ${method} here.` } };
  }
}

// ---- "Always allow" rules

// Codex offers no acceptForSession (on luna, on sol, for subagents: always
// ["accept", {acceptWithExecpolicyAmendment}, "cancel"]), and
// acceptWithExecpolicyAmendment saves a rule that outlives the thread. So
// the runner keeps its own rules in the thread's allowRules and answers
// matching requests itself:
//   codex:fileChange              any edit in this thread
//   codex:command:<JSON argv>     a plain command starting with these words
export const FILE_CHANGE_RULE = 'codex:fileChange';
const COMMAND_RULE = 'codex:command:';

export function commandRule(argv: string[]): string {
  return COMMAND_RULE + JSON.stringify(argv);
}

function ruleArgv(rule: string): string[] | null {
  if (!rule.startsWith(COMMAND_RULE)) return null;
  try {
    const v = JSON.parse(rule.slice(COMMAND_RULE.length));
    return Array.isArray(v) && v.length && v.every((x) => typeof x === 'string') ? v : null;
  } catch {
    return null;
  }
}

// Commands that run other commands given as arguments. A rule starting with
// one would allow anything, so none is made or matched.
const RUNS_OTHERS = new Set([
  'sh', 'bash', 'zsh', 'fish', 'dash', 'ksh', 'env', 'sudo', 'doas', 'su', 'xargs', 'eval', 'exec', 'command', 'builtin',
  'nohup', 'time', 'nice', 'timeout', 'watch', 'osascript',
]);

// Codex wraps every command as `/bin/zsh -lc '<command>'`. Returns the inner
// command, or the string as it is when it isn't wrapped.
export function unwrapShell(command: string): string {
  const m = /^\s*(?:\/(?:usr\/)?bin\/)?(?:zsh|bash|sh)\s+-l?c\s+([\s\S]+)$/.exec(command);
  if (!m) return command;
  const words = shellWords(m[1]);
  return words && words.length === 1 ? words[0] : command;
}

// Splits a command into words the way a shell would, or returns null if it
// isn't one plain command: any of ; & | > < or a newline outside quotes, or
// a backtick or $( outside single quotes (command substitution), means it
// could run something else, so it never matches a rule.
export function shellWords(s: string): string[] | null {
  const words: string[] = [];
  let cur = '';
  let inWord = false;
  let i = 0;
  while (i < s.length) {
    const c = s[i];
    if (c === "'") {
      const end = s.indexOf("'", i + 1);
      if (end < 0) return null;
      cur += s.slice(i + 1, end);
      inWord = true;
      i = end + 1;
      continue;
    }
    if (c === '"') {
      i++;
      let closed = false;
      while (i < s.length) {
        const d = s[i];
        if (d === '"') {
          closed = true;
          i++;
          break;
        }
        if (d === '`' || (d === '$' && s[i + 1] === '(')) return null;
        if (d === '\\' && i + 1 < s.length && '"\\$`\n'.includes(s[i + 1])) {
          cur += s[i + 1];
          i += 2;
          continue;
        }
        cur += d;
        i++;
      }
      if (!closed) return null;
      inWord = true;
      continue;
    }
    if (c === '\\') {
      if (i + 1 >= s.length || s[i + 1] === '\n') return null;
      cur += s[i + 1];
      inWord = true;
      i += 2;
      continue;
    }
    if (';&|<>\n`'.includes(c) || (c === '$' && s[i + 1] === '(')) return null;
    if (c === ' ' || c === '\t') {
      if (inWord) words.push(cur);
      cur = '';
      inWord = false;
      i++;
      continue;
    }
    cur += c;
    inWord = true;
    i++;
  }
  if (inWord) words.push(cur);
  return words;
}

// The plain argv of a command approval, or null when no rule may cover it:
// not a plain command, stdin to a running command, or network access.
export function plainArgv(p: CommandExecutionRequestApprovalParams): string[] | null {
  if ((p.kind ?? 'command') !== 'command') return null;
  if (p.networkApprovalContext || (Array.isArray(p.proposedNetworkPolicyAmendments) && p.proposedNetworkPolicyAmendments.length)) return null;
  if (typeof p.command !== 'string') return null;
  const argv = shellWords(unwrapShell(p.command));
  if (!argv || !argv.length || RUNS_OTHERS.has(argv[0].split('/').pop()!)) return null;
  return argv;
}

// The rule "Always allow" makes for a command: Codex's proposed amendment
// (["touch","b.txt"]) when it's a prefix of the command, else the exact argv.
export function ruleFor(p: CommandExecutionRequestApprovalParams): string | null {
  const argv = plainArgv(p);
  if (!argv) return null;
  const proposed = p.proposedExecpolicyAmendment;
  if (Array.isArray(proposed) && proposed.length && proposed.every((x) => typeof x === 'string') && startsWith(argv, proposed) && !RUNS_OTHERS.has(proposed[0])) {
    return commandRule(proposed);
  }
  return commandRule(argv);
}

export function commandAllowed(p: CommandExecutionRequestApprovalParams, rules: Iterable<string>): boolean {
  const argv = plainArgv(p);
  if (!argv) return false;
  for (const r of rules) {
    const prefix = ruleArgv(r);
    if (prefix && startsWith(argv, prefix)) return true;
  }
  return false;
}

function startsWith(argv: string[], prefix: string[]): boolean {
  return prefix.length <= argv.length && prefix.every((w, i) => argv[i] === w);
}

// ---- Handling requests

export type ApprovalsDeps = {
  log: Logger;
  label: string; // the thread id, for log lines
  reply(id: RequestId, result: unknown): void;
  replyError(id: RequestId, code: number, message: string): void;
  requestApproval(req: ToolApprovalRequest): Promise<ToolApprovalAnswer>;
  requestQuestion(req: QuestionRequest): Promise<QuestionAnswer>;
  rules(): Iterable<string>;
  addRules(rules: string[]): void; // kept for the thread (an allowRules output)
  note(text: string): void; // a system.note in the thread
  cwd(): string;
  // What the session saw of an item on item/started: the paths a fileChange
  // touches, for the card's title.
  itemPaths(itemId: string): string[] | undefined;
  callTool(params: DynamicToolCallParams, o: { fromChild: boolean; signal: AbortSignal }): Promise<DynamicToolCallResponse>;
  now(): number;
};

type Pending = { method: string; abort: AbortController };

export class CodexApprovals {
  private deps: ApprovalsDeps;
  private pending = new Map<string, Pending>();

  constructor(deps: ApprovalsDeps) {
    this.deps = deps;
  }

  get pendingCount(): number {
    return this.pending.size;
  }

  // `fromChild`: the request came from a subagent's thread. Its card goes to
  // this session with no itemId (there's no tool row for it here).
  handle(id: RequestId, method: string, params: unknown, o: { fromChild: boolean }): void {
    const p = (params ?? {}) as Record<string, unknown>;
    switch (method) {
      case 'item/commandExecution/requestApproval':
        return this.command(id, p as CommandExecutionRequestApprovalParams, o.fromChild);
      case 'item/fileChange/requestApproval':
        return this.fileChange(id, p as FileChangeRequestApprovalParams, o.fromChild);
      case 'item/permissions/requestApproval':
        return this.permissions(id, p as PermissionsRequestApprovalParams, o.fromChild);
      case 'item/tool/requestUserInput':
        return this.userInput(id, p as ToolRequestUserInputParams, o.fromChild);
      case 'mcpServer/elicitation/request':
        return this.elicitation(id, p as McpServerElicitationRequestParams);
      case 'item/tool/call':
        return this.toolCall(id, p as DynamicToolCallParams, o.fromChild);
      case 'execCommandApproval':
        return this.legacyCommand(id, p as ExecCommandApprovalParams, o.fromChild);
      case 'applyPatchApproval':
        return this.legacyPatch(id, p as ApplyPatchApprovalParams, o.fromChild);
      case 'currentTime/read':
        return this.deps.reply(id, { currentTimeAt: Math.floor(this.deps.now() / 1000) });
      default:
        this.deps.log.info('refused an unknown codex request', { threadId: this.deps.label, method });
        return this.deps.replyError(id, -32601, `Threadbare doesn't handle ${method}.`);
    }
  }

  // serverRequest/resolved arrives for every request, including the ones
  // we've just answered (under 1 ms after our reply). The pending entry is
  // dropped when we reply, so only a request still waiting on Mike is
  // expired here: Codex settled it itself (an interrupt, a non-blocking
  // question that timed out).
  resolved(requestId: RequestId): void {
    const key = String(requestId);
    const p = this.pending.get(key);
    if (!p) return;
    this.pending.delete(key);
    p.abort.abort();
  }

  // The session is ending: every open card expires and nothing is replied.
  cancelAll(): void {
    for (const p of this.pending.values()) p.abort.abort();
    this.pending.clear();
  }

  private open(id: RequestId, method: string): Pending {
    const p = { method, abort: new AbortController() };
    this.pending.set(String(id), p);
    return p;
  }

  // Sends the reply unless Codex has already resolved the request itself.
  private settle(id: RequestId, result: unknown): void {
    const key = String(id);
    if (!this.pending.has(key)) return;
    this.pending.delete(key);
    this.deps.reply(id, result);
  }

  private ask(id: RequestId, method: string, req: Omit<ToolApprovalRequest, 'signal'>, answer: (a: ToolApprovalAnswer) => unknown): void {
    const p = this.open(id, method);
    this.deps
      .requestApproval({ ...req, signal: p.abort.signal })
      .catch((e: unknown): ToolApprovalAnswer => {
        this.deps.log.warn('approval request failed', { threadId: this.deps.label, method, error: String(e) });
        return { decision: 'expired' };
      })
      .then((a) => this.settle(id, answer(a)));
  }

  private command(id: RequestId, p: CommandExecutionRequestApprovalParams, fromChild: boolean): void {
    const raw = typeof p.command === 'string' ? p.command : '';
    const inner = raw ? unwrapShell(raw) : (p.commandActions?.[0]?.command ?? '');
    const network = p.networkApprovalContext;
    const stdin = (p.kind ?? 'command') === 'writeStdin';
    const rule = stdin || network ? null : ruleFor(p);
    if (commandAllowed(p, this.deps.rules())) {
      this.deps.reply(id, { decision: 'accept' });
      return;
    }
    let title = firstLine(inner) || 'Run a command';
    if (stdin) title = `Send input to a running command${inner ? `: ${firstLine(inner)}` : ''}`;
    else if (network) title = `Allow network access to ${network.host}${inner ? ` for ${firstLine(inner)}` : ''}`;
    const input: Record<string, unknown> = { command: inner, cwd: p.cwd ?? this.deps.cwd() };
    if (p.reason) input.reason = p.reason;
    if (network) input.network = network;
    this.ask(
      id,
      'item/commandExecution/requestApproval',
      { toolUseId: fromChild ? undefined : p.itemId, name: 'shell', title, input: truncateInput(input), canAlwaysAllow: Boolean(rule) },
      (a) => {
        if (a.decision === 'allowAlways' && rule) this.deps.addRules([rule]);
        return { decision: commandDecision(a) };
      },
    );
  }

  private fileChange(id: RequestId, p: FileChangeRequestApprovalParams, fromChild: boolean): void {
    if (hasRule(this.deps.rules(), FILE_CHANGE_RULE)) {
      this.deps.reply(id, { decision: 'accept' });
      return;
    }
    const paths = (p.itemId && this.deps.itemPaths(p.itemId)) || [];
    const input: Record<string, unknown> = { paths };
    if (p.reason) input.reason = p.reason;
    if (p.grantRoot) input.grantRoot = p.grantRoot;
    this.ask(
      id,
      'item/fileChange/requestApproval',
      { toolUseId: fromChild ? undefined : p.itemId, name: 'apply_patch', title: editTitle(paths, this.deps.cwd()), input, canAlwaysAllow: true },
      (a) => {
        if (a.decision === 'allowAlways') this.deps.addRules([FILE_CHANGE_RULE]);
        return { decision: commandDecision(a) };
      },
    );
  }

  private permissions(id: RequestId, p: PermissionsRequestApprovalParams, fromChild: boolean): void {
    const requested: Record<string, unknown> = {};
    if (p.permissions?.network) requested.network = p.permissions.network;
    if (p.permissions?.fileSystem) requested.fileSystem = p.permissions.fileSystem;
    this.ask(
      id,
      'item/permissions/requestApproval',
      {
        toolUseId: fromChild ? undefined : p.itemId,
        name: 'permissions',
        title: firstLine(p.reason ?? '') || 'Allow extra permissions',
        input: truncateInput({ permissions: requested, cwd: p.cwd, reason: p.reason }),
        canAlwaysAllow: true,
      },
      (a) => {
        if (a.decision === 'allow') return { permissions: requested, scope: 'turn' };
        if (a.decision === 'allowAlways') return { permissions: requested, scope: 'session' };
        return { permissions: {}, scope: 'turn' };
      },
    );
  }

  private userInput(id: RequestId, p: ToolRequestUserInputParams, fromChild: boolean): void {
    const all = Array.isArray(p.questions) ? p.questions : [];
    const secret = all.filter((q) => q?.isSecret);
    for (const q of secret) this.deps.note(`Codex asked for something secret (${q.header || q.question}). Threadbare doesn't take secrets in a card, so it was declined.`);
    const asked = all.filter((q) => q && !q.isSecret);
    if (!asked.length) {
      this.deps.reply(id, { answers: {} });
      return;
    }
    const questions: Question[] = asked.map((q) => {
      const out: Question = {
        question: q.question || q.header || 'Codex has a question',
        multiSelect: false,
        options: (q.options ?? []).map((o) => (o.description ? { label: o.label, description: o.description } : { label: o.label })),
      };
      if (q.header) out.header = q.header;
      return out;
    });
    const pending = this.open(id, 'item/tool/requestUserInput');
    this.deps
      .requestQuestion({ toolUseId: fromChild ? undefined : p.itemId, questions, signal: pending.abort.signal })
      .catch((): QuestionAnswer => ({ answers: null }))
      .then((a) => {
        const answers: Record<string, { answers: string[] }> = {};
        if (a.answers) {
          asked.forEach((q, i) => {
            const v = a.answers![questions[i].question];
            if (typeof v === 'string' && v) answers[q.id] = { answers: [v] };
          });
        }
        this.settle(id, { answers });
      });
  }

  private elicitation(id: RequestId, p: McpServerElicitationRequestParams): void {
    const server = p.serverName || 'An MCP server';
    if (p.mode !== 'form') {
      const what = p.mode === 'url' && p.url ? `to open ${p.url}` : `for input Threadbare can't show (${p.mode})`;
      this.deps.note(`${server} asked ${what}${p.message ? `: ${firstLine(p.message)}` : ''}. Threadbare declined it.`);
      this.deps.reply(id, { action: 'decline', content: null, _meta: null });
      return;
    }
    const props = Object.entries(p.requestedSchema?.properties ?? {});
    const message = p.message || `${server} needs an answer`;
    const fields = props.map(([key, prop]) => ({ key, prop, choices: choicesFor(prop) }));
    const questions: Question[] = fields.length
      ? fields.map(({ key, prop, choices }, i) => {
          const label = prop.title || key;
          const detail = prop.description && prop.description !== label ? `${label}: ${prop.description}` : label;
          return {
            question: i === 0 ? `${message}\n\n${detail}` : detail,
            header: label.slice(0, 30),
            multiSelect: false,
            options: choices.map((c) => ({ label: c.label })),
          };
        })
      : [{ question: message, header: server.slice(0, 30), multiSelect: false, options: [{ label: 'Accept' }, { label: 'Decline' }] }];
    const pending = this.open(id, 'mcpServer/elicitation/request');
    this.deps
      .requestQuestion({ questions, signal: pending.abort.signal })
      .catch((): QuestionAnswer => ({ answers: null }))
      .then((a) => {
        if (!a.answers) return this.settle(id, { action: 'decline', content: null, _meta: null });
        if (!fields.length) {
          const accept = a.answers[questions[0].question] === 'Accept';
          return this.settle(id, accept ? { action: 'accept', content: {}, _meta: null } : { action: 'decline', content: null, _meta: null });
        }
        const content: Record<string, unknown> = {};
        fields.forEach(({ key, prop, choices }, i) => {
          const v = a.answers![questions[i].question];
          if (typeof v !== 'string' || v === '') return;
          content[key] = elicitedValue(v, prop, choices);
        });
        this.settle(id, { action: 'accept', content, _meta: null });
      });
  }

  private toolCall(id: RequestId, p: DynamicToolCallParams, fromChild: boolean): void {
    const pending = this.open(id, 'item/tool/call');
    this.deps
      .callTool(p, { fromChild, signal: pending.abort.signal })
      .catch((e: unknown): DynamicToolCallResponse => ({ contentItems: [{ type: 'inputText', text: (e as Error)?.message ?? String(e) }], success: false }))
      .then((r) => this.settle(id, r));
  }

  private legacyCommand(id: RequestId, p: ExecCommandApprovalParams, fromChild: boolean): void {
    // Treated like the v2 request, with the legacy decision names.
    const argv = Array.isArray(p.command) ? p.command.filter((x) => typeof x === 'string') : [];
    const asV2: CommandExecutionRequestApprovalParams = {
      kind: 'command',
      threadId: p.conversationId,
      turnId: '',
      itemId: p.callId,
      command: argv.length === 3 && /(^|\/)(zsh|bash|sh)$/.test(argv[0]) && /^-l?c$/.test(argv[1]) ? argv[2] : argv.map(quoteWord).join(' '),
      cwd: p.cwd,
      reason: p.reason,
    };
    if (commandAllowed(asV2, this.deps.rules())) {
      this.deps.reply(id, { decision: 'approved' });
      return;
    }
    const rule = ruleFor(asV2);
    const input: Record<string, unknown> = { command: asV2.command, cwd: p.cwd };
    if (p.reason) input.reason = p.reason;
    this.ask(
      id,
      'execCommandApproval',
      { toolUseId: fromChild ? undefined : p.callId, name: 'shell', title: firstLine(asV2.command ?? '') || 'Run a command', input: truncateInput(input), canAlwaysAllow: Boolean(rule) },
      (a) => {
        if (a.decision === 'allowAlways' && rule) this.deps.addRules([rule]);
        return { decision: legacyDecision(a) };
      },
    );
  }

  private legacyPatch(id: RequestId, p: ApplyPatchApprovalParams, fromChild: boolean): void {
    if (hasRule(this.deps.rules(), FILE_CHANGE_RULE)) {
      this.deps.reply(id, { decision: 'approved' });
      return;
    }
    const paths = Object.keys(p.fileChanges ?? {});
    const input: Record<string, unknown> = { paths };
    if (p.reason) input.reason = p.reason;
    this.ask(
      id,
      'applyPatchApproval',
      { toolUseId: fromChild ? undefined : p.callId, name: 'apply_patch', title: editTitle(paths, this.deps.cwd()), input, canAlwaysAllow: true },
      (a) => {
        if (a.decision === 'allowAlways') this.deps.addRules([FILE_CHANGE_RULE]);
        return { decision: legacyDecision(a) };
      },
    );
  }
}

// Never acceptForSession (nothing advertises it) or
// acceptWithExecpolicyAmendment (it saves a rule that outlives the thread).
// decline works although availableDecisions never lists it.
function commandDecision(a: ToolApprovalAnswer): 'accept' | 'decline' | 'cancel' {
  if (a.decision === 'allow' || a.decision === 'allowAlways') return 'accept';
  if (a.decision === 'expired') return 'cancel';
  return 'decline';
}

function legacyDecision(a: ToolApprovalAnswer): unknown {
  if (a.decision === 'allow' || a.decision === 'allowAlways') return 'approved';
  if (a.decision === 'expired') return 'abort';
  return { denied: { rejection: a.message || 'The user denied this.' } };
}

function hasRule(rules: Iterable<string>, rule: string): boolean {
  for (const r of rules) if (r === rule) return true;
  return false;
}

function editTitle(paths: string[], cwd: string): string {
  if (paths.length === 1) return `Edit ${displayPath(paths[0], cwd)}`;
  if (paths.length > 1) return `Edit ${paths.length} files`;
  return 'Edit files';
}

function firstLine(s: string, max = 200): string {
  const line = (s.split('\n').find((l) => l.trim()) ?? '').trim();
  return line.length > max ? line.slice(0, max - 1) + '…' : line;
}

function quoteWord(w: string): string {
  return /^[A-Za-z0-9_./:=@%+,-]+$/.test(w) ? w : `'${w.replace(/'/g, `'\\''`)}'`;
}

type Choice = { label: string; value: unknown };

function choicesFor(prop: ElicitationProperty): Choice[] {
  if (Array.isArray(prop.oneOf) && prop.oneOf.length) return prop.oneOf.map((o) => ({ label: o.title || String(o.const), value: o.const }));
  if (Array.isArray(prop.enum) && prop.enum.length) return prop.enum.map((v, i) => ({ label: prop.enumNames?.[i] || String(v), value: v }));
  if (prop.type === 'boolean') return [{ label: 'Yes', value: true }, { label: 'No', value: false }];
  return [];
}

function elicitedValue(answer: string, prop: ElicitationProperty, choices: Choice[]): unknown {
  const choice = choices.find((c) => c.label === answer);
  if (choice) return choice.value;
  if (prop.type === 'number' || prop.type === 'integer') {
    const n = Number(answer);
    return Number.isFinite(n) ? (prop.type === 'integer' ? Math.trunc(n) : n) : answer;
  }
  if (prop.type === 'boolean') return /^(y|yes|true|1)$/i.test(answer.trim());
  return answer;
}
