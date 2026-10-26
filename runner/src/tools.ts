import fs from 'node:fs';
import path from 'node:path';
import type { Hunk, PlanEntry, ToolKind } from './protocol.ts';
import { LIMITS } from './protocol.ts';
import { applyReplace, diffLines } from './diff.ts';

const KINDS: Record<string, ToolKind> = {
  Bash: 'command',
  BashOutput: 'command',
  KillShell: 'command',
  PowerShell: 'command',
  Monitor: 'command',
  Read: 'read',
  NotebookRead: 'read',
  ReadMcpResourceTool: 'read',
  Edit: 'edit',
  MultiEdit: 'edit',
  NotebookEdit: 'edit',
  Write: 'write',
  Glob: 'search',
  Grep: 'search',
  LS: 'search',
  ToolSearch: 'search',
  WebFetch: 'web',
  WebSearch: 'web',
  Agent: 'task',
  Task: 'task',
  TodoWrite: 'todo',
  TaskCreate: 'todo',
  TaskUpdate: 'todo',
  TaskList: 'todo',
  TaskGet: 'todo',
};

export function toolKind(name: string): ToolKind {
  if (name.startsWith('mcp__')) return 'mcp';
  return KINDS[name] ?? 'other';
}

export const EDIT_TOOLS = new Set(['Edit', 'MultiEdit', 'Write']);

function str(v: unknown): string {
  return typeof v === 'string' ? v : '';
}

function firstLine(s: string, max = 100): string {
  const line = s.split('\n').find((l) => l.trim() !== '') ?? '';
  const t = line.trim();
  return t.length > max ? t.slice(0, max - 1) + '…' : t;
}

const realpaths = new Map<string, string>();

function realCwd(cwd: string): string {
  let r = realpaths.get(cwd);
  if (r === undefined) {
    try {
      r = fs.realpathSync(cwd);
    } catch {
      r = cwd;
    }
    realpaths.set(cwd, r);
  }
  return r;
}

// Paths inside the thread's folder are shown relative to it. The CLI reports
// resolved paths (/private/tmp for /tmp), so the real path is tried too.
export function displayPath(p: string, cwd: string): string {
  if (!p) return '';
  if (!path.isAbsolute(p)) return p;
  for (const base of [cwd, realCwd(cwd)]) {
    const rel = path.relative(base, p);
    if (rel && !rel.startsWith('..') && !path.isAbsolute(rel)) return rel;
  }
  return p;
}

// One line describing the call, e.g. "npm test" or "Edit src/a.ts".
export function toolTitle(name: string, input: Record<string, unknown>, cwd: string): string {
  const p = displayPath(str(input.file_path) || str(input.notebook_path) || str(input.path), cwd);
  switch (name) {
    case 'Bash':
    case 'PowerShell':
      return firstLine(str(input.command)) || str(input.description) || name;
    case 'Monitor':
      return firstLine(str(input.description) || str(input.command)) || name;
    case 'Read':
      return `Read ${p}`.trim();
    case 'Edit':
    case 'MultiEdit':
    case 'NotebookEdit':
      return `Edit ${p}`.trim();
    case 'Write':
      return `Write ${p}`.trim();
    case 'Glob':
      return `Find ${str(input.pattern)}${p ? ` in ${p}` : ''}`;
    case 'Grep':
      return `Search for ${firstLine(str(input.pattern), 80)}${p ? ` in ${p}` : ''}`;
    case 'LS':
      return `List ${p}`.trim();
    case 'WebFetch':
      return `Fetch ${str(input.url)}`;
    case 'WebSearch':
      return `Search the web for ${firstLine(str(input.query), 80)}`;
    case 'Agent':
    case 'Task':
      return firstLine(str(input.description)) || 'Run an agent';
    case 'TodoWrite':
      return 'Update the plan';
    case 'TaskCreate':
      return `Add task: ${firstLine(str(input.subject), 80)}`;
    case 'TaskUpdate':
      return `Update task ${str(input.taskId)}${input.status ? ` to ${String(input.status).replace('_', ' ')}` : ''}`;
    case 'TaskList':
      return 'List tasks';
    case 'TaskGet':
      return `Read task ${str(input.taskId)}`;
    case 'Skill':
      return `Use skill ${str(input.skill) || str(input.name)}`.trim();
    case 'AskUserQuestion':
      return 'Ask a question';
    case 'ToolSearch':
      return `Find tools: ${firstLine(str(input.query), 80)}`;
    case 'ExitPlanMode':
      return 'Finish the plan';
    default:
      if (name.startsWith('mcp__threadbare__')) return threadbareTitle(name.slice('mcp__threadbare__'.length), input);
      if (name.startsWith('mcp__')) {
        const [, server, ...rest] = name.split('__');
        return `${server}: ${rest.join('__')}`;
      }
      return name;
  }
}

// The threadbare tools (threadbare-mcp.ts) in plain words, for tool rows and
// approval cards.
function threadbareTitle(tool: string, input: Record<string, unknown>): string {
  const id = (str(input.threadId) || str(input.id)).slice(0, 8);
  switch (tool) {
    case 'list_threads':
      return str(input.query) ? `Search threads: ${firstLine(str(input.query), 80)}` : 'List threads';
    case 'read_thread':
      return id ? `Read thread ${id}` : 'Read this thread';
    case 'list_accounts':
      return 'List accounts';
    case 'create_thread':
      return `Start a thread: ${firstLine(str(input.title) || str(input.text), 80)}`;
    case 'send_message':
      return `Message thread ${id}`;
    case 'update_thread':
      return id ? `Update thread ${id}` : 'Update this thread';
    case 'move_thread':
      return `Move ${id ? `thread ${id}` : 'this thread'} to ${str(input.folder)}`;
    case 'interrupt_thread':
      return `Stop thread ${id}`;
    case 'delete_thread':
      return `Delete thread ${id}`;
    default:
      return `threadbare: ${tool}`;
  }
}

// Large strings in tool input are cut to 16 KB so one giant Write can't bloat
// the event log. The full content is still in the CLI's own transcript.
export function truncateInput(input: unknown): Record<string, unknown> {
  const walk = (v: unknown, depth: number): unknown => {
    if (typeof v === 'string') {
      return v.length > LIMITS.toolInputString ? v.slice(0, LIMITS.toolInputString) + '\n[truncated]' : v;
    }
    if (depth > 8 || v === null || typeof v !== 'object') return v;
    if (Array.isArray(v)) return v.map((x) => walk(x, depth + 1));
    const out: Record<string, unknown> = {};
    for (const [k, x] of Object.entries(v)) out[k] = walk(x, depth + 1);
    return out;
  };
  const r = walk(input ?? {}, 0);
  return r && typeof r === 'object' && !Array.isArray(r) ? (r as Record<string, unknown>) : { value: r };
}

// Diff for an Edit/MultiEdit/Write call computed from its input and the
// file as it is now. Used when asking for approval (the file hasn't changed
// yet) and as a fallback when the CLI's result carries no patch.
export function computeEditDiff(
  name: string,
  input: Record<string, unknown>,
  current: string | null,
): { path: string; hunks: Hunk[] } | null {
  const file = str(input.file_path);
  if (!file) return null;
  if (name === 'Write') {
    const content = str(input.content);
    return { path: file, hunks: diffLines(current ?? '', content) };
  }
  const edits: { old_string: string; new_string: string; replace_all?: boolean }[] =
    name === 'MultiEdit' && Array.isArray(input.edits)
      ? (input.edits as { old_string: string; new_string: string; replace_all?: boolean }[])
      : name === 'Edit'
        ? [{ old_string: str(input.old_string), new_string: str(input.new_string), replace_all: Boolean(input.replace_all) }]
        : [];
  if (edits.length === 0) return null;
  if (current !== null) {
    let after: string | null = current;
    for (const e of edits) {
      after = after === null ? null : applyReplace(after, str(e.old_string), str(e.new_string), Boolean(e.replace_all));
    }
    if (after !== null) return { path: file, hunks: diffLines(current, after) };
  }
  // The file isn't readable or the text has moved: show the replacement on
  // its own, without file line numbers.
  const hunks: Hunk[] = [];
  for (const e of edits) hunks.push(...diffLines(str(e.old_string), str(e.new_string)));
  return { path: file, hunks };
}

// Tracks the agent's plan across TodoWrite and the TaskCreate/TaskUpdate
// family, producing plan.updated entries.
export class PlanTracker {
  private tasks = new Map<string, PlanEntry>();
  private order: string[] = [];
  // TodoWrite sends the whole list each time; the Task tools edit one task.
  // A CLI uses one or the other, so switching starts a fresh list.
  private source: 'todo' | 'tasks' | null = null;

  private use(source: 'todo' | 'tasks'): void {
    if (this.source !== source) {
      this.tasks.clear();
      this.order = [];
      this.source = source;
    }
  }

  fromTodoWrite(input: Record<string, unknown>): PlanEntry[] | null {
    if (!Array.isArray(input.todos)) return null;
    this.use('todo');
    this.tasks.clear();
    this.order = [];
    const entries: PlanEntry[] = [];
    (input.todos as Record<string, unknown>[]).forEach((t, i) => {
      const e: PlanEntry = { text: str(t.content) || str(t.activeForm), status: normStatus(t.status) };
      this.tasks.set(String(i), e);
      this.order.push(String(i));
      entries.push(e);
    });
    return entries;
  }

  taskCreated(id: string, subject: string): PlanEntry[] {
    this.use('tasks');
    if (!this.tasks.has(id)) this.order.push(id);
    this.tasks.set(id, { text: subject, status: 'pending' });
    return this.entries();
  }

  taskUpdated(input: Record<string, unknown>): PlanEntry[] | null {
    const id = str(input.taskId);
    if (!id) return null;
    this.use('tasks');
    if (input.status === 'deleted') {
      if (!this.tasks.delete(id)) return null;
      this.order = this.order.filter((x) => x !== id);
      return this.entries();
    }
    const prev = this.tasks.get(id);
    if (!prev && !input.subject) return null;
    if (!prev) this.order.push(id);
    this.tasks.set(id, {
      text: str(input.subject) || prev?.text || '',
      status: input.status ? normStatus(input.status) : (prev?.status ?? 'pending'),
    });
    return this.entries();
  }

  taskList(tasks: unknown): PlanEntry[] | null {
    if (!Array.isArray(tasks)) return null;
    this.use('tasks');
    this.tasks.clear();
    this.order = [];
    for (const t of tasks as Record<string, unknown>[]) {
      const id = str(t.id);
      this.order.push(id);
      this.tasks.set(id, { text: str(t.subject), status: normStatus(t.status) });
    }
    return this.entries();
  }

  entries(): PlanEntry[] {
    return this.order.map((id) => this.tasks.get(id)!).filter(Boolean);
  }
}

function normStatus(s: unknown): PlanEntry['status'] {
  return s === 'in_progress' || s === 'completed' ? s : 'pending';
}
