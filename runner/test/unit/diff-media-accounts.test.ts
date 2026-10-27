import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { diffLines } from '../../src/diff.ts';
import { computeEditDiff, displayPath } from '../../src/tools.ts';
import { sniffImage, copyImageInto, readImageInfo } from '../../src/media.ts';
import { AccountRegistry, discoverAccounts, resolveDefaultModel } from '../../src/accounts.ts';
import { cliEnv } from '../../src/adapters/claude/adapter.ts';
import { loadConfig, recordListening, readRunnerJson } from '../../src/config.ts';
import { tmpDir } from '../helpers/fakes.ts';
import { makePng } from '../helpers/png.ts';

test('diffLines matches the CLI patch shape', () => {
  assert.deepEqual(diffLines('alpha\nbeta\ngamma\n', 'alpha\nBETA\ngamma\n'), [
    { oldStart: 1, oldLines: 3, newStart: 1, newLines: 3, lines: [' alpha', '-beta', '+BETA', ' gamma'] },
  ]);
  assert.deepEqual(diffLines('', 'hi'), [{ oldStart: 0, oldLines: 0, newStart: 1, newLines: 1, lines: ['+hi'] }]);
  assert.deepEqual(diffLines('same\n', 'same\n'), []);
});

test('diffLines splits far-apart changes into hunks with 3 lines of context', () => {
  const before = Array.from({ length: 30 }, (_, i) => `line ${i + 1}`).join('\n');
  const after = before.replace('line 2\n', 'line two\n').replace('line 25\n', 'line twenty-five\n');
  const hunks = diffLines(before, after);
  assert.equal(hunks.length, 2);
  assert.deepEqual(hunks[0], { oldStart: 1, oldLines: 5, newStart: 1, newLines: 5, lines: [' line 1', '-line 2', '+line two', ' line 3', ' line 4', ' line 5'] });
  assert.equal(hunks[1].oldStart, 22);
  assert.equal(hunks[1].lines.filter((l) => l[0] === '-').length, 1);
});

test('computeEditDiff uses file line numbers when the file is known', () => {
  const file = 'a\nb\nc\nd\ne\nf\ng\nh\n';
  const d = computeEditDiff('Edit', { file_path: '/p/x.txt', old_string: 'f', new_string: 'F' }, file)!;
  assert.equal(d.path, '/p/x.txt');
  assert.deepEqual(d.hunks[0], { oldStart: 3, oldLines: 6, newStart: 3, newLines: 6, lines: [' c', ' d', ' e', '-f', '+F', ' g', ' h'] });
  const multi = computeEditDiff('MultiEdit', { file_path: '/p/x.txt', edits: [{ old_string: 'a', new_string: 'A' }, { old_string: 'h', new_string: 'H' }] }, file)!;
  // Six unchanged lines between the edits (2 x context) still make one hunk.
  assert.equal(multi.hunks.length, 1);
  assert.deepEqual(multi.hunks[0].lines.filter((l) => l[0] !== ' '), ['-a', '+A', '-h', '+H']);
  const missing = computeEditDiff('Edit', { file_path: '/p/x.txt', old_string: 'zzz', new_string: 'y' }, file)!;
  assert.deepEqual(missing.hunks[0].lines, ['-zzz', '+y']);
  const write = computeEditDiff('Write', { file_path: '/p/x.txt', content: 'a\nB\n' }, 'a\nb\n')!;
  assert.deepEqual(write.hunks[0].lines, [' a', '-b', '+B']);
});

test('displayPath shows paths relative to the thread folder, real path included', () => {
  const dir = tmpDir();
  assert.equal(displayPath(path.join(dir, 'src', 'a.ts'), dir), 'src/a.ts');
  assert.equal(displayPath(path.join(fs.realpathSync(dir), 'b.ts'), dir), 'b.ts');
  assert.equal(displayPath('/elsewhere/c.ts', dir), '/elsewhere/c.ts');
});

test('image sniffing reads type and size from headers', () => {
  const png = makePng(64, 48);
  assert.deepEqual(sniffImage(png), { mediaType: 'image/png', width: 64, height: 48 });
  const gif = Buffer.from('474946383961' + '0a00' + '0500' + '00', 'hex');
  assert.deepEqual(sniffImage(gif), { mediaType: 'image/gif', width: 10, height: 5 });
  // Minimal JPEG: SOI, APP0 stub, SOF0 with 3x2.
  const jpg = Buffer.from('ffd8ffe000104a46494600010100000100010000ffc0000b080002000301011100ffd9', 'hex');
  assert.deepEqual(sniffImage(jpg), { mediaType: 'image/jpeg', width: 3, height: 2 });
  assert.equal(sniffImage(Buffer.from('hello')), null);
  const dir = tmpDir();
  const src = path.join(dir, 'in.png');
  fs.writeFileSync(src, png);
  const ref = copyImageInto(path.join(dir, 'inbox'), src);
  assert.equal(ref.mediaType, 'image/png');
  assert.equal(ref.width, 64);
  assert.ok(ref.path.startsWith(path.join(dir, 'inbox')));
  assert.deepEqual(readImageInfo(ref.path), { mediaType: 'image/png', width: 64, height: 48 });
  fs.writeFileSync(path.join(dir, 'not.txt'), 'nope');
  assert.throws(() => copyImageInto(dir, path.join(dir, 'not.txt')), /Not a supported image/);
});

test('account discovery reads only the login email', () => {
  const root = tmpDir();
  const main = path.join(root, 'dot-claude');
  fs.mkdirSync(main);
  fs.writeFileSync(path.join(root, 'claude.json'), JSON.stringify({ oauthAccount: { emailAddress: 'main@example.com', accessToken: 'SHOULD-NOT-APPEAR' } }));
  const accts = path.join(root, 'Accounts');
  for (const n of ['claude-2', 'claude-10', 'codex-1', 'claude-x']) fs.mkdirSync(path.join(accts, n), { recursive: true });
  fs.writeFileSync(path.join(accts, 'claude-2', '.claude.json'), JSON.stringify({ oauthAccount: { emailAddress: 'two@example.com' } }));
  const found = discoverAccounts({ claudeMainDir: main, claudeMainJson: path.join(root, 'claude.json'), tokenStatsAccountsDir: accts });
  assert.deepEqual(found, [
    { id: 'claude-main', provider: 'claude', title: 'main@example.com', configDir: main },
    { id: 'claude-2', provider: 'claude', title: 'two@example.com', configDir: path.join(accts, 'claude-2') },
    { id: 'claude-10', provider: 'claude', title: 'claude-10', configDir: path.join(accts, 'claude-10') },
  ]);
  assert.ok(!JSON.stringify(found).includes('SHOULD-NOT-APPEAR'));
});

test("an account's default model: its settings.json, made exact by what the CLI says", () => {
  const root = tmpDir();
  const main = path.join(root, 'dot-claude');
  fs.mkdirSync(main);
  fs.writeFileSync(path.join(main, 'settings.json'), JSON.stringify({ model: 'claude-fable-5-1[1m]', apiKeyHelper: 'SHOULD-NOT-APPEAR' }));
  const accts = path.join(root, 'Accounts');
  fs.mkdirSync(path.join(accts, 'claude-2'), { recursive: true });
  fs.writeFileSync(path.join(accts, 'claude-2', 'settings.json'), '{ not json');
  const cfg = { claudeMainDir: main, claudeMainJson: path.join(root, 'claude.json'), tokenStatsAccountsDir: accts };
  const found = discoverAccounts(cfg);
  assert.equal(found[0].defaultModel, 'claude-fable-5-1', 'the [1m] suffix is not part of the id');
  assert.equal(found[1].defaultModel, undefined, 'nothing set: unknown until a turn runs');
  assert.ok(!JSON.stringify(found).includes('SHOULD-NOT-APPEAR'));

  const registry = new AccountRegistry(cfg);
  const models = [{ id: 'claude-fable-5-1[1m]', model: 'claude-fable-5-1', title: 'Fable 5.1' }, { id: 'sonnet', model: 'claude-sonnet-5-5', title: 'Sonnet 5.5' }];
  assert.equal(registry.learn('claude-main', { models }), true);
  assert.equal(registry.learn('claude-main', { models: [...models] }), false, 'the same list again is no change');
  assert.deepEqual(registry.get('claude-main')?.models, models);
  // A turn on a thread with no model is the truth, whatever settings say.
  assert.equal(registry.learn('claude-2', { defaultModel: 'claude-opus-5-5' }), true);
  assert.equal(registry.get('claude-2')?.defaultModel, 'claude-opus-5-5');
  assert.equal(registry.learn('claude-2', { defaultModel: 'claude-opus-5-5' }), false);
  // An alias in settings resolves through the list.
  assert.equal(resolveDefaultModel('sonnet', { models }), 'claude-sonnet-5-5');
  assert.equal(resolveDefaultModel('sonnet', undefined), 'sonnet');
  assert.equal(resolveDefaultModel(undefined, { models }), undefined);
});

test('CLI env: CLAUDE_CONFIG_DIR per account, parent session vars dropped', () => {
  const base = { PATH: '/bin', HOME: '/Users/x', CLAUDECODE: '1', CLAUDE_CODE_SESSION_ID: 's', CLAUDE_CONFIG_DIR: '/parent' };
  const main = cliEnv({ id: 'claude-main', provider: 'claude', title: '', configDir: '/Users/x/.claude' }, base);
  assert.equal(main.CLAUDE_CONFIG_DIR, undefined);
  assert.equal(main.CLAUDECODE, undefined);
  assert.equal(main.CLAUDE_CODE_SESSION_ID, undefined);
  assert.equal(main.PATH, '/bin');
  const three = cliEnv({ id: 'claude-3', provider: 'claude', title: '', configDir: '/acct/claude-3' }, base);
  assert.equal(three.CLAUDE_CONFIG_DIR, '/acct/claude-3');
});

test('config honours THREADBARE_HOME, THREADBARE_PORT and runner.json', () => {
  const home = tmpDir();
  fs.writeFileSync(path.join(home, 'runner.json'), JSON.stringify({ port: 9999, defaults: { cwd: '/tmp' }, idleMinutes: 5 }));
  const a = loadConfig({ THREADBARE_HOME: home });
  assert.equal(a.home, home);
  assert.equal(a.port, 9999);
  assert.equal(a.idleMs, 5 * 60_000);
  assert.equal(a.defaults.cwd, '/tmp');
  const b = loadConfig({ THREADBARE_HOME: home, THREADBARE_PORT: '18888', THREADBARE_IDLE_MS: '1000' });
  assert.equal(b.port, 18888);
  assert.equal(b.idleMs, 1000);
  // The app's name for the same override.
  assert.equal(loadConfig({ THREADBARE_DATA_DIR: home }).home, home);
  assert.equal(a.defaults.model, undefined, 'no default model: the account decides');
  fs.writeFileSync(path.join(home, 'runner.json'), JSON.stringify({ defaults: { cwd: '/tmp', model: ' claude-haiku-5-5 ' } }));
  assert.equal(loadConfig({ THREADBARE_HOME: home }).defaults.model, 'claude-haiku-5-5');
});

test('runner.json records the port the runner listens on and keeps other settings', () => {
  const home = tmpDir();
  recordListening(home, 8797, '~/dev/me/misc');
  assert.deepEqual(readRunnerJson(home), { port: 8797, defaults: { cwd: '~/dev/me/misc' } });
  fs.writeFileSync(path.join(home, 'runner.json'), JSON.stringify({ port: 8797, defaults: { cwd: '/tmp', accountId: 'claude-3' }, idleMinutes: 5 }));
  recordListening(home, 54321, '~/dev/me/misc');
  assert.deepEqual(readRunnerJson(home), { port: 54321, defaults: { cwd: '/tmp', accountId: 'claude-3' }, idleMinutes: 5 });
});
