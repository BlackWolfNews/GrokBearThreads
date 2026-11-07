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
  assert.match(h.adapter.last.opts.instructions ?? '', /standing instructions \(set in Threadbear, Skills > Instructions\)[\s\S]*world-class copywriter/);
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
