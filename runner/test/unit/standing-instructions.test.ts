// Mike's standing instructions (instructions.ts): a fresh session gets them
// with its instructions; a live or resumed one hears a change once, before
// his next message.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeHarness, tick, tmpDir } from '../helpers/fakes.ts';

test('standing instructions reach a fresh session, and each change reaches a live one once', async () => {
  let standing = 'You are a world-class copywriter.';
  const cwd = tmpDir();
  const h = makeHarness(tmpDir(), {}, { standingInstructions: () => standing });
  const { thread } = h.runner.create({ text: 'Write a tagline', cwd, accountId: 'claude-3' });
  await tick();
  assert.match(h.adapter.last.opts.instructions ?? '', /standing instructions \(set in Threadbear, Settings > General[\s\S]*world-class copywriter/);
  assert.equal(h.adapter.last.sent.at(-1)!.text, 'Write a tagline');
  const finish = async () => {
    h.adapter.last.init();
    h.adapter.last.result('completed');
    await tick();
  };
  await finish();
  // Unchanged: nothing before the next message.
  h.runner.send(thread.id, 'another');
  await tick();
  assert.equal(h.adapter.last.sent.at(-1)!.text, 'another');
  await finish();
  // Changed while it's live: said once, before the next message.
  standing = 'Be brief.';
  h.runner.send(thread.id, 'and now');
  await tick();
  assert.match(h.adapter.last.sent.at(-1)!.text, /^Note from Threadbear: the user's standing instructions have changed[\s\S]*Be brief\.\n\nand now$/);
  await finish();
  h.runner.send(thread.id, 'again');
  await tick();
  assert.equal(h.adapter.last.sent.at(-1)!.text, 'again');
  await finish();
  // Cleared: said once too.
  standing = '';
  h.runner.send(thread.id, 'last');
  await tick();
  assert.match(h.adapter.last.sent.at(-1)!.text, /^Note from Threadbear: the user cleared their standing instructions[\s\S]*\n\nlast$/);
});

test('with none set, sessions get nothing extra', async () => {
  const h = makeHarness(tmpDir(), {}, { standingInstructions: () => '  ' });
  h.runner.create({ text: 'Hi', cwd: tmpDir(), accountId: 'claude-3' });
  await tick();
  assert.equal(h.adapter.last.opts.instructions, undefined);
  assert.equal(h.adapter.last.sent.at(-1)!.text, 'Hi');
});

test("a change says so in the transcript, and a session with none writes nothing on the thread's record", async () => {
  let standing = '';
  const h = makeHarness(tmpDir(), {}, { standingInstructions: () => standing });
  const { thread } = h.runner.create({ text: 'Hi', cwd: tmpDir(), accountId: 'claude-3' });
  await tick();
  const finish = async () => {
    h.adapter.last.init();
    h.adapter.last.result('completed');
    await tick();
  };
  await finish();
  h.runner.send(thread.id, 'again');
  await tick();
  await finish();
  assert.equal(h.store.load(thread.id)?.instructionsTold, undefined);
  assert.equal(h.events(thread.id).filter((e: { text?: string }) => /standing instructions/.test(e.text ?? '')).length, 0);
  standing = 'Be brief.';
  h.runner.send(thread.id, 'now');
  await tick();
  assert.equal(h.events(thread.id).filter((e: { type: string; text?: string }) => e.type === 'system.note' && /standing instructions/.test(e.text ?? '')).length, 1);
  assert.match(h.adapter.last.sent.at(-1)!.text, /^Note from Threadbear: the user's standing instructions\.\n\n[\s\S]*Be brief\.\n\nnow$/);
});

test('a command keeps the news for the next message', async () => {
  let standing = '';
  const h = makeHarness(tmpDir(), {}, { standingInstructions: () => standing });
  const { thread } = h.runner.create({ text: 'Hi', cwd: tmpDir(), accountId: 'claude-3' });
  await tick();
  h.adapter.last.init();
  h.adapter.last.result('completed');
  await tick();
  standing = 'Be brief.';
  h.runner.send(thread.id, '/compact');
  await tick();
  assert.equal(h.adapter.last.sent.at(-1)!.text, '/compact');
  h.adapter.last.init();
  h.adapter.last.result('completed');
  await tick();
  h.runner.send(thread.id, 'next');
  await tick();
  assert.match(h.adapter.last.sent.at(-1)!.text, /Be brief\.\n\nnext$/);
});
