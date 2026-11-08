// Grok adapter: a fake `grok agent stdio` process, plus account discovery.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { discoverAccounts } from '../../src/accounts.ts';
import { GrokAdapter } from '../../src/adapters/grok/adapter.ts';
import type { AdapterOutput, SessionSink, StartSessionOptions, ToolApprovalAnswer } from '../../src/adapters/types.ts';

const fixture = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'fixtures', 'fake-grok.mjs');

function opts(over: Partial<StartSessionOptions> = {}): StartSessionOptions {
  return {
    threadId: 't1',
    cwd: os.tmpdir(),
    account: { id: 'grok-main', provider: 'grok', title: 'Grok', configDir: '/tmp/grok' },
    permissionMode: 'ask',
    sessionId: 'preassigned',
    resume: false,
    mediaDir: os.tmpdir(),
    blobsDir: os.tmpdir(),
    tmpDir: os.tmpdir(),
    ...over,
  };
}

function collect() {
  const out: AdapterOutput[] = [];
  let approval: ((a: ToolApprovalAnswer) => void) | undefined;
  let asked!: () => void;
  const askedFor = new Promise<void>((resolve) => { asked = resolve; });
  const sink: SessionSink = {
    output: (o) => out.push(o),
    requestApproval: () => {
      asked();
      return new Promise((resolve) => { approval = resolve; });
    },
    requestQuestion: async () => ({ answers: null }),
    exited: (error) => out.push({ kind: 'event', event: { type: 'error', message: error?.message ?? 'exited' } }),
  };
  return {
    out,
    sink,
    answer: (a: ToolApprovalAnswer) => approval?.(a),
    askedFor,
  };
}

function until(out: AdapterOutput[], pred: (o: AdapterOutput) => boolean): Promise<void> {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`timed out; saw ${out.map((o) => o.kind).join(',')}`)), 5000);
    const timer = setInterval(() => {
      if (out.some(pred)) {
        clearInterval(timer);
        clearTimeout(t);
        resolve();
      }
    }, 15);
  });
}

test('a new Grok session streams the reply and reports the CLI session id', async () => {
  const adapter = new GrokAdapter({ grokPath: 'grok', command: process.execPath, args: [fixture] });
  const bag = collect();
  const session = adapter.start(opts(), bag.sink);
  session.send({ id: 'turn-1', text: 'hi', images: [] });
  await until(bag.out, (o) => o.kind === 'result');
  const sessionOut = bag.out.find((o) => o.kind === 'session');
  assert.equal(sessionOut && sessionOut.kind === 'session' ? sessionOut.nativeSessionId : '', 'grok-sess-1');
  const text = bag.out.filter((o) => o.kind === 'delta').map((o) => (o.kind === 'delta' ? o.delta.text : '')).join('');
  assert.equal(text, 'Hello there');
  const result = bag.out.find((o) => o.kind === 'result');
  assert.equal(result && result.kind === 'result' ? result.result.outcome : '', 'completed');
  session.kill();
});

test('a tool permission is the same card, and the answer goes back to Grok', async () => {
  const adapter = new GrokAdapter({ grokPath: 'grok', command: process.execPath, args: [fixture] });
  const bag = collect();
  const session = adapter.start(opts(), bag.sink);
  session.send({ id: 'turn-2', text: 'ASK please', images: [] });
  await bag.askedFor;
  bag.answer({ decision: 'allow' });
  await until(bag.out, (o) => o.kind === 'result');
  const text = bag.out.filter((o) => o.kind === 'delta').map((o) => (o.kind === 'delta' ? o.delta.text : '')).join('');
  assert.equal(text, 'allowed');
  session.kill();
});

test('resuming a session Grok does not know starts fresh next time', async () => {
  const adapter = new GrokAdapter({ grokPath: 'grok', command: process.execPath, args: [fixture] });
  const bag = collect();
  adapter.start(opts({ resume: true, sessionId: 'missing' }), bag.sink);
  await until(bag.out, (o) => o.kind === 'event');
  const err = bag.out.find((o) => o.kind === 'event');
  assert.match(err && err.kind === 'event' && err.event.type === 'error' ? err.event.message : '', /not found/);
});

test('grok-main is discovered from its config directory', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'tb-grok-'));
  const grokMain = path.join(root, '.grok');
  fs.mkdirSync(grokMain);
  const found = discoverAccounts({
    claudeMainDir: path.join(root, 'no-claude'),
    claudeMainJson: path.join(root, 'no.json'),
    tokenStatsAccountsDir: path.join(root, 'no-stats'),
    grokMainDir: grokMain,
  });
  assert.deepEqual(found.map((a) => [a.id, a.provider, a.title]), [['grok-main', 'grok', 'Grok']]);
});
