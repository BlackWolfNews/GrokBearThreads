// Tools that let an agent drive Threadbare itself: list and read threads,
// start new ones, message them, rename, snooze, archive, move and delete
// them. The runner hands each Claude session its own in-process MCP server
// ("threadbare"), built with that session's thread id, so "this thread" is
// always the caller and nothing has to go over the WebSocket.
import path from 'node:path';
import { createSdkMcpServer, tool } from '@anthropic-ai/claude-agent-sdk';
import type { McpSdkServerConfigWithInstance } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';
import type { Runner } from './runner.ts';
import type { Account, PersistedEvent, Schedule, ThreadSummary } from './protocol.ts';
import type { Scheduler } from './schedules.ts';
import { parseWhen, relativeFuture, relativeTime } from './when.ts';

export { parseWhen, relativeFuture, relativeTime };
import { RUNNER_VERSION, expandHome } from './config.ts';

export type ThreadControl = Pick<
  Runner,
  'hello' | 'list' | 'search' | 'get' | 'events' | 'create' | 'send' | 'update' | 'interrupt' | 'delete'
>;

export type ScheduleControl = Pick<Scheduler, 'create' | 'list' | 'find' | 'update' | 'delete'>;

export const SERVER_NAME = 'threadbare';
// Asked about every time, even in a thread with full access: deleting is
// the one thing here that's hard to take back.
export const ALWAYS_ASK_TOOLS = new Set([`mcp__${SERVER_NAME}__delete_thread`]);

type Result = { content: { type: 'text'; text: string }[]; isError?: boolean };

const ok = (text: string): Result => ({ content: [{ type: 'text', text }] });
const fail = (text: string): Result => ({ content: [{ type: 'text', text }], isError: true });

function handle<A>(fn: (args: A) => string): (args: A) => Promise<Result> {
  return async (args) => {
    try {
      return ok(fn(args));
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

// Says which thread a threadbare tool call is about by its title, for the
// approval card ("Delete "Fix the tests"?" rather than a bare id).
export function approvalTitle(name: string, input: Record<string, unknown>, find: (idOrPrefix: string) => ThreadSummary | undefined): string | undefined {
  if (name !== `mcp__${SERVER_NAME}__delete_thread`) return undefined;
  const id = typeof input.threadId === 'string' ? input.threadId : typeof input.id === 'string' ? input.id : '';
  const t = id ? find(id) : undefined;
  return t ? `Delete the thread "${t.title}"` : undefined;
}

export function buildThreadbareTools(control: ThreadControl, selfId: string, now: () => number = Date.now, schedules?: ScheduleControl) {
  const all = (): ThreadSummary[] => control.list(['inbox', 'snoozed', 'archived']);

  // Full ids, or any unique prefix of one (the list shows 8 characters).
  const resolve = (id: string | undefined): string => {
    if (!id) return selfId;
    const hits = all().filter((t) => t.id === id || t.id.startsWith(id));
    if (hits.length === 1) return hits[0].id;
    if (hits.length === 0) throw new Error(`No thread with id ${id}. list_threads shows them.`);
    throw new Error(`${id} matches ${hits.length} threads; use more of the id.`);
  };

  const resolveOther = (id: string | undefined): string => {
    if (!id) throw new Error('threadId is required. list_threads shows the ids.');
    return resolve(id);
  };

  const account = (q: string | undefined): string | undefined => {
    if (!q) return undefined;
    const accounts: Account[] = control.hello().accounts;
    const hit =
      accounts.find((a) => a.id === q) ??
      accounts.find((a) => a.title === q) ??
      accounts.find((a) => a.title.split('@')[0] === q);
    if (!hit) throw new Error(`No account ${q}. Accounts: ${accounts.map((a) => `${a.id} (${a.title})`).join(', ')}`);
    return hit.id;
  };

  const folder = (f: string): string => {
    const base = control.get(selfId).cwd;
    return path.resolve(base, expandHome(f.trim()));
  };

  const line = (t: ThreadSummary): string => {
    const where = t.archivedAt ? 'archived' : t.snoozedUntil ? `snoozed until ${t.snoozedUntil}` : 'inbox';
    const flags = [t.status, where, t.needsYou ? 'needs Mike' : '', t.id === selfId ? 'this thread' : ''].filter(Boolean).join(', ');
    return `${t.id.slice(0, 8)}  ${t.title}  [${flags}]  ${t.cwd}  ${t.accountId}  ${relativeTime(t.lastActivityAt, now())}`;
  };

  const describe = (t: ThreadSummary): string =>
    [
      `id: ${t.id}`,
      `title: ${t.title}`,
      `status: ${t.status}${t.needsYou ? ' (needs Mike)' : ''}`,
      `folder: ${t.cwd}`,
      `account: ${t.accountId}`,
      `model: ${t.model ?? 'default'}${t.modelInUse ? ` (running as ${t.modelInUse})` : ''}`,
      `effort: ${t.effort ?? 'default'}${t.effortInUse ? ` (${t.effortInUse} last turn)` : ''}`,
      `permissions: ${t.permissionMode === 'full' ? 'full access' : 'ask before edits'}`,
      t.snoozedUntil ? `snoozed until: ${t.snoozedUntil}` : '',
      t.archivedAt ? `archived: ${t.archivedAt}` : '',
      `last activity: ${relativeTime(t.lastActivityAt, now())}`,
      t.costUsd !== undefined ? `cost so far: $${t.costUsd.toFixed(2)}` : '',
    ]
      .filter(Boolean)
      .join('\n');

  // Messages an agent sends say where they came from, so whoever reads the
  // other thread (Mike or its agent) knows it wasn't Mike typing.
  const from = (): string => `[Sent by the agent in the thread "${control.get(selfId).title}" (${selfId.slice(0, 8)})]\n\n`;


  const titleOf = (id: string): string => {
    try {
      return `"${control.get(id).title}"`;
    } catch {
      return id.slice(0, 8);
    }
  };

  const scheduleLine = (sc: Schedule): string => {
    const state = sc.finishedAt ? 'done' : sc.paused ? 'paused' : sc.nextRunAt ? `next ${relativeFuture(sc.nextRunAt, now())} (${sc.nextRunAt})` : 'no more runs';
    const target = sc.threadId ? (sc.threadId === selfId ? 'this thread' : `thread ${sc.threadId.slice(0, 8)} ${titleOf(sc.threadId)}`) : `a new thread in ${sc.cwd}`;
    const last = sc.lastRun && sc.lastRun.outcome !== 'sent' ? `; last run ${sc.lastRun.outcome}: ${sc.lastRun.note ?? ''}` : '';
    return `${sc.id.slice(0, 8)}  ${sc.title}  [${sc.whenText}; ${state}${last}]  to ${target}`;
  };

  const mustSchedules = (): ScheduleControl => {
    if (!schedules) throw new Error("This runner doesn't have schedules.");
    return schedules;
  };

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
        account: z.string().optional().describe('With new_thread: account id or email. Default: the last one used.'),
        model: z.string().optional().describe('With new_thread: model id.'),
        effort: z.enum(['low', 'medium', 'high', 'xhigh', 'max']).optional().describe('With new_thread: reasoning effort.'),
        permissionMode: z.enum(['full', 'ask']).optional().describe('With new_thread: "full" (default) or "ask".'),
      },
      handle(({ text, when, cron, timezone, title, threadId, id: alias, new_thread, folder: f, account: acc, model, effort, permissionMode }) => {
        if ((when === undefined) === (cron === undefined)) throw new Error('Give exactly one of when (once) and cron (repeating).');
        const target = new_thread
          ? { cwd: folder(f ?? '.'), accountId: account(acc), model, effort, permissionMode }
          : { threadId: resolve(threadId ?? alias) };
        if (!new_thread && (f || acc || model || effort || permissionMode)) throw new Error('folder, account, model, effort and permissionMode are for new_thread schedules; a thread keeps its own.');
        const sc = mustSchedules().create({
          text,
          title,
          ...(when !== undefined ? { at: parseWhen(when, now()) } : { cron }),
          timezone,
          ...target,
          createdBy: selfId,
        });
        return `Scheduled ${sc.id.slice(0, 8)}: ${scheduleLine(sc)}`;
      }),
    ),
    tool(
      'list_schedules',
      "Lists Threadbare's schedules: short id, title, when, the next run and where it sends. By default the ones that send to this thread or that this thread made; all for every schedule.",
      { all: z.boolean().optional().describe('Every schedule, not just this thread\'s.') },
      handle(({ all: everything }) => {
        const list = mustSchedules().list(everything ? undefined : selfId);
        return list.length ? list.map(scheduleLine).join('\n') : everything ? 'No schedules.' : 'No schedules for this thread. all: true shows every schedule.';
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
      handle(({ scheduleId, text, title, when, cron, timezone, paused }) => {
        const sc = mustSchedules().update({
          scheduleId,
          text,
          title,
          at: when === undefined ? undefined : parseWhen(when, now()),
          cron,
          timezone,
          paused,
        });
        return scheduleLine(sc);
      }),
    ),
    tool(
      'delete_schedule',
      'Deletes a schedule so it never sends again.',
      { scheduleId: z.string().describe('Schedule id or a unique prefix.') },
      handle(({ scheduleId }) => {
        const s = mustSchedules();
        const sc = s.find(scheduleId);
        s.delete(sc.id);
        return `Deleted the schedule "${sc.title}" (${sc.id.slice(0, 8)}).`;
      }),
    ),
  ];

  return [
    ...(schedules ? scheduleTools : []),
    tool(
      'list_threads',
      "Lists Threadbare threads, newest activity first: short id, title, status, folder, account. By default the inbox; include snoozed and archived ones to see everything. With a query, searches titles and previews across all threads.",
      {
        include: z.array(z.enum(['inbox', 'snoozed', 'archived'])).optional().describe('Which lists to include. Default ["inbox"].'),
        query: z.string().optional().describe('Words to search for in titles and previews, across every list.'),
        limit: z.number().int().min(1).max(200).optional().describe('Most threads to return. Default 30.'),
      },
      handle(({ include, query, limit }) => {
        const threads = query ? control.search(query, limit ?? 30) : control.list(include ?? ['inbox']).slice(0, limit ?? 30);
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
      handle(({ threadId, id: alias, messages }) => {
        const id = resolve(threadId ?? alias);
        const t = control.get(id);
        const want = messages ?? 10;
        const picked: string[] = [];
        let before: number | undefined;
        // Walk back a page at a time until there are enough messages.
        for (let pages = 0; pages < 20 && picked.length < want; pages++) {
          const page = control.events(id, { beforeSeq: before, limit: 500 });
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
      'Lists the Claude logins Threadbare can run threads on, and the defaults for new threads.',
      {},
      handle(() => {
        const h = control.hello();
        const rows = h.accounts.map((a) => `${a.id}  ${a.title}${a.id === h.defaults.accountId ? '  (default)' : ''}`);
        return `${rows.join('\n')}\n\nDefault folder: ${h.defaults.cwd}`;
      }),
      { annotations: { readOnlyHint: true } },
    ),
    tool(
      'create_thread',
      'Starts a new Threadbare thread and sends it a first message straight away; it runs on its own, like Mike starting it from the app. Returns the new thread\'s id. Use read_thread later to see how it went.',
      {
        text: z.string().min(1).describe('The first message: a complete brief, since the new thread knows nothing else.'),
        title: z.string().optional().describe('Title for the sidebar. Default: the first line of text.'),
        folder: z.string().optional().describe("Working folder. Default: this thread's folder. Relative paths are from this thread's folder."),
        account: z.string().optional().describe('Account id or email (see list_accounts). Default: the last one used.'),
        model: z.string().optional().describe("Model id. Default: the runner's default model if it has one (a dev runner's is the cheapest), else the account's."),
        effort: z.enum(['low', 'medium', 'high', 'xhigh', 'max']).optional().describe("Reasoning effort. Default: the model's own level."),
        permissionMode: z.enum(['full', 'ask']).optional().describe('"full" (default) or "ask" before edits and commands.'),
      },
      handle(({ text, title, folder: f, account: acc, model, effort, permissionMode }) => {
        const r = control.create({
          text: from() + text,
          title: title?.trim() || text.split('\n').map((l) => l.trim()).find(Boolean)?.slice(0, 200),
          cwd: folder(f ?? '.'),
          accountId: account(acc),
          model,
          effort,
          permissionMode,
        });
        return `Started thread ${r.thread.id} "${r.thread.title}" in ${r.thread.cwd} on ${r.thread.accountId}.`;
      }),
    ),
    tool(
      'send_message',
      'Sends a message to another thread, as if typed into it. If that thread is busy the message goes into its running turn, where its agent sees it at its next step (or straight after its reply). A snoozed or archived thread comes back to the inbox.',
      {
        ...other,
        text: z.string().min(1),
      },
      handle(({ threadId, id: alias, text }) => {
        const id = resolveOther(threadId ?? alias);
        if (id === selfId) throw new Error("That's this thread. Just carry on here.");
        control.send(id, from() + text);
        return `Sent to ${id.slice(0, 8)} "${control.get(id).title}".`;
      }),
    ),
    tool(
      'update_thread',
      "Changes a thread's title, model or permissions, snoozes it, or archives it. Leave threadId out for this thread. This thread can be renamed or have its model or permissions changed, but not snoozed or archived while it's working (that would stop this turn); say so to Mike instead.",
      {
        ...thisOrOther,
        title: z.string().optional(),
        model: z.string().nullable().optional().describe('Model id, or null for the account default.'),
        effort: z.enum(['low', 'medium', 'high', 'xhigh', 'max']).nullable().optional().describe("Reasoning effort, or null for the model's own level."),
        permissionMode: z.enum(['full', 'ask']).optional(),
        snooze: z.string().optional().describe('Snooze until: 30m, 2h, 1d, tomorrow, an ISO time, or "off" to wake it.'),
        archived: z.boolean().optional().describe('true to archive, false to bring back to the inbox.'),
      },
      handle(({ threadId, id: alias, title, model, effort, permissionMode, snooze, archived }) => {
        const id = resolve(threadId ?? alias);
        const stops = (snooze !== undefined && snooze.trim().toLowerCase() !== 'off') || archived === true;
        if (id === selfId && stops) throw new Error("Can't snooze or archive this thread from inside its own turn. Ask Mike to, or do it when the work is done.");
        const upd: Parameters<ThreadControl['update']>[0] = { threadId: id };
        if (title !== undefined) upd.title = title;
        if (model !== undefined) upd.model = model;
        if (effort !== undefined) upd.effort = effort;
        if (permissionMode !== undefined) upd.permissionMode = permissionMode;
        if (snooze !== undefined) upd.snoozedUntil = snooze.trim().toLowerCase() === 'off' ? null : parseWhen(snooze, now());
        if (archived !== undefined) upd.archived = archived;
        return describe(control.update(upd).thread);
      }),
    ),
    tool(
      'move_thread',
      "Moves a thread to another working folder (and optionally another account). For this thread the move happens when the current turn ends: the next message starts the CLI in the new folder and, on the same account, resumes the whole conversation there; on a new account it starts fresh with a short summary. Pass `then` to have this thread carry on by itself straight after the move, with that text as its next message; without it, the thread waits for Mike.",
      {
        folder: z.string().describe("The new folder. ~ works; relative paths are from this thread's current folder."),
        ...thisOrOther,
        account: z.string().optional().describe('Also move to this account (id or email).'),
        then: z.string().optional().describe('For this thread: what to do next once moved, sent as the next message.'),
      },
      handle(({ folder: f, threadId, id: alias, account: acc, then }) => {
        const id = resolve(threadId ?? alias);
        const cwd = folder(f);
        const t = control.update({ threadId: id, cwd, accountId: account(acc) }).thread;
        const self = id === selfId;
        if (then?.trim()) {
          control.send(id, `[Sent by the agent before moving to ${t.cwd}]\n\n${then.trim()}`);
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
      handle(({ threadId, id: alias }) => {
        const id = resolveOther(threadId ?? alias);
        if (id === selfId) throw new Error("That's this thread. Just end the turn.");
        control.interrupt(id);
        return `Interrupted ${id.slice(0, 8)} "${control.get(id).title}".`;
      }),
    ),
    tool(
      'delete_thread',
      "Deletes a thread: stops its CLI and moves its files to Threadbare's trash folder. Mike is always asked first. Archiving is usually what's wanted; delete only when he asked for it.",
      other,
      handle(({ threadId, id: alias }) => {
        const id = resolveOther(threadId ?? alias);
        if (id === selfId) throw new Error("A thread can't delete itself.");
        const title = control.get(id).title;
        control.delete(id);
        return `Deleted "${title}" (${id.slice(0, 8)}).`;
      }),
      { annotations: { destructiveHint: true } },
    ),
  ];
}

function clip(text: string, max = 2000): string {
  return text.length > max ? `${text.slice(0, max)}… (${text.length - max} more characters)` : text;
}

export function threadbareMcpServer(control: ThreadControl, selfId: string, schedules?: ScheduleControl): McpSdkServerConfigWithInstance {
  const server = createSdkMcpServer({
    name: SERVER_NAME,
    version: RUNNER_VERSION,
    instructions:
      `This session is a thread in Threadbare, Mike's own app for running agent threads (thread id ${selfId}). ` +
      'These tools manage Threadbare itself: list and read threads, start new ones, message them, rename, snooze, archive, move and delete them, and schedule messages for later (once or on a cron). ' +
      'Use move_thread when the work belongs in another folder (for example a repo), so this thread runs there from the next turn.',
    tools: buildThreadbareTools(control, selfId, Date.now, schedules),
  });
  server.tools = [...ALWAYS_ASK_TOOLS].map((name) => ({ name: name.split('__').at(-1)!, permission_policy: 'always_ask' as const }));
  return server;
}
