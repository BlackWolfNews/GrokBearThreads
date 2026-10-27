import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { makeHarness, tick, tmpDir, testConfig } from '../helpers/fakes.ts';
import { FakeClock } from '../../src/clock.ts';
import { ensureHome, loadConfig, readToken } from '../../src/config.ts';
import { nullLogger } from '../../src/log.ts';
import { HAIKU, Models, isPrivate, keyPath, writeKey } from '../../src/models/index.ts';
import type { ModelSettings } from '../../src/models/index.ts';
import { ledgerPath } from '../../src/models/ledger.ts';
import { SettingsService, modelMethods, settingsMethods } from '../../src/settings.ts';
import { cleanTitle } from '../../src/runner.ts';
import type { Notification } from '../../src/runner.ts';
import { RpcServer } from '../../src/rpc.ts';
import { ErrorCode, RpcError } from '../../src/protocol.ts';

const KEY = 'sk-or-v1-0123456789abcdef0123456789abcdefWXYZ';

type Call = { model: string; body: any; headers: Record<string, string> };

// Stands in for OpenRouter: answers each request with the next reply,
// or by a function of the request.
function fakeFetch(replies: (Reply | ((c: Call) => Reply))[]) {
  const calls: Call[] = [];
  const f = (async (_url: string, init: RequestInit) => {
    const body = JSON.parse(String(init.body));
    const call = { model: body.model, body, headers: init.headers as Record<string, string> };
    calls.push(call);
    let r = replies.shift() ?? { text: 'ok' };
    if (typeof r === 'function') r = r(call);
    if (r.throws) throw new Error(r.throws);
    if (r.hang) {
      return new Promise((_, reject) => init.signal?.addEventListener('abort', () => reject(new Error('aborted'))));
    }
    const status = r.status ?? 200;
    const json = status === 200 ? { choices: [{ message: { content: r.text ?? '' } }], usage: { prompt_tokens: 10, completion_tokens: 3, cost: r.cost ?? 0.0001 } } : { error: { code: status, message: r.text ?? 'nope' } };
    return new Response(JSON.stringify(json), { status });
  }) as unknown as typeof fetch;
  return { f, calls };
}

type Reply = { text?: string; status?: number; cost?: number; throws?: string; hang?: boolean };

function setup(opts: { key?: boolean; settings?: Partial<ModelSettings>; replies?: (Reply | ((c: Call) => Reply))[]; maxInFlight?: number; timeoutMs?: number } = {}) {
  const home = tmpDir();
  ensureHome(home);
  if (opts.key !== false) writeKey(home, KEY);
  const settings: ModelSettings = { dailyBudgetUsd: 1, privateFolders: [], ...opts.settings };
  const clock = new FakeClock();
  const notices: string[] = [];
  let spends = 0;
  const fetch = fakeFetch(opts.replies ?? []);
  const models = new Models({
    home,
    clock,
    log: nullLogger,
    settings: () => settings,
    fetch: fetch.f,
    notice: (_l, m) => notices.push(m),
    onSpend: () => spends++,
    maxInFlight: opts.maxInFlight,
    timeoutMs: opts.timeoutMs,
  });
  const ledger = () =>
    fs.existsSync(ledgerPath(home))
      ? fs.readFileSync(ledgerPath(home), 'utf8').trim().split('\n').map((l) => JSON.parse(l))
      : [];
  return { home, settings, clock, notices, models, calls: fetch.calls, ledger, spends: () => spends };
}

test('models: no key means nothing is sent', async () => {
  const s = setup({ key: false });
  const r = await s.models.generate({ feature: 'titles', prompt: 'hi' });
  assert.deepEqual(r.ok ? 'sent' : r.reason, 'no-key');
  assert.equal(s.calls.length, 0);
  assert.equal(s.models.hasKey(), false);
});

test('models: a call goes to OpenRouter with the key, and the usage file records it without the text', async () => {
  const s = setup({ replies: [{ text: '  Fix the flaky upload test \n', cost: 0.00012 }] });
  const r = await s.models.generate({ feature: 'titles', prompt: 'secret words in a thread', system: 'Name it' });
  assert.ok(r.ok);
  assert.equal(r.value, 'Fix the flaky upload test');
  assert.equal(r.model, HAIKU);
  assert.equal(s.calls[0].headers.authorization, `Bearer ${KEY}`);
  assert.deepEqual(s.calls[0].body.messages, [
    { role: 'system', content: 'Name it' },
    { role: 'user', content: 'secret words in a thread' },
  ]);
  assert.deepEqual(s.calls[0].body.usage, { include: true });
  const lines = s.ledger();
  assert.equal(lines.length, 1);
  assert.equal(lines[0].feature, 'titles');
  assert.equal(lines[0].job, 'generate');
  assert.equal(lines[0].costUsd, 0.00012);
  assert.equal(lines[0].inputTokens, 10);
  assert.ok(!JSON.stringify(lines).includes('secret'), 'no text from the call is kept');
  assert.equal(s.models.spentTodayUsd(), 0.00012);
  assert.equal(s.spends(), 1);
});

test('models: the key file is 0600 and removing it stops calls', async () => {
  const s = setup();
  assert.equal(fs.statSync(keyPath(s.home)).mode & 0o777, 0o600);
  writeKey(s.home, null);
  assert.equal(fs.existsSync(keyPath(s.home)), false);
  const r = await s.models.summarize({ feature: 'digest', text: 'x' });
  assert.equal(r.ok ? 'sent' : r.reason, 'no-key');
});

test('models: private folders and everything under them are never sent', async () => {
  const s = setup({ settings: { privateFolders: ['/work/client'] } });
  for (const cwd of ['/work/client', '/work/client/app']) {
    const r = await s.models.generate({ feature: 'titles', cwd, prompt: 'x' });
    assert.equal(r.ok ? 'sent' : r.reason, 'private', cwd);
  }
  assert.equal(s.calls.length, 0);
  // A sibling that merely starts with the same letters isn't under it.
  assert.ok((await s.models.generate({ feature: 'titles', cwd: '/work/client-other', prompt: 'x' })).ok);
  assert.equal(isPrivate('~/dev/x', ['~/dev']), true);
});

test('models: a budget of 0 turns calls off', async () => {
  const s = setup({ settings: { dailyBudgetUsd: 0 } });
  const r = await s.models.generate({ feature: 'titles', prompt: 'x' });
  assert.equal(r.ok ? 'sent' : r.reason, 'off');
  assert.equal(s.calls.length, 0);
});

test('models: once today\'s budget is spent, calls stop and one notice says so', async () => {
  const s = setup({ settings: { dailyBudgetUsd: 0.01 }, replies: [{ text: 'a', cost: 0.006 }, { text: 'b', cost: 0.006 }] });
  assert.ok((await s.models.generate({ feature: 'f', prompt: 'x' })).ok);
  assert.equal(s.notices.length, 0);
  assert.ok((await s.models.generate({ feature: 'f', prompt: 'x' })).ok, 'the call that crosses the line still answers');
  assert.equal(s.notices.length, 1);
  assert.match(s.notices[0], /\$0\.01 is spent/);
  const r = await s.models.generate({ feature: 'f', prompt: 'x' });
  assert.equal(r.ok ? 'sent' : r.reason, 'over-budget');
  assert.equal(s.calls.length, 2);
  // Tomorrow it starts again.
  s.clock.advance(24 * 60 * 60_000);
  assert.equal(s.models.spentTodayUsd(), 0);
  assert.ok((await s.models.generate({ feature: 'f', prompt: 'x' })).ok);
});

test('models: spend survives a restart through the usage file', async () => {
  const s = setup({ replies: [{ text: 'a', cost: 0.25 }] });
  await s.models.generate({ feature: 'f', prompt: 'x' });
  const again = new Models({ home: s.home, clock: s.clock, log: nullLogger, settings: () => s.settings });
  assert.equal(again.spentTodayUsd(), 0.25);
  assert.equal(again.spentMonthUsd(), 0.25);
});

test('models: one retry on a 5xx or a network error, none on a 4xx', async () => {
  const a = setup({ replies: [{ status: 502 }, { text: 'second time' }] });
  const r = await a.models.generate({ feature: 'f', prompt: 'x' });
  assert.ok(r.ok && r.value === 'second time');
  assert.equal(a.calls.length, 2);

  const b = setup({ replies: [{ throws: 'ECONNRESET' }, { throws: 'ECONNRESET' }] });
  const rb = await b.models.generate({ feature: 'f', prompt: 'x' });
  assert.equal(rb.ok ? 'sent' : rb.reason, 'provider');
  assert.equal(b.calls.length, 2);

  const c = setup({ replies: [{ status: 401, text: 'No auth credentials found' }] });
  const rc = await c.models.generate({ feature: 'f', prompt: 'x' });
  assert.ok(!rc.ok && rc.reason === 'provider' && /401: No auth credentials/.test(rc.message));
  assert.equal(c.calls.length, 1);
  assert.equal(c.ledger()[0].ok, false);
});

test('models: a call that hangs times out', async () => {
  const s = setup({ timeoutMs: 20, replies: [{ hang: true }, { hang: true }] });
  const r = await s.models.generate({ feature: 'f', prompt: 'x' });
  assert.equal(r.ok ? 'sent' : r.reason, 'timeout');
  assert.equal(s.calls.length, 1, 'a timeout is not tried again');
});

test('models: summarize tries ScaleDown first and falls back to Haiku', async () => {
  const s = setup({ replies: [{ status: 400, text: 'bad' }, { text: 'Short summary.' }] });
  const r = await s.models.summarize({ feature: 'digest', text: 'long text', maxWords: 20 });
  assert.ok(r.ok && r.value === 'Short summary.' && r.model === HAIKU);
  assert.deepEqual(s.calls.map((c) => c.model), ['scaledown/summarize', HAIKU]);
  assert.equal(s.calls[0].body.messages.length, 1, 'ScaleDown gets the text alone');
  assert.match(s.calls[1].body.messages[0].content, /at most 20 words/);
});

test('models: extract reads fields, null for ones not given, and moves on from an unreadable answer', async () => {
  const s = setup({
    replies: [{ text: 'here you go: not json' }, { text: '```json\n{"ask": "Set the API key", "where": null}\n```' }],
  });
  const r = await s.models.extract({ feature: 'asks', text: 'transcript', fields: { ask: 'what the agent needs', where: 'which site' } });
  assert.ok(r.ok);
  assert.deepEqual(r.value, { ask: 'Set the API key', where: null });
  assert.deepEqual(s.calls[0].body.provider, { options: { scaledown: { entities: { ask: 'what the agent needs', where: 'which site' } } } });
  const schema = s.calls[1].body.response_format.json_schema.schema;
  assert.deepEqual(schema.required, ['ask', 'where']);
  assert.deepEqual(s.ledger().map((l) => [l.model, l.ok, l.error]), [
    ['scaledown/extract', false, 'unreadable answer'],
    [HAIKU, true, undefined],
  ]);
});

test('models: classify answers one of the labels or fails', async () => {
  const s = setup({ replies: [{ text: '{"label":"needs-you"}' }, { text: '{"label":"maybe"}' }] });
  const r = await s.models.classify({ feature: 'triage', text: 'x', labels: ['needs-you', 'fyi', 'needs-you'] });
  assert.ok(r.ok && r.value === 'needs-you');
  assert.deepEqual(s.calls[0].body.response_format.json_schema.schema.properties.label.enum, ['needs-you', 'fyi']);
  const r2 = await s.models.classify({ feature: 'triage', text: 'x', labels: ['needs-you', 'fyi'] });
  assert.equal(r2.ok ? 'sent' : r2.reason, 'provider');
});

test('models: at most maxInFlight calls at once', async () => {
  const home = tmpDir();
  ensureHome(home);
  writeKey(home, KEY);
  let open = 0;
  let most = 0;
  const gates: (() => void)[] = [];
  // Each request stays open until the test lets it go.
  const f = (async () => {
    open++;
    most = Math.max(most, open);
    await new Promise<void>((r) => gates.push(r));
    open--;
    return new Response(JSON.stringify({ choices: [{ message: { content: 'x' } }] }));
  }) as unknown as typeof fetch;
  const models = new Models({ home, clock: new FakeClock(), log: nullLogger, settings: () => ({ dailyBudgetUsd: 1, privateFolders: [] }), fetch: f, maxInFlight: 2 });
  const all = Promise.all(Array.from({ length: 5 }, () => models.generate({ feature: 'f', prompt: 'x' })));
  for (let done = 0; done < 5; ) {
    await tick(5);
    assert.ok(open <= 2, `at most 2 in flight, saw ${open}`);
    const g = gates.shift();
    if (g) (g(), done++);
  }
  assert.ok((await all).every((r) => r.ok));
  assert.equal(most, 2);
});

// ------------------------------------------------------------- settings

function settingsSetup() {
  const home = tmpDir();
  ensureHome(home);
  const cfg = testConfig(home);
  const clock = new FakeClock();
  const published: Notification[] = [];
  const models = new Models({ home, clock, log: nullLogger, settings: () => cfg.models, fetch: fakeFetch([]).f });
  const svc = new SettingsService({ config: cfg, models, publish: (n) => published.push(n), clock });
  const methods = { ...settingsMethods(svc), ...modelMethods(models) };
  return { home, cfg, clock, published, svc, methods, models };
}

test('settings: get shows the key only as set and its last 4 characters', () => {
  const s = settingsSetup();
  assert.deepEqual(s.svc.get().models.openRouterKey, { set: false });
  const after = s.methods['settings.setKey']({ provider: 'openrouter', key: `  ${KEY}\n` }) as { settings: any };
  assert.deepEqual(after.settings.models.openRouterKey, { set: true, hint: 'WXYZ' });
  assert.ok(!JSON.stringify(after).includes(KEY.slice(0, 20)));
  assert.equal(fs.readFileSync(keyPath(s.home), 'utf8'), KEY + '\n');
  assert.equal(s.published.length, 1);
  assert.equal(s.published[0].method, 'settings.updated');
  s.methods['settings.setKey']({ provider: 'openrouter', key: null });
  assert.deepEqual(s.svc.get().models.openRouterKey, { set: false });
});

test('settings: setKey refuses what is plainly not a key, and other providers', () => {
  const s = settingsSetup();
  const code = (f: () => unknown) => {
    try {
      f();
    } catch (e) {
      return (e as RpcError).code;
    }
    return 'ok';
  };
  assert.equal(code(() => s.methods['settings.setKey']({ provider: 'openrouter', key: 'short' })), ErrorCode.badParams);
  assert.equal(code(() => s.methods['settings.setKey']({ provider: 'openrouter', key: 'sk-or-v1 0123456789abcdef0123' })), ErrorCode.badParams);
  assert.equal(code(() => s.methods['settings.setKey']({ provider: 'openai', key: KEY })), ErrorCode.badParams);
  assert.equal(fs.existsSync(keyPath(s.home)), false);
});

test('settings: update saves to runner.json, applies at once, and a bad field changes nothing', () => {
  const s = settingsSetup();
  const other = path.join(s.home, 'other');
  fs.mkdirSync(other);
  const r = s.methods['settings.update']({ defaultCwd: other, idleMinutes: 10, maxLiveCLIs: 3, followMain: false, models: { dailyBudgetUsd: 2.5, privateFolders: ['~/client', ' ', '~/client'] } }) as { settings: any };
  assert.equal(r.settings.defaultCwd, other);
  assert.equal(s.cfg.idleMs, 10 * 60_000);
  assert.equal(s.cfg.maxLive, 3);
  assert.equal(s.cfg.models.dailyBudgetUsd, 2.5);
  assert.deepEqual(s.cfg.models.privateFolders, ['~/client']);
  assert.equal(r.settings.followMain, false);
  const json = JSON.parse(fs.readFileSync(path.join(s.home, 'runner.json'), 'utf8'));
  assert.equal(json.idleMinutes, 10);
  assert.equal(json.followMain, false);
  assert.deepEqual(json.models, { dailyBudgetUsd: 2.5, privateFolders: ['~/client'] });
  // A fresh load reads the same.
  const cfg = loadConfig({ THREADBARE_HOME: s.home });
  assert.equal(cfg.models.dailyBudgetUsd, 2.5);
  assert.equal(cfg.defaults.cwd, other);

  for (const bad of [{ defaultCwd: '/nope/not/here' }, { idleMinutes: 0 }, { maxLiveCLIs: 2.5 }, { models: { dailyBudgetUsd: -1 } }, { idleMinutes: 5, models: { dailyBudgetUsd: 500 } }]) {
    assert.throws(() => s.methods['settings.update'](bad), (e: RpcError) => e.code === ErrorCode.badParams, JSON.stringify(bad));
  }
  assert.equal(s.cfg.idleMs, 10 * 60_000, 'a refused update changed nothing');
});

test('settings: a fresh runner.json means a $1 budget and no private folders', () => {
  const cfg = loadConfig({ THREADBARE_HOME: tmpDir() });
  assert.deepEqual(cfg.models, { dailyBudgetUsd: 1, privateFolders: [] });
});

test('settings: spend changes reach clients at most once a minute', () => {
  const s = settingsSetup();
  s.svc.spendChanged();
  s.svc.spendChanged();
  assert.equal(s.published.length, 0);
  s.clock.advance(60_000);
  assert.equal(s.published.length, 1);
  s.svc.spendChanged();
  s.clock.advance(60_000);
  assert.equal(s.published.length, 2);
});

test('models.run: refuses bad params and says why a call was not sent', async () => {
  const s = settingsSetup();
  await assert.rejects(async () => s.methods['models.run']({ job: 'classify', text: 'x', labels: ['one'] }), (e: RpcError) => e.code === ErrorCode.badParams);
  await assert.rejects(async () => s.methods['models.run']({ job: 'dance', text: 'x' }), (e: RpcError) => e.code === ErrorCode.badParams);
  const r = await s.methods['models.run']({ job: 'generate', text: 'x' });
  assert.deepEqual((r as any).reason, 'no-key');
});

// --------------------------------------------------------------- titles

test('titles: a model title replaces the first line, unless one was set meanwhile', async () => {
  const asked: any[] = [];
  let answer = '"Fix the upload test."';
  const models = { generate: async (p: any) => (asked.push(p), { ok: true as const, value: answer, model: HAIKU }) };
  const h = makeHarness(undefined, {}, { models });
  const { thread } = h.runner.create({ text: 'can you look at why the upload test keeps failing on CI', accountId: 'claude-3' });
  assert.equal(thread.title, 'can you look at why the upload test keeps failing on CI');
  await tick();
  assert.equal(h.runner.get(thread.id)!.title, 'Fix the upload test');
  assert.equal(asked[0].feature, 'titles');
  assert.equal(asked[0].cwd, thread.cwd, 'the folder goes along, for private folders');

  // Named by hand before the model answered: the hand wins.
  let release!: () => void;
  const slow = { generate: (p: any) => new Promise<any>((r) => (release = () => r({ ok: true, value: 'Model title', model: HAIKU }))) };
  const h2 = makeHarness(undefined, {}, { models: slow });
  const t2 = h2.runner.create({ text: 'something', accountId: 'claude-3' }).thread;
  h2.runner.update({ threadId: t2.id, title: 'Mine' });
  release();
  await tick();
  assert.equal(h2.runner.get(t2.id)!.title, 'Mine');

  // A title given at create isn't asked about at all; a failure keeps the first line.
  answer = 'unused';
  const before = asked.length;
  h.runner.create({ text: 'x', title: 'Given', accountId: 'claude-3' });
  assert.equal(asked.length, before);
  const failing = { generate: async () => ({ ok: false as const, reason: 'no-key' as const, message: '' }) };
  const h3 = makeHarness(undefined, {}, { models: failing });
  const t3 = h3.runner.create({ text: 'first line\nsecond', accountId: 'claude-3' }).thread;
  await tick();
  assert.equal(h3.runner.get(t3.id)!.title, 'first line');
});

test('titles: cleanTitle tidies what a model says', () => {
  assert.equal(cleanTitle('Title: "Ship the settings window."'), 'Ship the settings window');
  assert.equal(cleanTitle('\n**Debug flaky CI**\nextra'), 'Debug flaky CI');
  assert.equal(cleanTitle('x'.repeat(80)).length, 60);
});

// ------------------------------------------------------------------ tb

test('tb settings and tb models key over a real socket; the key goes in by stdin', async () => {
  const s = settingsSetup();
  const h = makeHarness(s.home);
  const server = new RpcServer({ host: '127.0.0.1', port: 0, token: readToken(s.home), runner: h.runner, log: nullLogger, methods: s.methods });
  const { port } = await server.listen();
  const url = `ws://127.0.0.1:${port}/rpc`;
  const TB = path.join(import.meta.dirname, '..', '..', 'bin', 'tb');
  const run = (args: string[], stdin = '') =>
    new Promise<{ code: number | null; out: string }>((resolve) => {
      let out = '';
      const p = spawn(process.execPath, [TB, ...args], { env: { ...process.env, THREADBARE_HOME: s.home, THREADBARE_URL: url }, stdio: ['pipe', 'pipe', 'pipe'] });
      p.stdout.on('data', (d) => (out += d));
      p.stderr.on('data', (d) => (out += d));
      p.stdin.end(stdin);
      p.once('exit', (code) => resolve({ code, out }));
    });
  try {
    let r = await run(['models', 'key'], KEY + '\n');
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /Key saved, ends in WXYZ/);
    r = await run(['models', 'key', KEY]);
    assert.notEqual(r.code, 0);
    assert.match(r.out, /shell history/);
    r = await run(['settings']);
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /OpenRouter key\s+set, ends in WXYZ/);
    assert.match(r.out, /Daily budget\s+\$1\.00/);
    r = await run(['models', 'key', '--remove']);
    assert.match(r.out, /Key removed/);
  } finally {
    await server.close();
  }
});
