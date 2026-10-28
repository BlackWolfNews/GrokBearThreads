import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ClaudeAdapter, alwaysAllow, modelChoices, terminalMcpTools } from '../../src/adapters/claude/adapter.ts';
import type { SessionSink, AdapterOutput, ToolApprovalRequest } from '../../src/adapters/types.ts';
import { ProcessRegistry } from '../../src/proc.ts';
import { nullLogger } from '../../src/log.ts';
import { tmpDir } from '../helpers/fakes.ts';

test('"Always allow" keeps only allow rules, scoped to the session', () => {
  const { updates, rules } = alwaysAllow('Bash', [
    { type: 'setMode', mode: 'acceptEdits', destination: 'session' },
    { type: 'addRules', rules: [{ toolName: 'Bash', ruleContent: 'touch second.txt' }], behavior: 'allow', destination: 'localSettings' },
    { type: 'addDirectories', directories: ['/tmp/x'], destination: 'projectSettings' },
  ]);
  assert.deepEqual(rules, ['Bash(touch second.txt)']);
  assert.deepEqual(updates, [
    { type: 'addRules', rules: [{ toolName: 'Bash', ruleContent: 'touch second.txt' }], behavior: 'allow', destination: 'session' },
    { type: 'addDirectories', directories: ['/tmp/x'], destination: 'session' },
  ]);
  // Only a mode switch on offer: allow this tool for the thread instead.
  const edit = alwaysAllow('Edit', [{ type: 'setMode', mode: 'acceptEdits', destination: 'session' }]);
  assert.deepEqual(edit.rules, ['Edit']);
  assert.deepEqual(edit.updates, [{ type: 'addRules', rules: [{ toolName: 'Edit' }], behavior: 'allow', destination: 'session' }]);
});

// A stand-in for the SDK's query(): records the options and the messages
// sent, and lets the test call canUseTool.
function fakeQuery() {
  const state: { options?: any; sent: any[]; flags: unknown[]; models?: any[]; close?: () => void } = { sent: [], flags: [] };
  const fn = ((args: { prompt: AsyncIterable<any>; options: any }) => {
    state.options = args.options;
    let stop!: () => void;
    const stopped = new Promise<void>((r) => (stop = r));
    state.close = stop;
    void (async () => {
      for await (const m of args.prompt) state.sent.push(m);
    })();
    return {
      async *[Symbol.asyncIterator]() {
        await stopped;
      },
      interrupt: async () => undefined,
      setModel: async () => undefined,
      setPermissionMode: async () => undefined,
      applyFlagSettings: async (s: unknown) => {
        state.flags.push(s);
      },
      initializationResult: async () => ({ models: state.models ?? [] }),
      close: () => stop(),
    };
  }) as any;
  return { fn, state };
}

function start(allowRules: string[] = [], extra: Record<string, unknown> = {}) {
  const { fn, state } = fakeQuery();
  const outputs: AdapterOutput[] = [];
  const approvals: ToolApprovalRequest[] = [];
  const sink: SessionSink = {
    output: (o) => outputs.push(o),
    requestApproval: async (req) => {
      approvals.push(req);
      return { decision: 'allowAlways' };
    },
    requestQuestion: async () => ({ answers: null }),
    exited: () => {},
  };
  const adapter = new ClaudeAdapter({ claudePath: '/nonexistent', registry: new ProcessRegistry(tmpDir(), nullLogger), log: nullLogger, queryFn: fn });
  const dir = tmpDir();
  const session = adapter.start(
    {
      threadId: 't1',
      cwd: dir,
      account: { id: 'claude-3', provider: 'claude', title: 'x', configDir: dir },
      permissionMode: 'ask',
      sessionId: '00000000-0000-0000-0000-000000000001',
      resume: false,
      mediaDir: dir,
      blobsDir: dir,
      tmpDir: dir,
      allowRules,
      ...extra,
    },
    sink,
  );
  return { session, state, outputs, approvals, adapter };
}

test('effort: sent at start, changed through flag settings, and read back from the Stop hook', async () => {
  const { session, state, outputs } = start([], { effort: 'low' });
  assert.equal(state.options.effort, 'low');
  await session.setEffort('max');
  await session.setEffort(undefined);
  assert.deepEqual(state.flags, [{ effortLevel: 'max' }, { effortLevel: null }]);
  const stop = state.options.hooks.Stop[0].hooks[0];
  await stop({ hook_event_name: 'Stop', effort: { level: 'high' } });
  await stop({ hook_event_name: 'Stop' });
  await stop({ hook_event_name: 'Stop', effort: { level: 'silly' } });
  assert.deepEqual(outputs.filter((o) => o.kind === 'effort'), [{ kind: 'effort', level: 'high' }]);
  state.close!();
});

test("models() asks a promptless CLI for its picker; the 'default' row is left out", async () => {
  const { fn, state } = fakeQuery();
  state.models = [
    { value: 'default', resolvedModel: 'claude-opus-5-5', displayName: 'Default (recommended)', description: 'Opus 5.5 · Best' },
    { value: 'opus', resolvedModel: 'claude-opus-5-5', displayName: 'Opus 5.5', description: 'For complex work', supportsEffort: true, supportedEffortLevels: ['low', 'medium', 'high', 'xhigh', 'max'] },
    { value: 'claude-fable-5-1[1m]', resolvedModel: 'claude-fable-5-1', displayName: 'Fable 5.1', supportsEffort: true, supportedEffortLevels: ['low', 'nope'] },
    { value: 'claude-haiku-4-5-20251001', displayName: 'Haiku 4.5', description: 'Fastest' },
  ];
  const dir = tmpDir();
  const adapter = new ClaudeAdapter({ claudePath: '/nonexistent', registry: new ProcessRegistry(dir, nullLogger), log: nullLogger, queryFn: fn });
  const models = await adapter.models({ id: 'claude-3', provider: 'claude', title: 'x', configDir: dir });
  assert.deepEqual(models, [
    { id: 'opus', model: 'claude-opus-5-5', title: 'Opus 5.5', description: 'For complex work', effortLevels: ['low', 'medium', 'high', 'xhigh', 'max'] },
    { id: 'claude-fable-5-1[1m]', model: 'claude-fable-5-1', title: 'Fable 5.1', effortLevels: ['low'] },
    { id: 'claude-haiku-4-5-20251001', model: 'claude-haiku-4-5-20251001', title: 'Haiku 4.5', description: 'Fastest' },
  ]);
  assert.deepEqual(state.options.tools, []);
  assert.equal(state.options.env.CLAUDE_CONFIG_DIR, dir);
  assert.deepEqual(modelChoices([{ value: '', displayName: '' } as never]), []);
});

test('thread rules go to the CLI as allowedTools; messages carry the turn id', async () => {
  const { session, state } = start(['Bash(npm test)']);
  assert.deepEqual(state.options.allowedTools, ['Bash(npm test)']);
  session.send({ id: 'turn-1', text: 'hi', images: [] });
  await new Promise((r) => setImmediate(r));
  assert.equal(state.sent[0].uuid, 'turn-1');
  state.close!();
});

// Without this the CLI nudged the model after every end_turn ("[Your
// previous response had no visible output...]") and a throwaway line
// landed under the real answer (28 Oct 2026).
test('end_turn is a terminal MCP tool for the CLI, so its result ends the turn without a nudge', () => {
  const { state } = start();
  assert.equal(state.options.env.CLAUDE_CODE_TERMINAL_MCP_TOOLS, 'mcp__threadbear__end_turn');
  assert.equal(terminalMcpTools(undefined), 'mcp__threadbear__end_turn');
  assert.equal(terminalMcpTools(' mcp__other__finish , '), 'mcp__other__finish,mcp__threadbear__end_turn');
  assert.equal(terminalMcpTools('mcp__threadbear__end_turn'), 'mcp__threadbear__end_turn');
  state.close!();
});

test("a subagent's approval is asked at once, with no itemId and no diff", async () => {
  const { state, outputs, approvals } = start();
  const t0 = Date.now();
  const res = await state.options.canUseTool('Write', { file_path: '/tmp/x.txt', content: 'hi' }, {
    signal: new AbortController().signal,
    toolUseID: 'toolu_sub',
    agentID: 'agent-1',
    suggestions: [{ type: 'setMode', mode: 'acceptEdits', destination: 'session' }],
  });
  assert.ok(Date.now() - t0 < 1000, 'no wait for a tool.call that never comes');
  assert.equal(approvals[0].toolUseId, undefined);
  assert.ok(!outputs.some((o) => o.kind === 'event' && o.event.type === 'edit.diff'));
  assert.equal(res.behavior, 'allow');
  assert.deepEqual(res.updatedPermissions, [{ type: 'addRules', rules: [{ toolName: 'Write' }], behavior: 'allow', destination: 'session' }]);
  assert.deepEqual(outputs.find((o) => o.kind === 'allowRules'), { kind: 'allowRules', rules: ['Write'] });
  state.close!();
});
