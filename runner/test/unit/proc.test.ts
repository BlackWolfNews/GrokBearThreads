import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn, type ChildProcess } from 'node:child_process';
import { ProcessRegistry, groupAlive, groupSpawner, killGroup, processInfo } from '../../src/proc.ts';
import { acquireLock } from '../../src/lock.ts';
import { nullLogger } from '../../src/log.ts';
import { tmpDir } from '../helpers/fakes.ts';

const RUNNER_DIR = path.join(import.meta.dirname, '..', '..');

// A detached process (its own group). With ignoreTerm, SIGTERM does nothing.
function group(ignoreTerm = false): ChildProcess {
  const script = ignoreTerm ? 'trap "" TERM; sleep 60' : 'sleep 60';
  const c = spawn('/bin/bash', ['-c', script], { detached: true, stdio: 'ignore' });
  c.unref();
  return c;
}

async function until(fn: () => boolean, ms = 5000): Promise<boolean> {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (fn()) return true;
    await new Promise((r) => setTimeout(r, 50));
  }
  return fn();
}

test('the startup sweep waits until old groups are gone, and leaves a recycled pid alone', async () => {
  const run = tmpDir();
  const stubborn = group(true);
  const other = group();
  await new Promise((r) => setTimeout(r, 200));
  try {
    const entries = [
      { pid: stubborn.pid, command: '/bin/bash', startedAt: new Date().toISOString(), lstart: processInfo(stubborn.pid!)!.lstart, groups: [] },
      // Same pid as something alive, but it started at another time: a recycled pid.
      { pid: other.pid, command: '/bin/bash', startedAt: new Date().toISOString(), lstart: 'Mon Jan  1 00:00:00 2001', groups: [] },
    ];
    fs.writeFileSync(path.join(run, 'children.json'), JSON.stringify(entries));
    const reg = new ProcessRegistry(run, nullLogger);
    const t0 = Date.now();
    assert.equal(await reg.sweepOrphans(300), 1);
    assert.equal(groupAlive(stubborn.pid!), false, 'gone by the time the sweep returns');
    assert.ok(Date.now() - t0 >= 300, 'it ignored SIGTERM, so it took a SIGKILL');
    assert.equal(groupAlive(other.pid!), true, 'the recycled pid was not touched');
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(run, 'children.json'), 'utf8')), []);
  } finally {
    killGroup(stubborn.pid!, 'SIGKILL');
    killGroup(other.pid!, 'SIGKILL');
  }
});

test("a CLI that dies hard has its tool commands' process groups stopped too", async () => {
  const run = tmpDir();
  const reg = new ProcessRegistry(run, nullLogger);
  const spawnCli = groupSpawner(reg, nullLogger, () => {});
  // A stand-in CLI that runs a "tool command" in a group of its own, as
  // Claude Code's Bash tool does.
  const script = `const c = require('node:child_process').spawn('/bin/sleep', ['60'], { detached: true, stdio: 'ignore' }); console.log(c.pid); setInterval(() => {}, 1000);`;
  const cli = spawnCli({ command: process.execPath, args: ['-e', script], cwd: run, env: process.env, signal: new AbortController().signal } as any) as unknown as ChildProcess;
  const toolPid = await new Promise<number>((resolve) => cli.stdout!.once('data', (d) => resolve(Number(String(d).trim()))));
  try {
    await reg.scan();
    assert.deepEqual(reg.toolGroups(cli.pid!), [toolPid]);
    const saved = JSON.parse(fs.readFileSync(path.join(run, 'children.json'), 'utf8'));
    assert.equal(saved[0].groups[0].pgid, toolPid, 'recorded for a runner restart too');
    process.kill(cli.pid!, 'SIGKILL');
    assert.ok(await until(() => !groupAlive(toolPid)), 'the tool command was stopped');
    assert.deepEqual(reg.pids(), []);
  } finally {
    killGroup(toolPid, 'SIGKILL');
    killGroup(cli.pid!, 'SIGKILL');
  }
});

test('only one runner holds the data dir lock; a dead or recycled holder is taken over', async () => {
  const run = tmpDir();
  const holder = spawn(process.execPath, ['--input-type=module', '-e', `import { acquireLock } from ${JSON.stringify(path.join(RUNNER_DIR, 'src', 'lock.ts'))}; acquireLock(process.argv[1]); console.log('held'); setInterval(() => {}, 1000);`, run], { stdio: ['ignore', 'pipe', 'inherit'] });
  try {
    await new Promise((r) => holder.stdout!.once('data', r));
    const second = acquireLock(run);
    assert.deepEqual(second, { heldBy: holder.pid });
    holder.kill('SIGKILL');
    await new Promise((r) => holder.once('exit', r));
    const mine = acquireLock(run);
    assert.ok('release' in mine, 'a dead holder is taken over');
    mine.release();
    assert.equal(fs.existsSync(path.join(run, 'runner.pid')), false);
    // A live pid that started at a different time isn't the old runner.
    fs.writeFileSync(path.join(run, 'runner.pid'), JSON.stringify({ pid: process.ppid, lstart: 'Mon Jan  1 00:00:00 2001' }));
    const again = acquireLock(run);
    assert.ok('release' in again);
    again.release();
  } finally {
    holder.kill('SIGKILL');
  }
});

test('a lock with no start time still counts while a runner under launch.mjs holds it', async () => {
  const run = tmpDir();
  // A release runs as `node <home>/runner/launch.mjs`, not main.ts.
  const script = path.join(tmpDir(), 'launch.mjs');
  fs.writeFileSync(script, "console.log('up'); setInterval(() => {}, 1000);\n");
  const holder = spawn(process.execPath, [script], { stdio: ['ignore', 'pipe', 'inherit'] });
  try {
    await new Promise((r) => holder.stdout!.once('data', r));
    fs.writeFileSync(path.join(run, 'runner.pid'), JSON.stringify({ pid: holder.pid, lstart: '' }));
    assert.deepEqual(acquireLock(run), { heldBy: holder.pid });
  } finally {
    holder.kill('SIGKILL');
  }
});
