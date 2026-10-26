import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ClaudeAdapter, alwaysAllow } from '../../src/adapters/claude/adapter.ts';
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
  const state: { options?: any; sent: any[]; close?: () => void } = { sent: [] };
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
      close: () => stop(),
    };
  }) as any;
  return { fn, state };
}

function start(allowRules: string[] = []) {
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
    },
    sink,
  );
  return { session, state, outputs, approvals };
}

test('thread rules go to the CLI as allowedTools; messages carry the turn id', async () => {
  const { session, state } = start(['Bash(npm test)']);
  assert.deepEqual(state.options.allowedTools, ['Bash(npm test)']);
  session.send({ id: 'turn-1', text: 'hi', images: [] });
  await new Promise((r) => setImmediate(r));
  assert.equal(state.sent[0].uuid, 'turn-1');
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
