// Starts the real runner entry point (no CLI is ever spawned: claudePath
// points nowhere) to check what happens when two start at once.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn, type ChildProcess } from 'node:child_process';
import { tmpDir } from '../helpers/fakes.ts';
import { groupAlive, killGroup, processInfo } from '../../src/proc.ts';

const RUNNER_DIR = path.join(import.meta.dirname, '..', '..');

function startRunner(home: string, port = 0): { proc: ChildProcess; out: () => string; listening: Promise<number>; exited: Promise<number | null> } {
  let out = '';
  const proc = spawn(process.execPath, ['src/main.ts'], {
    cwd: RUNNER_DIR,
    env: {
      ...process.env,
      THREADBEAR_HOME: home,
      THREADBEAR_PORT: String(port),
      THREADBEAR_LOG: path.join(home, 'runner.log'),
      THREADBEAR_CLAUDE_PATH: '/nonexistent/claude',
      THREADBEAR_ACCOUNTS_DIR: path.join(home, 'no-accounts'),
      THREADBEAR_CLAUDE_MAIN_DIR: path.join(home, 'no-main'),
      THREADBEAR_CLAUDE_MAIN_JSON: path.join(home, 'no-main.json'),
      // Never the real ~/.codex (its config.toml) or Token Stats' limits.json.
      THREADBEAR_CODEX_MAIN_DIR: path.join(home, 'no-codex-main'),
      THREADBEAR_TOKEN_STATS_LIMITS: path.join(home, 'no-limits.json'),
      THREADBEAR_CLI_UPDATES: 'off',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  proc.stdout!.on('data', (d) => (out += d));
  proc.stderr!.on('data', (d) => (out += d));
  const exited = new Promise<number | null>((r) => proc.once('exit', (code) => r(code)));
  const listening = new Promise<number>((resolve, reject) => {
    proc.stdout!.on('data', () => {
      const m = /listening on (\d+)/.exec(out);
      if (m) resolve(Number(m[1]));
    });
    void exited.then((code) => reject(new Error(`exited ${code}: ${out}`)));
  });
  listening.catch(() => {});
  return { proc, out: () => out, listening, exited };
}

test('a second runner on the same data dir refuses to start and touches nothing', async () => {
  const home = tmpDir();
  const a = startRunner(home);
  const port = await a.listening;
  // A process group the first runner owns, as children.json would list it.
  const owned = spawn('/bin/sleep', ['60'], { detached: true, stdio: 'ignore' });
  owned.unref();
  try {
    await new Promise((r) => setTimeout(r, 100));
    fs.writeFileSync(
      path.join(home, 'run', 'children.json'),
      JSON.stringify([{ pid: owned.pid, command: '/bin/sleep', startedAt: new Date().toISOString(), lstart: processInfo(owned.pid!)!.lstart, groups: [] }]),
    );
    const b = startRunner(home);
    assert.equal(await b.exited, 1);
    assert.match(b.out(), /Another runner \(pid \d+\) is already using/);
    assert.equal(groupAlive(owned.pid!), true, "the first runner's CLI was not swept");

    // A runner on another data dir but the same port says so and exits.
    const c = startRunner(tmpDir(), port);
    assert.equal(await c.exited, 1);
    assert.match(c.out(), /port \d+ is already in use/);
    assert.doesNotMatch(c.out(), /Unhandled 'error' event/);

    a.proc.kill('SIGTERM');
    assert.equal(await a.exited, 0);
    assert.equal(fs.existsSync(path.join(home, 'run', 'runner.pid')), false, 'the lock is released on a clean stop');
  } finally {
    killGroup(owned.pid!, 'SIGKILL');
    a.proc.kill('SIGKILL');
  }
});
