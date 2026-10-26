import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { ClaudeNormalizer, type NormalizerContext } from '../../src/adapters/claude/normalize.ts';
import type { AdapterOutput } from '../../src/adapters/types.ts';
import { saveBase64Image } from '../../src/media.ts';
import { checkEvent } from '../helpers/protocol-check.ts';
import { tmpDir } from '../helpers/fakes.ts';

const FIX = path.join(import.meta.dirname, '..', 'fixtures');

function load(name: string): Record<string, unknown>[] {
  return fs
    .readFileSync(path.join(FIX, name), 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

function ctx(files: Record<string, string> = {}): NormalizerContext & { blobs: Record<string, string>; copied: Record<string, string>; media: string } {
  const media = tmpDir('tb-media-');
  const blobs: Record<string, string> = {};
  const copied: Record<string, string> = {};
  return {
    cwd: '/work/proj',
    media,
    blobs,
    copied,
    readFile: (p) => files[p] ?? null,
    saveImage: (data, mediaType, hint) => saveBase64Image(media, data, mediaType, hint),
    saveBlob: (itemId, text) => {
      blobs[itemId] = text;
      return `/blobs/${itemId}.txt`;
    },
    copyBlob: (itemId, src) => {
      copied[itemId] = src;
      return `/blobs/${itemId}.txt`;
    },
  };
}

// Recordings start with the runner's message, so the normaliser is told
// one was sent, as the adapter does.
function run(name: string, c = ctx()): AdapterOutput[] {
  const n = new ClaudeNormalizer(c);
  n.sent();
  return load(name).flatMap((m) => n.handle(m));
}

function events(outs: AdapterOutput[]) {
  return outs.filter((o): o is Extract<AdapterOutput, { kind: 'event' }> => o.kind === 'event').map((o) => o.event as any);
}

function deltas(outs: AdapterOutput[]) {
  return outs.filter((o): o is Extract<AdapterOutput, { kind: 'delta' }> => o.kind === 'delta').map((o) => o.delta);
}

// Every normalised event, given an envelope, must pass the protocol check.
function assertProtocol(outs: AdapterOutput[]) {
  for (const o of outs) {
    if (o.kind !== 'event' && o.kind !== 'delta') continue;
    const body = o.kind === 'event' ? o.event : o.delta;
    const e = { seq: 1, ts: '2026-10-26T00:00:00.000Z', threadId: 't', ...body };
    assert.deepEqual(checkEvent(e), [], `${body.type} breaks the protocol`);
  }
}

test('plain text reply: session, deltas, one assistant.text, result', () => {
  const outs = run('text.ndjson');
  assertProtocol(outs);
  const session = outs.find((o) => o.kind === 'session');
  assert.ok(session && session.kind === 'session' && session.nativeSessionId && session.model === 'claude-haiku-5-5');
  const texts = events(outs).filter((e) => e.type === 'assistant.text');
  assert.equal(texts.length, 1);
  const ds = deltas(outs);
  assert.ok(ds.length >= 2);
  assert.ok(ds.every((d) => d.type === 'assistant.text.delta' && d.itemId === texts[0].itemId));
  assert.equal(ds.map((d) => d.text).join(''), texts[0].text);
  // The persisted event comes after all of its deltas.
  const lastDelta = outs.findLastIndex((o) => o.kind === 'delta');
  const textIdx = outs.findIndex((o) => o.kind === 'event' && o.event.type === 'assistant.text');
  assert.ok(textIdx > lastDelta);
  const ctxOut = outs.find((o) => o.kind === 'context');
  assert.ok(ctxOut && ctxOut.kind === 'context' && ctxOut.contextTokens > 1000);
  const result = outs.at(-1)!;
  assert.equal(result.kind, 'result');
  assert.equal(result.kind === 'result' && result.result.outcome, 'completed');
  assert.ok(result.kind === 'result' && result.result.totalCostUsd! > 0);
});

test('read tool: tool.call with kind and relative title, then tool.result', () => {
  const outs = run('read-tool.ndjson');
  assertProtocol(outs);
  const evs = events(outs);
  const call = evs.find((e) => e.type === 'tool.call');
  assert.equal(call.name, 'Read');
  assert.equal(call.kind, 'read');
  assert.equal(call.title, 'Read note.txt');
  const result = evs.find((e) => e.type === 'tool.result');
  assert.equal(result.itemId, call.itemId);
  assert.equal(result.ok, true);
  assert.match(result.text, /beta/);
  assert.equal(result.truncated, false);
  assert.deepEqual(result.images, []);
  assert.deepEqual(
    evs.map((e) => e.type),
    ['tool.call', 'tool.result', 'assistant.text'],
  );
});

test('image in a tool result is saved to media with its size', () => {
  const c = ctx();
  const outs = run('image-result.ndjson', c);
  assertProtocol(outs);
  const result = events(outs).find((e) => e.type === 'tool.result');
  assert.equal(result.images.length, 1);
  const img = result.images[0];
  assert.equal(img.mediaType, 'image/png');
  assert.equal(img.width, 64);
  assert.equal(img.height, 48);
  assert.ok(img.path.startsWith(c.media));
  assert.ok(fs.existsSync(img.path));
});

test('AskUserQuestion turn: reasoning, tool call, result and answer text', () => {
  const outs = run('ask-question.ndjson');
  assertProtocol(outs);
  const evs = events(outs);
  assert.deepEqual(
    evs.map((e) => e.type),
    ['reasoning', 'tool.call', 'tool.result', 'assistant.text'],
  );
  const reasoning = evs[0];
  const rDeltas = deltas(outs).filter((d) => d.type === 'reasoning.delta');
  assert.ok(rDeltas.length > 0);
  assert.equal(rDeltas.map((d) => d.text).join(''), reasoning.text);
  assert.ok(rDeltas.every((d) => d.itemId === reasoning.itemId));
  assert.equal(evs[1].name, 'AskUserQuestion');
  assert.equal(evs[1].title, 'Ask a question');
  assert.equal(evs[3].text, 'Tea.');
});

test('Edit and Write in ask mode: edit.diff from the CLI patch, new file as all additions', () => {
  const outs = run('edit-ask-mode.ndjson');
  assertProtocol(outs);
  const evs = events(outs);
  assert.deepEqual(
    evs.map((e) => e.type),
    ['reasoning', 'tool.call', 'edit.diff', 'tool.result', 'tool.call', 'edit.diff', 'tool.result', 'assistant.text'],
  );
  const [editCall, editDiff, , writeCall, writeDiff] = evs.slice(1);
  assert.equal(editCall.kind, 'edit');
  assert.equal(editCall.title, 'Edit note.txt');
  assert.equal(editDiff.itemId, editCall.itemId);
  assert.equal(editDiff.path, '/work/proj/note.txt');
  assert.deepEqual(editDiff.hunks, [{ oldStart: 1, oldLines: 3, newStart: 1, newLines: 3, lines: [' alpha', '-beta', '+BETA', ' gamma'] }]);
  assert.equal(writeCall.kind, 'write');
  assert.equal(writeCall.title, 'Write new.txt');
  assert.deepEqual(writeDiff.hunks, [{ oldStart: 0, oldLines: 0, newStart: 1, newLines: 1, lines: ['+hi'] }]);
});

test('diff shown at approval time is not repeated when the result lands', () => {
  const c = ctx({ '/work/proj/note.txt': 'alpha\nbeta\ngamma\n' });
  const n = new ClaudeNormalizer(c);
  const msgs = load('edit-ask-mode.ndjson');
  const outs: AdapterOutput[] = [];
  for (const m of msgs) {
    outs.push(...n.handle(m));
    const call = outs.at(-1);
    if (call?.kind === 'event' && call.event.type === 'tool.call' && call.event.name === 'Edit') {
      outs.push(...n.beforeApproval(call.event.itemId, 'Edit', call.event.input));
    }
  }
  const diffs = events(outs).filter((e) => e.type === 'edit.diff');
  assert.equal(diffs.length, 2); // one Edit, one Write
  assert.deepEqual(diffs[0].hunks[0].lines, [' alpha', '-beta', '+BETA', ' gamma']);
});

test('interrupt mid-stream keeps the partial text and reports interrupted', () => {
  const outs = run('interrupt.ndjson');
  assertProtocol(outs);
  const texts = events(outs).filter((e) => e.type === 'assistant.text');
  assert.equal(texts.length, 1);
  assert.match(texts[0].text, /^one\ntwo\nthree/);
  const result = outs.at(-1)!;
  assert.equal(result.kind === 'result' && result.result.outcome, 'interrupted');
  assert.equal(result.kind === 'result' && result.result.error, undefined);
});

test('text that streamed without a complete frame is kept at the result', () => {
  const n = new ClaudeNormalizer(ctx());
  const outs = [
    { type: 'stream_event', event: { type: 'message_start', message: { id: 'm1' } }, parent_tool_use_id: null },
    { type: 'stream_event', event: { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }, parent_tool_use_id: null },
    { type: 'stream_event', event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'half a ' } }, parent_tool_use_id: null },
    { type: 'stream_event', event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'sentence' } }, parent_tool_use_id: null },
    { type: 'result', subtype: 'error_during_execution', is_error: true, terminal_reason: 'aborted_streaming', duration_ms: 5, errors: ['[ede_diagnostic] x'] },
  ].flatMap((m) => n.handle(m));
  const evs = events(outs);
  assert.deepEqual(evs, [{ type: 'assistant.text', itemId: 'm1:0', text: 'half a sentence' }]);
});

test('tool output over 64 KB is truncated and saved as a blob', () => {
  const c = ctx();
  const n = new ClaudeNormalizer(c);
  const big = 'x'.repeat(70 * 1024);
  n.handle({ type: 'assistant', message: { id: 'm1', content: [{ type: 'tool_use', id: 'tu1', name: 'Bash', input: { command: 'cat big\nsecond line' } }] }, parent_tool_use_id: null });
  const outs = n.handle({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'tu1', content: big }] }, parent_tool_use_id: null });
  const r = events(outs)[0];
  assert.equal(r.truncated, true);
  assert.equal(Buffer.byteLength(r.text), 64 * 1024);
  assert.equal(r.blobPath, '/blobs/tu1.txt');
  assert.equal(c.blobs.tu1, big);
});

test('tool titles and kinds for common tools', () => {
  const n = new ClaudeNormalizer(ctx());
  const call = (name: string, input: Record<string, unknown>) =>
    events(n.handle({ type: 'assistant', message: { id: `m-${name}`, content: [{ type: 'tool_use', id: `id-${name}`, name, input }] }, parent_tool_use_id: null }))[0];
  assert.deepEqual([call('Bash', { command: 'npm test\nnpm run lint' }).title, call('Bash', { command: 'x' }).kind], ['npm test', 'command']);
  assert.equal(call('Grep', { pattern: 'TODO', path: '/work/proj/src' }).title, 'Search for TODO in src');
  assert.equal(call('Glob', { pattern: '**/*.ts' }).title, 'Find **/*.ts');
  assert.equal(call('WebFetch', { url: 'https://example.com' }).kind, 'web');
  const mcp = call('mcp__paper__get_page', {});
  assert.equal(mcp.kind, 'mcp');
  assert.equal(mcp.title, 'paper: get_page');
  assert.equal(call('Agent', { description: 'Find the bug', prompt: 'p' }).kind, 'task');
  const big = call('Write', { file_path: '/work/proj/a.txt', content: 'y'.repeat(20_000) });
  assert.ok(String(big.input.content).length < 17_000);
});

test('TodoWrite and Task tools become plan.updated', () => {
  const n = new ClaudeNormalizer(ctx());
  let outs = n.handle({
    type: 'assistant',
    message: { id: 'm1', content: [{ type: 'tool_use', id: 'td', name: 'TodoWrite', input: { todos: [{ content: 'Read code', status: 'completed', activeForm: 'Reading' }, { content: 'Fix bug', status: 'in_progress', activeForm: 'Fixing' }] } }] },
    parent_tool_use_id: null,
  });
  assert.deepEqual(events(outs)[1], { type: 'plan.updated', entries: [{ text: 'Read code', status: 'completed' }, { text: 'Fix bug', status: 'in_progress' }] });

  n.handle({ type: 'assistant', message: { id: 'm2', content: [{ type: 'tool_use', id: 'tc', name: 'TaskCreate', input: { subject: 'Write tests', description: 'd' } }] }, parent_tool_use_id: null });
  outs = n.handle({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'tc', content: 'Task #1 created' }] }, tool_use_result: { task: { id: '1', subject: 'Write tests' } }, parent_tool_use_id: null });
  assert.deepEqual(events(outs).at(-1), { type: 'plan.updated', entries: [{ text: 'Write tests', status: 'pending' }] });
  n.handle({ type: 'assistant', message: { id: 'm3', content: [{ type: 'tool_use', id: 'tu', name: 'TaskUpdate', input: { taskId: '1', status: 'completed' } }] }, parent_tool_use_id: null });
  outs = n.handle({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'tu', content: 'ok' }] }, tool_use_result: { success: true, taskId: '1' }, parent_tool_use_id: null });
  assert.deepEqual(events(outs).at(-1), { type: 'plan.updated', entries: [{ text: 'Write tests', status: 'completed' }] });
});

test('subagent traffic and replays are ignored', () => {
  const n = new ClaudeNormalizer(ctx());
  assert.deepEqual(n.handle({ type: 'assistant', message: { id: 'm', content: [{ type: 'text', text: 'inner' }] }, parent_tool_use_id: 'toolu_x' }), []);
  assert.deepEqual(n.handle({ type: 'user', isReplay: true, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'a', content: 'x' }] }, parent_tool_use_id: null }), []);
});

test('failed results carry the error text', () => {
  const n = new ClaudeNormalizer(ctx());
  const [r] = n.handle({ type: 'result', subtype: 'success', is_error: true, result: 'API Error: overloaded', duration_ms: 3, total_cost_usd: 0 });
  assert.equal(r.kind === 'result' && r.result.outcome, 'failed');
  assert.equal(r.kind === 'result' && r.result.error, 'API Error: overloaded');
});

test('compaction becomes a system note', () => {
  const n = new ClaudeNormalizer(ctx());
  assert.deepEqual(events(n.handle({ type: 'system', subtype: 'compact_boundary', compact_metadata: { trigger: 'auto', pre_tokens: 1 } })), [
    { type: 'system.note', text: 'Compacted the conversation' },
  ]);
});

// ---------------------------------------------------------------- review fixes

const sys = (subtype: string, extra: Record<string, unknown> = {}) => ({ type: 'system', subtype, session_id: 's1', ...extra });
const life = (state: string, uuid: string) => ({ type: 'command_lifecycle', command_uuid: uuid, state });
const result = (extra: Record<string, unknown> = {}) => ({ type: 'result', subtype: 'success', is_error: false, duration_ms: 5, total_cost_usd: 0.01, ...extra });

test('turns the CLI starts itself are reported, with the finished task as a note', () => {
  const n = new ClaudeNormalizer(ctx());
  n.sent();
  const turn1 = [life('queued', 'u1'), life('started', 'u1'), sys('init'), result(), life('completed', 'u1')].flatMap((m) => n.handle(m));
  assert.ok(!turn1.some((o) => o.kind === 'cliTurn'));
  const r1 = turn1.find((o) => o.kind === 'result');
  assert.deepEqual(r1?.kind === 'result' && [r1.result.own, r1.result.answers], [undefined, 'u1']);
  // A background shell finishes while nothing is running.
  const own = [
    sys('task_notification', { status: 'completed', task_id: 'b1', summary: 'Background command "sleep 5" completed (exit code 0)' }),
    sys('background_tasks_changed', { tasks: [] }),
    sys('init'),
    { type: 'assistant', message: { id: 'm2', content: [{ type: 'text', text: 'It finished.' }] }, parent_tool_use_id: null },
    result(),
  ].flatMap((m) => n.handle(m));
  assert.deepEqual(own.find((o) => o.kind === 'cliTurn'), { kind: 'cliTurn', note: 'Background command "sleep 5" completed (exit code 0)' });
  assert.deepEqual(own.find((o) => o.kind === 'tasks'), { kind: 'tasks', tasks: [] });
  const r2 = own.find((o) => o.kind === 'result');
  assert.equal(r2?.kind === 'result' && r2.result.own, true);
  // The cliTurn comes before the turn's output.
  assert.ok(own.findIndex((o) => o.kind === 'cliTurn') < own.findIndex((o) => o.kind === 'event'));
});

test('a message queued behind a CLI turn: the CLI turn is its own, the next answers it', () => {
  const n = new ClaudeNormalizer(ctx());
  n.sent();
  [life('queued', 'u1'), life('started', 'u1'), sys('init'), result(), life('completed', 'u1')].forEach((m) => n.handle(m));
  n.sent();
  const outs = [
    sys('task_notification', { status: 'completed', summary: 'done' }),
    life('queued', 'u2'),
    sys('init'),
    result(),
    life('started', 'u2'),
    sys('init'),
    result(),
  ].flatMap((m) => n.handle(m));
  const results = outs.filter((o) => o.kind === 'result').map((o) => (o.kind === 'result' ? [o.result.own, o.result.answers] : null));
  assert.deepEqual(results, [[true, undefined], [undefined, 'u2']]);
});

test('without lifecycle frames, turns are matched by counting messages sent', () => {
  const n = new ClaudeNormalizer(ctx());
  n.sent();
  const first = [sys('init'), result()].flatMap((m) => n.handle(m));
  assert.ok(!first.some((o) => o.kind === 'cliTurn'));
  const second = [sys('init'), result()].flatMap((m) => n.handle(m));
  assert.ok(second.some((o) => o.kind === 'cliTurn'), 'nothing was sent, so this one is the CLI\'s own');
});

test('background tasks: ambient ones are left out', () => {
  const n = new ClaudeNormalizer(ctx());
  const outs = n.handle(sys('background_tasks_changed', { tasks: [
    { task_id: 'b1', task_type: 'local_bash', description: 'npm run dev' },
    { task_id: 'w1', task_type: 'watcher', description: 'watch', ambient: true },
  ] }));
  assert.deepEqual(outs, [{ kind: 'tasks', tasks: [{ id: 'b1', type: 'local_bash', description: 'npm run dev' }] }]);
});

test('edit.diff drops the "No newline at end of file" markers', () => {
  const n = new ClaudeNormalizer(ctx());
  n.handle({ type: 'assistant', message: { id: 'm1', content: [{ type: 'tool_use', id: 'e1', name: 'Edit', input: { file_path: '/work/proj/a.txt', old_string: 'beta', new_string: 'gamma' } }] }, parent_tool_use_id: null });
  const outs = n.handle({
    type: 'user',
    message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'e1', content: 'ok' }] },
    tool_use_result: { filePath: '/work/proj/a.txt', structuredPatch: [{ oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, lines: [' alpha', '-beta', '\\ No newline at end of file', '+gamma', '\\ No newline at end of file'] }] },
    parent_tool_use_id: null,
  });
  assertProtocol(outs);
  const diff = events(outs).find((e) => e.type === 'edit.diff');
  assert.deepEqual(diff.hunks[0].lines, [' alpha', '-beta', '+gamma']);
});

test('after /compact, earlier local command output the CLI re-sends is not shown again', () => {
  const n = new ClaudeNormalizer(ctx());
  const cost = { type: 'assistant', message: { id: 'aa-1', content: [{ type: 'text', text: 'You are using your subscription' }] }, local_command_source: '<local-command-stdout>You are using your subscription</local-command-stdout>', parent_tool_use_id: null };
  const first = [cost, result({ result: '' })].flatMap((m) => n.handle(m));
  assert.equal(events(first).filter((e) => e.type === 'assistant.text').length, 1);
  const compact = [
    sys('compact_boundary', { compact_metadata: { trigger: 'manual' } }),
    { ...cost, message: { ...cost.message, id: 'bb-2' } },
    result({ result: '' }),
  ].flatMap((m) => n.handle(m));
  assert.deepEqual(events(compact).map((e) => e.type), ['system.note']);
  // A later /cost shows as usual.
  const again = [cost, result({ result: '' })].flatMap((m) => n.handle(m));
  assert.equal(events(again).filter((e) => e.type === 'assistant.text').length, 1);
});

test('tool output cut at 64 KB never splits a character', () => {
  const c = ctx();
  const n = new ClaudeNormalizer(c);
  n.handle({ type: 'assistant', message: { id: 'm1', content: [{ type: 'tool_use', id: 'tu1', name: 'Bash', input: { command: 'euros' } }] }, parent_tool_use_id: null });
  const outs = n.handle({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'tu1', content: '€'.repeat(30000) }] }, parent_tool_use_id: null });
  assertProtocol(outs);
  const r = events(outs)[0];
  assert.ok(Buffer.byteLength(r.text) <= 64 * 1024);
  assert.ok(!r.text.includes('�'));
  assert.equal(r.text, '€'.repeat(Math.floor((64 * 1024) / 3)));
  assert.equal(r.truncated, true);
});

test('output the CLI saved to a file is copied into the thread and pointed at', () => {
  const c = ctx();
  const n = new ClaudeNormalizer(c);
  n.handle({ type: 'assistant', message: { id: 'm1', content: [{ type: 'tool_use', id: 'tu1', name: 'Bash', input: { command: 'seq 1 60000' } }] }, parent_tool_use_id: null });
  const preview = '<persisted-output>\nOutput too large (340.7KB). Full output saved to: /acct/projects/x/tool-results/b1.txt\n\nPreview (first 2KB):\n1\n2\n';
  let outs = n.handle({
    type: 'user',
    message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'tu1', content: preview }] },
    tool_use_result: { stdout: '1\n2\n', persistedOutputPath: '/acct/projects/x/tool-results/b1.txt', persistedOutputSize: 348894 },
    parent_tool_use_id: null,
  });
  let r = events(outs)[0];
  assert.deepEqual([r.text, r.truncated, r.blobPath], [preview, true, '/blobs/tu1.txt']);
  assert.equal(c.copied.tu1, '/acct/projects/x/tool-results/b1.txt');
  // Without the structured field, the path in the preview is used.
  n.handle({ type: 'assistant', message: { id: 'm2', content: [{ type: 'tool_use', id: 'tu2', name: 'Bash', input: { command: 'cat big' } }] }, parent_tool_use_id: null });
  outs = n.handle({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'tu2', content: preview }] }, parent_tool_use_id: null });
  r = events(outs)[0];
  assert.equal(r.blobPath, '/blobs/tu2.txt');
  assert.equal(c.copied.tu2, '/acct/projects/x/tool-results/b1.txt');
});
