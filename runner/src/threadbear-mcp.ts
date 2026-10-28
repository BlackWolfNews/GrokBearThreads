// Tools that let an agent drive Threadbear itself: list and read threads,
// start new ones, message them, rename, snooze, archive, move and delete
// them. The runner hands each Claude session its own in-process MCP server
// ("threadbear"), built with that session's thread id, so "this thread" is
// always the caller and nothing has to go over the WebSocket.
import path from 'node:path';
import { createSdkMcpServer, tool } from '@anthropic-ai/claude-agent-sdk';
import type { McpSdkServerConfigWithInstance } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';
import type { Runner } from './runner.ts';
import type { Account, EffortLevel, PersistedEvent, Schedule, ThreadSummary } from './protocol.ts';
import { usageLine } from './usage.ts';
import { findPool, poolLine } from './pools.ts';
import { AGENT_MESSAGE_PREFIX, EFFORT_LEVELS } from './protocol.ts';
import type { Scheduler } from './schedules.ts';
import type { Projects } from './projects.ts';
import { parseWhen, relativeFuture, relativeTime } from './when.ts';

export { parseWhen, relativeFuture, relativeTime };
import { RUNNER_VERSION, expandHome } from './config.ts';
import { END_TURN_DESCRIPTION, END_TURN_TOOL } from './needs.ts';
import { asksForAppRestart, type AppRestarts } from './app-restarts.ts';

// What the tools drive: the Runner itself, or during a handover
// (docs/protocol.md) a ThreadRouter (handover.ts) that reaches threads on
// the other runner, which is why every call may be a promise.
type Aw<T> = T | Promise<T>;
type Async<T, K extends keyof T> = { [P in K]: T[P] extends (...a: infer A) => infer R ? (...a: A) => Aw<R> : never };
export type ThreadControl = {
  hello: Runner['hello'];
  createReview?: (...args: Parameters<Runner['createReview']>) => Aw<ReturnType<Runner['createReview']>>;
  pin?: (...args: Parameters<Runner['pin']>) => Aw<ReturnType<Runner['pin']>>;
  unpin?: (...args: Parameters<Runner['unpin']>) => Aw<ReturnType<Runner['unpin']>>;
} & Async<Runner, 'list' | 'search' | 'get' | 'events' | 'create' | 'send' | 'update' | 'interrupt' | 'delete'>;

// Messages a thread when the Mac app restarts onto a new build (app-restarts.ts).
export type AppRestartControl = Pick<AppRestarts, 'watch' | 'isWatching'>;

export type ScheduleControl = Async<Scheduler, 'create' | 'list' | 'find' | 'update' | 'delete'>;

export type ProjectControl = Pick<Projects, 'list' | 'get' | 'find' | 'create' | 'update' | 'appendNote' | 'changeMembership'> & Partial<Pick<Projects, 'chooseIcon'>>;

export const SERVER_NAME = 'threadbear';
// Asked about every time, even in a thread with full access: deleting is
// the one thing here that's hard to take back.
export const ALWAYS_ASK_TOOLS = new Set([`mcp__${SERVER_NAME}__delete_thread`]);

type Result = { content: { type: 'text'; text: string }[]; isError?: boolean };

// Every level, Codex's ultra included; the runner drops one the thread's
// model doesn't offer, with a note.
const effortEnum = z.enum(EFFORT_LEVELS as unknown as [EffortLevel, ...EffortLevel[]]);

const providerName = (a: Pick<Account, 'provider'>): string => (a.provider === 'codex' ? 'Codex' : 'Claude');

const ok = (text: string): Result => ({ content: [{ type: 'text', text }] });
const fail = (text: string): Result => ({ content: [{ type: 'text', text }], isError: true });

function handle<A>(fn: (args: A) => string | Promise<string>): (args: A) => Promise<Result> {
  return async (args) => {
    try {
      return ok(await fn(args));
    } catch (e) {
      return fail((e as Error).message ?? String(e));
    }
  };
}

// Models sometimes say `id` for a thread id; take it rather than quietly
// falling back to "this thread".
const thisOrOther = {
  threadId: z.string().optional().describe('Thread id or a unique prefix. Default: this thread.'),
  id: z.string().optional().describe('Same as threadId.'),
};
const other = {
  threadId: z.string().optional().describe('Thread id or a unique prefix (required).'),
  id: z.string().optional().describe('Same as threadId.'),
};

// Says which thread a threadbear tool call is about by its title, for the
// approval card ("Delete "Fix the tests"?" rather than a bare id).
export function approvalTitle(name: string, input: Record<string, unknown>, find: (idOrPrefix: string) => ThreadSummary | undefined): string | undefined {
  if (name !== `mcp__${SERVER_NAME}__delete_thread`) return undefined;
  const id = typeof input.threadId === 'string' ? input.threadId : typeof input.id === 'string' ? input.id : '';
  const t = id ? find(id) : undefined;
  return t ? `Delete the thread "${t.title}"` : undefined;
}

export function buildThreadbearTools(control: ThreadControl, selfId: string, now: () => number = Date.now, schedules?: ScheduleControl, projects?: ProjectControl, appRestarts?: AppRestartControl) {
  const all = async (): Promise<ThreadSummary[]> => control.list(['inbox', 'snoozed', 'archived']);

  // Full ids, or any unique prefix of one (the list shows 8 characters).
  const resolve = async (id: string | undefined): Promise<string> => {
    if (!id) return selfId;
    const hits = (await all()).filter((t) => t.id === id || t.id.startsWith(id));
    if (hits.length === 1) return hits[0].id;
    if (hits.length === 0) throw new Error(`No thread with id ${id}. list_threads shows them.`);
    throw new Error(`${id} matches ${hits.length} threads; use more of the id.`);
  };

  const resolveOther = async (id: string | undefined): Promise<string> => {
    if (!id) throw new Error('threadId is required. list_threads shows the ids.');
    return resolve(id);
  };

  // An account by id, email, title or the part of the email before the @,
  // or "codex" / "claude" when that provider has only one. claude-1 and
  // codex-main can share an email, so a name that fits several is refused
  // rather than guessed.
  const account = async (q: string | undefined): Promise<string | undefined> => {
    if (!q) return undefined;
    const accounts: Account[] = control.hello().accounts;
    const named = (a: Account) => `${a.id} (${a.title})`;
    const exact = accounts.find((a) => a.id === q);
    if (exact) return exact.id;
    const email = (a: Account) => a.email ?? a.title.replace(/^Codex · /, '');
    let hits = accounts.filter((a) => a.title === q || email(a) === q);
    if (!hits.length) hits = accounts.filter((a) => email(a).split('@')[0] === q);
    if (!hits.length) hits = accounts.filter((a) => a.provider === q.toLowerCase());
    if (hits.length === 1) return hits[0].id;
    if (hits.length > 1) throw new Error(`${q} fits ${hits.map(named).join(' and ')}; use the id.`);
    throw new Error(`No account ${q}. Accounts: ${accounts.map(named).join(', ')}`);
  };

  // A pool by id or title (docs/protocol.md, "Pools").
  const pool = (q: string): string => {
    const pools = control.hello().pools ?? [];
    const hit = findPool(pools, q);
    if (!hit) throw new Error(`No pool ${q}. Pools: ${pools.map((p) => `${p.id} (${p.title})`).join(', ') || 'none'}`);
    return hit.id;
  };

  const folder = async (f: string): Promise<string> => {
    const base = (await control.get(selfId)).cwd;
    return path.resolve(base, expandHome(f.trim()));
  };

  const line = (t: ThreadSummary): string => {
    const where = t.archivedAt ? 'archived' : t.snoozedUntil ? `snoozed until ${snoozeEnd(t)}` : 'inbox';
    const flags = [t.status, where, t.needsYou ? 'needs Mike' : '', t.id === selfId ? 'this thread' : ''].filter(Boolean).join(', ');
    return `${t.id.slice(0, 8)}  ${t.title}  [${flags}]  ${t.cwd}  ${t.accountId}  ${relativeTime(t.lastActivityAt, now())}`;
  };

  const describe = (t: ThreadSummary): string =>
    [
      `id: ${t.id}`,
      `title: ${t.title}`,
      `status: ${t.status}${t.needsYou ? ' (needs Mike)' : ''}`,
      `folder: ${t.cwd}`,
      `account: ${t.accountId} (${providerName(t)})`,
      `pool: ${t.poolId ?? 'none (pinned to its account)'}`,
      t.waitingForRoom ? `waiting for room until: ${t.waitingForRoom.until}` : '',
      `model: ${t.model ?? 'default'}${t.modelInUse ? ` (running as ${t.modelInUse})` : ''}`,
      `effort: ${t.effort ?? 'default'}${t.effortInUse ? ` (${t.effortInUse} last turn)` : ''}`,
      `permissions: ${t.permissionMode === 'full' ? 'full access' : 'ask before edits'}`,
      t.snoozedUntil ? `snoozed until: ${snoozeEnd(t)}` : '',
      t.archivedAt ? `archived: ${t.archivedAt}` : '',
      `last activity: ${relativeTime(t.lastActivityAt, now())}`,
      t.costUsd !== undefined ? `cost so far: $${t.costUsd.toFixed(2)}` : '',
    ]
      .filter(Boolean)
      .join('\n');

  // Messages an agent sends say where they came from, so whoever reads the
  // other thread (Mike or its agent) knows it wasn't Mike typing.
  const from = async (): Promise<string> => `${AGENT_MESSAGE_PREFIX}"${(await control.get(selfId)).title}" (${selfId.slice(0, 8)})]\n\n`;


  const titleOf = async (id: string): Promise<string> => {
    try {
      return `"${(await control.get(id)).title}"`;
    } catch {
      return id.slice(0, 8);
    }
  };

  const scheduleLine = async (sc: Schedule): Promise<string> => {
    const state = sc.finishedAt ? 'done' : sc.paused ? 'paused' : sc.nextRunAt ? `next ${relativeFuture(sc.nextRunAt, now())} (${sc.nextRunAt})` : 'no more runs';
    const target = sc.threadId ? (sc.threadId === selfId ? 'this thread' : `thread ${sc.threadId.slice(0, 8)} ${await titleOf(sc.threadId)}`) : `a new thread in ${sc.cwd}`;
    const last = sc.lastRun && sc.lastRun.outcome !== 'sent' ? `; last run ${sc.lastRun.outcome}: ${sc.lastRun.note ?? ''}` : '';
    return `${sc.id.slice(0, 8)}  ${sc.title}  [${sc.whenText}; ${state}${last}]  to ${target}`;
  };

  const mustSchedules = (): ScheduleControl => {
    if (!schedules) throw new Error("This runner doesn't have schedules.");
    return schedules;
  };

  const reviewTools = [
    tool(
      'show_options',
      'Shows Mike a set of images to compare side by side in a review window, with an optional pick and notes per image. Use this whenever you have two or more design alternatives (mockups, wireframes, screenshots of variants) for Mike to choose between, instead of pinning them, listing them in your reply or reading every image into the transcript. Returns a review ID promptly; finish your turn and Mike’s answer arrives later as a message. Images are copied into the thread. Reference images can receive notes but cannot be picked.',
      {
        title: z.string().min(1).max(200).describe('What Mike is reviewing.'),
        note: z.string().max(4000).optional().describe('A short explanation or question for the whole review.'),
        options: z.array(z.object({
          id: z.string().min(1).max(200).describe('Stable option ID, such as A or B.'),
          title: z.string().min(1).max(200),
          path: z.string().min(1).describe('Image path, absolute or relative to this thread’s folder.'),
          note: z.string().max(4000).optional(),
          reference: z.boolean().optional().describe('Context image that can receive notes but cannot be picked.'),
        })).min(1).max(12),
      },
      handle(async (input) => {
        if (!control.createReview) throw new Error('This runner does not support image reviews yet.');
        const { review } = await control.createReview(selfId, input);
        return `Review ${review.id}: ${review.title} (${review.options.length} images). Mike can compare them and send a choice or notes. You can finish this turn; his reply will arrive as a later message.`;
      }),
    ),
  ];

  // Highlights (docs/protocol.md): the list beside the transcript of what
  // the thread made and shared. Always this thread's own.
  const highlightTools = [
    tool(
      'pin',
      "Pins a file or link to this thread's Highlights, the list beside the transcript in Threadbear, so Mike can find it without scrolling: something you made for him to review (a mockup, a doc, a screenshot), a preview URL, a PR. Prefer this to running `open` on a file or page meant for Mike; with show: true it opens in the app's side pane straight away instead of taking over his screen. Files you write and links you mention are listed by themselves, so pin only what matters most, with a note saying why.",
      {
        path: z.string().optional().describe('A file, absolute or relative to this thread’s folder. Give path or url.'),
        url: z.string().optional().describe('A link, with its scheme (https://, http://localhost:5173).'),
        title: z.string().max(200).optional().describe('What to call it. Default: the file name or the link.'),
        note: z.string().max(500).optional().describe('One line on why Mike should look at it.'),
        show: z.boolean().optional().describe('Open it in the side pane now.'),
      },
      handle(async (input) => {
        if (!control.pin) throw new Error("This runner doesn't keep highlights yet.");
        const { id } = await control.pin(selfId, input);
        return `Pinned (${id})${input.show ? ', and shown in the side pane' : ''}.`;
      }),
    ),
    tool(
      'unpin',
      "Takes a pin off this thread's Highlights, by the id `pin` returned.",
      { id: z.string().min(1).describe('The id pin returned, e.g. file:/Users/.../mock.html.') },
      handle(async ({ id }) => {
        if (!control.unpin) throw new Error("This runner doesn't keep highlights yet.");
        const { removed } = await control.unpin(selfId, id);
        return removed ? 'Unpinned.' : `Nothing pinned as ${id}.`;
      }),
    ),
  ];

  const scheduleTools = [
    tool(
      'schedule_message',
      'Schedules a message to be sent later, once or over and over, like a Convex scheduled function or cron. By default it goes to this thread, so you can check back on something yourself ("look at the deploy again in 20 minutes"); it starts a turn here when it comes due (after any turn that is running then). Or send it to another thread, or set new_thread to start a fresh thread each time (for recurring jobs like a morning summary). Give exactly one of `when` (once) and `cron` (repeating). The message should be a complete instruction: when it arrives the agent may not remember why it was scheduled.',
      {
        text: z.string().min(1).describe('The message to send when it comes due.'),
        when: z.string().optional().describe('Once: 30m, 2h, 1d, tomorrow (9 am) or an ISO time.'),
        cron: z.string().optional().describe('Repeating: a 5-field cron, minute hour day-of-month month day-of-week, e.g. "0 9 * * 1-5" for weekdays at 9:00, "*/30 * * * *" for every 30 minutes; or @hourly, @daily, @weekly, @monthly. Read in the Mac\'s time zone unless timezone is set.'),
        timezone: z.string().optional().describe('IANA zone for the cron, e.g. Australia/Perth. Default: the Mac\'s.'),
        title: z.string().optional().describe('Short name for lists. Default: the first line of text.'),
        ...thisOrOther,
        new_thread: z.boolean().optional().describe('Start a new thread each time instead of sending to a thread.'),
        folder: z.string().optional().describe("With new_thread: its working folder. Default: this thread's folder."),
        account: z.string().optional().describe('With new_thread: account id or email (Claude or Codex; see list_accounts). Default: the one with the most room, on the provider last used.'),
        model: z.string().optional().describe("With new_thread: model id, one of the account's (list_accounts shows them)."),
        effort: effortEnum.optional().describe('With new_thread: reasoning effort (ultra is Codex only).'),
        permissionMode: z.enum(['full', 'ask']).optional().describe('With new_thread: "full" (default) or "ask".'),
      },
      handle(async ({ text, when, cron, timezone, title, threadId, id: alias, new_thread, folder: f, account: acc, model, effort, permissionMode }) => {
        if ((when === undefined) === (cron === undefined)) throw new Error('Give exactly one of when (once) and cron (repeating).');
        const target = new_thread
          ? { cwd: await folder(f ?? '.'), accountId: await account(acc), model, effort, permissionMode }
          : { threadId: await resolve(threadId ?? alias) };
        if (!new_thread && (f || acc || model || effort || permissionMode)) throw new Error('folder, account, model, effort and permissionMode are for new_thread schedules; a thread keeps its own.');
        const sc = await mustSchedules().create({
          text,
          title,
          ...(when !== undefined ? { at: parseWhen(when, now()) } : { cron }),
          timezone,
          ...target,
          createdBy: selfId,
        });
        return `Scheduled ${sc.id.slice(0, 8)}: ${await scheduleLine(sc)}`;
      }),
    ),
    tool(
      'list_schedules',
      "Lists Threadbear's schedules: short id, title, when, the next run and where it sends. By default the ones that send to this thread or that this thread made; all for every schedule.",
      { all: z.boolean().optional().describe('Every schedule, not just this thread\'s.') },
      handle(async ({ all: everything }) => {
        const list = await mustSchedules().list(everything ? undefined : selfId);
        return list.length ? (await Promise.all(list.map(scheduleLine))).join('\n') : everything ? 'No schedules.' : 'No schedules for this thread. all: true shows every schedule.';
      }),
      { annotations: { readOnlyHint: true } },
    ),
    tool(
      'update_schedule',
      'Changes a schedule: its message, title or time, or pauses and resumes it. Setting when makes it a one-off, setting cron makes it repeat.',
      {
        scheduleId: z.string().describe('Schedule id or a unique prefix (list_schedules shows them).'),
        text: z.string().optional(),
        title: z.string().optional(),
        when: z.string().optional().describe('Once: 30m, 2h, 1d, tomorrow or an ISO time.'),
        cron: z.string().optional().describe('Repeating: a 5-field cron.'),
        timezone: z.string().nullable().optional().describe("IANA zone for the cron, or null for the Mac's."),
        paused: z.boolean().optional(),
      },
      handle(async ({ scheduleId, text, title, when, cron, timezone, paused }) => {
        const sc = await mustSchedules().update({
          scheduleId,
          text,
          title,
          at: when === undefined ? undefined : parseWhen(when, now()),
          cron,
          timezone,
          paused,
        });
        return await scheduleLine(sc);
      }),
    ),
    tool(
      'delete_schedule',
      'Deletes a schedule so it never sends again.',
      { scheduleId: z.string().describe('Schedule id or a unique prefix.') },
      handle(async ({ scheduleId }) => {
        const s = mustSchedules();
        const sc = await s.find(scheduleId);
        await s.delete(sc.id);
        return `Deleted the schedule "${sc.title}" (${sc.id.slice(0, 8)}).`;
      }),
    ),
  ];

  const mustProjects = (): ProjectControl => {
    if (!projects) throw new Error("This runner doesn't have projects yet.");
    return projects;
  };
  const project = (q: string) => {
    const p = mustProjects().find(q);
    if (!p) throw new Error(`No project ${q}. list_projects shows them.`);
    return p;
  };
  const home = process.env.HOME ?? '';
  const tilde = (p: string) => (home && p.startsWith(home + '/') ? '~' + p.slice(home.length) : p);
  const projectFolder = (f: string): Promise<string> => folder(f);

  const projectTools = [
    tool(
      'list_projects',
      "Lists Mike's projects: groupings above folders that carry goals, state and notes from thread to thread. Shows which this thread is in. A background librarian files threads into them; you can too (join_project), and should keep a project's state and notes current (update_project).",
      { archived: z.boolean().optional().describe('Include archived projects.') },
      handle(async ({ archived }) => {
        const mine = new Set(((await control.get(selfId)).projects ?? []).map((m) => m.id));
        const list = mustProjects().list({ archived });
        if (!list.length) return 'No projects yet. create_project makes one.';
        return list
          .map((p) => {
            const bits = [`${p.id} "${p.title}"${mine.has(p.id) ? ' (this thread is in it)' : ''}${p.archived ? ' (archived)' : ''}`, `${p.threadCount} thread${p.threadCount === 1 ? '' : 's'}`];
            if (p.folders.length) bits.push(`folders ${p.folders.map(tilde).join(', ')}`);
            const state = p.state.split('\n')[0];
            if (state) bits.push(`state: ${clip(state, 160)}`);
            return bits.join(' · ');
          })
          .join('\n');
      }),
    ),
    tool(
      'read_project',
      "Reads a project: its folders, goals, state, notes and threads. Read the notes before working on a project you're in, for decisions and gotchas earlier threads left.",
      { project: z.string().describe('Project id, id prefix or title.') },
      handle(async ({ project: q }) => {
        const { project: p, threadIds } = mustProjects().get(project(q).id);
        const threads: string[] = [];
        for (const id of threadIds.slice(0, 20)) {
          const t = await Promise.resolve(control.get(id)).catch(() => undefined);
          threads.push(`- ${id.slice(0, 8)} "${t?.title ?? '?'}"${id === selfId ? ' (this thread)' : ''}`);
        }
        return [
          `${p.title} (${p.id})${p.archived ? ', archived' : ''}`,
          `Folders: ${p.folders.map(tilde).join(', ') || 'none'}`,
          `Goals: ${p.goals || '(none yet)'}`,
          `State: ${p.state || '(none yet)'}`,
          '',
          'Notes:',
          p.notes || '(none yet)',
          '',
          `Threads (${p.threadCount}):`,
          ...threads,
          ...(threadIds.length > 20 ? [`… and ${threadIds.length - 20} more`] : []),
        ].join('\n');
      }),
    ),
    tool(
      'create_project',
      "Makes a project and puts this thread in it. For a body of work Mike will come back to (an app, a library, a video, an ongoing job), not a single task; check list_projects first so you don't make a second one for the same thing.",
      {
        title: z.string().min(1).describe('Short name, as Mike would say it.'),
        folders: z.array(z.string()).optional().describe("Repos the work lives in. ~ works; relative paths are from this thread's folder."),
        goals: z.string().optional().describe("What it's for and what done looks like, a few lines."),
        state: z.string().optional().describe("Where it's up to and what's next, a few lines."),
        notes: z.string().optional().describe('Markdown: decisions, gotchas, commands, links.'),
        join: z.boolean().optional().describe('Put this thread in it. Default true.'),
      },
      handle(async ({ title, folders, goals, state, notes, join }) => {
        const p = mustProjects().create({
          title,
          folders: await Promise.all((folders ?? []).map(projectFolder)),
          goals,
          state,
          notes,
          by: 'agent',
          byThread: selfId,
          threadIds: join === false ? [] : [selfId],
        });
        return `Made the project "${p.title}" (${p.id})${join === false ? '' : ' and put this thread in it'}.`;
      }),
    ),
    tool(
      'update_project',
      "Changes a project: title, goals, state, notes, folders or icon. Keep state current as work moves on (what's done, what's next, what's blocked), and add to the notes anything a later thread should know. appendNote adds a paragraph without rewriting the notes. The librarian finds icons by itself from the project's folders, so only set one when Mike asks or the project gets a new app icon somewhere it wouldn't look.",
      {
        project: z.string().describe('Project id, id prefix or title.'),
        title: z.string().optional(),
        goals: z.string().optional(),
        state: z.string().optional(),
        notes: z.string().optional().describe('Replaces all the notes.'),
        appendNote: z.string().optional().describe('Adds a paragraph to the end of the notes.'),
        addFolders: z.array(z.string()).optional(),
        removeFolders: z.array(z.string()).optional(),
        icon: z
          .string()
          .optional()
          .describe('A path to a picture (PNG, SVG, ICNS...), an SF Symbol name such as "film", or "auto" to let the librarian find one again.'),
      },
      handle(async ({ project: q, title, goals, state, notes, appendNote, addFolders, removeFolders, icon }) => {
        const pc = mustProjects();
        const p = project(q);
        let folders: string[] | undefined;
        if (addFolders?.length || removeFolders?.length) {
          const drop = new Set(await Promise.all((removeFolders ?? []).map(projectFolder)));
          const add = await Promise.all((addFolders ?? []).map(projectFolder));
          folders = [...p.folders.filter((f) => !drop.has(f)), ...add.filter((f) => !p.folders.includes(f))];
        }
        let out = pc.update(p.id, { title, goals, state, notes, folders });
        if (appendNote?.trim()) out = pc.appendNote(p.id, appendNote);
        if (icon?.trim()) {
          if (!pc.chooseIcon) throw new Error("This runner can't set project icons yet.");
          const v = icon.trim();
          const choice = v === 'auto' ? {} : /[/~]/.test(v) ? { path: v } : { symbol: v };
          out = await pc.chooseIcon(p.id, choice, 'agent');
        }
        return `Updated "${out.title}" (${out.id}).`;
      }),
    ),
    tool(
      'join_project',
      "Puts a thread (this one by default) in a project, so it gets the project's brief and the patches from its folders. Pinned: the librarian won't take it out.",
      { project: z.string().describe('Project id, id prefix or title.'), ...thisOrOther },
      handle(async ({ project: q, threadId, id: alias }) => {
        const id = await resolve(threadId ?? alias);
        const p = project(q);
        mustProjects().changeMembership(id, { add: [p.id], by: 'agent' });
        return `${id === selfId ? 'This thread is' : `"${(await control.get(id)).title}" is`} in "${p.title}" now.`;
      }),
    ),
    tool(
      'leave_project',
      'Takes a thread (this one by default) out of a project. The librarian will not put it back.',
      { project: z.string().describe('Project id, id prefix or title.'), ...thisOrOther },
      handle(async ({ project: q, threadId, id: alias }) => {
        const id = await resolve(threadId ?? alias);
        const p = project(q);
        mustProjects().changeMembership(id, { remove: [p.id], by: 'agent' });
        return `${id === selfId ? 'This thread is' : `"${(await control.get(id)).title}" is`} no longer in "${p.title}".`;
      }),
    ),
  ];

  return [
    // Says what the turn needs from Mike. The runner reads it from the
    // thread's own tool.call when the turn completes (needs.ts), so the
    // handler only checks it; a sub-agent's call never reaches the thread.
    tool(
      END_TURN_TOOL,
      END_TURN_DESCRIPTION,
      {
        needs: z.enum(['you', 'nothing']).describe('"you" when Mike has to do something before this can go on; "nothing" when it is done.'),
        asks: z
          .array(
            z.object({
              action: z.string().min(1).describe('One concrete thing for Mike to do, in a short sentence: "Paste your OpenRouter key into Settings".'),
              where: z.string().optional().describe('Where he does it: an app, site, file or person, e.g. "Threadbear › Settings › Models".'),
              reply: z.string().optional().describe('The exact words to send back when it is done, e.g. "done" or "key set". Leave it out when the reply is his own answer (a decision, a choice).'),
              why: z.string().optional().describe('One line of context, for when he has forgotten the details: "Preview is green and the events arrive."'),
              options: z.array(z.string()).max(6).optional().describe('Likely answers to pick from, short: ["Merge", "Test locally first"]. He can always write his own instead.'),
              suggested: z.number().int().optional().describe('Index into options of the answer you would pick.'),
            }),
          )
          .max(10)
          .optional()
          .describe('With needs "you": each thing he has to do, most blocking first. Usually one or two.'),
        archive: z
          .boolean()
          .optional()
          .describe('true to archive this thread once the turn is over. Only when Mike has asked for this thread to be archived, and only with needs "nothing".'),
      },
      handle(async ({ needs, asks, archive }) => {
        // Asking Mike to Restart to Update means wanting to know when he
        // has, to check the change in the running app: the same as
        // wait_for_app_restart, unless that was already asked for.
        let restart = '';
        if (needs === 'you' && appRestarts && asksForAppRestart(asks)) {
          if (!appRestarts.isWatching(selfId)) appRestarts.watch(selfId);
          restart = " You'll get a message here when the app restarts onto the new build.";
        }
        return needs === 'you'
          ? `Noted: this thread will wait in Needs you${archive ? ', and stays in the inbox, as it needs something from Mike' : ''}.${restart} End the turn now, with no more text.`
          : `Noted: this thread is done${archive ? ', and will be archived once the turn is over' : ''}. End the turn now, with no more text.`;
      }),
    ),
    ...(appRestarts
      ? [
          tool(
            'wait_for_app_restart',
            "Sends you a message in this thread when Mike's Threadbear Mac app next restarts onto a new build: after you've landed an app change and asked him to Restart to Update (in the Threadbear menu), so you can check it in the running app. An end_turn ask that mentions Restart to Update does this by itself. `text` is what to send then; by default a line saying it restarted. One per thread: asking again replaces it.",
            { text: z.string().max(4000).optional().describe('What to send when it restarts, e.g. what to check.') },
            handle(async ({ text }) => {
              const { build } = appRestarts.watch(selfId, text);
              return `You'll get a message here when the app restarts onto a build other than the one running now${build ? ` (${build.short})` : ''}. End your turn when you've nothing else to do.`;
            }),
          ),
        ]
      : []),
    ...reviewTools,
    ...highlightTools,
    ...(schedules ? scheduleTools : []),
    ...(projects ? projectTools : []),
    tool(
      'list_threads',
      "Lists Threadbear threads, newest activity first: short id, title, status, folder, account. By default the inbox; include snoozed and archived ones to see everything. With a query, searches titles and previews across all threads.",
      {
        include: z.array(z.enum(['inbox', 'snoozed', 'archived'])).optional().describe('Which lists to include. Default ["inbox"].'),
        query: z.string().optional().describe('Words to search for in titles and previews, across every list.'),
        limit: z.number().int().min(1).max(200).optional().describe('Most threads to return. Default 30.'),
      },
      handle(async ({ include, query, limit }) => {
        const threads = query ? await control.search(query, limit ?? 30) : (await control.list(include ?? ['inbox'])).slice(0, limit ?? 30);
        return threads.length ? threads.map(line).join('\n') : 'No threads.';
      }),
    ),
    tool(
      'read_thread',
      'Shows a thread\'s settings and its most recent messages from Mike and the agent (tool calls left out). Leave threadId out for this thread.',
      {
        ...thisOrOther,
        messages: z.number().int().min(1).max(100).optional().describe('How many recent messages. Default 10.'),
      },
      handle(async ({ threadId, id: alias, messages }) => {
        const id = await resolve(threadId ?? alias);
        const t = await control.get(id);
        const want = messages ?? 10;
        const picked: string[] = [];
        let before: number | undefined;
        // Walk back a page at a time until there are enough messages.
        for (let pages = 0; pages < 20 && picked.length < want; pages++) {
          const page = await control.events(id, { beforeSeq: before, limit: 500 });
          const evs = page.events as PersistedEvent[];
          for (const e of [...evs].reverse()) {
            if (picked.length >= want) break;
            // The runner's own messages (the resume after a restart) aren't
            // Mike's, and an agent shouldn't take them for his instructions.
            if (e.type === 'user.message') picked.push(`${e.origin === 'runner' ? 'Runner' : e.origin === 'schedule' ? 'Schedule' : 'Mike'} (${e.ts}):\n${clip(e.text)}`);
            else if (e.type === 'assistant.text') picked.push(`Agent (${e.ts}):\n${clip(e.text)}`);
          }
          if (!evs.length || page.firstSeq <= 1) break;
          before = page.firstSeq;
        }
        return `${describe(t)}\n\n${picked.reverse().join('\n\n') || '(no messages yet)'}`;
      }),
      { annotations: { readOnlyHint: true } },
    ),
    tool(
      'list_accounts',
      'Lists the Claude and Codex logins Threadbear can run threads on (provider, how much room each has left, its models), then the pools: named lists of logins a thread can run on, where the runner picks the login with room for each turn and moves the thread when one runs dry. Says which pool a new thread with no account or pool starts on.',
      {},
      handle(async () => {
        const h = control.hello();
        const rows = h.accounts.map((a) => {
          const bits = [providerName(a), a.note ?? '', usageLine(a.usage, now()), a.id === h.defaults.accountId ? 'default for new threads' : ''].filter(Boolean);
          const head = `${a.id}  ${a.title}  [${bits.join('; ')}]`;
          const models = a.models?.length ? `\n    models: ${a.models.map((m) => (m.model === a.defaultModel || m.id === a.defaultModel ? `${m.id} (default)` : m.id)).join(', ')}` : '';
          return head + models;
        });
        const pools = (h.pools ?? []).map((p) => {
          const flags = [p.folders?.length ? `folders: ${p.folders.join(', ')}` : '', p.id === h.defaults.poolId ? 'new threads start here' : ''].filter(Boolean);
          return `${p.id}  ${p.title}: ${poolLine(p, h.accounts, now())}${flags.length ? `  [${flags.join('; ')}]` : ''}`;
        });
        const poolText = pools.length ? `\n\nPools (a new thread in a pool's folder starts on that pool):\n${pools.join('\n')}` : '';
        return `${rows.join('\n')}${poolText}\n\nDefault folder: ${h.defaults.cwd}`;
      }),
      { annotations: { readOnlyHint: true } },
    ),
    tool(
      'create_thread',
      'Starts a new Threadbear thread and sends it a first message straight away; it runs on its own, like Mike starting it from the app. Returns the new thread\'s id. Use read_thread later to see how it went.',
      {
        text: z.string().min(1).describe('The first message: a complete brief, since the new thread knows nothing else.'),
        title: z.string().optional().describe('Title for the sidebar. Default: the first line of text.'),
        folder: z.string().optional().describe("Working folder. Default: this thread's folder. Relative paths are from this thread's folder."),
        pool: z.string().optional().describe("Pool id or title (see list_accounts). The runner picks the pool's login with room for each turn and moves the thread when one runs dry. Default: the folder's pool, else the one with the model's provider, else the last one picked."),
        account: z.string().optional().describe('Account id or email, Claude or Codex (see list_accounts). Pins the thread to that login, which it then never leaves; leave it out to let a pool pick.'),
        model: z.string().optional().describe("Model id, one of the account's (list_accounts shows them; Codex ones look like gpt-6-luna). With no account or pool, its provider picks the pool. Default: the runner's default model for the provider if it has one (a dev runner's is the cheapest), else the account's."),
        effort: effortEnum.optional().describe("Reasoning effort (ultra is Codex only). Default: the model's own level."),
        permissionMode: z.enum(['full', 'ask']).optional().describe('"full" (default) or "ask" before edits and commands.'),
      },
      handle(async ({ text, title, folder: f, pool: p, account: acc, model, effort, permissionMode }) => {
        const r = await control.create({
          text: (await from()) + text,
          title: title?.trim() || text.split('\n').map((l) => l.trim()).find(Boolean)?.slice(0, 200),
          cwd: await folder(f ?? '.'),
          accountId: await account(acc),
          ...(p !== undefined && !acc ? { poolId: pool(p) } : {}),
          model,
          effort,
          permissionMode,
        });
        const where = r.thread.poolId ? ` It's in the ${r.thread.poolId} pool, so it moves to another login if this one runs dry.` : '';
        return `Started thread ${r.thread.id} "${r.thread.title}" in ${r.thread.cwd} on ${r.thread.accountId}${r.thread.model ? ` (${r.thread.model})` : ''}.${where}`;
      }),
    ),
    tool(
      'send_message',
      'Sends a message to another thread, as if typed into it. If that thread is busy the message goes into its running turn, where its agent sees it at its next step (or straight after its reply). A snoozed or archived thread comes back to the inbox.',
      {
        ...other,
        text: z.string().min(1),
      },
      handle(async ({ threadId, id: alias, text }) => {
        const id = await resolveOther(threadId ?? alias);
        if (id === selfId) throw new Error("That's this thread. Just carry on here.");
        await control.send(id, (await from()) + text);
        return `Sent to ${id.slice(0, 8)} "${(await control.get(id)).title}".`;
      }),
    ),
    tool(
      'update_thread',
      "Changes a thread's title, model or permissions, snoozes it, or archives it. Leave threadId out for this thread. This thread can be renamed or have its model or permissions changed, but not snoozed or archived while it's working (that would stop this turn). If Mike asks for this thread to be archived, pass archive: true to end_turn instead.",
      {
        ...thisOrOther,
        title: z.string().optional(),
        mikeAsked: z.boolean().optional().describe('true when Mike asked for this title. A thread Mike named himself keeps his title unless he asks for a new one.'),
        model: z.string().nullable().optional().describe('Model id, or null for the account default.'),
        effort: effortEnum.nullable().optional().describe("Reasoning effort, or null for the model's own level (ultra is Codex only)."),
        pool: z.string().nullable().optional().describe('Pool id or title to put the thread in (it moves onto one of its logins from the next turn if its current one isn\'t in it), or null or "pin" to pin it to its current login.'),
        permissionMode: z.enum(['full', 'ask']).optional(),
        snooze: z.string().optional().describe('Snooze until: 30m, 2h, 1d, tomorrow, an ISO time, "restart" (until the runner next starts), or "off" to wake it.'),
        archived: z.boolean().optional().describe('true to archive, false to bring back to the inbox.'),
      },
      handle(async ({ threadId, id: alias, title, mikeAsked, model, effort, pool: p, permissionMode, snooze, archived }) => {
        const id = await resolve(threadId ?? alias);
        const stops = (snooze !== undefined && snooze.trim().toLowerCase() !== 'off') || archived === true;
        if (id === selfId && stops) throw new Error("Can't snooze or archive this thread from inside its own turn. Ask Mike to, or do it when the work is done.");
        const upd: Parameters<ThreadControl['update']>[0] = { threadId: id };
        if (title !== undefined) {
          upd.title = title;
          upd.titleBy = mikeAsked ? 'mike' : 'agent';
        }
        if (model !== undefined) upd.model = model;
        if (effort !== undefined) upd.effort = effort;
        if (p !== undefined) upd.poolId = p === null || p.trim().toLowerCase() === 'pin' ? null : pool(p);
        if (permissionMode !== undefined) upd.permissionMode = permissionMode;
        if (snooze !== undefined) {
          const word = snooze.trim().toLowerCase();
          upd.snoozedUntil = word === 'off' ? null : word === 'restart' ? 'restart' : parseWhen(snooze, now());
        }
        if (archived !== undefined) upd.archived = archived;
        return describe((await control.update(upd)).thread);
      }),
    ),
    tool(
      'move_thread',
      "Moves a thread to another working folder (and optionally another account). For this thread the move happens when the current turn ends: the next message starts the CLI in the new folder and, on the same account, resumes the whole conversation there; on a new account it starts fresh with a short summary. Pass `then` to have this thread carry on by itself straight after the move, with that text as its next message; without it, the thread waits for Mike.",
      {
        folder: z.string().describe("The new folder. ~ works; relative paths are from this thread's current folder."),
        ...thisOrOther,
        account: z.string().optional().describe('Also move to this account (id or email), Claude or Codex. Another provider starts fresh with a summary, on that provider\'s default model.'),
        then: z.string().optional().describe('For this thread: what to do next once moved, sent as the next message.'),
      },
      handle(async ({ folder: f, threadId, id: alias, account: acc, then }) => {
        const id = await resolve(threadId ?? alias);
        const cwd = await folder(f);
        const t = (await control.update({ threadId: id, cwd, accountId: await account(acc) })).thread;
        const self = id === selfId;
        if (then?.trim()) {
          await control.send(id, `[Sent by the agent before moving to ${t.cwd}]\n\n${then.trim()}`);
        }
        const when = self ? 'when this turn ends' : 'on its next message';
        const next = then?.trim() ? (self ? ' It carries on by itself straight after.' : ' Your message waits for it.') : self ? ' It waits for Mike after that.' : '';
        return `Moved ${self ? 'this thread' : `"${t.title}"`} to ${t.cwd}${acc ? ` on ${t.accountId}` : ''}. That takes effect ${when}.${next}`;
      }),
    ),
    tool(
      'interrupt_thread',
      'Stops the turn another thread is running, like pressing Stop in the app.',
      other,
      handle(async ({ threadId, id: alias }) => {
        const id = await resolveOther(threadId ?? alias);
        if (id === selfId) throw new Error("That's this thread. Just end the turn.");
        await control.interrupt(id);
        return `Interrupted ${id.slice(0, 8)} "${(await control.get(id)).title}".`;
      }),
    ),
    tool(
      'delete_thread',
      "Deletes a thread: stops its CLI and moves its files to Threadbear's trash folder. Mike is always asked first. Archiving is usually what's wanted; delete only when he asked for it.",
      other,
      handle(async ({ threadId, id: alias }) => {
        const id = await resolveOther(threadId ?? alias);
        if (id === selfId) throw new Error("A thread can't delete itself.");
        const title = (await control.get(id)).title;
        await control.delete(id);
        return `Deleted "${title}" (${id.slice(0, 8)}).`;
      }),
      { annotations: { destructiveHint: true } },
    ),
  ];
}

function snoozeEnd(t: ThreadSummary): string {
  return t.snoozedUntilRestart ? 'the runner restarts' : t.snoozedUntil ?? '';
}

function clip(text: string, max = 2000): string {
  return text.length > max ? `${text.slice(0, max)}… (${text.length - max} more characters)` : text;
}

// In the server's instructions, which every thread sees from its first
// turn. Tool descriptions aren't enough: the CLI defers MCP tools, so an
// agent sees only their names until it loads one, and an agent that made
// three mockups pinned them and asked in chat instead of calling
// show_options, never knowing the review window was there.
export const SHOWING_MIKE =
  'When you have design options, mockups or wireframes for Mike to choose between, put them in front of him with show_options (a side-by-side review window where he picks one and leaves notes), not as pins or a list in your reply; his answer comes back as a message. ' +
  "For a single file or link he should look at (a doc, a screenshot, a preview URL, a PR), use pin, with show: true to open it in Threadbear's side pane rather than running `open`. " +
  'After landing a change to the Threadbear Mac app, ask Mike to Restart to Update (Threadbear menu) in end_turn: you get a message here when the app is back on the new build (wait_for_app_restart says what to send).';

// Also in the instructions, for the same reason. The librarian files
// threads by itself, but it only sees a summary and can miss one; the
// thread's own agent knows what it's working on. Once an agent (or Mike)
// has filed a thread, the librarian leaves its projects alone.
export const FILING_PROJECTS =
  "If this thread's work belongs to one of Mike's projects (list_projects) and it isn't in it yet, put it there early with join_project, or make one with create_project for a new body of work he'll come back to (not for a one-off question or chore). " +
  "When the thread ships or finishes something, makes a decision or hits a blocker that changes where the project stands, update the project's state with update_project.";

export function threadbearMcpServer(control: ThreadControl, selfId: string, schedules?: ScheduleControl, projects?: ProjectControl, appRestarts?: AppRestartControl): McpSdkServerConfigWithInstance {
  const server = createSdkMcpServer({
    name: SERVER_NAME,
    version: RUNNER_VERSION,
    instructions:
      `This session is a thread in Threadbear, Mike's own app for running agent threads (thread id ${selfId}). ` +
      'These tools manage Threadbear itself: list and read threads, start new ones, message them, rename, snooze, archive, move and delete them, schedule messages for later (once or on a cron), and keep Mike\'s projects (groupings above folders with goals, state and notes) up to date. ' +
      'Use move_thread when the work belongs in another folder (for example a repo), so this thread runs there from the next turn. ' +
      `${SHOWING_MIKE} ` +
      (projects ? `${FILING_PROJECTS} ` : '') +
      'End every turn by calling end_turn, after your final message, to say whether Mike has to do anything.',
    tools: buildThreadbearTools(control, selfId, Date.now, schedules, projects, appRestarts),
  });
  server.tools = [...ALWAYS_ASK_TOOLS].map((name) => ({ name: name.split('__').at(-1)!, permission_policy: 'always_ask' as const }));
  return server;
}
