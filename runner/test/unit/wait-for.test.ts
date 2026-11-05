// end_turn's waitFor (runner/hibernation.ts, waitOn): a thread hibernates
// until the threads it names finish, then wakes with their replies.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeHarness } from '../helpers/fakes.ts';
import { checkSummary } from '../helpers/protocol-check.ts';
import { WAIT_FOR_DEFAULT_MS } from '../../src/runner/hibernation.ts';

const END_TURN = 'mcp__threadbear__end_turn';

function setup() {
  const h = makeHarness();
  const make = (text: string) => {
    const { thread } = h.runner.create({ text, accountId: 'claude-3' });
    const s = h.adapter.last;
    s.init();
    s.result();
    return thread.id;
  };
  const waiter = make('Write the plan once the I/O numbers are in');
  const target = make('Measure the Convex I/O saving');
  const other = make('Something else');
  // The thread's live session, or the newest one it started.
  const session = (id: string) => h.adapter.sessions.filter((s) => s.opts.threadId === id).at(-1)!;
  // A turn in a thread that ends with this end_turn, after a reply.
  const turn = (id: string, input: Record<string, unknown>, reply = 'Done.') => {
    h.runner.send(id, 'go on');
    const s = session(id);
    s.out({ kind: 'event', event: { type: 'tool.call', itemId: 'e1', name: END_TURN, kind: 'mcp', title: 'end_turn', input } });
    s.text('m1', reply);
    s.result();
  };
  return { h, waiter, target, other, session, turn };
}

test('waitFor: hibernates until the thread finishes, then wakes and carries on with its reply', () => {
  const { h, waiter, target, session, turn } = setup();
  turn(waiter, { needs: 'nothing', waitFor: [target.slice(0, 8)] });
  let t = h.runner.get(waiter);
  assert.deepEqual(checkSummary(t), []);
  assert.equal(Date.parse(t.snoozedUntil!), h.clock.now() + WAIT_FOR_DEFAULT_MS);
  assert.deepEqual(t.waitingOn, [{ threadId: target, title: h.runner.get(target).title }]);
  assert.match(h.events(waiter).at(-1).text, /^Hibernating until ".+" finishes, or .+ at the latest\.$/);

  turn(target, { needs: 'nothing' }, 'Saved 4.1 MB on the restart.');
  t = h.runner.get(waiter);
  assert.equal(t.snoozedUntil, undefined);
  assert.equal(t.waitingOn, undefined);
  assert.ok(['starting', 'running'].includes(t.status), 'a new turn started in the waiting thread');
  const msg = h.events(waiter).filter((e) => e.type === 'user.message').at(-1);
  assert.equal(msg.origin, 'runner');
  const sent = msg.text as string;
  assert.match(sent, /Saved 4\.1 MB on the restart\./);
  assert.match(sent, /Carry on from here/);
  assert.ok(h.events(waiter).some((e) => e.type === 'system.note' && /^Woke up.*: ".+" finished\.$/.test(e.text)));
});

test('waitFor: a target that ends needing Mike, or hibernates itself, has not finished', () => {
  const { h, waiter, target, turn } = setup();
  turn(waiter, { needs: 'nothing', waitFor: [target] });
  turn(target, { needs: 'you', asks: [{ question: 'Restart the runner?' }] });
  assert.ok(h.runner.get(waiter).snoozedUntil);
  turn(target, { needs: 'nothing', snooze: 'restart' });
  assert.ok(h.runner.get(waiter).snoozedUntil);
  assert.deepEqual(h.runner.get(waiter).waitingOn?.map((w) => w.done), [undefined]);
});

test('waitFor: with two threads it wakes once both are done; archiving one counts', () => {
  const { h, waiter, target, other, turn } = setup();
  turn(waiter, { needs: 'nothing', waitFor: [target, other], snooze: '2h' });
  assert.equal(Date.parse(h.runner.get(waiter).snoozedUntil!), h.clock.now() + 2 * 3_600_000);
  turn(target, { needs: 'nothing' }, 'First one done.');
  let t = h.runner.get(waiter);
  assert.ok(t.snoozedUntil);
  assert.deepEqual(t.waitingOn?.map((w) => w.done), [true, undefined]);
  assert.deepEqual(checkSummary(t), []);
  h.runner.update({ threadId: other, archived: true });
  t = h.runner.get(waiter);
  assert.equal(t.snoozedUntil, undefined);
});

test('waitFor: a message from the thread it waits on wakes it as any message does', () => {
  const { h, waiter, target, turn } = setup();
  turn(waiter, { needs: 'nothing', waitFor: [target] });
  h.runner.send(waiter, 'Here is the report early');
  assert.equal(h.runner.get(waiter).waitingOn, undefined);
  assert.equal(h.runner.get(waiter).snoozedUntil, undefined);
});

test('waitFor: only with needs "nothing", and an unknown id leaves it in the inbox with a note', () => {
  const { h, waiter, target, turn } = setup();
  turn(waiter, { needs: 'you', asks: [{ question: 'Which?' }], waitFor: [target] });
  assert.equal(h.runner.get(waiter).snoozedUntil, undefined);
  turn(waiter, { needs: 'nothing', waitFor: ['ffffffff'] });
  assert.equal(h.runner.get(waiter).snoozedUntil, undefined);
  assert.ok(h.events(waiter).some((e) => e.type === 'system.note' && /^Not hibernated: none of the threads/.test(e.text)));
});
