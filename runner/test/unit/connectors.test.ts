import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makeHarness, tmpDir } from '../helpers/fakes.ts';
import { buildThreadbearTools } from '../../src/threadbear-mcp.ts';
import {
  CLAUDE_AI_CONNECTORS_URL,
  ConnectorsMonitor,
  FRESH_MS,
  POLL_MS,
  SIGN_IN_NUDGE,
  connectorsMethods,
  findGateway,
  gatewayBase,
  parseHealth,
  serviceState,
  signInProblem,
  turnSignIns,
  uncovered,
} from '../../src/connectors.ts';
import type { PersistedEvent } from '../../src/protocol.ts';

// docs/protocol.md, "Connectors".

const BASE = 'https://bruce.example.ts.net:8443';

// ------------------------------------------------------------------ /health

test("the first gateway's /health: a map of id to state, titled from the id", () => {
  const h = parseHealth({ ok: true, version: '0.1.0', release: '20261026T125212Z-700a3bb9', upstreams: { notion: 'ready', sentry: 'needs_sign_in', cloudflare: 'error', deepwiki: 'disabled' } }, BASE);
  assert.equal(h.version, '0.1.0');
  assert.equal(h.release, '20261026T125212Z-700a3bb9');
  assert.deepEqual(h.services, [
    { id: 'notion', title: 'Notion', state: 'connected' },
    { id: 'sentry', title: 'Sentry', state: 'signed_out', connectUrl: `${BASE}/admin/connect/sentry` },
    { id: 'cloudflare', title: 'Cloudflare', state: 'error', connectUrl: `${BASE}/admin/connect/cloudflare` },
    { id: 'deepwiki', title: 'Deepwiki', state: 'disabled' },
  ]);
});

test('the newer /health: a list with titles, messages and connect URLs, read leniently', () => {
  const h = parseHealth(
    {
      ok: true,
      upstreams: [
        { id: 'notion', title: 'Notion', state: 'connected', tools: 14, extra: { x: 1 } },
        { id: 'sentry', title: 'Sentry', state: 'signed_out', message: 'Token expired', connectUrl: '/admin/connect/sentry' },
        { id: 'cf', title: 'Cloudflare', state: 'connecting' },
        { id: 'linear', state: 'something_new', message: 'Hmm' },
        { id: 'bad', state: 'signed_out', connectUrl: 'javascript:alert(1)' },
        { title: 'No id' },
        'junk',
        { id: 'notion', state: 'error' }, // a repeat is dropped
      ],
    },
    BASE,
  );
  assert.deepEqual(h.services, [
    { id: 'notion', title: 'Notion', state: 'connected' },
    { id: 'sentry', title: 'Sentry', state: 'signed_out', message: 'Token expired', connectUrl: `${BASE}/admin/connect/sentry` },
    { id: 'cf', title: 'Cloudflare', state: 'connecting', connectUrl: `${BASE}/admin/connect/cf` },
    { id: 'linear', title: 'Linear', state: 'unknown', message: 'Hmm', connectUrl: `${BASE}/admin/connect/linear` },
    { id: 'bad', title: 'Bad', state: 'signed_out', connectUrl: `${BASE}/admin/connect/bad` },
  ]);
  assert.deepEqual(parseHealth(null, BASE).services, []);
  assert.deepEqual(parseHealth({ upstreams: 'x' }, BASE).services, []);
});

test('state words map onto the states the app knows', () => {
  assert.equal(serviceState('ready'), 'connected');
  assert.equal(serviceState('needs_sign_in'), 'signed_out');
  assert.equal(serviceState('Signed out'), 'signed_out');
  assert.equal(serviceState('idle'), 'connecting');
  assert.equal(serviceState('disabled'), 'disabled');
  assert.equal(serviceState('error'), 'error');
  assert.equal(serviceState('who knows'), 'unknown');
  assert.equal(serviceState(3), 'unknown');
});

test('the gateway is found in runner.json, else the connectors MCP server in ~/.claude.json', () => {
  const dir = tmpDir();
  const claudeJson = path.join(dir, '.claude.json');
  fs.writeFileSync(claudeJson, JSON.stringify({ mcpServers: { connectors: { type: 'http', url: `${BASE}/mcp`, headers: { Authorization: 'Bearer x' } } } }));
  assert.equal(findGateway(undefined, claudeJson), BASE);
  assert.equal(findGateway({ url: 'https://other.example:9000/mcp' }, claudeJson), 'https://other.example:9000');
  assert.equal(findGateway({ url: '' }, claudeJson), undefined);
  assert.equal(findGateway({ enabled: false }, claudeJson), undefined);
  assert.equal(findGateway(undefined, path.join(dir, 'missing.json')), undefined);
  assert.equal(gatewayBase('ftp://x'), undefined);
});

// ---------------------------------------------------------------- monitor

function fakeFetch(answers: (() => Response | Promise<Response>)[]) {
  const calls: string[] = [];
  const fn = (async (url: string) => {
    calls.push(String(url));
    const next = answers.shift();
    if (!next) throw new Error('no more answers');
    return next();
  }) as unknown as typeof fetch;
  return { fn, calls };
}

test('the monitor asks /health, says when what it shows changes, and keeps asking every few minutes', async () => {
  let now = Date.parse('2026-10-29T10:00:00Z');
  const timers: { fn: () => void; ms: number; cancelled: boolean }[] = [];
  const changes: string[] = [];
  const f = fakeFetch([
    () => Response.json({ upstreams: { notion: 'ready' } }),
    () => Response.json({ upstreams: { notion: 'ready' } }),
    () => Response.json({ upstreams: { notion: 'needs_sign_in' } }),
  ]);
  const m = new ConnectorsMonitor({
    url: BASE,
    fetch: f.fn,
    now: () => now,
    setTimeout: (fn, ms) => {
      const t = { fn, ms, cancelled: false };
      timers.push(t);
      return { cancel: () => (t.cancelled = true) };
    },
    onChange: (s) => changes.push(`${s.state}:${s.services.map((x) => `${x.id}=${x.state}`).join(',')}`),
  });
  assert.equal(m.status().state, 'checking');
  const first = await m.refresh();
  assert.equal(first.state, 'ok');
  assert.equal(f.calls[0], `${BASE}/health`);
  assert.equal(first.checkedAt, '2026-10-29T10:00:00.000Z');
  // Asked again within FRESH_MS: the same answer, no call.
  now += FRESH_MS - 1;
  await m.refresh();
  assert.equal(f.calls.length, 1);
  // The poll: the same again isn't news, a sign-out is.
  assert.equal(timers.at(-1)?.ms, POLL_MS);
  now += POLL_MS;
  timers.at(-1)!.fn();
  await new Promise((r) => setImmediate(r));
  now += POLL_MS;
  timers.at(-1)!.fn();
  await new Promise((r) => setImmediate(r));
  assert.equal(f.calls.length, 3);
  assert.deepEqual(changes, ['ok:notion=connected', 'ok:notion=signed_out']);
  m.stop();
  assert.ok(timers.at(-1)!.cancelled);
});

test("a gateway that can't be reached says so plainly; one ask at a time", async () => {
  const refused = Object.assign(new TypeError('fetch failed'), { cause: { code: 'ECONNREFUSED' } });
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  const f = fakeFetch([
    async () => {
      await gate;
      throw refused;
    },
    () => new Response('nope', { status: 502 }),
    () => new Response('<html>', { status: 200 }),
  ]);
  const m = new ConnectorsMonitor({ url: BASE, fetch: f.fn, setTimeout: () => ({ cancel() {} }) });
  const a = m.refresh();
  const b = m.refresh(true);
  release();
  assert.equal(await a, await b, 'the second waits for the first');
  assert.equal(f.calls.length, 1);
  const s = m.status();
  assert.equal(s.state, 'unreachable');
  assert.match(s.error ?? '', /refused the connection/);
  assert.deepEqual(s.services, []);
  assert.match((await m.refresh(true)).error ?? '', /answered 502/);
  assert.match((await m.refresh(true)).error ?? '', /wasn't JSON/);
});

test('with no gateway the monitor is off and never fetches', async () => {
  const f = fakeFetch([]);
  const m = new ConnectorsMonitor({ fetch: f.fn });
  m.start();
  assert.deepEqual(await m.refresh(true), { state: 'off', services: [] });
  assert.equal(f.calls.length, 0);
});

test('connectors.status answers at once, or after a fresh ask with refresh', async () => {
  const f = fakeFetch([() => Response.json({ upstreams: [{ id: 'notion', title: 'Notion', state: 'signed_out' }] })]);
  const m = new ConnectorsMonitor({ url: BASE, fetch: f.fn, setTimeout: () => ({ cancel() {} }) });
  const methods = connectorsMethods(m);
  assert.deepEqual(methods['connectors.status']({}), { connectors: { state: 'checking', url: BASE, services: [] } });
  const r = (await methods['connectors.status']({ refresh: true })) as { connectors: { services: { state: string }[] } };
  assert.equal(r.connectors.services[0].state, 'signed_out');
});

// ------------------------------------------------------- sign-in problems

test("claude.ai's and the gateway's sign-in errors are found in MCP tool results only", () => {
  assert.deepEqual(signInProblem('mcp__claude_ai_Gmail__search_threads', 'Error: MCP server "claude.ai Gmail" needs you to sign in again'), {
    service: 'Gmail',
    source: 'claude.ai',
    url: CLAUDE_AI_CONNECTORS_URL,
  });
  // The first gateway's words, with its admin page.
  assert.deepEqual(signInProblem('mcp__connectors__notion__notion-search', `Notion needs signing in again. Ask Mike to open ${BASE}/admin and press Connect for Notion.`), {
    service: 'Notion',
    source: 'gateway',
    url: `${BASE}/admin`,
  });
  // The sign_in stub, whatever it says, and its connect page wins.
  assert.deepEqual(signInProblem('mcp__connectors__sentry__sign_in', `Sentry is signed out. Ask Mike to open ${BASE}/admin/connect/sentry, then try again.`), {
    service: 'Sentry',
    source: 'gateway',
    url: `${BASE}/admin/connect/sentry`,
  });
  assert.deepEqual(signInProblem('mcp__connectors__cf__sign_in', 'Signed out.'), { service: 'Cf', source: 'gateway' });
  // A grep that finds the words, or Threadbear's own tools: not a problem.
  assert.equal(signInProblem('Bash', 'MCP server "claude.ai Gmail" needs you to sign in again'), undefined);
  assert.equal(signInProblem('mcp__threadbear__read_thread', 'Notion needs signing in again.'), undefined);
  assert.equal(signInProblem('mcp__connectors__notion__notion-search', 'Found 3 pages'), undefined);
});

let seq = 0;
const ev = (e: Record<string, unknown>): PersistedEvent => ({ seq: ++seq, ts: '2026-10-29T10:00:00Z', ...e }) as unknown as PersistedEvent;

test("turnSignIns reads only this turn's tool results, one per service", () => {
  const events = [
    ev({ type: 'turn.started', turnId: 'a' }),
    ev({ type: 'tool.call', itemId: 'old', name: 'mcp__claude_ai_Notion__search', kind: 'mcp', title: '', input: {} }),
    ev({ type: 'tool.result', itemId: 'old', ok: false, text: 'MCP server "claude.ai Notion" needs you to sign in again', truncated: false, images: [] }),
    ev({ type: 'turn.started', turnId: 'b' }),
    ev({ type: 'tool.call', itemId: 'g1', name: 'mcp__claude_ai_Gmail__search', kind: 'mcp', title: '', input: {} }),
    ev({ type: 'tool.result', itemId: 'g1', ok: false, text: 'MCP server "claude.ai Gmail" needs you to sign in again', truncated: false, images: [] }),
    ev({ type: 'tool.call', itemId: 'g2', name: 'mcp__claude_ai_Gmail__get_thread', kind: 'mcp', title: '', input: {} }),
    ev({ type: 'tool.result', itemId: 'g2', ok: false, text: 'MCP server "claude.ai Gmail" needs you to sign in again', truncated: false, images: [] }),
    ev({ type: 'tool.call', itemId: 'b1', name: 'Bash', kind: 'command', title: '', input: {} }),
    ev({ type: 'tool.result', itemId: 'b1', ok: true, text: 'Sentry needs signing in again', truncated: false, images: [] }),
  ];
  assert.deepEqual(turnSignIns(events), [{ service: 'Gmail', source: 'claude.ai', url: CLAUDE_AI_CONNECTORS_URL }]);
});

test('an ask that links the page or names the service covers the problem', () => {
  const p = [{ service: 'Gmail', source: 'claude.ai' as const, url: CLAUDE_AI_CONNECTORS_URL }];
  assert.equal(uncovered(p, undefined).length, 1);
  assert.equal(uncovered(p, [{ action: 'Merge the PR', why: 'It is green.' }]).length, 1);
  assert.equal(uncovered(p, [{ action: 'Sign in to Gmail again on claude.ai.' }]).length, 0);
  assert.equal(uncovered(p, [{ action: 'Reconnect it.', links: [{ url: CLAUDE_AI_CONNECTORS_URL }] }]).length, 0);
});

// ------------------------------------------------------------ end_turn

test('end_turn is refused once a turn when a sign-in error has no ask, naming the service and the page', async () => {
  const h = makeHarness();
  const { thread } = h.runner.create({ text: 'Find the email from Emily', accountId: 'claude-3' });
  const s = h.adapter.last;
  s.init();
  const endTurn = buildThreadbearTools(h.runner, thread.id, Date.now, undefined, undefined, undefined, { sleep: async () => {} }).find((x) => x.name === 'end_turn')!;
  const call = async (args: Record<string, unknown>, itemId: string) => {
    s.out({ kind: 'event', event: { type: 'tool.call', itemId, name: 'mcp__threadbear__end_turn', kind: 'mcp', title: 'end_turn', input: args } });
    const r = (await endTurn.handler(args as never, {})) as { content: { text: string }[]; isError?: boolean };
    const text = r.content.map((c) => c.text).join('\n');
    s.out({ kind: 'event', event: { type: 'tool.result', itemId, ok: !r.isError, text, truncated: false, images: [] } });
    return { text, error: Boolean(r.isError) };
  };
  s.out({ kind: 'event', event: { type: 'tool.call', itemId: 'g1', name: 'mcp__claude_ai_Gmail__search_threads', kind: 'mcp', title: 'Gmail', input: {} } });
  s.out({ kind: 'event', event: { type: 'tool.result', itemId: 'g1', ok: false, text: 'MCP server "claude.ai Gmail" needs you to sign in again', truncated: false, images: [] } });
  s.text('m1', "I couldn't search Gmail: it needs signing in again.");
  let r = await call({ needs: 'nothing' }, 'e1');
  assert.equal(r.error, true);
  assert.ok(r.text.startsWith(SIGN_IN_NUDGE));
  assert.match(r.text, /Gmail needs signing in again, on claude\.ai/);
  assert.ok(r.text.includes(CLAUDE_AI_CONNECTORS_URL));
  // Once a turn: called again as it was, it's taken.
  s.text('m2', 'It was only a nice-to-have.');
  r = await call({ needs: 'nothing' }, 'e2');
  assert.equal(r.error, false);
  assert.match(r.text, /is done/);
});

test('end_turn takes an ask that covers the sign-in straight away', async () => {
  const h = makeHarness();
  const { thread } = h.runner.create({ text: 'Check Sentry', accountId: 'claude-3' });
  const s = h.adapter.last;
  s.init();
  const endTurn = buildThreadbearTools(h.runner, thread.id, Date.now, undefined, undefined, undefined, { sleep: async () => {} }).find((x) => x.name === 'end_turn')!;
  s.out({ kind: 'event', event: { type: 'tool.call', itemId: 's1', name: 'mcp__connectors__sentry__sign_in', kind: 'mcp', title: 'Sentry', input: {} } });
  s.out({ kind: 'event', event: { type: 'tool.result', itemId: 's1', ok: false, text: `Sentry needs signing in again. Ask Mike to open ${BASE}/admin/connect/sentry.`, truncated: false, images: [] } });
  s.text('m1', 'Sentry needs signing in before I can look.');
  const args = { needs: 'you', asks: [{ action: 'Sign Sentry in again.', why: 'Then I can read the issue.', links: [{ title: 'Sign in to Sentry', url: `${BASE}/admin/connect/sentry` }] }] };
  s.out({ kind: 'event', event: { type: 'tool.call', itemId: 'e1', name: 'mcp__threadbear__end_turn', kind: 'mcp', title: 'end_turn', input: args } });
  const r = (await endTurn.handler(args as never, {})) as { content: { text: string }[]; isError?: boolean };
  assert.equal(r.isError, undefined);
  assert.match(r.content[0].text, /Needs you/);
});
