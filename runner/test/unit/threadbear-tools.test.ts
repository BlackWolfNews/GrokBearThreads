import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { FakeAccounts, makeHarness, tick, tmpDir, withCodex } from '../helpers/fakes.ts';
import { copySessionTranscript, projectDirName } from '../../src/transcripts.ts';
import { buildThreadbearTools, parseWhen } from '../../src/threadbear-mcp.ts';
import { toolTitle } from '../../src/tools.ts';

function start(h: ReturnType<typeof makeHarness>, text = 'Fix the tests', extra: Record<string, unknown> = {}) {
  const { thread } = h.runner.create({ text, accountId: 'claude-3', ...extra });
  const s = h.adapter.last;
  s.init();
  return { thread, s };
}

function tools(h: ReturnType<typeof makeHarness>, selfId: string) {
  // end_turn's wait for its own call to land is counted, not slept.
  const slept: number[] = [];
  const list = buildThreadbearTools(h.runner, selfId, () => Date.parse('2026-10-26T12:00:00Z'), undefined, undefined, undefined, {
    sleep: async (ms) => {
      slept.push(ms);
    },
  });
  const call = async (name: string, args: Record<string, unknown> = {}) => {
    const t = list.find((x) => x.name === name);
    assert.ok(t, `tool ${name}`);
    const r = (await t.handler(args as never, {})) as { content: { text: string }[]; isError?: boolean };
    return { text: r.content.map((c) => c.text).join('\n'), error: Boolean(r.isError) };
  };
  return { list, call, slept };
}

// What the CLI has told the runner by the time the end_turn handler runs:
// the agent's text (if any), then the end_turn call itself.
const END_TURN = 'mcp__threadbear__end_turn';
function toolCall(s: ReturnType<typeof makeHarness>['adapter']['last'], itemId: string, name: string, input: Record<string, unknown> = {}) {
  s.out({ kind: 'event', event: { type: 'tool.call', itemId, name, kind: name === 'Bash' ? 'command' : 'mcp', title: name, input } });
}
function toolResult(s: ReturnType<typeof makeHarness>['adapter']['last'], itemId: string) {
  s.out({ kind: 'event', event: { type: 'tool.result', itemId, ok: true, text: 'ok', truncated: false, images: [] } });
}

// ------------------------------------------------------------ transcripts

test('projectDirName matches how the CLI names folders', () => {
  assert.equal(projectDirName('/Users/m5-mike/dev/me/misc'), '-Users-m5-mike-dev-me-misc');
  assert.equal(projectDirName('/Users/x/.agents/a_b c'), '-Users-x--agents-a-b-c');
});

test('copySessionTranscript copies the jsonl and the subagent folder, using real paths', () => {
  const config = tmpDir();
  const a = fs.realpathSync(tmpDir());
  const b = tmpDir(); // under /var -> /private/var, so the real path differs
  const sid = '0b7a4c1e-1111-2222-3333-444455556666';
  const src = path.join(config, 'projects', projectDirName(a));
  fs.mkdirSync(path.join(src, sid, 'subagents'), { recursive: true });
  fs.writeFileSync(path.join(src, `${sid}.jsonl`), '{"x":1}\n');
  fs.writeFileSync(path.join(src, sid, 'subagents', 'agent-1.jsonl'), '{}\n');
  assert.equal(copySessionTranscript(config, config, a, b, sid), true);
  const dest = path.join(config, 'projects', projectDirName(fs.realpathSync(b)));
  assert.equal(fs.readFileSync(path.join(dest, `${sid}.jsonl`), 'utf8'), '{"x":1}\n');
  assert.ok(fs.existsSync(path.join(dest, sid, 'subagents', 'agent-1.jsonl')));
  assert.ok(fs.existsSync(path.join(src, `${sid}.jsonl`)), 'the original stays');
  assert.equal(copySessionTranscript(config, config, a, b, 'not-there'), false);
  assert.equal(copySessionTranscript(config, config, a, b, '../evil'), false);
});

test('copySessionTranscript copies into another login\'s config dir, in the same folder', () => {
  const from = tmpDir();
  const to = tmpDir();
  const cwd = fs.realpathSync(tmpDir());
  const sid = '0b7a4c1e-1111-2222-3333-777788889999';
  const src = path.join(from, 'projects', projectDirName(cwd));
  fs.mkdirSync(src, { recursive: true });
  fs.writeFileSync(path.join(src, `${sid}.jsonl`), '{"y":2}\n');
  assert.equal(copySessionTranscript(from, to, cwd, cwd, sid), true);
  assert.equal(fs.readFileSync(path.join(to, 'projects', projectDirName(cwd), `${sid}.jsonl`), 'utf8'), '{"y":2}\n');
  assert.ok(fs.existsSync(path.join(src, `${sid}.jsonl`)), 'the original stays');
  // Nothing in the old login's folder: nothing to carry.
  assert.equal(copySessionTranscript(to, from, tmpDir(), cwd, sid), false);
});

// ------------------------------------------------------ moving a thread

test('a folder move on the same account carries the transcript and resumes the same session', async () => {
  const copies: string[][] = [];
  const h = makeHarness(undefined, {}, {
    copyTranscript: (fromConfig, toConfig, from, to, sid) => {
      copies.push([fromConfig, toConfig, from, to, sid]);
      return true;
    },
  });
  const { thread, s } = start(h);
  s.result('completed', 0.01);
  const other = tmpDir();
  h.runner.update({ threadId: thread.id, cwd: other });
  await tick();
  h.runner.send(thread.id, 'Now commit it');
  await tick();
  const s2 = h.adapter.last;
  assert.notEqual(s2, s);
  assert.equal(s2.opts.cwd, other);
  assert.equal(s2.opts.resume, true, 'resumes rather than starting fresh');
  assert.equal(s2.opts.sessionId, s.opts.sessionId);
  assert.equal(s2.sent[0].text, 'Now commit it', 'no handoff note');
  assert.deepEqual(copies, [['/tmp/three', '/tmp/three', h.cfg.defaults.cwd, other, s.opts.sessionId]]);
  assert.ok(h.events(thread.id).some((e) => e.type === 'system.note' && /^Moved to /.test(e.text)));
});

test('a move falls back to the handoff note when the transcript cannot be carried', async () => {
  let called = 0;
  const h = makeHarness(undefined, {}, {
    copyTranscript: () => {
      called++;
      return false;
    },
  });
  const { thread, s } = start(h);
  s.text('m1:0', 'Done.');
  s.result();
  h.runner.update({ threadId: thread.id, cwd: tmpDir() });
  await tick();
  h.runner.send(thread.id, 'next');
  await tick();
  const s2 = h.adapter.last;
  assert.equal(s2.opts.resume, false);
  assert.match(s2.sent[0].text, /^\[Threadbear handoff\]/);
  assert.equal(called, 1, 'copy attempts');
});

test('a move to another Claude login carries the transcript into its config dir and resumes there', async () => {
  const copies: string[][] = [];
  const h = makeHarness(undefined, {}, { copyTranscript: (fc, tc, f, t, sid) => (copies.push([fc, tc, f, t, sid]), true) });
  const { thread, s } = start(h);
  s.text('m1:0', 'Done.');
  s.result();
  h.runner.update({ threadId: thread.id, accountId: 'claude-main' });
  await tick();
  h.runner.send(thread.id, 'next');
  await tick();
  const s2 = h.adapter.last;
  assert.equal(s2.opts.account.id, 'claude-main');
  assert.equal(s2.opts.resume, true);
  assert.equal(s2.opts.sessionId, s.opts.sessionId);
  assert.equal(s2.sent[0].text, 'next', 'no handoff note');
  assert.deepEqual(copies, [['/tmp/three', '/tmp/main', h.cfg.defaults.cwd, h.cfg.defaults.cwd, s.opts.sessionId]]);
  assert.ok(h.events(thread.id).some((e) => e.type === 'system.note' && e.text === 'Resumed the session on main@example.com, with the whole conversation.'));
});

test('if the carried transcript will not resume, the fresh session gets the handoff note', async () => {
  const h = makeHarness(undefined, {}, { copyTranscript: () => true });
  const { thread, s } = start(h);
  s.text('m1:0', 'The tests pass now.');
  s.result();
  h.runner.update({ threadId: thread.id, cwd: tmpDir() });
  await tick();
  h.runner.send(thread.id, 'Now commit it');
  await tick();
  const s2 = h.adapter.last;
  assert.equal(s2.opts.resume, true);
  s2.sink.exited(new Error('No conversation found with session ID x'));
  await tick();
  const s3 = h.adapter.last;
  assert.notEqual(s3, s2);
  assert.equal(s3.opts.resume, false);
  assert.match(s3.sent[0].text, /^\[Threadbear handoff\][\s\S]*The tests pass now\.[\s\S]*Now commit it$/);
});

// ---------------------------------------------------------------- delete

test('delete stops the CLI, moves the files to trash and tells clients', async () => {
  const h = makeHarness();
  const { thread, s } = start(h);
  const dir = h.store.threadDir(thread.id);
  assert.ok(fs.existsSync(dir));
  h.runner.delete(thread.id);
  await tick();
  assert.equal(s.endedHard, true);
  assert.ok(!fs.existsSync(dir));
  const trashed = fs.readdirSync(path.join(h.home, 'trash'));
  assert.equal(trashed.length, 1);
  assert.ok(trashed[0].startsWith(thread.id));
  assert.ok(h.notes.some((n) => n.method === 'thread.deleted' && n.params.threadId === thread.id));
  assert.throws(() => h.runner.get(thread.id), (e: { code: number }) => e.code === -32004);
  // Late output from the old CLI goes nowhere and doesn't bring the folder back.
  s.text('m1:0', 'late');
  s.result();
  h.runner.flush();
  assert.ok(!fs.existsSync(dir));
  assert.equal(h.restart().runner.list(['inbox', 'snoozed', 'archived']).length, 0, 'gone after a restart too');
});

// ----------------------------------------------------------------- tools

test('list, read and account tools', async () => {
  const h = makeHarness();
  const { thread: a, s } = start(h, 'First thread');
  s.text('m1:0', 'Hello from the agent');
  s.result();
  const { thread: b } = start(h, 'Second thread');
  const t = tools(h, a.id);
  const list = await t.call('list_threads');
  assert.match(list.text, /First thread .*this thread/);
  assert.match(list.text, /Second thread/);
  const read = await t.call('read_thread', { threadId: b.id.slice(0, 8) });
  assert.match(read.text, /title: Second thread/);
  const self = await t.call('read_thread');
  assert.match(self.text, /Mike \(.*\):\nFirst thread/);
  assert.match(self.text, /Agent \(.*\):\nHello from the agent/);
  // The runner's resume after a restart isn't Mike's.
  h.runner.send(a.id, 'The runner restarted on release R. Check your change.', [], { origin: 'runner' });
  const resumed = await t.call('read_thread');
  assert.match(resumed.text, /Runner \(.*\):\nThe runner restarted on release R/);
  assert.doesNotMatch(resumed.text, /Mike \(.*\):\nThe runner restarted/);
  assert.match((await t.call('list_accounts')).text, /claude-3 {2}three@example\.com/);
  assert.match((await t.call('list_threads', { query: 'Second' })).text, /Second thread/);
  const missing = await t.call('read_thread', { threadId: 'zzzz' });
  assert.equal(missing.error, true);
});

test('create and send say where the message came from', async () => {
  const h = makeHarness();
  const { thread: me } = start(h, 'Boss thread');
  const t = tools(h, me.id);
  const made = await t.call('create_thread', { text: 'Write the docs\nin detail', account: 'three', folder: '.' });
  assert.equal(made.error, false, made.text);
  const child = h.runner.list().find((x) => x.title === 'Write the docs')!;
  assert.ok(child, 'title from the first line, without the prefix');
  assert.equal(child.cwd, me.cwd);
  const cs = h.adapter.last;
  assert.match(cs.sent[0].text, /^\[Sent by the agent in the thread "Boss thread"/);
  cs.init();
  cs.result();
  await t.call('send_message', { threadId: child.id, text: 'Also add examples' });
  const um = h.events(child.id).filter((e) => e.type === 'user.message').at(-1);
  assert.match(um.text, /^\[Sent by the agent[\s\S]*Also add examples$/);
  assert.equal((await t.call('send_message', { threadId: me.id, text: 'x' })).error, true, 'not to itself');
});

test('update renames and snoozes others, but will not stop its own turn', async () => {
  const h = makeHarness();
  const { thread: me } = start(h, 'Me');
  const { thread: other } = start(h, 'Other');
  const t = tools(h, me.id);
  assert.match((await t.call('update_thread', { title: 'Renamed me' })).text, /title: Renamed me/);
  const own = await t.call('update_thread', { archived: true });
  assert.equal(own.error, true);
  assert.equal(h.runner.get(me.id).archivedAt, undefined);
  const snoozed = await t.call('update_thread', { threadId: other.id, snooze: '2h' });
  assert.match(snoozed.text, /snoozed until: 2026-10-26T14:00:00\.000Z/);
  await t.call('update_thread', { threadId: other.id, snooze: 'off' });
  assert.equal(h.runner.get(other.id).snoozedUntil, undefined);
});

test('move_thread on itself switches folder after the turn and carries on with `then`', async () => {
  const h = makeHarness(undefined, {}, { copyTranscript: () => true });
  const { thread: me, s } = start(h, 'Move me');
  const dest = tmpDir();
  const t = tools(h, me.id);
  const r = await t.call('move_thread', { folder: dest, then: 'Carry on with the tests' });
  assert.equal(r.error, false, r.text);
  assert.match(r.text, /when this turn ends.*carries on by itself/);
  assert.equal(h.adapter.sessions.length, 1, 'the running turn is left alone');
  assert.equal(h.runner.get(me.id).cwd, dest);
  s.result();
  await tick();
  const s2 = h.adapter.last;
  assert.notEqual(s2, s);
  assert.equal(s2.opts.cwd, dest);
  assert.equal(s2.opts.resume, true);
  assert.match(s2.sent[0].text, /^\[Sent by the agent before moving to .*\]\n\nCarry on with the tests$/);
  assert.equal((await t.call('move_thread', { folder: '/definitely/not/here' })).error, true);
});

test('interrupt and delete refuse this thread and work on others', async () => {
  const h = makeHarness();
  const { thread: me } = start(h, 'Me');
  const { thread: other, s: os } = start(h, 'Other');
  const t = tools(h, me.id);
  assert.equal((await t.call('interrupt_thread', { threadId: me.id })).error, true);
  assert.equal((await t.call('delete_thread', { threadId: me.id })).error, true);
  await t.call('interrupt_thread', { threadId: other.id });
  assert.equal(os.interrupts, 1);
  const del = await t.call('delete_thread', { threadId: other.id.slice(0, 8) });
  assert.match(del.text, /Deleted "Other"/);
  assert.equal(h.runner.list().length, 1);
});

test('`id` works as a thread id, and a missing one is an error rather than "this thread"', async () => {
  const h = makeHarness();
  const { thread: me } = start(h, 'Me');
  const { thread: other } = start(h, 'Other');
  const t = tools(h, me.id);
  await t.call('update_thread', { id: other.id, title: 'Renamed other' });
  assert.equal(h.runner.get(other.id).title, 'Renamed other');
  assert.equal(h.runner.get(me.id).title, 'Me');
  assert.equal((await t.call('delete_thread', {})).error, true);
  assert.equal(h.runner.list().length, 2);
});

test("update_thread leaves a title Mike gave alone unless he asked for the new one", async () => {
  const h = makeHarness();
  const { thread: me } = start(h, 'Me');
  const { thread: other } = start(h, 'Other');
  const t = tools(h, me.id);
  // An agent's title doesn't stop a later agent rename.
  await t.call('update_thread', { id: other.id, title: 'Agent name' });
  await t.call('update_thread', { id: other.id, title: 'Better agent name' });
  assert.equal(h.runner.get(other.id).title, 'Better agent name');
  // Mike renames it in the app (threads.update, no titleBy).
  h.runner.update({ threadId: other.id, title: 'Mike name' });
  const refused = await t.call('update_thread', { id: other.id, title: 'Agent again', snooze: '2h' });
  assert.equal(refused.error, true);
  assert.match(refused.text, /Mike named this thread "Mike name" himself/);
  assert.equal(h.runner.get(other.id).title, 'Mike name');
  assert.equal(h.runner.get(other.id).snoozedUntil, undefined, 'nothing else in the refused call changed');
  // The same title, or one Mike asked for, goes through.
  assert.equal((await t.call('update_thread', { id: other.id, title: 'Mike name', snooze: 'off' })).error, false);
  assert.equal((await t.call('update_thread', { id: other.id, title: 'Asked for', mikeAsked: true })).error, false);
  assert.equal(h.runner.get(other.id).title, 'Asked for');
  assert.equal((await t.call('update_thread', { id: other.id, title: 'Sneaky' })).error, true, 'still his');
});

test('the delete approval names the thread', async () => {
  const h = makeHarness();
  const { thread: other } = start(h, 'Old experiment');
  const { thread: me, s } = start(h, 'Me', { permissionMode: 'ask' });
  const answer = s.sink.requestApproval({
    toolUseId: 'tu1',
    name: 'mcp__threadbear__delete_thread',
    title: 'Delete thread x',
    input: { id: other.id.slice(0, 8) },
    canAlwaysAllow: false,
    signal: new AbortController().signal,
  });
  const ask = h.events(me.id).find((e) => e.type === 'approval.requested');
  assert.equal(ask.title, 'Delete the thread "Old experiment"');
  h.runner.respondApproval({ threadId: me.id, approvalId: ask.approvalId, decision: 'deny' });
  assert.equal((await answer).decision, 'deny');
});

test('parseWhen and tool titles', () => {
  const now = Date.parse('2026-10-26T12:00:00Z');
  assert.equal(parseWhen('30m', now), '2026-10-26T12:30:00.000Z');
  assert.equal(parseWhen('1d', now), '2026-10-27T12:00:00.000Z');
  assert.throws(() => parseWhen('soonish', now));
  assert.equal(toolTitle('mcp__threadbear__move_thread', { folder: '~/dev/x' }, '/'), 'Move this thread to ~/dev/x');
  assert.equal(toolTitle('mcp__threadbear__delete_thread', { threadId: 'abcdef123456' }, '/'), 'Delete thread abcdef12');
});

test('list_accounts shows each login\'s provider, note, room left and models; create and move take Codex accounts', async () => {
  const usage = { windows: [{ kind: 'five_hour' as const, title: '5-hour', remainingPercent: 89 }, { kind: 'weekly' as const, title: 'Weekly', remainingPercent: 78 }], readAt: '2026-10-26T12:00:00Z', source: 'tokenStats' as const };
  const accounts = withCodex().map((a) =>
    a.id === 'claude-3' ? { ...a, note: 'Convex work only', email: 'three@example.com', usage } : a.id === 'claude-main' ? { ...a, email: 'main@example.com' } : a,
  );
  const h = makeHarness(undefined, { defaults: { cwd: '', models: { codex: 'gpt-6-luna' } } }, { accounts: new FakeAccounts(accounts) });
  h.cfg.defaults.cwd = path.join(h.home, 'work');
  const { thread: me } = h.runner.create({ text: 'Boss', accountId: 'claude-main' });
  h.adapter.last.init();
  const t = tools(h, me.id);
  const list = (await t.call('list_accounts')).text;
  assert.match(list, /claude-main {2}main@example\.com {2}\[Claude; usage unknown; default for new threads\]/);
  assert.match(list, /claude-3 {2}three@example\.com {2}\[Claude; Convex work only; 5-hour 89% left, weekly 78% left\]/);
  assert.match(list, /codex-main {2}Codex · main@example\.com {2}\[Codex; usage unknown\]\n {4}models: gpt-6\.1-sol \(default\), gpt-6-luna/);

  // claude-main and codex-main share an email: that's refused, not guessed.
  const clash = await t.call('create_thread', { text: 'x', account: 'main@example.com' });
  assert.equal(clash.error, true);
  assert.match(clash.text, /fits claude-main .* and codex-main .*; use the id/);
  // "codex" names the one Codex login; ultra passes the schema.
  const made = await t.call('create_thread', { text: 'Draw a bear', account: 'codex', effort: 'ultra' });
  assert.equal(made.error, false, made.text);
  assert.match(made.text, /on codex-main \(gpt-6-luna\)\.$/);
  const child = h.runner.list().find((x) => x.title === 'Draw a bear')!;
  assert.equal(child.provider, 'codex');
  assert.equal(child.model, 'gpt-6-luna');
  assert.equal(child.effort, undefined, 'luna has no ultra: dropped with a note');
  assert.equal(h.codex.last.opts.account.id, 'codex-main');
  const read = await t.call('read_thread', { threadId: child.id });
  assert.match(read.text, /account: codex-main \(Codex\)/);

  // move_thread to the Codex login: fresh session there, on its defaults.
  h.adapter.last.result();
  const moved = await t.call('move_thread', { threadId: me.id, folder: '.', account: 'codex-main' });
  assert.equal(moved.error, false, moved.text);
  assert.equal(h.runner.get(me.id).provider, 'codex');
  assert.equal(h.runner.get(me.id).model, 'gpt-6-luna');
});

test('pools in the tools: list_accounts prints them, create_thread and update_thread take a pool, and a named model picks its provider', async () => {
  const h = makeHarness(undefined, {}, { accounts: new FakeAccounts(withCodex()) });
  const { thread: me } = h.runner.create({ text: 'Boss', accountId: 'claude-main' });
  h.adapter.last.init();
  const t = tools(h, me.id);
  const list = (await t.call('list_accounts')).text;
  assert.match(list, /Pools \(a new thread in a pool's folder starts on that pool\):\nclaude {2}Claude: claude-main room unknown, claude-3 room unknown {2}\[new threads start here\]\ncodex {2}Codex: codex-main room unknown/);
  // A Claude model with no account or pool, while Codex is the default: Claude.
  h.runner.create({ text: 'x', accountId: 'codex-main' });
  const opus = await t.call('create_thread', { text: 'Use Opus', model: 'claude-opus-5-5' });
  assert.equal(opus.error, false, opus.text);
  const o = h.runner.list().find((x) => x.title === 'Use Opus')!;
  assert.equal(o.provider, 'claude');
  assert.equal(o.poolId, 'claude');
  assert.equal(o.model, 'claude-opus-5-5');
  assert.match(opus.text, /\(claude-opus-5-5\)\. It's in the claude pool/);
  // By title, ignoring case; an unknown one says which there are.
  const made = await t.call('create_thread', { text: 'On Codex', pool: 'CODEX' });
  assert.equal(made.error, false, made.text);
  assert.equal(h.runner.list().find((x) => x.title === 'On Codex')!.poolId, 'codex');
  const bad = await t.call('create_thread', { text: 'y', pool: 'grok' });
  assert.equal(bad.error, true);
  assert.match(bad.text, /No pool grok\. Pools: claude \(Claude\), codex \(Codex\)/);
  // update_thread: "pin" pins, a pool puts it back.
  const pinned = await t.call('update_thread', { threadId: o.id, pool: 'pin' });
  assert.match(pinned.text, /pool: none \(pinned to its account\)/);
  const back = await t.call('update_thread', { threadId: o.id, pool: 'claude' });
  assert.match(back.text, /pool: claude/);
  assert.equal((await t.call('update_thread', { threadId: o.id, pool: null })).error, false);
  assert.equal(h.runner.get(o.id).poolId, undefined);
});

// ------------------------------------------------------------ end_turn

test('end_turn only acknowledges; its description says when to call it', async () => {
  const h = makeHarness();
  const { thread, s } = start(h);
  const { list, call, slept } = tools(h, thread.id);
  const t = list.find((x) => x.name === 'end_turn')!;
  assert.match(t.description, /last thing in every turn/);
  assert.match(t.description, /refused until the turn has a reply/);
  assert.match(t.description, /Sub-agents never call this/);
  s.text('m1', 'Yes or no?');
  toolCall(s, 'e1', END_TURN, { needs: 'you' });
  const r = await call('end_turn', { needs: 'you', asks: [{ action: 'Say yes' }] });
  assert.equal(r.error, false);
  assert.match(r.text, /Needs you/);
  toolResult(s, 'e1');
  toolCall(s, 'e2', END_TURN, { needs: 'nothing' });
  assert.match((await call('end_turn', { needs: 'nothing' })).text, /done/);
  assert.deepEqual(slept, [], 'the call had landed; nothing to wait for');
  // The runner reads the call from the thread's events, not the handler.
  assert.equal(h.runner.get(thread.id).needs, undefined);
});

// An agent drafted its answer in thinking, ran two commands and called
// end_turn; Mike saw a folded work group and a card, twice (28 Oct 2026).
test('end_turn is refused until the turn has replied to Mike in text', async () => {
  const h = makeHarness();
  const { thread, s } = start(h);
  const { call, slept } = tools(h, thread.id);
  toolCall(s, 'b1', 'Bash', { command: 'grep sammy' });
  toolResult(s, 'b1');
  toolCall(s, 'e1', END_TURN, { needs: 'nothing' });
  let r = await call('end_turn', { needs: 'nothing' });
  assert.equal(r.error, true);
  assert.match(r.text, /hasn't had a reply this turn/);
  assert.match(r.text, /write the whole answer as ordinary text/);
  toolResult(s, 'e1');
  // A progress line before more work isn't the reply either.
  s.text('m1', 'Found it, one more check.');
  toolCall(s, 'b2', 'Bash', { command: 'git log' });
  toolResult(s, 'b2');
  toolCall(s, 'e2', END_TURN, { needs: 'nothing' });
  r = await call('end_turn', { needs: 'nothing' });
  assert.equal(r.error, true);
  toolResult(s, 'e2');
  // The reply, then one of Threadbear's own tools, then end_turn: fine.
  s.text('m2', 'No, the camera is not where the delay is.');
  toolCall(s, 'p1', 'mcp__threadbear__pin', { url: '/tmp/x.png' });
  toolResult(s, 'p1');
  toolCall(s, 'e3', END_TURN, { needs: 'nothing' });
  r = await call('end_turn', { needs: 'nothing' });
  assert.equal(r.error, false);
  assert.match(r.text, /done/);
  assert.deepEqual(slept, []);
});

// The SDK runs the tool as soon as it reads the call, so the handler can run
// before the runner has logged the frames before it.
test("end_turn waits for its own call to land, and takes a call that never lands (a sub-agent's) at its word", async () => {
  const h = makeHarness();
  const { thread, s } = start(h);
  const { call, slept } = tools(h, thread.id);
  // The text and the call arrive while the handler is waiting.
  let polls = 0;
  const late = buildThreadbearTools(h.runner, thread.id, Date.now, undefined, undefined, undefined, {
    sleep: async () => {
      if (++polls === 3) {
        s.text('m1', 'All done.');
        toolCall(s, 'e1', END_TURN, { needs: 'nothing' });
      }
    },
  }).find((x) => x.name === 'end_turn')!;
  const r = (await late.handler({ needs: 'nothing' } as never, {})) as { isError?: boolean };
  assert.equal(r.isError, undefined);
  assert.equal(polls, 3);
  // Never lands: acknowledged after the wait, as the events can't judge it.
  toolResult(s, 'e1');
  toolCall(s, 'b1', 'Bash', { command: 'ls' });
  toolResult(s, 'b1');
  const r2 = await call('end_turn', { needs: 'nothing' });
  assert.equal(r2.error, false);
  assert.ok(slept.length >= 20 && slept.every((ms) => ms === 50), `waited about a second in short sleeps: ${slept.length}`);
});

// ------------------------------------------------------------ instructions

// The CLI defers MCP tools (an agent sees only their names), so the server's
// instructions are the one place sure to tell an agent when to reach for
// show_options and pin. Without them an agent pinned three mockups and asked
// Mike to choose in chat.
test('both instruction texts say when to use show_options and pin', async () => {
  const { threadbearMcpServer } = await import('../../src/threadbear-mcp.ts');
  const { TOOL_GUIDANCE } = await import('../../src/adapters/codex/tools.ts');
  const claude = threadbearMcpServer({} as never, 'self');
  const instructions = (claude.instance as unknown as { server: { _instructions?: string } }).server._instructions ?? '';
  for (const [who, text] of [['claude', instructions], ['codex', TOOL_GUIDANCE]] as const) {
    assert.match(text, /show_options/, who);
    assert.match(text, /\bpin\b/, who);
  }
});
