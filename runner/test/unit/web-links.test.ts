import assert from 'node:assert/strict';
import { test } from 'node:test';
import { escapeDestinations, findStep, readLink } from '../../../web/src/thread-links.ts';

test('escapes the destinations agents write, so they parse as links', () => {
  // The same text Mike saw raw on the phone, 1 Nov; the website had it too.
  assert.equal(
    escapeDestinations("that's [landed on main](work:Commit, land, retire the old simulator) as `ec865ff`."),
    "that's [landed on main](work:Commit%2C%20land%2C%20retire%20the%20old%20simulator) as `ec865ff`.",
  );
  assert.equal(escapeDestinations('[a](thread:a1b2c3d4)'), '[a](thread:a1b2c3d4)');
  assert.equal(escapeDestinations('[done](work:npm%20test)'), '[done](work:npm%20test)');
  assert.equal(escapeDestinations('[a](work:npm test (unit)) next'), '[a](work:npm%20test%20(unit)) next');
  assert.equal(escapeDestinations('[odd](work:100% done)'), '[odd](work:100%25%20done)');
});

test('leaves everything else alone', () => {
  const web = '[x](https://a.b/c) and [y](/a/b.md)';
  assert.equal(escapeDestinations(web), web);
  assert.equal(
    escapeDestinations('Write `[a](work:npm test)` like that, [b](work:npm test)'),
    'Write `[a](work:npm test)` like that, [b](work:npm%20test)',
  );
  const fenced = '```\n[a](work:npm test)\n```\n[b](work:npm test)';
  assert.equal(escapeDestinations(fenced), '```\n[a](work:npm test)\n```\n[b](work:npm%20test)');
});

test('reads each kind of link', () => {
  assert.deepEqual(readLink('work:npm%20test'), { kind: 'step', quote: 'npm test' });
  assert.deepEqual(readLink('thread:a1b2c3d4'), { kind: 'thread', id: 'a1b2c3d4' });
  assert.deepEqual(readLink('review:abc'), { kind: 'review' });
  assert.equal(readLink('https://a.b'), undefined);
  assert.equal(readLink('/a/b.md'), undefined);
  assert.equal(readLink('work:'), undefined);
});

const rows = [
  { seq: 1, role: 'user' as const, text: 'First' },
  { seq: 2, role: 'tool' as const, text: 'Run the tests' },
  { seq: 3, role: 'assistant' as const, text: 'All done.', summary: true },
  { seq: 4, role: 'user' as const, text: 'Second' },
  { seq: 5, role: 'tool' as const, text: 'Run the tests' },
  { seq: 6, role: 'assistant' as const, text: 'Now the risky part.' },
  { seq: 7, role: 'tool' as const, text: 'Commit, land, retire the old simulator' },
  { seq: 8, role: 'tool' as const, text: 'Edited ~/dev/a.tsx' },
  { seq: 9, role: 'assistant' as const, text: '- [Landed](work:Commit, land)', summary: true },
];

test('a work link finds its step in its own turn', () => {
  assert.equal(findStep('commit,  LAND', 9, rows), 7);
  assert.equal(findStep('Run the tests', 9, rows), 5);
  assert.equal(findStep('Run the tests', 3, rows), 2);
  assert.equal(findStep('risky part', 9, rows), 6);
  assert.equal(findStep('/Users/mike/dev/a.tsx', 9, rows), 8);
});

test('words found nowhere in the turn find nothing', () => {
  assert.equal(findStep('npm run nothing', 9, rows), undefined);
  assert.equal(findStep('Landed', 9, rows), undefined);
  assert.equal(findStep('Edited', 3, rows), undefined);
  assert.equal(findStep('Run the tests', 99, rows), undefined);
});
