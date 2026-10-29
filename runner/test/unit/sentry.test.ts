// Only the installed runner reports to Sentry: a release on the real data
// dir. Dev runners, tests and sandbox installs never do.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { defaultHome } from '../../src/config.ts';
import { logLineEvent, safeFields, sentryWanted } from '../../src/sentry.ts';
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

test('a WARN line goes as a warning, grouped by its message with ids taken out', () => {
  const now = 1_000_000;
  const a = logLineEvent('warning', 'could not tell 6f1c2d3e-1111-4222-8333-944445555666 the app restarted', { error: 'Thread not found: x' }, now);
  assert.equal(a?.level, 'warning');
  assert.equal(a?.title, 'could not tell <id> the app restarted');
  assert.deepEqual(a?.fingerprint, ['runner-log', 'warning', 'could not tell <id> the app restarted']);
  // Another thread's id is the same fault, inside the hour: nothing more.
  assert.equal(logLineEvent('warning', 'could not tell 0a0b0c0d-1111-4222-8333-944445555666 the app restarted', undefined, now + 1000), null);
  // An hour on it goes again.
  assert.ok(logLineEvent('warning', 'could not tell 0a0b0c0d-1111-4222-8333-944445555666 the app restarted', undefined, now + 60 * 60_000));
});

test('a WARN and an ERROR with the same text are separate issues', () => {
  const now = 2_000_000;
  assert.ok(logLineEvent('error', 'phone command failed (both levels)', undefined, now));
  assert.ok(logLineEvent('warning', 'phone command failed (both levels)', undefined, now));
});

test('model limits and Convex sync network blips are never sent', () => {
  assert.equal(logLineEvent('warning', 'model call failed', { error: 'rate limited' }), null);
  assert.equal(logLineEvent('warning', 'convex sync failed; will retry', { error: 'TypeError: fetch failed' }), null);
  // A Convex sync failure that isn't the network still goes.
  assert.ok(logLineEvent('warning', 'convex sync failed; will retry', { error: 'ArgumentValidationError: bad field' }));
});

test('uncaught exceptions are left to reportException, which has the stack', () => {
  assert.equal(logLineEvent('error', 'uncaught exception', { error: 'boom' }), null);
});
