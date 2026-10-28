import { test } from 'node:test';
import assert from 'node:assert/strict';
import { archiveFromTool, needsFromText, needsFromTool } from '../../src/needs.ts';

test('end_turn input: nothing, you with asks, and junk falls back', () => {
  assert.deepEqual(needsFromTool({ needs: 'nothing', asks: [{ action: 'ignored' }] }), { needs: 'nothing' });
  assert.deepEqual(
    needsFromTool({ needs: 'you', asks: [{ action: ' Paste the key ', where: 'Settings › Models', reply: 'done' }, { action: '' }, 'x', { action: 'Pick a budget', where: '' }] }),
    { needs: 'you', asks: [{ action: 'Paste the key', where: 'Settings › Models', reply: 'done' }, { action: 'Pick a budget' }] },
  );
  assert.deepEqual(needsFromTool({ needs: 'you' }), { needs: 'you' });
  assert.equal(needsFromTool({ needs: 'maybe' }), undefined);
  // archive only counts with needs "nothing": a thread that asks for something stays in the inbox.
  assert.equal(archiveFromTool({ needs: 'nothing', archive: true }), true);
  assert.equal(archiveFromTool({ needs: 'you', archive: true }), false);
  assert.equal(archiveFromTool({ needs: 'nothing', archive: 'yes' }), false);
  assert.equal(archiveFromTool({ needs: 'nothing' }), false);
  assert.equal(archiveFromTool(undefined), false);
  assert.equal(needsFromTool(null), undefined);
  assert.equal(needsFromTool({ needs: 'you', asks: Array.from({ length: 20 }, (_, i) => ({ action: `a${i}` })) })!.asks!.length, 10);
});

test('end_turn input: a decision keeps its why, options and a valid pick', () => {
  assert.deepEqual(
    needsFromTool({ needs: 'you', asks: [{ action: 'Merge #52?', why: ' Preview is green. ', options: ['Merge', ' ', 'Test locally', 3], suggested: 1 }] }),
    { needs: 'you', asks: [{ action: 'Merge #52?', why: 'Preview is green.', options: ['Merge', 'Test locally'], suggested: 1 }] },
  );
  // A pick that isn't one of the options is dropped, and so is one with no options.
  assert.deepEqual(needsFromTool({ needs: 'you', asks: [{ action: 'a', options: ['x'], suggested: 4 }] })!.asks, [{ action: 'a', options: ['x'] }]);
  assert.deepEqual(needsFromTool({ needs: 'you', asks: [{ action: 'a', options: [], suggested: 0 }] })!.asks, [{ action: 'a' }]);
  assert.equal(needsFromTool({ needs: 'you', asks: [{ action: 'a', options: Array.from({ length: 9 }, (_, i) => `o${i}`) }] })!.asks![0].options!.length, 6);
});

test('the section: a bold heading then a numbered list, with a reply phrase', () => {
  const text = [
    'The Settings window is in.',
    '',
    '**What I need from you**',
    '',
    '1. Open Settings > Models, paste your OpenRouter key, then reply "key set".',
    '   It only needs a small credit limit.',
    '',
    '2. Say whether **$1 a day** is right.',
    '',
    "Meanwhile I'll keep going on the app side.",
  ].join('\n');
  assert.deepEqual(needsFromText(text), {
    needs: 'you',
    asks: [
      { action: 'Open Settings > Models, paste your OpenRouter key, then reply "key set". It only needs a small credit limit.', reply: 'key set' },
      { action: 'Say whether $1 a day is right.' },
    ],
  });
});

test('the section: "nothing needed" under the heading, on its line, or with no heading', () => {
  assert.deepEqual(needsFromText('Done.\n\n**What I need from you**\n\nNothing needed from you right now. It is finished.'), { needs: 'nothing' });
  assert.deepEqual(needsFromText('Done.\n\n**What I need from you:** nothing right now. Still building.'), { needs: 'nothing' });
  assert.deepEqual(needsFromText('Done.\n\nNothing needed from you right now, the work is done. Next step: archive it.'), { needs: 'nothing' });
  assert.deepEqual(needsFromText('I wrote the file. The task is finished, and nothing is needed from you right now.'), { needs: 'nothing' });
});

test('the section: the last heading wins, a mention in a sentence does not count', () => {
  const text = [
    'Agents end with a **What I need from you** section, which we could parse.',
    '',
    '**What I need from you**',
    '',
    '- Reply "go" to build it.',
  ].join('\n');
  assert.deepEqual(needsFromText(text), { needs: 'you', asks: [{ action: 'Reply "go" to build it.', reply: 'go' }] });
  assert.equal(needsFromText('It reads the "What I need from you" heading. I will report back.'), undefined);
  assert.equal(needsFromText('All done here.'), undefined);
});

test('the section: a # heading, and prose under it with no list is one ask', () => {
  assert.deepEqual(needsFromText('## What I need from you\n\n1. Say yes or no.'), { needs: 'you', asks: [{ action: 'Say yes or no.' }] });
  assert.deepEqual(needsFromText('**What I need from you**\n\nRestart the app when you get a minute.'), { needs: 'you', asks: [{ action: 'Restart the app when you get a minute.' }] });
});

test('the section: choices under an ask stay with it, and a choice is not a reply', () => {
  const text = [
    '**What I need from you**',
    '',
    '1. Pick a fix and reply with it:',
    '   - "fix it": I make the tests work.',
    '   - "leave it": nothing changes.',
    '2. Decide on the filter. Reply "filter" or "wait".',
  ].join('\n');
  assert.deepEqual(needsFromText(text), {
    needs: 'you',
    asks: [
      { action: 'Pick a fix and reply with it: "fix it": I make the tests work. "leave it": nothing changes.' },
      { action: 'Decide on the filter. Reply "filter" or "wait".' },
    ],
  });
});

test('the section: a code block in an ask stays in it', () => {
  const text = '**What I need from you**\n\n1. Run this:\n```\n- not an item\n```\nThen reply "done".';
  assert.deepEqual(needsFromText(text), { needs: 'you', asks: [{ action: 'Run this: ``` - not an item ``` Then reply "done".', reply: 'done' }] });
});
