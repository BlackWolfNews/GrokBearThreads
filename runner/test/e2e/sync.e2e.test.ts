// The Convex mirror against a real deployment: the repo's local dev
// deployment (`npx convex deployment create mikec:threadbear:local
// --select` wrote .env.local at the repo root; nothing here touches the
// Sydney project). Starts `npx convex dev` for the local backend, points a
// runner at it with its own key, and reads back what it wrote through the
// deployment's HTTP API and the phone's queries. No CLI is spawned
// (claudePath points nowhere) so it costs nothing. Skips without
// .env.local.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn, execFile, type ChildProcess } from 'node:child_process';
import { promisify } from 'node:util';
import { RunnerClient } from '../../src/client.ts';
import { readRunnerJson } from '../../src/config.ts';

const RUNNER_DIR = path.join(import.meta.dirname, '..', '..');
const REPO = path.join(RUNNER_DIR, '..');
const ENV_FILE = path.join(REPO, '.env.local');
const run = promisify(execFile);

function readEnvLocal(): Record<string, string> {
  if (!fs.existsSync(ENV_FILE)) return {};
  const out: Record<string, string> = {};
  for (const line of fs.readFileSync(ENV_FILE, 'utf8').split('\n')) {
    const m = /^\s*([A-Z_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (m) out[m[1]!] = m[2]!.replace(/^["']|["']$/g, '');
  }
  return out;
}

const envLocal = readEnvLocal();
const CONVEX_URL = envLocal.CONVEX_URL;
const LOCAL = Boolean(CONVEX_URL && /^https?:\/\/(127\.0\.0\.1|localhost)/.test(CONVEX_URL));

describe('convex mirror e2e', { skip: LOCAL ? false : 'no local Convex deployment in .env.local at the repo root' }, () => {
  let convexDev: ChildProcess;
  let convexOut = '';
  let runner: ChildProcess;
  let runnerOut = '';
  let client: RunnerClient;
  let home: string;
  const key = 'e2e-' + crypto.randomBytes(8).toString('hex');

  const api = async (kind: 'query' | 'mutation', fn: string, args: Record<string, unknown>): Promise<any> => {
    const res = await fetch(`${CONVEX_URL}/api/${kind}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ path: fn, args, format: 'json' }) });
    const body = (await res.json()) as { status: string; value?: unknown; errorMessage?: string };
    if (body.status !== 'success') throw new Error(body.errorMessage ?? `HTTP ${res.status}`);
    return body.value;
  };
  const until = async <T,>(what: string, fn: () => Promise<T | undefined>, ms = 20_000): Promise<T> => {
    const end = Date.now() + ms;
    for (;;) {
      const v = await fn().catch(() => undefined);
      if (v !== undefined) return v;
      if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
      await new Promise((r) => setTimeout(r, 300));
    }
  };

  before(async () => {
    // The local backend, with the functions pushed to it.
    convexDev = spawn('npx', ['convex', 'dev', '--tail-logs', 'disable', '--typecheck', 'disable'], { cwd: REPO, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
    convexDev.stdout!.on('data', (d) => (convexOut += d));
    convexDev.stderr!.on('data', (d) => (convexOut += d));
    await until('convex dev to be ready', async () => (/Convex functions ready/.test(convexOut) ? true : undefined), 180_000).catch((e) => {
      throw new Error(`${e.message}\n${convexOut}`);
    });
    await run('npx', ['convex', 'env', 'set', 'RUNNER_KEY', key], { cwd: REPO });

    home = fs.mkdtempSync(path.join(os.tmpdir(), 'tb-sync-e2e-'));
    fs.mkdirSync(path.join(home, 'secrets'), { recursive: true, mode: 0o700 });
    fs.writeFileSync(path.join(home, 'secrets', 'convex-key'), key + '\n', { mode: 0o600 });
    fs.writeFileSync(path.join(home, 'runner.json'), JSON.stringify({ sync: { name: 'E2E Mac' } }));
    // A fake claude-main login, so a thread can be made; its turn fails at
    // once because claudePath points nowhere, which is all this needs.
    fs.mkdirSync(path.join(home, 'fake-main'), { recursive: true });
    fs.writeFileSync(path.join(home, 'fake-main.json'), JSON.stringify({ oauthAccount: { emailAddress: 'e2e@example.com' } }));
    const env = { ...process.env };
    delete env.THREADBEAR_SYNC; // check.sh sets it off for every other test
    runner = spawn(process.execPath, ['src/main.ts'], {
      cwd: RUNNER_DIR,
      env: {
        ...env,
        THREADBEAR_HOME: home,
        THREADBEAR_PORT: '0',
        THREADBEAR_LOG: path.join(home, 'runner.log'),
        THREADBEAR_CLAUDE_PATH: '/nonexistent/claude',
        THREADBEAR_ACCOUNTS_DIR: path.join(home, 'no-accounts'),
        THREADBEAR_CLAUDE_MAIN_DIR: path.join(home, 'fake-main'),
        THREADBEAR_CLAUDE_MAIN_JSON: path.join(home, 'fake-main.json'),
        THREADBEAR_CODEX_MAIN_DIR: path.join(home, 'no-codex-main'),
        THREADBEAR_TOKEN_STATS_LIMITS: path.join(home, 'no-limits.json'),
        THREADBEAR_CLI_UPDATES: 'off',
        THREADBEAR_SYNC_URL: CONVEX_URL,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    runner.stdout!.on('data', (d) => (runnerOut += d));
    runner.stderr!.on('data', (d) => (runnerOut += d));
    const port = await until('the runner to listen', async () => {
      const m = /listening on (\d+)/.exec(runnerOut);
      return m ? Number(m[1]) : undefined;
    }, 30_000);
    const token = fs.readFileSync(path.join(home, 'secrets', 'runner-token'), 'utf8').trim();
    client = await RunnerClient.connect(`ws://127.0.0.1:${port}/rpc`, token);
    await client.call('hello', { client: 'sync-e2e', version: '1' });
  });

  after(async () => {
    client?.close();
    if (runner && runner.exitCode === null) {
      const exited = new Promise((r) => runner.once('exit', r));
      runner.kill('SIGTERM');
      await exited;
    }
    if (convexDev?.pid && convexDev.exitCode === null) {
      // The CLI and the local backend it started.
      try {
        process.kill(-convexDev.pid, 'SIGTERM');
      } catch {}
      await new Promise((r) => setTimeout(r, 1000));
    }
    if (home) fs.rmSync(home, { recursive: true, force: true });
  });

  test('a thread is mirrored, updated, and removed; the runner is listed and signs off', async () => {
    const runnerId = readRunnerJson(home).sync?.runnerId;
    assert.ok(runnerId, 'the runner made itself an id');

    const status = (await client.call('runner.status')) as any;
    assert.equal(status.sync?.state, 'ok');
    assert.equal(status.sync?.url, CONVEX_URL);
    assert.equal(status.sync?.name, 'E2E Mac');

    const runners = await until('the heartbeat', async () => {
      const list = (await api('query', 'sync:runnersList', { key })) as any[];
      const me = list.find((r) => r.runnerId === runnerId);
      return me ?? undefined;
    });
    assert.equal(runners.name, 'E2E Mac');
    assert.ok(runners.lastSeenAt > Date.now() - 60_000);

    // No accounts, so the create needs none; the turn fails at once (no
    // claude), which is fine: the thread exists and is mirrored.
    const { thread: made } = (await client.call('threads.create', { text: 'hello from the e2e', cwd: home, accountId: 'claude-main' })) as any;

    const row = await until('the thread row', async () => {
      const rows = (await api('query', 'sync:threadsOf', { key, runnerId })) as any[];
      return rows.find((r) => r.threadId === made.id);
    });
    assert.equal(row.runnerId, runnerId);
    assert.equal(row.view, 'inbox');
    assert.equal(row.cwd, home);

    await client.call('threads.update', { threadId: made.id, title: 'Renamed from the e2e', archived: true });
    const renamed = await until('the rename and den', async () => {
      const rows = (await api('query', 'sync:threadsOf', { key, runnerId })) as any[];
      const r = rows.find((x) => x.threadId === made.id);
      return r?.title === 'Renamed from the e2e' && r.view === 'den' ? r : undefined;
    });
    assert.ok(renamed.archivedAt);

    // The phone's own queries, with a token issued the documented way.
    const { stdout } = await run('npx', ['convex', 'run', 'tokens:issue', JSON.stringify({ name: 'e2e', days: 1 })], { cwd: REPO });
    // convex run prints the result as pretty JSON, after any log lines.
    const issued = JSON.parse(stdout.slice(stdout.indexOf('{'))) as { token: string };
    const den = (await api('query', 'phone:threads', { token: issued.token, view: 'den' })) as any[];
    assert.ok(den.some((r) => r.threadId === made.id));
    const one = (await api('query', 'phone:thread', { token: issued.token, threadId: made.id })) as any;
    assert.equal(one.thread.title, 'Renamed from the e2e');
    assert.deepEqual(one.messages, []);
    await assert.rejects(api('query', 'phone:threads', { token: 'tb_wrong', view: 'inbox' }), /auth|token/);
    await run('npx', ['convex', 'run', 'tokens:revoke', JSON.stringify({ name: 'e2e' })], { cwd: REPO });

    await client.call('threads.delete', { threadId: made.id });
    await until('the row to go', async () => {
      const rows = (await api('query', 'sync:threadsOf', { key, runnerId })) as any[];
      return rows.some((r) => r.threadId === made.id) ? undefined : true;
    });

    // A stop for good says bye: lastSeenAt goes to 0.
    client.close();
    const exited = new Promise((r) => runner.once('exit', r));
    runner.kill('SIGTERM');
    await exited;
    await until('the goodbye', async () => {
      const list = (await api('query', 'sync:runnersList', { key })) as any[];
      const me = list.find((r) => r.runnerId === runnerId);
      return me && me.lastSeenAt === 0 ? true : undefined;
    });
  });
});
