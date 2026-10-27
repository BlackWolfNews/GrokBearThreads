// Projects: a grouping above folders (docs/protocol.md, "Projects"). A
// project can have several folders, a thread can be in several projects,
// and each keeps goals, state and notes that carry forward from thread to
// thread. Nobody has to make them: the librarian (librarian.ts) and the
// agents (threadbare-mcp.ts) do, and Mike can fix anything by hand.
//
// The projects themselves are kept in projects.json in the data dir; which
// projects a thread is in is kept on the thread's record (store.ts), so it
// goes with the thread when it's deleted. A project is also the unit
// patches load by: a thread gets the patches of every folder of every
// project it's in (patches.ts).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import type { Clock } from './clock.ts';
import type { Logger } from './log.ts';
import type { Notification } from './runner.ts';
import type { Project, ProjectMaker, ThreadProject, ThreadSummary } from './protocol.ts';
import { ErrorCode, RpcError } from './protocol.ts';
import type { ThreadRecord } from './store.ts';
import type { ProjectFolder } from './patches.ts';
import { atomicWriteFileSync, isDirectory, readJsonSync } from './fsutil.ts';
import { expandHome } from './config.ts';

// What projects.json holds for each: the counts are worked out from the
// threads when they're sent.
export type ProjectRecord = Omit<Project, 'threadCount' | 'lastActivityAt'>;

// What the projects need from the runner: its threads, a way to change
// one (which saves it, sends its summary and says what changed), and the
// clients.
export type ProjectHost = {
  threadRecords(): ThreadRecord[];
  // Changes a thread's record, then saves it and sends its summary. `note`
  // goes in the transcript.
  editThread(threadId: string, edit: (rec: ThreadRecord) => void, say?: { note?: string }): ThreadSummary;
  // Sends these threads' summaries again (a title changed) and reads their
  // patches again (folders changed).
  touchThreads(threadIds: string[]): void;
  resolveThread(idOrPrefix: string): string;
  publish(n: Notification): void;
  onNotification(fn: (n: Notification) => void): () => void;
};

export type CreateProjectParams = {
  title: string;
  folders?: string[];
  goals?: string;
  state?: string;
  notes?: string;
  threadIds?: string[];
  by: ProjectMaker;
  byThread?: string;
};

export type UpdateProjectParams = {
  title?: string;
  folders?: string[];
  goals?: string;
  state?: string;
  notes?: string;
  archived?: boolean;
};

export type MembershipChange = {
  add?: string[];
  remove?: string[];
  by: ProjectMaker;
};

const TITLE_MAX = 80;
const SHORT_MAX = 2000; // goals and state
const NOTES_MAX = 50_000;
// How much of the projects goes into a session's brief, all of them together.
export const BRIEF_MAX = 2000;

export class Projects {
  private file: string;
  private clock: Clock;
  private log: Logger;
  private home: string;
  private items = new Map<string, ProjectRecord>();
  private host?: ProjectHost;
  private unlisten?: () => void;
  // Set on a draining runner (handover): the primary owns projects.json now.
  private frozen = false;

  constructor(deps: { home: string; clock: Clock; log: Logger; userHome?: string }) {
    this.file = path.join(deps.home, 'projects.json');
    this.clock = deps.clock;
    this.log = deps.log;
    this.home = deps.userHome ?? os.homedir();
  }

  // Reads projects.json and starts listening to the runner. Called once the
  // runner's threads are loaded.
  start(host: ProjectHost): void {
    this.host = host;
    const saved = readJsonSync<{ projects?: ProjectRecord[] }>(this.file);
    if (!saved && fs.existsSync(this.file)) this.log.error('projects.json could not be read; starting with none', { file: this.file });
    for (const p of saved?.projects ?? []) {
      if (p && typeof p.id === 'string' && typeof p.title === 'string') this.items.set(p.id, { ...p, folders: p.folders ?? [], goals: p.goals ?? '', state: p.state ?? '', notes: p.notes ?? '' });
    }
    // A deleted thread changes its projects' counts.
    this.unlisten = host.onNotification((n) => {
      if (n.method === 'thread.deleted') this.publish();
    });
    this.log.info('projects loaded', { count: this.items.size });
  }

  stop(): void {
    this.unlisten?.();
  }

  // A draining runner reads projects for its kept threads but no longer
  // changes them.
  freeze(): void {
    this.frozen = true;
  }

  // ---------------------------------------------------------------- reads

  list(opts: { archived?: boolean } = {}): Project[] {
    const threads = this.host?.threadRecords() ?? [];
    return [...this.items.values()]
      .filter((p) => opts.archived || !p.archived)
      .map((p) => this.withCounts(p, threads))
      .sort((a, b) => (b.lastActivityAt ?? b.updatedAt).localeCompare(a.lastActivityAt ?? a.updatedAt));
  }

  get(projectId: string): { project: Project; threadIds: string[] } {
    const p = this.must(projectId);
    const threads = this.host?.threadRecords() ?? [];
    const threadIds = threads
      .filter((t) => t.projects?.some((m) => m.id === p.id))
      .sort((a, b) => b.lastActivityAt.localeCompare(a.lastActivityAt))
      .map((t) => t.id);
    return { project: this.withCounts(p, threads), threadIds };
  }

  // A project by id, unique id prefix or title (any case), for agents and
  // tb, who may name one either way.
  find(q: string): ProjectRecord | undefined {
    const want = q.trim();
    if (!want) return undefined;
    const exact = this.items.get(want);
    if (exact) return exact;
    const all = [...this.items.values()];
    const byPrefix = all.filter((p) => p.id.startsWith(want));
    if (byPrefix.length === 1) return byPrefix[0];
    const byTitle = all.filter((p) => p.title.toLowerCase() === want.toLowerCase());
    if (byTitle.length === 1) return byTitle[0];
    return undefined;
  }

  record(projectId: string): ProjectRecord | undefined {
    return this.items.get(projectId);
  }

  // The thread's projects as its summary shows them.
  threadProjects(rec: ThreadRecord): ThreadProject[] | undefined {
    const out: ThreadProject[] = [];
    for (const m of rec.projects ?? []) {
      const p = this.items.get(m.id);
      if (p) out.push({ ...m, title: p.title });
    }
    return out.length ? out : undefined;
  }

  // The folders the thread's patches load from, besides its own.
  foldersFor(rec: ThreadRecord): ProjectFolder[] {
    const out: ProjectFolder[] = [];
    for (const m of rec.projects ?? []) {
      const p = this.items.get(m.id);
      if (!p || p.archived) continue;
      for (const folder of p.folders) out.push({ folder, projectId: p.id });
    }
    return out;
  }

  // What a session starting on the thread is told about its projects
  // (docs/protocol.md, "The brief"), or undefined when it's in none.
  brief(rec: ThreadRecord): string | undefined {
    const projects = (rec.projects ?? []).map((m) => this.items.get(m.id)).filter((p): p is ProjectRecord => Boolean(p && !p.archived));
    if (!projects.length) return undefined;
    // Each project gets an even share; long goals and state are cut.
    const share = Math.floor(BRIEF_MAX / projects.length);
    const blocks = projects.map((p) => this.briefBlock(p, share));
    return (
      '[Threadbear projects] This thread is part of the projects below. A project outlasts any one thread: ' +
      'when you learn something that should carry on (a decision, where things are up to, what is next, a gotcha), ' +
      'update it with the threadbare tool update_project. read_project has each one\'s notes.\n\n' +
      blocks.join('\n\n')
    );
  }

  private briefBlock(p: ProjectRecord, max: number): string {
    const head = `## ${p.title} (${p.id})` + (p.folders.length ? `\nFolders: ${p.folders.map((f) => this.tilde(f)).join(', ')}` : '');
    const room = Math.max(120, max - head.length - 20);
    const goals = clip(p.goals, Math.floor(room / 2));
    const state = clip(p.state, room - goals.length);
    return [head, goals && `Goals: ${goals}`, state && `State: ${state}`].filter(Boolean).join('\n');
  }

  // The projects a brief covers, for knowing what a session has been told.
  briefIds(rec: ThreadRecord): string[] {
    return (rec.projects ?? []).map((m) => m.id).filter((id) => this.items.get(id) && !this.items.get(id)!.archived);
  }

  // Lines for a session told about these projects since it started.
  joinedLines(ids: string[]): string | undefined {
    const lines = ids.map((id) => this.items.get(id)).filter((p): p is ProjectRecord => Boolean(p)).map((p) => this.joinedLine(p));
    return lines.length ? lines.join('\n') : undefined;
  }

  // A line for the agent when its thread joins a project mid-session.
  joinedLine(p: ProjectRecord): string {
    const bits = [`[Threadbear project] This thread is now part of the project "${p.title}" (${p.id}).`];
    if (p.goals) bits.push(`Goals: ${clip(p.goals, 300)}`);
    if (p.state) bits.push(`State: ${clip(p.state, 300)}`);
    bits.push('read_project has its notes; update_project keeps it current.');
    return bits.join(' ');
  }

  // ---------------------------------------------------------------- writes

  create(params: CreateProjectParams): Project {
    const title = checkTitle(params.title);
    const now = this.iso();
    const rec: ProjectRecord = {
      id: this.newId(),
      title,
      folders: this.checkFolders(params.folders ?? []),
      goals: checkText('goals', params.goals ?? '', SHORT_MAX),
      state: checkText('state', params.state ?? '', SHORT_MAX),
      notes: checkText('notes', params.notes ?? '', NOTES_MAX),
      createdBy: params.by,
      createdAt: now,
      updatedAt: now,
    };
    if (params.byThread) rec.createdByThread = params.byThread;
    if (rec.state) rec.stateUpdatedAt = now;
    // Every thread named must exist before anything changes.
    const threadIds = (params.threadIds ?? []).map((t) => this.mustHost().resolveThread(t));
    this.items.set(rec.id, rec);
    this.save();
    this.log.info('project made', { id: rec.id, title: rec.title, by: params.by });
    for (const t of threadIds) this.changeMembership(t, { add: [rec.id], by: params.by });
    this.publish();
    return this.withCounts(rec, this.mustHost().threadRecords());
  }

  update(projectId: string, params: UpdateProjectParams): Project {
    const rec = this.must(projectId);
    const next = { ...rec };
    if (params.title !== undefined) next.title = checkTitle(params.title);
    if (params.folders !== undefined) next.folders = this.checkFolders(params.folders);
    if (params.goals !== undefined) next.goals = checkText('goals', params.goals, SHORT_MAX);
    if (params.state !== undefined) next.state = checkText('state', params.state, SHORT_MAX);
    if (params.notes !== undefined) next.notes = checkText('notes', params.notes, NOTES_MAX);
    if (params.archived !== undefined) {
      if (params.archived) next.archived = true;
      else delete next.archived;
    }
    const now = this.iso();
    if (params.state !== undefined && next.state !== rec.state) next.stateUpdatedAt = now;
    next.updatedAt = now;
    this.items.set(rec.id, next);
    this.save();
    // Its threads' summaries carry its title, and their patches its folders.
    if (next.title !== rec.title || JSON.stringify(next.folders) !== JSON.stringify(rec.folders) || next.archived !== rec.archived) {
      this.mustHost().touchThreads(this.threadsIn(rec.id));
    }
    this.publish();
    return this.withCounts(next, this.mustHost().threadRecords());
  }

  // Adds a paragraph to the notes rather than replacing them, for agents
  // that only want to say one thing.
  appendNote(projectId: string, text: string): Project {
    const rec = this.must(projectId);
    const add = text.trim();
    if (!add) throw bad('The note is empty.');
    return this.update(projectId, { notes: rec.notes.trim() ? `${rec.notes.trimEnd()}\n\n${add}` : add });
  }

  merge(projectId: string, intoId: string): Project {
    const from = this.must(projectId);
    const into = this.must(intoId);
    if (from.id === into.id) throw bad("A project can't be merged into itself.");
    const now = this.iso();
    const kept: ProjectRecord = {
      ...into,
      folders: [...into.folders, ...from.folders.filter((f) => !into.folders.includes(f))],
      goals: into.goals || from.goals,
      state: into.state || from.state,
      notes: [into.notes.trim(), from.notes.trim() && `## From ${from.title}\n\n${from.notes.trim()}`].filter(Boolean).join('\n\n'),
      updatedAt: now,
    };
    this.items.set(into.id, kept);
    this.items.delete(from.id);
    this.save();
    for (const t of this.mustHost().threadRecords()) {
      if (!t.projects?.some((m) => m.id === from.id)) continue;
      this.mustHost().editThread(t.id, (r) => {
        const had = r.projects!.find((m) => m.id === from.id)!;
        r.projects = r.projects!.filter((m) => m.id !== from.id);
        if (!r.projects.some((m) => m.id === into.id)) r.projects.push({ ...had, id: into.id });
        if (r.projectsLeft?.includes(from.id)) r.projectsLeft = r.projectsLeft.filter((x) => x !== from.id);
      });
    }
    this.mustHost().touchThreads(this.threadsIn(into.id));
    this.log.info('projects merged', { from: from.id, into: into.id });
    this.publish();
    return this.withCounts(kept, this.mustHost().threadRecords());
  }

  delete(projectId: string): Record<string, never> {
    const rec = this.must(projectId);
    for (const t of this.threadsIn(rec.id)) {
      this.mustHost().editThread(t, (r) => {
        r.projects = (r.projects ?? []).filter((m) => m.id !== rec.id);
        if (!r.projects.length) delete r.projects;
      });
    }
    // Forgotten everywhere, so "never put back" doesn't outlive it.
    for (const t of this.mustHost().threadRecords()) {
      if (t.projectsLeft?.includes(rec.id)) {
        this.mustHost().editThread(t.id, (r) => {
          r.projectsLeft = r.projectsLeft!.filter((x) => x !== rec.id);
          if (!r.projectsLeft.length) delete r.projectsLeft;
        });
      }
    }
    this.items.delete(rec.id);
    this.save();
    this.log.info('project deleted', { id: rec.id, title: rec.title });
    this.publish();
    return {};
  }

  // Puts a thread in projects and takes it out of others. Mike's and
  // agents' changes are pinned (added) or remembered (removed), so the
  // librarian never undoes them; the librarian only adds where nobody has
  // taken the thread out, and only takes out what it put there itself.
  // Returns the projects that actually changed.
  changeMembership(threadId: string, change: MembershipChange): { joined: string[]; left: string[]; thread: ThreadSummary } {
    const host = this.mustHost();
    const id = host.resolveThread(threadId);
    const add = (change.add ?? []).map((p) => this.must(p).id);
    const remove = (change.remove ?? []).map((p) => this.must(p).id);
    const rec = host.threadRecords().find((t) => t.id === id)!;
    const joined: string[] = [];
    const left: string[] = [];
    const at = this.iso();
    const current = new Map((rec.projects ?? []).map((m) => [m.id, m]));
    const plan: ((r: ThreadRecord) => void)[] = [];
    for (const p of add) {
      const has = current.get(p);
      if (change.by === 'librarian') {
        if (has || rec.projectsLeft?.includes(p)) continue;
      } else if (has) {
        // Already there: Mike or an agent saying so pins it.
        if (!has.pinned) plan.push((r) => (r.projects!.find((m) => m.id === p)!.pinned = true));
        continue;
      }
      joined.push(p);
      plan.push((r) => {
        (r.projects ??= []).push({ id: p, by: change.by, at, ...(change.by === 'librarian' ? {} : { pinned: true }) });
        if (r.projectsLeft?.includes(p)) {
          r.projectsLeft = r.projectsLeft.filter((x) => x !== p);
          if (!r.projectsLeft.length) delete r.projectsLeft;
        }
      });
    }
    for (const p of remove) {
      const has = current.get(p);
      if (!has) continue;
      if (change.by === 'librarian' && (has.pinned || has.by !== 'librarian')) continue;
      left.push(p);
      plan.push((r) => {
        r.projects = (r.projects ?? []).filter((m) => m.id !== p);
        if (!r.projects.length) delete r.projects;
        if (change.by !== 'librarian' && !r.projectsLeft?.includes(p)) (r.projectsLeft ??= []).push(p);
      });
    }
    if (!plan.length) return { joined, left, thread: host.editThread(id, () => {}) };
    const names = (ids: string[]) => ids.map((p) => this.items.get(p)!.title).join(' and ');
    const say: { note?: string } = {};
    // Mike sees his own change; the librarian's and agents' are said in
    // the transcript so a wrong guess gets noticed.
    if (change.by !== 'mike') {
      const who = change.by === 'librarian' ? 'by the librarian' : 'by the agent';
      const parts = [joined.length ? `Put in ${names(joined)}` : '', left.length ? `Taken out of ${names(left)}` : ''].filter(Boolean);
      say.note = `${parts.join('. ')} ${who}.`;
    }
    // An agent that joined one itself knows: don't tell it again.
    if (change.by === 'agent' && joined.length) plan.push((r) => (r.projectsTold = [...new Set([...(r.projectsTold ?? []), ...joined])]));
    const thread = host.editThread(id, (r) => plan.forEach((f) => f(r)), say);
    this.log.info('thread projects changed', { threadId: id, by: change.by, joined, left });
    this.publish();
    return { joined, left, thread };
  }

  // ------------------------------------------------------------- helpers

  threadsIn(projectId: string): string[] {
    return (this.host?.threadRecords() ?? []).filter((t) => t.projects?.some((m) => m.id === projectId)).map((t) => t.id);
  }

  private withCounts(p: ProjectRecord, threads: ThreadRecord[]): Project {
    let count = 0;
    let last: string | undefined;
    for (const t of threads) {
      if (!t.projects?.some((m) => m.id === p.id)) continue;
      count++;
      if (!last || t.lastActivityAt > last) last = t.lastActivityAt;
    }
    const out: Project = { ...p, threadCount: count };
    if (last) out.lastActivityAt = last;
    return out;
  }

  private must(projectId: string): ProjectRecord {
    const p = typeof projectId === 'string' ? this.items.get(projectId) ?? this.find(projectId) : undefined;
    if (!p) throw new RpcError(ErrorCode.projectNotFound, `No project called ${projectId}`);
    return p;
  }

  private mustHost(): ProjectHost {
    if (!this.host) throw new Error('Projects used before start()');
    return this.host;
  }

  private checkFolders(folders: string[]): string[] {
    if (!Array.isArray(folders)) throw bad('folders must be a list of paths');
    const out: string[] = [];
    for (const f of folders) {
      if (typeof f !== 'string' || !f.trim()) throw bad('folders must be a list of paths');
      const dir = path.resolve(expandHome(f.trim()));
      if (!isDirectory(dir)) throw bad(`Folder not found: ${dir}`);
      if (!out.includes(dir)) out.push(dir);
    }
    return out;
  }

  private newId(): string {
    for (;;) {
      const id = 'p_' + crypto.randomBytes(4).toString('hex');
      if (!this.items.has(id)) return id;
    }
  }

  private tilde(p: string): string {
    return p === this.home || p.startsWith(this.home + path.sep) ? '~' + p.slice(this.home.length) : p;
  }

  private save(): void {
    if (this.frozen) throw new RpcError(ErrorCode.other, 'This runner is handing over; projects are changed on the new one.');
    atomicWriteFileSync(this.file, JSON.stringify({ projects: [...this.items.values()] }, null, 2));
  }

  private publish(): void {
    this.host?.publish({ method: 'projects.updated', params: { projects: this.list({ archived: true }) } });
  }

  private iso(): string {
    return new Date(this.clock.now()).toISOString();
  }
}

function checkTitle(title: unknown): string {
  if (typeof title !== 'string' || !title.trim()) throw bad('A project needs a title.');
  const t = title.trim().replace(/\s+/g, ' ');
  if (t.length > TITLE_MAX) throw bad(`A project title is at most ${TITLE_MAX} characters.`);
  return t;
}

function checkText(name: string, text: unknown, max: number): string {
  if (typeof text !== 'string') throw bad(`${name} must be text`);
  if (text.length > max) throw bad(`${name} is at most ${max} characters.`);
  return text.trim();
}

function clip(text: string, max: number): string {
  const t = text.trim();
  return t.length > max ? t.slice(0, Math.max(0, max - 1)).trimEnd() + '…' : t;
}

function bad(message: string): RpcError {
  return new RpcError(ErrorCode.badParams, message);
}

// ------------------------------------------------------------- the methods

export function projectMethods(projects: Projects): Record<string, (p: Record<string, unknown>) => unknown> {
  return {
    'projects.list': (p) => ({ projects: projects.list({ archived: bool(p, 'archived') }) }),
    'projects.get': (p) => projects.get(reqStr(p, 'projectId')),
    'projects.create': (p) => ({
      project: projects.create({
        title: reqStr(p, 'title'),
        folders: strList(p, 'folders'),
        goals: str(p, 'goals'),
        state: str(p, 'state'),
        notes: str(p, 'notes'),
        threadIds: strList(p, 'threadIds'),
        by: 'mike',
      }),
    }),
    'projects.update': (p) => ({
      project: projects.update(reqStr(p, 'projectId'), {
        title: str(p, 'title'),
        folders: strList(p, 'folders'),
        goals: str(p, 'goals'),
        state: str(p, 'state'),
        notes: str(p, 'notes'),
        archived: bool(p, 'archived'),
      }),
    }),
    'projects.merge': (p) => ({ project: projects.merge(reqStr(p, 'projectId'), reqStr(p, 'intoId')) }),
    'projects.delete': (p) => projects.delete(reqStr(p, 'projectId')),
    'threads.setProjects': (p) => ({
      thread: projects.changeMembership(reqStr(p, 'threadId'), { add: strList(p, 'add'), remove: strList(p, 'remove'), by: 'mike' }).thread,
    }),
  };
}

function str(p: Record<string, unknown>, k: string): string | undefined {
  const v = p[k];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'string') throw bad(`${k} must be a string`);
  return v;
}

function reqStr(p: Record<string, unknown>, k: string): string {
  const v = str(p, k);
  if (v === undefined) throw bad(`${k} must be a string`);
  return v;
}

function strList(p: Record<string, unknown>, k: string): string[] | undefined {
  const v = p[k];
  if (v === undefined || v === null) return undefined;
  if (!Array.isArray(v) || !v.every((x) => typeof x === 'string')) throw bad(`${k} must be a list of strings`);
  return v as string[];
}

function bool(p: Record<string, unknown>, k: string): boolean | undefined {
  const v = p[k];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'boolean') throw bad(`${k} must be a boolean`);
  return v;
}

// The project tools' view of Projects, refusing while `blocked` says why
// (a draining runner during a handover).
export function guardProjects<K extends 'list' | 'get' | 'find' | 'create' | 'update' | 'appendNote' | 'changeMembership'>(
  projects: Projects,
  blocked: () => string | undefined,
): Pick<Projects, K> {
  const writes = new Set(['create', 'update', 'appendNote', 'changeMembership']);
  return new Proxy(projects, {
    get(target, prop, receiver) {
      const v = Reflect.get(target, prop, receiver);
      if (typeof v !== 'function') return v;
      return (...args: unknown[]) => {
        const why = writes.has(String(prop)) ? blocked() : undefined;
        if (why) throw new Error(why);
        return (v as (...a: unknown[]) => unknown).apply(target, args);
      };
    },
  }) as Pick<Projects, K>;
}
