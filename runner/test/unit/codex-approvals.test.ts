import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  CodexApprovals,
  FILE_CHANGE_RULE,
  commandAllowed,
  commandRule,
  plainArgv,
  refusal,
  prefixRule,
  ruleFor,
  shellWords,
  unwrapShell,
  type ApprovalsDeps,
} from '../../src/adapters/codex/approvals.ts';
import { dynamicToolSpecs, NAMESPACE_DESCRIPTION_MAX, type ToolDefinition } from '../../src/adapters/codex/tools.ts';
import { buildThreadbearTools } from '../../src/threadbear-mcp.ts';
import { nullLogger } from '../../src/log.ts';
import type { QuestionAnswer, QuestionRequest, ToolApprovalAnswer, ToolApprovalRequest } from '../../src/adapters/types.ts';
import type { CommandExecutionRequestApprovalParams } from '../../src/adapters/codex/types.ts';

// ---- Parsing commands

test('the zsh wrapper is stripped and plain commands split into words', () => {
  assert.equal(unwrapShell("/bin/zsh -lc 'touch b.txt'"), 'touch b.txt');
  assert.equal(unwrapShell(`/bin/bash -c "echo 'hi there'"`), "echo 'hi there'");
  assert.equal(unwrapShell('ls -la'), 'ls -la');
  assert.deepEqual(shellWords('touch b.txt'), ['touch', 'b.txt']);
  assert.deepEqual(shellWords(`git commit -m 'a; b | c > d'`), ['git', 'commit', '-m', 'a; b | c > d']);
  assert.deepEqual(shellWords(`echo "a b" c\\ d ''`), ['echo', 'a b', 'c d', '']);
});

test('anything zsh would expand, glob or run is not plain', () => {
  for (const cmd of [
    'cat =(id)',
    'diff <(ls) b',
    'tee >(sh) x',
    'ls *(e:\'rm -rf ~\':)',
    'ls *.txt',
    'ls file?',
    'ls [ab]',
    'echo $HOME',
    'echo ${HOME}',
    'echo "${HOME}"',
    'echo "$HOME"',
    'ls ~root',
    'cat ~/x',
    'echo !!',
    'echo "!!"',
    'echo {a,b}',
    '(ls)',
    'ls #x',
    'ls ^x',
    '=ls',
    'kill %1',
    'echo \\$HOME',
    'echo "a\\$b"',
    'echo a\u0007b',
  ]) {
    assert.equal(shellWords(cmd), null, cmd);
  }
  // Still plain: literal words, quoted specials, = and % inside a word.
  assert.deepEqual(shellWords("echo '$HOME' '*' '~' '!!'"), ['echo', '$HOME', '*', '~', '!!']);
  assert.deepEqual(shellWords('git commit --message=done'), ['git', 'commit', '--message=done']);
  assert.deepEqual(shellWords('date +%Y-%m-%d'), ['date', '+%Y-%m-%d']);
  assert.deepEqual(shellWords('touch my\\ file.txt'), ['touch', 'my file.txt']);
  // Through the wrapper, as Codex sends them.
  assert.equal(plainArgv(req('cat =(id)')), null);
  assert.equal(commandAllowed(req('touch *(e:\'rm -rf ~\':)'), [prefixRule(['touch', 'x'])]), false);
});

test('chained, piped, redirected and substituted commands are not plain', () => {
  for (const cmd of [
    'touch b.txt; rm -rf ~',
    'cat a | sh',
    'echo hi > f',
    'sort < f',
    'make && make install',
    'sleep 5 &',
    'echo $(whoami)',
    'echo $x',
    'echo "$(rm -rf ~)"',
    'echo `id`',
    'echo "`id`"',
    'echo a\nrm b',
    "echo 'unclosed",
  ]) {
    assert.equal(shellWords(cmd), null, cmd);
  }
});

const req = (command: string, extra: Partial<CommandExecutionRequestApprovalParams> = {}): CommandExecutionRequestApprovalParams => ({
  kind: 'command',
  threadId: 't',
  turnId: 'u',
  itemId: 'exec-1',
  command: `/bin/zsh -lc '${command}'`,
  ...extra,
});

test('rules: exactly the command shown, or Codex\'s own amendment as a prefix of two words or more', () => {
  assert.equal(ruleFor(req('touch b.txt', { proposedExecpolicyAmendment: ['touch', 'b.txt'] })), commandRule(['touch', 'b.txt']));
  assert.equal(ruleFor(req('npm test --watch', { proposedExecpolicyAmendment: ['npm', 'test'] })), prefixRule(['npm', 'test']));
  assert.equal(ruleFor(req('rm -rf build', { proposedExecpolicyAmendment: ['rm'] })), commandRule(['rm', '-rf', 'build']), 'a one-word prefix is too wide');
  assert.equal(ruleFor(req('npm test', { proposedExecpolicyAmendment: ['rm', '-rf'] })), commandRule(['npm', 'test']));
  assert.equal(ruleFor(req('npm test')), commandRule(['npm', 'test']));
  // Nothing that runs other commands or code, and nothing that isn't plain.
  for (const cmd of ['bash x.sh', 'sudo ls', 'python3 x.py', 'node x.js', 'npx thing', 'uv run x', 'awk 1 f', 'find . -name x', 'make', 'xargs echo', 'env A=1 ls', 'timeout 5 ls', 'osascript x', 'perl x', 'bunx y', 'deno run x']) {
    assert.equal(ruleFor(req(cmd)), null, cmd);
  }
  assert.equal(ruleFor(req('touch a; touch b')), null);
});

test('an exact rule covers only that command; a prefix rule covers what starts with it', () => {
  const rules = [commandRule(['touch', 'b.txt']), prefixRule(['npm', 'test'])];
  assert.equal(commandAllowed(req('touch b.txt'), rules), true);
  assert.equal(commandAllowed(req('touch b.txt c.txt'), rules), false, 'more than the card showed');
  assert.equal(commandAllowed(req('npm test -- --grep x'), rules), true);
  assert.equal(commandAllowed(req('npm install'), rules), false);
  assert.equal(commandAllowed(req('npm'), rules), false);
  // A prefix rule for something that runs other commands is never honoured.
  assert.equal(commandAllowed(req('python3 -c print'), [prefixRule(['python3', '-c'])]), false);
  assert.equal(commandAllowed(req('touch b.txt; rm -rf ~'), rules), false);
  assert.equal(commandAllowed(req('touch b.txt | sh'), rules), false);
  assert.equal(commandAllowed(req('touch b.txt > /etc/x'), rules), false);
  // Rules never cover stdin to a running command or network access.
  assert.equal(commandAllowed(req('touch b.txt', { kind: 'writeStdin' }), rules), false);
  assert.equal(commandAllowed(req('touch b.txt', { networkApprovalContext: { host: 'example.com', protocol: 'https' } }), rules), false);
  assert.equal(commandAllowed(req('touch b.txt', { proposedNetworkPolicyAmendments: [{ host: 'x', action: 'allow' }] }), rules), false);
  assert.equal(plainArgv(req('touch b.txt', { kind: 'writeStdin' })), null);
  // A rule that isn't ours is ignored.
  assert.equal(commandAllowed(req('touch b.txt'), ['Bash(touch b.txt)', 'codex:command:not json']), false);
});

test('refusals: cancel for approvals, decline for elicitations, -32601 otherwise', () => {
  assert.deepEqual(refusal('item/commandExecution/requestApproval'), { result: { decision: 'cancel' } });
  assert.deepEqual(refusal('execCommandApproval'), { result: { decision: 'abort' } });
  assert.deepEqual(refusal('item/permissions/requestApproval'), { result: { permissions: {}, scope: 'turn' } });
  assert.deepEqual(refusal('mcpServer/elicitation/request'), { result: { action: 'decline', content: null, _meta: null } });
  assert.equal((refusal('item/tool/call') as { error: { code: number } }).error.code, -32601);
});

// ---- The handler

function harness(rules: string[] = []) {
  const replies: { id: unknown; result?: unknown; error?: { code: number; message: string } }[] = [];
  const asked: ToolApprovalRequest[] = [];
  const questions: QuestionRequest[] = [];
  const notes: string[] = [];
  const added: string[][] = [];
  const set = new Set(rules);
  let answer: (r: ToolApprovalRequest) => Promise<ToolApprovalAnswer> = async () => ({ decision: 'allow' });
  let questionAnswer: (q: QuestionRequest) => Promise<QuestionAnswer> = async () => ({ answers: null });
  const deps: ApprovalsDeps = {
    log: nullLogger,
    label: 't',
    reply: (id, result) => replies.push({ id, result }),
    replyError: (id, code, message) => replies.push({ id, error: { code, message } }),
    requestApproval: (r) => {
      asked.push(r);
      return answer(r);
    },
    requestQuestion: (q) => {
      questions.push(q);
      return questionAnswer(q);
    },
    rules: () => set,
    addRules: (r) => {
      added.push(r);
      r.forEach((x) => set.add(x));
    },
    note: (t) => notes.push(t),
    cwd: () => '/work/proj',
    itemPaths: (id) => (id === 'fc-3' ? ['/work/proj/a.ts', '/work/proj/b.ts', '/work/proj/c.ts'] : id === 'fc-1' ? ['/work/proj/a.txt'] : undefined),
    callTool: async () => ({ contentItems: [{ type: 'inputText', text: 'ok' }], success: true }),
    now: () => 1_793_000_000_000,
  };
  const a = new CodexApprovals(deps);
  return {
    a,
    replies,
    asked,
    questions,
    notes,
    added,
    rules: set,
    answerWith(fn: typeof answer) {
      answer = fn;
    },
    answerQuestionsWith(fn: typeof questionAnswer) {
      questionAnswer = fn;
    },
  };
}

const flush = () => new Promise((r) => setImmediate(r));

test('command approvals: allow, deny and expire map to accept, decline and cancel', async () => {
  const h = harness();
  h.a.handle(0, 'item/commandExecution/requestApproval', req('touch b.txt', { reason: 'Allow creating b.txt?', commandActions: [{ type: 'unknown', command: 'touch b.txt' }] }), { fromChild: false });
  await flush();
  assert.deepEqual(h.asked[0].input, { command: 'touch b.txt', cwd: '/work/proj', reason: 'Allow creating b.txt?' });
  assert.equal(h.asked[0].name, 'shell');
  assert.equal(h.asked[0].title, 'touch b.txt');
  assert.equal(h.asked[0].toolUseId, 'exec-1');
  assert.equal(h.asked[0].canAlwaysAllow, true);
  h.answerWith(async () => ({ decision: 'deny' }));
  h.a.handle(1, 'item/commandExecution/requestApproval', req('touch c.txt'), { fromChild: false });
  h.answerWith(async () => ({ decision: 'expired' }));
  h.a.handle(2, 'item/commandExecution/requestApproval', req('touch d.txt'), { fromChild: false });
  await flush();
  assert.deepEqual(
    h.replies.map((r) => r.result),
    [{ decision: 'accept' }, { decision: 'decline' }, { decision: 'cancel' }],
  );
});

test('"Always allow" keeps a runner rule, answers the next match itself, and asks again for anything chained', async () => {
  const h = harness();
  h.answerWith(async () => ({ decision: 'allowAlways' }));
  h.a.handle(0, 'item/commandExecution/requestApproval', req('touch b.txt', { proposedExecpolicyAmendment: ['touch', 'b.txt'], availableDecisions: ['accept', { acceptWithExecpolicyAmendment: { execpolicy_amendment: ['touch', 'b.txt'] } }, 'cancel'] }), { fromChild: false });
  await flush();
  assert.deepEqual(h.added, [[commandRule(['touch', 'b.txt'])]]);
  assert.equal(h.asked.length, 1);
  h.a.handle(1, 'item/commandExecution/requestApproval', req('touch b.txt'), { fromChild: true });
  await flush();
  assert.equal(h.asked.length, 1, 'answered by the rule, no card');
  h.answerWith(async () => ({ decision: 'deny' }));
  h.a.handle(2, 'item/commandExecution/requestApproval', req('touch b.txt; rm -rf ~'), { fromChild: false });
  h.a.handle(3, 'item/commandExecution/requestApproval', req('touch b.txt', { kind: 'writeStdin' }), { fromChild: false });
  h.a.handle(4, 'item/commandExecution/requestApproval', req('touch b.txt', { networkApprovalContext: { host: 'example.com', protocol: 'https' } }), { fromChild: false });
  await flush();
  assert.equal(h.asked.length, 4);
  assert.equal(h.asked[1].canAlwaysAllow, false, 'no rule can cover a chained command');
  assert.equal(h.asked[2].canAlwaysAllow, false);
  assert.match(h.asked[2].title, /^Send input to a running command/);
  assert.equal(h.asked[3].canAlwaysAllow, false);
  assert.match(h.asked[3].title, /^Allow network access to example\.com/);
  // Never acceptForSession, never acceptWithExecpolicyAmendment.
  for (const r of h.replies) {
    const d = (r.result as { decision: unknown }).decision;
    assert.ok(d === 'accept' || d === 'decline' || d === 'cancel', JSON.stringify(d));
  }
});

test('serverRequest/resolved straight after our reply expires nothing; before it, the card expires', async () => {
  const h = harness();
  let release!: (a: ToolApprovalAnswer) => void;
  h.a.handle(5, 'item/commandExecution/requestApproval', req('touch b.txt'), { fromChild: false });
  await flush();
  h.a.resolved(5); // under 1 ms after our reply, as Codex does
  h.answerWith((r) => new Promise((res) => {
    release = res;
    r.signal.addEventListener('abort', () => res({ decision: 'expired' }));
  }));
  h.a.handle(6, 'item/fileChange/requestApproval', { threadId: 't', turnId: 'u', itemId: 'fc-1', reason: null, grantRoot: null }, { fromChild: false });
  h.a.handle(7, 'item/commandExecution/requestApproval', req('touch c.txt'), { fromChild: false });
  await flush();
  assert.equal(h.a.pendingCount, 2);
  // Codex resolved 6 by itself (an interrupt): its card expires, and no
  // reply goes out for it.
  h.a.resolved(6);
  assert.equal(h.asked[1].signal.aborted, true);
  assert.equal(h.asked[2].signal.aborted, false);
  await flush();
  release({ decision: 'allow' });
  await flush();
  assert.deepEqual(h.replies.map((r) => r.id), [5, 7]);
  assert.equal(h.a.pendingCount, 0);
});

test('file changes: titled from the item\'s paths; "Always allow" is the codex:fileChange rule', async () => {
  const h = harness();
  h.answerWith(async () => ({ decision: 'allowAlways' }));
  h.a.handle(0, 'item/fileChange/requestApproval', { threadId: 't', turnId: 'u', itemId: 'fc-3', reason: null, grantRoot: null }, { fromChild: false });
  await flush();
  assert.equal(h.asked[0].name, 'apply_patch');
  assert.equal(h.asked[0].title, 'Edit 3 files');
  assert.equal(h.asked[0].canAlwaysAllow, true);
  assert.deepEqual(h.added, [[FILE_CHANGE_RULE]]);
  h.a.handle(1, 'item/fileChange/requestApproval', { threadId: 't', turnId: 'u', itemId: 'fc-1', reason: null, grantRoot: null }, { fromChild: false });
  h.a.handle(2, 'applyPatchApproval', { conversationId: 't', callId: 'c', fileChanges: { '/w/a': {} }, reason: null }, { fromChild: false });
  await flush();
  assert.equal(h.asked.length, 1);
  assert.deepEqual(h.replies.map((r) => r.result), [{ decision: 'accept' }, { decision: 'accept' }, { decision: 'approved' }]);
  const one = harness();
  one.a.handle(0, 'item/fileChange/requestApproval', { threadId: 't', turnId: 'u', itemId: 'fc-1', reason: null, grantRoot: null }, { fromChild: false });
  await flush();
  assert.equal(one.asked[0].title, 'Edit a.txt');
});

test('permissions: a turn or a session grant, or nothing', async () => {
  const h = harness();
  const params = { threadId: 't', turnId: 'u', itemId: 'p1', environmentId: null, cwd: '/w', reason: 'Needs the network', permissions: { network: { enabled: true }, fileSystem: null } };
  h.a.handle(0, 'item/permissions/requestApproval', params, { fromChild: false });
  h.answerWith(async () => ({ decision: 'allowAlways' }));
  h.a.handle(1, 'item/permissions/requestApproval', params, { fromChild: false });
  h.answerWith(async () => ({ decision: 'deny' }));
  h.a.handle(2, 'item/permissions/requestApproval', params, { fromChild: false });
  await flush();
  assert.equal(h.asked[0].title, 'Needs the network');
  assert.deepEqual(h.replies.map((r) => r.result), [
    { permissions: { network: { enabled: true } }, scope: 'turn' },
    { permissions: { network: { enabled: true } }, scope: 'session' },
    { permissions: {}, scope: 'turn' },
  ]);
});

test('questions: options or free text, keyed back by question id; secrets declined with a note', async () => {
  const h = harness();
  h.answerQuestionsWith(async (q) => ({ answers: { [q.questions[0].question]: 'Blue', [q.questions[1].question]: 'my own words' } }));
  h.a.handle(
    0,
    'item/tool/requestUserInput',
    {
      threadId: 't', turnId: 'u', itemId: 'q1', isBlocking: true, autoResolutionMs: null,
      questions: [
        { id: 'colour', header: 'Colour', question: 'Which colour?', isOther: false, isSecret: false, options: [{ label: 'Red', description: 'warm' }, { label: 'Blue', description: '' }] },
        { id: 'name', header: 'Name', question: 'What name?', isOther: true, isSecret: false, options: null },
        { id: 'pw', header: 'Password', question: 'Your password?', isOther: false, isSecret: true, options: null },
      ],
    },
    { fromChild: false },
  );
  await flush();
  assert.deepEqual(h.questions[0].questions, [
    { question: 'Which colour?', header: 'Colour', multiSelect: false, options: [{ label: 'Red', description: 'warm' }, { label: 'Blue' }] },
    { question: 'What name?', header: 'Name', multiSelect: false, options: [] },
  ]);
  assert.equal(h.questions[0].toolUseId, 'q1');
  assert.deepEqual(h.replies[0].result, { answers: { colour: { answers: ['Blue'] }, name: { answers: ['my own words'] } } });
  assert.match(h.notes[0], /secret \(Password\)/);
  // Only secrets: answered at once, empty.
  h.a.handle(1, 'item/tool/requestUserInput', { threadId: 't', turnId: 'u', itemId: 'q2', isBlocking: true, questions: [{ id: 'pw', header: 'Password', question: '?', isOther: false, isSecret: true, options: null }] }, { fromChild: false });
  assert.deepEqual(h.replies[1].result, { answers: {} });
  // Dismissed.
  h.answerQuestionsWith(async () => ({ answers: null }));
  h.a.handle(2, 'item/tool/requestUserInput', { threadId: 't', turnId: 'u', itemId: 'q3', isBlocking: false, questions: [{ id: 'a', header: 'A', question: 'A?', isOther: false, isSecret: false, options: null }] }, { fromChild: true });
  await flush();
  assert.equal(h.questions[1].toolUseId, undefined);
  assert.deepEqual(h.replies[2].result, { answers: {} });
});

test('MCP elicitations: a form becomes questions, a URL is declined with a note', async () => {
  const h = harness();
  h.answerQuestionsWith(async (q) => ({ answers: Object.fromEntries(q.questions.map((x, i) => [x.question, ['Staging', '3', 'Yes'][i]])) }));
  h.a.handle(
    0,
    'mcpServer/elicitation/request',
    {
      threadId: 't', turnId: 'u', serverName: 'deploy', mode: 'form', _meta: null, message: 'Where to deploy?',
      requestedSchema: {
        type: 'object',
        properties: {
          env: { type: 'string', title: 'Environment', oneOf: [{ const: 'stg', title: 'Staging' }, { const: 'prod', title: 'Production' }] },
          replicas: { type: 'integer', title: 'Replicas' },
          confirm: { type: 'boolean', title: 'Confirm' },
        },
      },
    },
    { fromChild: false },
  );
  await flush();
  assert.equal(h.questions[0].questions.length, 3);
  assert.match(h.questions[0].questions[0].question, /^Where to deploy\?\n\nEnvironment/);
  assert.deepEqual(h.questions[0].questions[0].options, [{ label: 'Staging' }, { label: 'Production' }]);
  assert.deepEqual(h.questions[0].questions[2].options, [{ label: 'Yes' }, { label: 'No' }]);
  assert.deepEqual(h.replies[0].result, { action: 'accept', content: { env: 'stg', replicas: 3, confirm: true }, _meta: null });
  h.a.handle(1, 'mcpServer/elicitation/request', { threadId: 't', turnId: null, serverName: 'login', mode: 'url', _meta: null, message: 'Sign in', url: 'https://example.com/auth', elicitationId: 'e' }, { fromChild: false });
  assert.deepEqual(h.replies[1].result, { action: 'decline', content: null, _meta: null });
  assert.match(h.notes[0], /login asked to open https:\/\/example\.com\/auth/);
});

test('legacy requests use the legacy decision names; the clock and unknown requests', async () => {
  const h = harness();
  h.a.handle(0, 'execCommandApproval', { conversationId: 't', callId: 'c1', command: ['/bin/zsh', '-lc', 'touch x'], cwd: '/w', reason: null, parsedCmd: [] }, { fromChild: false });
  h.answerWith(async () => ({ decision: 'deny', message: 'no' }));
  h.a.handle(1, 'execCommandApproval', { conversationId: 't', callId: 'c2', command: ['touch', 'y z'], cwd: '/w', reason: null }, { fromChild: false });
  h.answerWith(async () => ({ decision: 'expired' }));
  h.a.handle(2, 'applyPatchApproval', { conversationId: 't', callId: 'c3', fileChanges: {}, reason: null }, { fromChild: false });
  await flush();
  assert.equal(h.asked[0].title, 'touch x');
  assert.equal(h.asked[1].title, "touch 'y z'");
  assert.deepEqual(h.replies.map((r) => r.result), [{ decision: 'approved' }, { decision: { denied: { rejection: 'no' } } }, { decision: 'abort' }]);
  h.a.handle(3, 'currentTime/read', {}, { fromChild: false });
  assert.deepEqual(h.replies[3].result, { currentTimeAt: 1_793_000_000 });
  h.a.handle(4, 'attestation/generate', {}, { fromChild: false });
  assert.equal(h.replies[4].error!.code, -32601);
});

test('ending the session expires every open card without replying', async () => {
  const h = harness();
  h.answerWith((r) => new Promise((res) => r.signal.addEventListener('abort', () => res({ decision: 'expired' }))));
  h.a.handle(0, 'item/commandExecution/requestApproval', req('touch b.txt'), { fromChild: false });
  await flush();
  h.a.cancelAll();
  await flush();
  assert.equal(h.asked[0].signal.aborted, true);
  assert.equal(h.replies.length, 0);
});

// ---- The threadbear tools as dynamic tools

test('every threadbear tool converts to a dynamic tool with a JSON Schema', () => {
  // Typed against the runner's real tool list, so C's wiring type-checks.
  const tools: ToolDefinition[] = buildThreadbearTools({} as never, 'self', Date.now, undefined, undefined, undefined, { provider: 'codex' });
  const [ns] = dynamicToolSpecs(tools);
  assert.equal(ns.name, 'threadbear');
  // Codex refuses thread/start with a longer one, so no Codex thread starts.
  assert.ok(ns.description.length <= NAMESPACE_DESCRIPTION_MAX, `namespace description is ${ns.description.length} characters`);
  assert.ok(ns.tools.length >= 9);
  for (const t of ns.tools) {
    const schema = t.inputSchema as { type?: string; properties?: unknown; $schema?: unknown };
    assert.equal(schema.type, 'object', t.name);
    assert.equal(schema.$schema, undefined);
    assert.ok(t.description.length > 10, t.name);
  }
  assert.ok(ns.tools.some((t) => t.name === 'delete_thread'));
  assert.deepEqual(dynamicToolSpecs([]), []);
});
