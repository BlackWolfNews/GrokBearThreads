// Only the installed runner reports to Sentry: a release on the real data
// dir. Dev runners, tests and sandbox installs never do.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { defaultHome } from '../../src/config.ts';
import { safeFields, sentryWanted } from '../../src/sentry.ts';
import { tmpDir } from '../helpers/fakes.ts';

const RELEASE_ID = '20261029T012558Z-3e0bd5d';

test('a release on the real data dir reports', () => {
  assert.equal(sentryWanted(defaultHome(), {}, RELEASE_ID), true);
});

test('a runner from a checkout never reports, even on the real data dir', () => {
  assert.equal(sentryWanted(defaultHome(), {}, undefined), false);
});

test('a release on another data dir (a sandbox install, a test) never reports', () => {
  assert.equal(sentryWanted(tmpDir(), {}, RELEASE_ID), false);
});

test('THREADBEAR_SENTRY=off and NODE_ENV=test turn it off', () => {
  assert.equal(sentryWanted(defaultHome(), { THREADBEAR_SENTRY: 'off' }, RELEASE_ID), false);
  assert.equal(sentryWanted(defaultHome(), { NODE_ENV: 'test' }, RELEASE_ID), false);
});

test('only the named fields of a log line go, strings cut short', () => {
  const out = safeFields({ error: 'x'.repeat(1200), threadId: 't1', pid: 4, prompt: 'private words', file: '/Users/someone/notes.md', nested: { a: 1 } });
  assert.deepEqual(Object.keys(out).sort(), ['error', 'pid', 'threadId']);
  assert.equal((out.error as string).length, 1001);
});
