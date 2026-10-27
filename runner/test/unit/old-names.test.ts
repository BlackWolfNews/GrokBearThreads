import { test } from 'node:test';
import assert from 'node:assert/strict';
import { adoptOldNames, loadConfig } from '../../src/config.ts';
import { tmpDir } from '../helpers/fakes.ts';

test('THREADBARE_* (the names from before the rename) stand in for THREADBEAR_*, never over them', () => {
  const env: NodeJS.ProcessEnv = { THREADBARE_HOME: '/old', THREADBARE_THREAD_ID: 't1', THREADBEAR_THREAD_ID: 't2', OTHER: 'x' };
  adoptOldNames(env);
  assert.equal(env.THREADBEAR_HOME, '/old');
  assert.equal(env.THREADBEAR_THREAD_ID, 't2', 'the new name wins');
  assert.equal(env.OTHER, 'x');
  // A launchd job installed before the rename still finds its data dir.
  const home = tmpDir();
  assert.equal(loadConfig({ THREADBARE_HOME: home, THREADBARE_PORT: '0' }).home, home);
});
