// Grok adapter: a fake `grok agent stdio` process, plus account discovery.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';
import { discoverAccounts } from '../../src/accounts.ts';
import { GrokAdapter } from '../../src/adapters/grok/adapter.ts';
import { toolSchemas, type GrokTool } from '../../src/adapters/grok/tools.ts';
import type { AdapterOutput, SessionSink, StartSessionOptions, ToolApprovalAnswer } from '../../src/adapters/types.ts';
import { buildThreadbearTools } from '../../src/threadbear-mcp.ts';

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

function until(out: AdapterOutput[], pred: (o: AdapterOutput) => boolean, ms = 5000): Promise<void> {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`timed out; saw ${out.map((o) => o.kind).join(',')}`)), ms);
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
  const version = bag.out.find((o) => o.kind === 'cliVersion');
  assert.equal(version && version.kind === 'cliVersion' ? version.version : '', 'test');
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
  const session = adapter.start(opts({ resume: true, sessionId: 'missing' }), bag.sink);
  await until(bag.out, (o) => o.kind === 'event');
  const err = bag.out.find((o) => o.kind === 'event');
  assert.match(err && err.kind === 'event' && err.event.type === 'error' ? err.event.message : '', /not found/);
  session.kill();
});

function calls(out: AdapterOutput[]) {
  return out.filter((o) => o.kind === 'event' && o.event.type === 'tool.call');
}

test('end_turn is recorded once, under the name the runner watches, before the handler runs', async () => {
  const bag = collect();
  let sawCall = false;
  const tools: GrokTool[] = [{
    name: 'end_turn',
    description: 'End the turn',
    inputSchema: { needs: z.string().optional() },
    handler: async () => {
      sawCall = bag.out.some((o) => o.kind === 'event' && o.event.type === 'tool.call' && o.event.name === 'mcp__threadbear__end_turn');
      return { content: [{ type: 'text', text: 'ended nothing' }] };
    },
  }];
  const adapter = new GrokAdapter({
    grokPath: 'grok',
    command: process.execPath,
    args: [fixture],
    toolsFor: () => tools,
    instructionsFor: () => 'End every turn by calling end_turn.',
  });
  const session = adapter.start(opts(), bag.sink);
  session.send({ id: 'turn-end', text: 'END the turn', images: [] });
  await until(bag.out, (o) => o.kind === 'result', 8000);
  assert.equal(sawCall, true);
  const toolCalls = calls(bag.out);
  assert.equal(toolCalls.length, 1);
  const call = toolCalls[0];
  assert.equal(call && call.kind === 'event' && call.event.type === 'tool.call' ? call.event.name : '', 'mcp__threadbear__end_turn');
  assert.equal(call && call.kind === 'event' && call.event.type === 'tool.call' ? call.event.input.needs : '', 'nothing');
  const result = bag.out.find((o) => o.kind === 'event' && o.event.type === 'tool.result');
  assert.equal(result && result.kind === 'event' && result.event.type === 'tool.result' ? result.event.ok : false, true);
  assert.equal(result && result.kind === 'event' && result.event.type === 'tool.result' ? result.event.text : '', 'ended nothing');
  session.kill();
});

test('a threadbear tool that always asks is refused before its handler runs', async () => {
  let ran = false;
  const tools: GrokTool[] = [{
    name: 'delete_thread',
    description: 'Delete a thread',
    inputSchema: { threadId: z.string() },
    handler: async () => {
      ran = true;
      return { content: [{ type: 'text', text: 'deleted' }] };
    },
  }];
  const adapter = new GrokAdapter({
    grokPath: 'grok',
    command: process.execPath,
    args: [fixture],
    toolsFor: () => tools,
    instructionsFor: () => 'Tools for this thread.',
  });
  const bag = collect();
  const session = adapter.start(opts(), bag.sink);
  session.send({ id: 'turn-del', text: 'DELETE it', images: [] });
  await bag.askedFor;
  bag.answer({ decision: 'deny' });
  await until(bag.out, (o) => o.kind === 'result', 8000);
  assert.equal(ran, false);
  assert.equal(calls(bag.out).length, 0);
  const result = bag.out.find((o) => o.kind === 'result');
  assert.equal(result && result.kind === 'result' ? result.result.outcome : '', 'completed');
  session.kill();
});

test('the real threadbear tools publish an end_turn schema', () => {
  const tools = buildThreadbearTools({} as never, 'thread-1') as GrokTool[];
  const end = toolSchemas(tools).find((t) => t.name === 'end_turn');
  assert.ok(end);
  assert.match(end.description, /end_turn|Ends the turn/);
  const schema = end.inputSchema as { properties?: Record<string, unknown> };
  assert.ok(schema.properties?.needs);
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
