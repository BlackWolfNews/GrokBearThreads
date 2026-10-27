import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makeHarness, tick, tmpDir } from '../helpers/fakes.ts';
import { checkSummary } from '../helpers/protocol-check.ts';
import { Projects, projectMethods, BRIEF_MAX } from '../../src/projects.ts';
import { Librarian, librarianMethods, SETTLE_MS, CATCH_UP_MS } from '../../src/librarian.ts';
import { buildThreadbareTools } from '../../src/threadbare-mcp.ts';
import { FakeClock } from '../../src/clock.ts';
import { nullLogger } from '../../src/log.ts';
import { RpcError } from '../../src/protocol.ts';
import type { GenerateParams, ModelResult } from '../../src/models/index.ts';

// A harness whose runner has projects, with a fake home holding repos.
function setup(opts: { models?: (p: GenerateParams) => Promise<ModelResult<string>> | ModelResult<string> } = {}) {
  const root = tmpDir();
  const repo = (rel: string, files: Record<string, string> = {}) => {
    const dir = path.join(root, rel);
    fs.mkdirSync(path.join(dir, '.git'), { recursive: true });
    for (const [name, text] of Object.entries(files)) {
      fs.mkdirSync(path.dirname(path.join(dir, name)), { recursive: true });
      fs.writeFileSync(path.join(dir, name), text);
    }
    return dir;
  };
  const misc = path.join(root, 'dev/misc');
  fs.mkdirSync(misc, { recursive: true });
  const home = tmpDir();
  const projects = new Projects({ home, clock: new FakeClock(), log: nullLogger, userHome: root });
  const asked: GenerateParams[] = [];
  const models = opts.models
    ? {
        generate: async (p: GenerateParams) => {
          asked.push(p);
          return opts.models!(p);
        },
      }
    : undefined;
  const h = makeHarness(home, {}, { projects, panelsRoot: root, actionShell: ['/bin/sh', '-c'], actionTimeoutMs: 5000 });
  projects.start(h.runner);
  const librarian = new Librarian({ host: h.runner, projects, models, clock: h.clock, log: nullLogger, home, userHome: root });
  librarian.start();
  const create = (text = 'Work on the app', cwd = misc) => h.runner.create({ text, cwd, accountId: 'claude-3' });
  // Ends the thread's running turn as the CLI would.
  const finish = async (threadId: string, edited: string[] = []) => {
    const s = h.adapter.sessions.filter((x) => x.opts.threadId === threadId).at(-1)!;
    s.init();
    for (const file of edited) s.out({ kind: 'event', event: { type: 'tool.call', itemId: `w${Math.random()}`, name: 'Write', kind: 'write', input: { file_path: file, content: 'x' } } as never });
    s.result('completed');
    await tick();
  };
  return { h, root, misc, repo, projects, librarian, asked, create, finish };
}

const rec = (h: ReturnType<typeof makeHarness>, id: string) => h.runner.threadRecords().find((t) => t.id === id)!;
const reply = (v: unknown, costUsd = 0.002): ModelResult<string> => ({ ok: true, value: JSON.stringify(v), model: 'haiku', costUsd });

// ------------------------------------------------------------- projects

test('Mike makes a project with a thread in it: pinned, in the summary, counted, kept', () => {
  const { h, repo, projects, create } = setup();
  const app = repo('dev/app');
  const { thread } = create();
  const p = projects.create({ title: '  Poddle ', folders: [app], goals: 'A podcast player', threadIds: [thread.id.slice(0, 8)], by: 'mike' });
  assert.match(p.id, /^p_[0-9a-f]{8}$/);
  assert.equal(p.title, 'Poddle');
  assert.equal(p.threadCount, 1);
  const s = h.runner.get(thread.id);
  assert.deepEqual(checkSummary(s), []);
  assert.deepEqual(s.projects?.map((m) => [m.id, m.title, m.by, m.pinned]), [[p.id, 'Poddle', 'mike', true]]);
  const sent = h.notes.filter((n) => n.method === 'projects.updated');
  assert.ok(sent.length >= 1);
  // A rename reaches the thread's summary.
  projects.update(p.id, { title: 'Poddle app' });
  assert.equal(h.runner.get(thread.id).projects?.[0].title, 'Poddle app');
  // Bad input is refused with what's wrong.
  assert.throws(() => projects.create({ title: ' ', by: 'mike' }), (e: RpcError) => e.code === -32602);
  assert.throws(() => projects.create({ title: 'x', folders: ['/nope/not/here'], by: 'mike' }), /Folder not found/);
  assert.throws(() => projects.get('p_nothere'), (e: RpcError) => e.code === -32007);
  // Saved: a new store reads it back.
  const again = new Projects({ home: h.home, clock: new FakeClock(), log: nullLogger });
  again.start(h.runner);
  assert.equal(again.find('poddle app')?.id, p.id);
  assert.deepEqual(again.get(p.id).threadIds, [thread.id]);
});

test('membership: the librarian never undoes Mike or an agent, and says what it did', () => {
  const { h, projects, create } = setup();
  const { thread } = create();
  const a = projects.create({ title: 'Alpha', by: 'mike' });
  const b = projects.create({ title: 'Beta', by: 'mike' });
  // The librarian puts it in Alpha: said in the transcript, not pinned.
  const r1 = projects.changeMembership(thread.id, { add: [a.id], by: 'librarian' });
  assert.deepEqual(r1.joined, [a.id]);
  assert.equal(r1.thread.projects?.[0].pinned, undefined);
  assert.ok(h.events(thread.id).some((e) => e.type === 'system.note' && e.text === 'Put in Alpha by the librarian.'));
  // Mike takes it out: remembered, and the librarian can't put it back.
  projects.changeMembership(thread.id, { remove: [a.id], by: 'mike' });
  assert.deepEqual(projects.changeMembership(thread.id, { add: [a.id], by: 'librarian' }).joined, []);
  assert.equal(h.runner.get(thread.id).projects, undefined);
  // An agent joins Beta: pinned, so the librarian can't take it out.
  projects.changeMembership(thread.id, { add: [b.id], by: 'agent' });
  assert.equal(h.runner.get(thread.id).projects?.[0].pinned, true);
  assert.deepEqual(projects.changeMembership(thread.id, { remove: [b.id], by: 'librarian' }).left, []);
  // Mike putting it back in Alpha clears the "never".
  projects.changeMembership(thread.id, { add: [a.id], by: 'mike' });
  assert.deepEqual(h.runner.get(thread.id).projects?.map((m) => m.id), [b.id, a.id]);
  assert.equal(rec(h, thread.id)?.projectsLeft, undefined);
});

test('merge moves threads, folders and notes over; delete takes threads out', () => {
  const { h, repo, projects, create } = setup();
  const one = repo('dev/one');
  const two = repo('dev/two');
  const { thread: t1 } = create('first');
  const { thread: t2 } = create('second');
  const a = projects.create({ title: 'A', folders: [one], notes: 'from a', threadIds: [t1.id], by: 'mike' });
  const b = projects.create({ title: 'B', folders: [two], notes: 'about b', threadIds: [t1.id, t2.id], by: 'mike' });
  const kept = projects.merge(a.id, b.id);
  assert.equal(kept.id, b.id);
  assert.deepEqual(kept.folders, [two, one]);
  assert.equal(kept.notes, 'about b\n\n## From A\n\nfrom a');
  assert.equal(kept.threadCount, 2);
  assert.deepEqual(h.runner.get(t1.id).projects?.map((m) => m.id), [b.id], 'in B once, not twice');
  assert.equal(projects.find(a.id), undefined);
  projects.delete(b.id);
  assert.equal(h.runner.get(t1.id).projects, undefined);
  assert.deepEqual(projects.list(), []);
});

test('the RPC methods: list, get, create, update, setProjects, archive', () => {
  const { h, projects, create } = setup();
  const m = projectMethods(projects);
  const { thread } = create();
  const { project } = m['projects.create']({ title: 'Gamma', goals: 'Do it', threadIds: [thread.id] }) as any;
  assert.equal(project.createdBy, 'mike');
  const got = m['projects.get']({ projectId: project.id }) as any;
  assert.deepEqual(got.threadIds, [thread.id]);
  m['projects.update']({ projectId: project.id, archived: true });
  assert.equal((m['projects.list']({}) as any).projects.length, 0);
  assert.equal((m['projects.list']({ archived: true }) as any).projects[0].archived, true);
  const r = m['threads.setProjects']({ threadId: thread.id, remove: [project.id] }) as any;
  assert.equal(r.thread.projects, undefined);
  assert.throws(() => m['projects.update']({ projectId: project.id, folders: 'nope' }), /folders must be a list/);
});

// ------------------------------------------------------- brief and patches

test('a session starting on a thread in projects gets the brief; a live one hears about a new project once', async () => {
  const { h, repo, projects, create, finish } = setup();
  const app = repo('dev/app');
  const p = projects.create({ title: 'Poddle', folders: [app], goals: 'A podcast player for Mike', state: 'Build 12 is in review', by: 'mike' });
  const { thread } = create();
  // Not in any project when its CLI started: no brief.
  assert.equal(h.adapter.last.opts.instructions, undefined);
  await finish(thread.id);
  projects.changeMembership(thread.id, { add: [p.id], by: 'librarian' });
  h.runner.send(thread.id, 'carry on');
  await tick();
  const sent = h.adapter.last.sent.at(-1)!;
  assert.match(sent.text, /^\[Threadbear project\] This thread is now part of the project "Poddle" \(p_[0-9a-f]+\)\. Goals: A podcast player for Mike State: Build 12 is in review/);
  assert.match(sent.text, /\n\ncarry on$/);
  // Said once.
  await finish(thread.id);
  h.runner.send(thread.id, 'again');
  await tick();
  assert.equal(h.adapter.last.sent.at(-1)!.text, 'again');
  // Once its CLI is let go, the next session starts with the whole brief.
  await finish(thread.id);
  h.clock.advance(h.cfg.idleMs + 1000);
  await tick();
  h.runner.send(thread.id, 'back again');
  await tick();
  const brief = h.adapter.last.opts.instructions!;
  assert.match(brief, /^\[Threadbear projects\]/);
  assert.match(brief, /## Poddle \(p_[0-9a-f]+\)\nFolders: ~\/dev\/app\nGoals: A podcast player for Mike\nState: Build 12 is in review/);
  assert.equal(h.adapter.last.sent.at(-1)!.text, 'back again');
});

test('the brief stays short however many projects there are', () => {
  const { projects, create, h } = setup();
  const { thread } = create();
  const long = 'x'.repeat(1900);
  for (let i = 0; i < 4; i++) {
    const p = projects.create({ title: `P${i}`, goals: long, state: long, by: 'mike' });
    projects.changeMembership(thread.id, { add: [p.id], by: 'mike' });
  }
  const brief = projects.brief(rec(h, thread.id))!;
  const body = brief.slice(brief.indexOf('## '));
  assert.ok(body.length <= BRIEF_MAX + 200, `brief body ${body.length}`);
  assert.equal((brief.match(/^## /gm) ?? []).length, 4);
});

test("a thread in a project gets its folders' patches, and their actions run in that folder", async () => {
  const { h, repo, projects, create } = setup();
  const app = repo('dev/app', { '.threadbear/patches/tools.ts': `export default { actions: [{ title: "Where", run: "pwd" }] };` });
  const { thread } = create();
  await tick();
  assert.equal(h.runner.get(thread.id).actions, undefined);
  projects.create({ title: 'App', folders: [app], threadIds: [thread.id], by: 'mike' });
  // The new set loads in the background.
  h.runner.get(thread.id);
  await tick(6);
  const s = h.runner.get(thread.id);
  assert.deepEqual(checkSummary(s), []);
  assert.deepEqual(s.actions?.map((a) => [a.id, a.folder]), [['tools.where', app]]);
  const r = await h.runner.runAction(thread.id, 'tools.where');
  assert.equal(r.ok, true);
  const run = h.events(thread.id).find((e) => e.type === 'action.run');
  assert.equal(run.text.trim(), fs.realpathSync(app));
});

// ----------------------------------------------------------- the librarian

test('the librarian looks after the first turn: makes a project and files the thread', async () => {
  const s = setup({
    models: (p) => {
      assert.equal(p.feature, 'projects');
      assert.match(p.prompt, /Projects:\n\(none yet\)/);
      assert.match(p.prompt, /Thread "Build the podcast player", in ~\/dev\/misc \(not a repo: a catch-all folder\)/);
      assert.match(p.prompt, /Edited files in: ~\/dev\/poddle/);
      assert.match(p.prompt, /First message: Build the podcast player/);
      return reply({ projects: [], new: { title: 'Poddle', folders: ['~/dev/poddle', '~/dev/misc'], goals: 'A podcast player', state: 'Just started' }, state: {}, why: 'New app work' });
    },
  });
  const { h, repo, create, finish, librarian, projects } = s;
  const poddle = repo('dev/poddle');
  const { thread } = create('Build the podcast player');
  await finish(thread.id, [path.join(poddle, 'src/app.ts')]);
  const st = librarian.status();
  assert.equal(st.state, 'idle');
  assert.deepEqual(st.queue.map((j) => [j.reason, j.why]), [['first-turn', 'Its first turn ended']]);
  assert.equal(Date.parse(st.queue[0].dueAt) - h.clock.now(), SETTLE_MS);
  h.clock.advance(SETTLE_MS);
  await tick(6);
  const after = librarian.status();
  assert.equal(after.queue.length, 0);
  assert.equal(after.looksToday, 1);
  assert.equal(after.spentTodayUsd, 0.002);
  assert.deepEqual(after.recent.map((e) => [e.outcome, e.text, e.reason]), [['created', 'Made Poddle and put it there', 'first-turn']]);
  const [p] = projects.list();
  // The catch-all folder isn't a project folder.
  assert.deepEqual(p.folders, [poddle]);
  assert.equal(p.createdBy, 'librarian');
  assert.equal(p.createdByThread, thread.id);
  assert.deepEqual(h.runner.get(thread.id).projects?.map((m) => [m.title, m.by]), [['Poddle', 'librarian']]);
  assert.ok(h.notes.some((n) => n.method === 'librarian.updated'));
});

test('the librarian: catch-up an hour after a look, new folders sooner, state updates, moves', async () => {
  let answer: unknown = { projects: [], new: null, why: 'A one-off question' };
  const s = setup({ models: () => reply(answer) });
  const { h, repo, create, finish, librarian, projects } = s;
  const app = repo('dev/app');
  const other = repo('dev/other');
  const p = projects.create({ title: 'App', folders: [app], state: 'old', by: 'mike' });
  const { thread } = create();
  await finish(thread.id);
  h.clock.advance(SETTLE_MS);
  await tick(6);
  assert.equal(librarian.status().recent[0].text, 'Nothing to change: a one-off question');
  // Another turn with nothing new: an hour after that look.
  h.runner.send(thread.id, 'more');
  await tick();
  await finish(thread.id, [path.join(s.misc, 'notes.md')]);
  const catchUp = librarian.status().queue[0];
  assert.equal(catchUp.reason, 'catch-up');
  assert.ok(Date.parse(catchUp.dueAt) - h.clock.now() > CATCH_UP_MS - 60_000);
  // A turn that edits another repo: sooner, and the better reason wins.
  h.runner.send(thread.id, 'edit app');
  await tick();
  await finish(thread.id, [path.join(app, 'x.ts')]);
  const job = librarian.status().queue[0];
  assert.deepEqual([job.reason, job.why], ['new-folder', 'Edited files in ~/dev/app']);
  answer = { projects: [p.id], state: { [p.id]: 'Working on x.ts' }, addFolders: { [p.id]: ['~/dev/other'] } };
  h.clock.advance(SETTLE_MS);
  await tick(8);
  const entry = librarian.status().recent[0];
  assert.equal(entry.outcome, 'joined');
  assert.equal(entry.text, "Put it in App. Added ~/dev/other to App. Updated App's state");
  assert.equal(projects.record(p.id)?.state, 'Working on x.ts');
  assert.deepEqual(projects.record(p.id)?.folders, [app, other]);
  // A move: looked at again, and it may take out its own guess.
  answer = { projects: [], why: 'Moved away' };
  h.runner.update({ threadId: thread.id, cwd: other });
  assert.equal(librarian.status().queue[0].reason, 'moved');
  h.clock.advance(SETTLE_MS);
  await tick(8);
  assert.equal(librarian.status().recent[0].text, 'Took it out of App');
  assert.equal(h.runner.get(thread.id).projects, undefined);
});

test('the librarian waits without a key, skips private folders, can be paused, and backfills', async () => {
  let result: ModelResult<string> = { ok: false, reason: 'no-key', message: 'No key' };
  const s = setup({ models: () => result });
  const { h, create, finish, librarian } = s;
  const m = librarianMethods(librarian);
  const { thread } = create();
  await finish(thread.id);
  h.clock.advance(SETTLE_MS);
  await tick(6);
  let st = librarian.status();
  assert.equal(st.state, 'off');
  assert.equal(st.reason, 'No OpenRouter key');
  assert.equal(st.queue.length, 1, 'kept for later');
  // Paused: nothing runs even when due.
  m['librarian.update']({ paused: true });
  result = { ok: false, reason: 'private', message: 'private' };
  h.clock.advance(20 * 60_000);
  await tick(6);
  st = librarian.status();
  assert.equal(st.state, 'paused');
  assert.equal(st.queue.length, 1);
  m['librarian.update']({ paused: false });
  await tick(6);
  st = librarian.status();
  assert.equal(st.queue.length, 0);
  assert.deepEqual([st.recent[0].outcome, st.recent[0].text], ['skipped', 'Private folder, not sent']);
  // Backfill: threads it has never looked at, newest first.
  const { thread: t2 } = create('second');
  h.clock.advance(1000);
  const { thread: t3 } = create('third');
  m['librarian.update']({ paused: true });
  const r = m['librarian.run']({}) as any;
  assert.deepEqual(r.librarian.queue.map((j: any) => j.threadId), [t3.id, t2.id]);
  // Deleting a thread drops its job.
  await h.runner.delete(t3.id);
  assert.deepEqual(librarian.status().queue.map((j) => j.threadId), [t2.id]);
  // Kept across a restart.
  const again = new Librarian({ host: h.runner, projects: s.projects, clock: h.clock, log: nullLogger, home: h.home });
  again.start();
  assert.deepEqual(again.status().queue.map((j) => j.threadId), [t2.id]);
  assert.equal(again.status().recent.length, st.recent.length);
  again.stop();
});

// ---------------------------------------------------------- agent tools

test('agent tools: make, read, update, join and leave projects', async () => {
  const { h, repo, projects, create } = setup();
  const app = repo('dev/app');
  const { thread } = create();
  const tools = buildThreadbareTools(h.runner, thread.id, Date.now, undefined, projects);
  const call = async (name: string, args: Record<string, unknown>) => {
    const t = tools.find((x) => x.name === name)!;
    const r = await t.handler(args as never, {} as never);
    return { text: r.content.map((c: any) => c.text).join(''), error: Boolean(r.isError) };
  };
  assert.equal((await call('list_projects', {})).text, 'No projects yet. create_project makes one.');
  const made = await call('create_project', { title: 'App', folders: [app], goals: 'Ship it' });
  assert.match(made.text, /^Made the project "App" \(p_[0-9a-f]+\) and put this thread in it\.$/);
  const p = projects.list()[0];
  assert.deepEqual(h.runner.get(thread.id).projects?.map((m) => [m.by, m.pinned]), [['agent', true]]);
  assert.equal(p.createdBy, 'agent');
  await call('update_project', { project: 'app', state: 'Half done', appendNote: 'Use npm ci.' });
  const read = await call('read_project', { project: p.id });
  assert.match(read.text, /^App \(p_[0-9a-f]+\)\nFolders: .*\nGoals: Ship it\nState: Half done\n\nNotes:\nUse npm ci\.\n\nThreads \(1\):\n- [0-9a-f]{8} ".*" \(this thread\)$/);
  assert.match((await call('list_projects', {})).text, /\(this thread is in it\) · 1 thread · folders .* · state: Half done/);
  assert.match((await call('leave_project', { project: p.id })).text, /no longer in "App"/);
  assert.equal(rec(h, thread.id)?.projectsLeft?.[0], p.id);
  assert.equal((await call('read_project', { project: 'nope' })).error, true);
});
