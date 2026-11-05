// The Convex mirror against a real deployment: the repo's local one, named
// in .env.e2e at the repo root (gitignored; `npx convex deployment create
// mikec:threadbear:local --select` writes .env.local, which is then copied
// to .env.e2e so the Sydney dev deployment can stay selected for everyday
// work). Every convex command here passes `--env-file .env.e2e`, so
// nothing touches the Sydney project. Starts `npx convex dev` for the local
// backend, points a runner at it with its own key, and reads back what it
// wrote through the deployment's HTTP API and the phone's queries. No CLI
// is spawned (claudePath points nowhere) so it costs nothing. Skips
// without .env.e2e.
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
import { BACKEND_API_VERSION } from '../../src/sync.ts';

const RUNNER_DIR = path.join(import.meta.dirname, '..', '..');
const REPO = path.join(RUNNER_DIR, '..');
const ENV_FILE = path.join(REPO, '.env.e2e');
const ENV_ARGS = ['--env-file', ENV_FILE];
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

describe('convex mirror e2e', { skip: LOCAL ? false : 'no local Convex deployment in .env.e2e at the repo root' }, () => {
  let convexDev: ChildProcess;
  let convexOut = '';
  let runner: ChildProcess;
  let runnerOut = '';
  let client: RunnerClient;
  let home: string;
  const key = 'e2e-' + crypto.randomBytes(8).toString('hex');
  // `convex dev --env-file` still rewrites .env.local to the deployment it
  // ran against, which would leave the repo pointed at the local one.
  const envLocalPath = path.join(REPO, '.env.local');
  const envLocalBefore = fs.existsSync(envLocalPath) ? fs.readFileSync(envLocalPath, 'utf8') : undefined;

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
    convexDev = spawn('npx', ['convex', 'dev', ...ENV_ARGS, '--tail-logs', 'disable', '--typecheck', 'disable'], { cwd: REPO, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
    convexDev.stdout!.on('data', (d) => (convexOut += d));
    convexDev.stderr!.on('data', (d) => (convexOut += d));
    await until('convex dev to be ready', async () => (/Convex functions ready/.test(convexOut) ? true : undefined), 180_000).catch((e) => {
      throw new Error(`${e.message}\n${convexOut}`);
    });
    await run('npx', ['convex', 'env', 'set', ...ENV_ARGS, 'RUNNER_KEY', key], { cwd: REPO });

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
        THREADBEAR_CLI_UPDATES: 'off', THREADBEAR_TOKEN_TALLY: 'off',
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
    if (envLocalBefore !== undefined) fs.writeFileSync(envLocalPath, envLocalBefore);
    else if (fs.existsSync(envLocalPath)) fs.rmSync(envLocalPath);
  });

  // Step 6 (docs/protocol.md, Schedules, "Runners"): with an API 9 backend
  // the runner moves its schedules into the table, makes them there, takes
  // each due run with a claim, runs what another runner asked for, and can
  // put one on another runner (here a pretend "bruce" that only heartbeats).
  test('schedules live in the backend: made there, claimed when due, run on request, made for another runner', async () => {
    const runnerId = readRunnerJson(home).sync?.runnerId;
    const owned = async () => (await api('query', 'sync:schedules', { key })) as any[];
    const row = (id: string) => owned().then((rows) => rows.find((r) => r.id === id));

    // Made through the runner once it has attached (the first heartbeat).
    const daily = await until('the scheduler to attach', async () => {
      try {
        return ((await client.call('schedules.create', { text: 'Daily check', cron: '0 9 * * *', cwd: home, accountId: 'claude-main' })) as any).schedule;
      } catch {
        return undefined;
      }
    });
    const saved = await until('the row', () => row(daily.id));
    assert.equal(saved.runnerId, runnerId);
    assert.equal(saved.whenText, 'Every day at 9:00');
    assert.equal(saved.cwd, home);
    // Made before the first heartbeat it was the file's, and moved up; either
    // way it's listed with this runner's name now.
    const listed = await until('the runner name', async () => {
      const l = ((await client.call('schedules.list')) as any).schedules.find((x: any) => x.id === daily.id);
      return l?.runnerName ? l : undefined;
    });
    assert.equal(listed.runnerName, 'E2E Mac');

    // Another runner, as the backend knows it.
    await api('mutation', 'sync:heartbeat', { key, runner: { runnerId: 'e2e-bruce', name: 'bruce', version: 'x', startedAt: new Date().toISOString(), draining: false, threadCount: 0 } });
    // The local deployment keeps the runners of earlier runs (said goodbye,
    // so not offered); this one is first.
    const runners = ((await client.call('runners.list')) as any).runners;
    assert.deepEqual([runners[0].name, runners[0].self], ['E2E Mac', true]);
    assert.ok(runners.some((r: any) => r.id === 'e2e-bruce' && r.name === 'bruce' && r.online && !r.self), JSON.stringify(runners));
    const away = ((await client.call('schedules.create', { text: 'On Bruce', cron: '@hourly', runnerId: 'bruce' })) as any).schedule;
    assert.equal(away.runnerId, 'e2e-bruce');
    assert.equal(away.runnerName, 'bruce');
    assert.equal((await until('bruce\'s row', () => row(away.id))).cwd, undefined, "bruce's default folder");
    // Run now on bruce's: asked for, not run here.
    const asked = (await client.call('schedules.run', { scheduleId: away.id })) as any;
    assert.equal(asked.queued, true);
    assert.ok((await row(away.id)).runRequestedAt);

    // Due: an `at` already passed runs straight away, once.
    const once = ((await client.call('schedules.create', { text: 'Now please', at: new Date(Date.now() - 60_000).toISOString(), cwd: home, accountId: 'claude-main' })) as any).schedule;
    const ran = await until('the due run', async () => {
      const r = await row(once.id);
      return r?.finishedAt ? r : undefined;
    });
    assert.equal(ran.runs, 1);
    assert.equal(ran.lastRun.outcome, 'sent');
    assert.equal(ran.nextRunAt, undefined);

    // A run another runner asked for on ours: this runner sends it.
    await api('mutation', 'sync:requestScheduleRun', { key, scheduleId: daily.id, at: new Date().toISOString() });
    const requested = await until('the requested run', async () => {
      const r = await row(daily.id);
      return r?.runs === 1 && !r.runRequestedAt ? r : undefined;
    });
    assert.equal(requested.nextRunAt, saved.nextRunAt, 'a run now keeps the next time');
    const started = ((await client.call('threads.list', { include: ['inbox'] })) as any).threads.filter((t: any) => t.schedule?.id === daily.id || t.schedule?.id === once.id);
    assert.equal(started.length, 2, 'one thread each');

    // Delete goes to the backend.
    for (const sc of [daily, away, once]) await client.call('schedules.delete', { scheduleId: sc.id });
    await until('the rows to go', async () => ((await owned()).some((r) => [daily.id, away.id, once.id].includes(r.id)) ? undefined : true));
    for (const t of started) await client.call('threads.delete', { threadId: t.id });
    const saidOnDisk = JSON.parse(fs.readFileSync(path.join(home, 'schedules.json'), 'utf8'));
    assert.equal(saidOnDisk.version, 2, 'the file is the backend copy');
    // Bruce goes, so the phone's main runner online is this one again.
    await api('mutation', 'sync:bye', { key, runnerId: 'e2e-bruce' });
  });

  // Step 6 part 2 (docs/protocol.md, "Other runners' threads"): the runner
  // writes its sidebar rows, and hands the app another runner's rows (here a
  // pretend "e2e-other" that only heartbeats and writes its index).
  test('API 37: one account at a time, firstSeen, and a thread row without its messages', async () => {
    // Its own each run: the local deployment keeps its rows between runs.
    const runnerId = 'e2e-accounts-' + crypto.randomBytes(4).toString('hex');
    const beat = (r: string) => api('mutation', 'sync:heartbeat', { key, runner: { runnerId: r, name: r, version: 'x', startedAt: 'x', draining: false, threadCount: 0 } });
    assert.deepEqual(await beat(runnerId), { apiVersion: BACKEND_API_VERSION, firstSeen: true });
    assert.deepEqual(await beat(runnerId), { apiVersion: BACKEND_API_VERSION });

    const acct = (id: string, title: string) => ({ id, provider: 'claude', title, usage: { windows: [{ kind: 'week', title: 'Week', remainingPercent: 40 }], readAt: '2026-11-05T00:00:00Z', source: 'x' } });
    const { token } = await api('mutation', 'sync:issueToken', { key, kind: 'browser', name: 'e2e-37' });
    const mine = async () => ((await api('query', 'phone:accounts', { token })) as { id: string; title: string; runnerId: string }[]).filter((a) => a.runnerId === runnerId).map((a) => `${a.id}:${a.title}`).sort();
    await api('mutation', 'sync:setAccounts', { key, runnerId, accounts: [acct('a', 'A'), acct('b', 'B')] });
    await api('mutation', 'sync:upsertAccounts', { key, runnerId, accounts: [acct('a', 'A2'), acct('c', 'C')], removed: ['b', 'never-there'] });
    assert.deepEqual(await mine(), ['a:A2', 'c:C']);

    const threadId = 'e2e-row-' + crypto.randomBytes(4).toString('hex');
    const doc = { threadId, runnerId, title: 'Row', cwd: '/x', accountId: 'a', provider: 'claude', status: 'idle', needsYou: false, unread: false, preview: 'p', createdAt: 'x', lastActivityAt: 'x', lastActivityMs: 1, view: 'inbox' };
    await api('mutation', 'sync:upsertThreads', { key, threads: [doc] });
    assert.deepEqual(await api('query', 'phone:threadRow', { token, threadId }), doc);
    await api('mutation', 'sync:removeThreads', { key, threadIds: [threadId] });
    await assert.rejects(api('query', 'phone:threadRow', { token, threadId }));
    // API 43: a list once, then only what changed.
    const a = 'e2e-a-' + crypto.randomBytes(4).toString('hex');
    const b = 'e2e-b-' + crypto.randomBytes(4).toString('hex');
    const start = await api('query', 'phone:threadsAt', { token, view: 'inbox' });
    assert.equal(typeof start.at, 'number');
    await api('mutation', 'sync:upsertThreads', { key, threads: [{ ...doc, threadId: a }, { ...doc, threadId: b }] });
    const since = start.at - 5000;
    const heard = await api('query', 'phone:threadsSince', { token, since });
    const ids = heard.rows.map((r: { threadId: string }) => r.threadId);
    assert.ok(ids.includes(a) && ids.includes(b), JSON.stringify(ids));
    assert.equal(typeof heard.rows.find((r: { threadId: string }) => r.threadId === a).updatedMs, 'number');
    const later = Math.max(...heard.rows.map((r: { updatedMs: number }) => r.updatedMs)) + 1;
    assert.deepEqual((await api('query', 'phone:threadsSince', { token, since: later })).rows, []);
    await api('mutation', 'sync:upsertThreads', { key, threads: [{ ...doc, threadId: a, view: 'den' }] });
    await api('mutation', 'sync:removeThreads', { key, threadIds: [b] });
    const moved = await api('query', 'phone:threadsSince', { token, since: later });
    assert.equal(moved.rows.find((r: { threadId: string }) => r.threadId === a)?.view, 'den');
    assert.ok(moved.gone.includes(b));
    // Removed and made again: the row's what's true, whatever order they came in.
    await api('mutation', 'sync:upsertThreads', { key, threads: [{ ...doc, threadId: b }] });
    const back = await api('query', 'phone:threadsSince', { token, since: later });
    assert.ok(back.rows.some((r: { threadId: string }) => r.threadId === b));
    assert.equal(back.gone.includes(b), false);
    await api('mutation', 'sync:removeThreads', { key, threadIds: [b] });
    // From further back than deletions are kept: load the list again.
    assert.equal((await api('query', 'phone:threadsSince', { token, since: start.at - 24 * 60 * 60_000 })).more, true);
    // The runner's own read of its rows still passes its validator.
    await api('query', 'sync:threadsOf', { key, runnerId });
    await api('mutation', 'sync:removeThreads', { key, threadIds: [a] });

    // Offline again, or the phone's next new thread could pick this runner.
    await api('mutation', 'sync:bye', { key, runnerId });
  });

  test('API 40: a project lists its threads newest first, archived ones too, and follows moves and deletes', async () => {
    const runnerId = 'e2e-links-' + crypto.randomBytes(4).toString('hex');
    const pid = 'e2e-proj-' + crypto.randomBytes(4).toString('hex');
    const other = pid + '-other';
    const { token } = await api('mutation', 'sync:issueToken', { key, kind: 'browser', name: 'e2e-40' });
    const doc = (n: number, view: string, projects: string[]) => ({
      threadId: `${runnerId}-t${n}`, runnerId, title: `T${n}`, cwd: '/x', accountId: 'a', provider: 'claude', status: 'idle', needsYou: false, unread: false, preview: 'p',
      createdAt: 'x', lastActivityAt: 'x', lastActivityMs: n, view, projects: projects.map((id) => ({ id, title: id })),
    });
    const titles = async (projectId: string, limit?: number) =>
      ((await api('query', 'phone:projectThreads', { token, projectId, ...(limit ? { limit } : {}) })) as { title: string; view: string }[]).map((t) => `${t.title}:${t.view}`);
    await api('mutation', 'sync:upsertThreads', { key, threads: [doc(1, 'den', [pid]), doc(2, 'inbox', [pid, other]), doc(3, 'hibernating', [pid]), doc(4, 'inbox', [])] });
    assert.deepEqual(await titles(pid), ['T3:hibernating', 'T2:inbox', 'T1:den']);
    assert.deepEqual(await titles(other), ['T2:inbox']);
    assert.deepEqual(await titles(pid, 2), ['T3:hibernating', 'T2:inbox']);
    // A turn moves T1 to the top; T2 leaves the project; T3 is deleted.
    await api('mutation', 'sync:upsertThreads', { key, threads: [{ ...doc(1, 'inbox', [pid]), lastActivityMs: 10 }, doc(2, 'inbox', [other])] });
    await api('mutation', 'sync:removeThreads', { key, threadIds: [`${runnerId}-t3`] });
    assert.deepEqual(await titles(pid), ['T1:inbox']);
    // A prune drops the links of the threads it deletes.
    await api('mutation', 'sync:prune', { key, runnerId, keep: [`${runnerId}-t1`, `${runnerId}-t4`] });
    assert.deepEqual(await titles(other), []);
    // The backfill relinks what's there without doubling anything.
    await api('mutation', 'sync:heartbeat', { key, runner: { runnerId, name: runnerId, version: 'x', startedAt: 'x', draining: false, threadCount: 0 } });
    await new Promise((r) => setTimeout(r, 1000));
    assert.deepEqual(await titles(pid), ['T1:inbox']);
    await assert.rejects(api('query', 'phone:projectThreads', { token: 'tb_wrong', projectId: pid }), /auth|token/);
    await api('mutation', 'sync:removeThreads', { key, threadIds: [`${runnerId}-t1`, `${runnerId}-t4`] });
    await api('mutation', 'sync:bye', { key, runnerId });
  });

  test('the sidebar table: this runner\'s rows go up, another runner\'s come back as remoteThreads', async () => {
    const runnerId = readRunnerJson(home).sync?.runnerId;
    const { thread } = (await client.call('threads.create', { text: 'index me', cwd: home, accountId: 'claude-main' })) as any;
    const mine = await until('this runner\'s index row', async () => {
      const r = (await api('query', 'sync:otherRunnersThreads', { key, runnerId: 'someone-else' })) as any;
      return r.threads.find((t: any) => t.threadId === thread.id);
    });
    assert.equal(mine.runnerId, runnerId);
    assert.equal(mine.title, 'index me');

    await api('mutation', 'sync:heartbeat', { key, runner: { runnerId: 'e2e-other', name: 'other', version: 'x', startedAt: new Date().toISOString(), draining: false, threadCount: 1, icon: 'macmini', rpcUrl: 'wss://other.example.ts.net/rpc' } });
    const row = { threadId: 'other-t1', title: 'On the other Mac', cwd: '/Users/other', accountId: 'codex-main', provider: 'codex', status: 'idle', needsYou: true, unread: false, preview: 'done', createdAt: new Date().toISOString(), lastActivityAt: new Date().toISOString() };
    await api('mutation', 'sync:setThreadIndex', { key, runnerId: 'e2e-other', rows: [row], removed: [] });
    const remote = await until('remoteThreads.list', async () => {
      const r = (await client.call('remoteThreads.list')) as any;
      return r.threads.some((t: any) => t.threadId === 'other-t1') ? r : undefined;
    });
    const other = remote.runners.find((r: any) => r.id === 'e2e-other');
    assert.deepEqual([other.name, other.icon, other.online, other.rpcUrl, other.tokenFile], ['other', 'macmini', true, 'wss://other.example.ts.net/rpc', undefined]);
    assert.ok(!remote.runners.some((r: any) => r.id === runnerId), 'not this runner itself');
    assert.equal(remote.threads.find((t: any) => t.threadId === 'other-t1').needsYou, true);

    // Its thread goes, and the other runner signs off.
    await api('mutation', 'sync:setThreadIndex', { key, runnerId: 'e2e-other', rows: [], removed: ['other-t1'] });
    await until('the row to go', async () => (((await client.call('remoteThreads.list')) as any).threads.some((t: any) => t.threadId === 'other-t1') ? undefined : true));
    await api('mutation', 'sync:bye', { key, runnerId: 'e2e-other' });
    await client.call('threads.delete', { threadId: thread.id });
    await until('this runner\'s row to go', async () => {
      const r = (await api('query', 'sync:otherRunnersThreads', { key, runnerId: 'someone-else' })) as any;
      return r.threads.some((t: any) => t.threadId === thread.id) ? undefined : true;
    });
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
    const { stdout } = await run('npx', ['convex', 'run', ...ENV_ARGS, 'tokens:issue', JSON.stringify({ name: 'e2e', days: 1 })], { cwd: REPO });
    // convex run prints the result as pretty JSON, after any log lines.
    const issued = JSON.parse(stdout.slice(stdout.indexOf('{'))) as { token: string };
    const den = (await api('query', 'phone:threads', { token: issued.token, view: 'den' })) as any[];
    assert.ok(den.some((r) => r.threadId === made.id));
    // phone:search finds archived threads by a word of the title, the last
    // one as a prefix; the search index catches up a moment after the write.
    await until('phone:search', async () => {
      const found = (await api('query', 'phone:search', { token: issued.token, text: 'renamed fr' })) as any[];
      return found.some((r) => r.threadId === made.id && r.view === 'den') || undefined;
    });
    assert.deepEqual(await api('query', 'phone:search', { token: issued.token, text: 'nothingmatchesthis' }), []);
    const one = (await api('query', 'phone:thread', { token: issued.token, threadId: made.id })) as any;
    assert.equal(one.thread.title, 'Renamed from the e2e');
    await assert.rejects(api('query', 'phone:threads', { token: 'tb_wrong', view: 'inbox' }), /auth|token/);

    // Messages: the first message was mirrored (the turn itself failed,
    // there's no claude, so there's no reply).
    const withMessages = await until('the first message', async () => {
      const r = (await api('query', 'phone:thread', { token: issued.token, threadId: made.id })) as any;
      return r.messages.length ? r : undefined;
    });
    assert.deepEqual(withMessages.messages.map((m: any) => [m.seq, m.role, m.text]), [[1, 'user', 'hello from the e2e']]);

    // Lists: the fake login is in accounts.
    const accounts = await until('the accounts list', async () => {
      const a = (await api('query', 'phone:accounts', { token: issued.token })) as any[];
      return a.length ? a : undefined;
    });
    assert.ok(accounts.some((a) => a.id === 'claude-main' && a.email === 'e2e@example.com'), JSON.stringify(accounts));

    // A command from the phone: the runner takes it, applies it (the
    // message lands in the transcript as from the phone), and finishes it.
    await client.call('threads.update', { threadId: made.id, archived: false });
    const commandId = (await api('mutation', 'phone:send', { token: issued.token, threadId: made.id, text: 'sent from the phone' })) as string;
    const outcome = await until('the command to finish', async () => {
      const c = (await api('query', 'phone:command', { token: issued.token, commandId })) as any;
      return c.state === 'done' || c.state === 'failed' ? c : undefined;
    });
    assert.equal(outcome.state, 'done', JSON.stringify(outcome));
    const { events } = (await client.call('threads.events', { threadId: made.id })) as any;
    const fromPhone = events.find((e: any) => e.type === 'user.message' && e.text === 'sent from the phone');
    assert.equal(fromPhone?.origin, 'phone');
    // And it's mirrored back as a message.
    await until('the phone message in the mirror', async () => {
      const r = (await api('query', 'phone:thread', { token: issued.token, threadId: made.id })) as any;
      return r.messages.some((m: any) => m.text === 'sent from the phone' && m.origin === 'phone') ? true : undefined;
    });
    const created = (await api('mutation', 'phone:create', { token: issued.token, text: 'a thread from the phone', cwd: home, accountId: 'claude-main' })) as string;
    const createdOutcome = await until('the create to finish', async () => {
      const c = (await api('query', 'phone:command', { token: issued.token, commandId: created })) as any;
      return c.state === 'done' || c.state === 'failed' ? c : undefined;
    });
    assert.equal(createdOutcome.state, 'done', JSON.stringify(createdOutcome));
    assert.ok(createdOutcome.threadId);
    const newThread = (await client.call('threads.list', { include: ['inbox'] }) as any).threads.find((t: any) => t.id === createdOutcome.threadId);
    assert.equal(newThread?.title, 'a thread from the phone');
    await client.call('threads.delete', { threadId: createdOutcome.threadId });
    // With no runner named, a new thread goes to the runner with the most
    // threads, even when a spare Mac heartbeat last: a phone thread once went
    // to Bruce, which has none of Mike's repos and no printer.
    const beat = (id: string, threadCount: number) => api('mutation', 'sync:heartbeat', { key, runner: { runnerId: id, name: id, version: 'x', startedAt: new Date().toISOString(), draining: false, threadCount } });
    await beat('e2e-main', 100_000);
    await beat('e2e-spare', 0);
    const routed = (await api('mutation', 'phone:create', { token: issued.token, text: 'which runner?' })) as string;
    const toMain = (await api('query', 'sync:pendingCommands', { key, runnerId: 'e2e-main' })) as any[];
    assert.ok(toMain.some((c) => c.commandId === routed), JSON.stringify(toMain));
    await api('mutation', 'sync:takeCommand', { key, commandId: routed });
    await api('mutation', 'sync:finishCommand', { key, commandId: routed, ok: true });
    for (const id of ['e2e-main', 'e2e-spare']) await api('mutation', 'sync:bye', { key, runnerId: id });
    await client.call('threads.update', { threadId: made.id, archived: true });
    await run('npx', ['convex', 'run', ...ENV_ARGS, 'tokens:revoke', JSON.stringify({ name: 'e2e' })], { cwd: REPO });

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
