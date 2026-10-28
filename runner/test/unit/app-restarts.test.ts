import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeHarness } from '../helpers/fakes.ts';
import { AppRestarts, asksForAppRestart } from '../../src/app-restarts.ts';
import { nullLogger } from '../../src/log.ts';

const A = { commit: 'aaaa1111', short: 'aaaa111', tree: 'tree-a' };
const B = { commit: 'bbbb2222', short: 'bbbb222', tree: 'tree-b' };

function setUp() {
  const h = makeHarness();
  const watcher = new AppRestarts({ runner: h.runner, home: h.home, clock: h.clock, log: nullLogger });
  const { thread } = h.runner.create({ text: 'Build the dock', accountId: 'claude-3' });
  h.adapter.last.init();
  return { h, watcher, thread };
}

const said = (h: ReturnType<typeof makeHarness>, threadId: string) => {
  const evs = h.events(threadId);
  return {
    note: evs.findLast((e) => e.type === 'system.note' && String(e.text).startsWith('Threadbear app restarted'))?.text,
    message: evs.findLast((e) => e.type === 'user.message' && e.origin === 'runner')?.text,
  };
};

test('a thread waiting hears when the app comes back on another build', () => {
  const { h, watcher, thread } = setUp();
  watcher.appHello(A);
  watcher.watch(thread.id);
  // The same build again (the app reconnecting to a restarted runner): nothing.
  watcher.appHello(A);
  assert.equal(said(h, thread.id).message, undefined);
  watcher.appHello(B);
  const { note, message } = said(h, thread.id);
  assert.equal(note, 'Threadbear app restarted: aaaa111 to bbbb222');
  assert.match(message, /restarted onto bbbb222/);
  // Once only.
  watcher.appHello({ ...A, tree: 'tree-c' });
  assert.equal(h.events(thread.id).filter((e) => e.type === 'user.message' && e.origin === 'runner').length, 1);
});

test('the agent\'s own text is sent, and the last request wins', () => {
  const { h, watcher, thread } = setUp();
  watcher.appHello(A);
  watcher.watch(thread.id, 'Check the dock in the real app.');
  watcher.watch(thread.id, 'Check the panels move.');
  watcher.appHello(B);
  assert.match(said(h, thread.id).message, /Check the panels move\.$/);
});

test('remembered across a runner restart', () => {
  const { h, watcher, thread } = setUp();
  watcher.appHello(A);
  watcher.watch(thread.id);
  const again = new AppRestarts({ runner: h.runner, home: h.home, clock: h.clock, log: nullLogger });
  again.appHello(A);
  assert.equal(said(h, thread.id).message, undefined);
  again.appHello(B);
  assert.match(said(h, thread.id).message, /restarted onto bbbb222/);
});

test('an archived thread or a stale request only gets the note', () => {
  const { h, watcher, thread } = setUp();
  watcher.appHello(A);
  watcher.watch(thread.id);
  h.clock.advance(25 * 60 * 60_000);
  watcher.appHello(B);
  assert.equal(said(h, thread.id).message, undefined);
  assert.match(said(h, thread.id).note, /more than a day old/);
});

test('asks that tell Mike to restart the app count as a request', () => {
  assert.equal(asksForAppRestart([{ action: 'Click Restart to Update in the Threadbear menu' }]), true);
  assert.equal(asksForAppRestart([{ action: 'Restart Threadbear', where: 'Threadbear menu > Restart to Update' }]), true);
  // The ask is one paragraph now, so the words can be in its why.
  assert.equal(asksForAppRestart([{ action: 'Try the new card', why: 'It needs Restart to Update in the Threadbear menu first.' }]), true);
  assert.equal(asksForAppRestart([{ action: 'Restart the runner' }]), false);
  assert.equal(asksForAppRestart(undefined), false);
});

test('end_turn asking for Restart to Update signs the thread up; wait_for_app_restart sets the text', async () => {
  const { buildThreadbearTools } = await import('../../src/threadbear-mcp.ts');
  const { h, watcher, thread } = setUp();
  watcher.appHello(A);
  const tools = buildThreadbearTools(h.runner, thread.id, Date.now, undefined, undefined, watcher);
  const call = async (name: string, args: Record<string, unknown>) => {
    const t = tools.find((x) => x.name === name)!;
    const r = (await t.handler(args as never, {})) as { content: { text: string }[] };
    return r.content.map((c) => c.text).join('\n');
  };
  const reply = await call('end_turn', { needs: 'you', asks: [{ action: 'Click Restart to Update', where: 'Threadbear menu' }] });
  assert.match(reply, /message here when the app restarts/);
  assert.equal(watcher.isWatching(thread.id), true);
  // Asks about something else don't.
  const { thread: other } = h.runner.create({ text: 'Other', accountId: 'claude-3' });
  const otherTools = buildThreadbearTools(h.runner, other.id, Date.now, undefined, undefined, watcher);
  await otherTools.find((x) => x.name === 'end_turn')!.handler({ needs: 'you', asks: [{ action: 'Paste the key' }] } as never, {});
  assert.equal(watcher.isWatching(other.id), false);
  // Every ask has to say why: a card with only an action and a place
  // left Mike guessing (28 Oct). The schema refuses one without.
  const shape = (tools.find((x) => x.name === 'end_turn')!.inputSchema as any).asks;
  assert.equal(shape.safeParse([{ action: 'Fix the Slack draft', where: 'Slack' }]).success, false);
  assert.equal(shape.safeParse([{ action: 'Fix the Slack draft', why: 'It says Hayden; he is Pete.', links: [{ title: 'Open the Slack message', url: 'https://x.slack.com/archives/C1/p1' }] }]).success, true);
  // The tool's text is what's sent.
  assert.match(await call('wait_for_app_restart', { text: 'Drag Highlights about.' }), /aaaa111/);
  watcher.appHello(B);
  assert.match(said(h, thread.id).message, /Drag Highlights about\.$/);
});
