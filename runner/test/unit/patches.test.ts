import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { tmpDir } from '../helpers/fakes.ts';
import { makePng } from '../helpers/png.ts';
import { checkPanel } from '../helpers/protocol-check.ts';
import { CONVEX_DASHBOARD, CONVEX_LOCAL_DASHBOARD, convexDashboardUrl, parseEnvValue, projectPanels, renderPanel } from '../../src/patches.ts';

function project(home: string, rel: string, files: Record<string, string | null> = {}): string {
  const dir = path.join(home, rel);
  fs.mkdirSync(dir, { recursive: true });
  for (const [name, text] of Object.entries(files)) {
    const p = path.join(dir, name);
    if (text === null) fs.mkdirSync(p, { recursive: true });
    else fs.writeFileSync(p, text);
  }
  return dir;
}

test('a folder with convex/ gets the dashboard panel for its deployment', () => {
  const home = tmpDir();
  const dir = project(home, 'dev/app', { convex: null, '.env.local': 'CONVEX_DEPLOYMENT=dev:happy-otter-123 # team: mike\nCONVEX_URL=https://happy-otter-123.convex.cloud\n' });
  const panels = projectPanels(dir, home);
  assert.equal(panels.length, 1);
  assert.deepEqual(checkPanel(panels[0] as never), []);
  assert.deepEqual(panels[0], {
    id: 'convex.dashboard', title: 'Convex', kind: 'url', patch: 'convex',
    url: 'https://dashboard.convex.dev/d/happy-otter-123', note: 'happy-otter-123 (dev)',
  });
});

test('a thread in a package of the project still gets the project panels; nothing above home', () => {
  const home = tmpDir();
  project(home, 'dev/app', { convex: null, '.env.local': 'CONVEX_DEPLOYMENT=prod:big-cat-9\n' });
  const sub = project(home, 'dev/app/packages/web');
  assert.equal(projectPanels(sub, home)[0]?.url, 'https://dashboard.convex.dev/d/big-cat-9');
  // A convex/ folder in the fake home's parent isn't found from inside home.
  fs.mkdirSync(path.join(path.dirname(home), 'convex'), { recursive: true });
  try {
    assert.deepEqual(projectPanels(project(home, 'dev/plain'), home), []);
  } finally {
    fs.rmSync(path.join(path.dirname(home), 'convex'), { recursive: true, force: true });
  }
});

test('dashboard URLs: no deployment, anonymous local, quoted .env values, .env.local first', () => {
  assert.deepEqual(convexDashboardUrl(undefined), { url: CONVEX_DASHBOARD, note: 'No deployment in .env.local yet' });
  assert.deepEqual(convexDashboardUrl('anonymous:anonymous-app'), { url: CONVEX_LOCAL_DASHBOARD, note: 'anonymous-app, local; the dashboard is up while convex dev runs' });
  assert.equal(convexDashboardUrl('local:my-local-1').url, 'https://dashboard.convex.dev/d/my-local-1');
  assert.equal(convexDashboardUrl('odd name').url, 'https://dashboard.convex.dev/d/odd%20name');
  assert.equal(parseEnvValue('export CONVEX_DEPLOYMENT="dev:quoted-1"\n', 'CONVEX_DEPLOYMENT'), 'dev:quoted-1');
  assert.equal(parseEnvValue("CONVEX_DEPLOYMENT='dev:single-1'", 'CONVEX_DEPLOYMENT'), 'dev:single-1');
  assert.equal(parseEnvValue('# CONVEX_DEPLOYMENT=dev:commented\nOTHER=1\n', 'CONVEX_DEPLOYMENT'), undefined);
  const home = tmpDir();
  const dir = project(home, 'p', { convex: null, '.env': 'CONVEX_DEPLOYMENT=prod:from-env\n', '.env.local': 'CONVEX_DEPLOYMENT=dev:from-local\n' });
  assert.equal(projectPanels(dir, home)[0]?.note, 'from-local (dev)');
});

test('an Xcode project gets the Simulator panel; both patches can apply', () => {
  const home = tmpDir();
  const ios = project(home, 'dev/Walkies', { 'Walkies.xcodeproj': null });
  const panels = projectPanels(ios, home);
  assert.deepEqual(panels, [{ id: 'xcode.simulator', title: 'Simulator', kind: 'image', patch: 'xcode', note: 'Walkies' }]);
  assert.deepEqual(checkPanel(panels[0] as never), []);
  const both = project(home, 'dev/Both', { 'App.xcworkspace': null, convex: null });
  assert.deepEqual(projectPanels(both, home).map((p) => p.id), ['convex.dashboard', 'xcode.simulator']);
  assert.deepEqual(projectPanels(project(home, 'dev/nothing'), home), []);
});

test('rendering the Simulator panel: a screenshot becomes an image ref, no device a note', async () => {
  const dir = path.join(tmpDir(), 'panels');
  const panel = { id: 'xcode.simulator', title: 'Simulator', kind: 'image' as const, patch: 'xcode' };
  const ok = await renderPanel(panel, dir, async (file) => fs.writeFileSync(file, makePng(40, 30)));
  assert.equal(ok.note, undefined);
  assert.equal(ok.image?.path, path.join(dir, 'xcode.simulator.png'));
  assert.equal(ok.image?.mediaType, 'image/png');
  assert.equal(ok.image?.width, 40);
  assert.equal(ok.image?.height, 30);
  // Rendered again: the same file, overwritten, no leftovers.
  await renderPanel(panel, dir, async (file) => fs.writeFileSync(file, makePng(10, 10)));
  assert.deepEqual(fs.readdirSync(dir), ['xcode.simulator.png']);
  const none = await renderPanel(panel, dir, async () => { throw new Error('No devices are booted.'); });
  assert.equal(none.image, undefined);
  assert.equal(none.note, 'No simulator is booted. Build and run, or open Simulator.');
  const other = await renderPanel(panel, dir, async () => { throw new Error('xcrun: error: unable to find utility "simctl"\nmore'); });
  assert.equal(other.note, 'Couldn\'t take a screenshot: xcrun: error: unable to find utility "simctl"');
  const url = await renderPanel({ id: 'convex.dashboard', title: 'Convex', kind: 'url', url: 'https://x', patch: 'convex' }, dir);
  assert.equal(url.note, 'This panel has nothing to render.');
});

import { loadPatchSet, readPatchModule, runCommand, slug } from '../../src/patches.ts';
import { checkAction } from '../helpers/protocol-check.ts';
import { tick } from '../helpers/fakes.ts';

function writePatch(dir: string, name: string, text: string): string {
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, name);
  fs.writeFileSync(file, text);
  return file;
}

test('patch files in the project and in home give actions and panels, with ids from the title', async () => {
  const home = tmpDir();
  const app = project(home, 'dev/app', { convex: null });
  const file = writePatch(path.join(app, '.threadbear/patches'), 'reseed.ts', `
    export default {
      actions: [
        { title: "Reseed dev DB", run: "npx convex run seed:reset", note: "Dev only" },
        { title: "Explain the schema", prompt: "Read convex/schema.ts and explain it." },
      ],
      panels: [{ title: "Storybook", url: "http://localhost:6006" }],
    } satisfies Record<string, unknown>;
  `);
  const homeFile = writePatch(path.join(home, '.threadbear/patches'), 'everywhere.mjs', `export default { actions: [{ title: "Disk space", run: "df -h ." }] };`);
  const set = await loadPatchSet(path.join(app, 'packages/web'), home);
  fs.mkdirSync(path.join(app, 'packages/web'), { recursive: true });
  assert.deepEqual(set.patches, [
    { id: 'convex', source: 'builtin' },
    { id: 'everywhere', source: 'home', file: homeFile },
    { id: 'reseed', source: 'project', file },
  ]);
  assert.deepEqual(set.actions.map((a) => a.id), ['everywhere.disk-space', 'reseed.reseed-dev-db', 'reseed.explain-the-schema']);
  for (const a of set.actions) assert.deepEqual(checkAction(a as never), [], a.id);
  assert.deepEqual(set.actions[1], { id: 'reseed.reseed-dev-db', title: 'Reseed dev DB', kind: 'command', command: 'npx convex run seed:reset', patch: 'reseed', note: 'Dev only' });
  assert.deepEqual(set.actions[2], { id: 'reseed.explain-the-schema', title: 'Explain the schema', kind: 'prompt', prompt: 'Read convex/schema.ts and explain it.', patch: 'reseed' });
  assert.deepEqual(set.panels.map((p) => p.id), ['convex.dashboard', 'reseed.storybook']);
  assert.deepEqual(checkPanel(set.panels[1] as never), []);
});

test('a patch file that breaks is listed with its error and gives nothing; an edit reloads it', async () => {
  const home = tmpDir();
  const app = project(home, 'p');
  const dir = path.join(app, '.threadbear/patches');
  const file = writePatch(dir, 'broken.ts', 'export default { actions: [{ title: "No command" }] };');
  writePatch(dir, 'syntax.ts', 'export default {');
  writePatch(dir, 'types.d.ts', 'export {};');
  writePatch(dir, '.hidden.ts', 'export default { actions: [{ title: "Hidden", run: "true" }] };');
  const cache = new Map();
  let set = await loadPatchSet(app, home, cache);
  assert.deepEqual(set.actions, []);
  assert.equal(set.patches.length, 2);
  assert.equal(set.patches[0].id, 'broken');
  assert.equal(set.patches[0].error, 'actions[0] ("No command") needs run (a command) or prompt (a message).');
  assert.equal(set.patches[1].id, 'syntax');
  assert.match(set.patches[1].error ?? '', /./);
  // Fixed: the file's mtime moves on, so it's read again.
  await new Promise((r) => setTimeout(r, 20));
  fs.writeFileSync(file, 'export default { actions: [{ title: "Now fine", run: "true" }] };');
  const later = new Date(Date.now() + 2000);
  fs.utimesSync(file, later, later);
  set = await loadPatchSet(app, home, cache);
  assert.deepEqual(set.actions.map((a) => a.id), ['broken.now-fine']);
  assert.equal(set.patches[0].error, undefined);
});

test('readPatchModule: the shapes it refuses', () => {
  const read = (v: unknown) => readPatchModule('x', 'project', '/p/x.ts', v).info.error;
  assert.equal(read(undefined), 'The default export should be an object with actions and/or panels.');
  assert.equal(read([]), 'The default export should be an object with actions and/or panels.');
  assert.equal(read({ actions: {} }), 'actions should be an array.');
  assert.equal(read({ actions: [{ run: 'x' }] }), 'actions[0] needs a title.');
  assert.equal(read({ actions: [{ title: 'Both', run: 'x', prompt: 'y' }] }), 'actions[0] ("Both") should have run or prompt, not both.');
  assert.equal(read({ panels: [{ title: 'No url' }] }), 'panels[0] ("No url") needs a url.');
  assert.equal(read({ panels: [{ title: 'Bad', url: 'localhost:3000' }] }), 'panels[0] ("Bad") needs a url.');
  assert.equal(read({ actions: [{ title: 'Same!', run: 'a' }, { title: 'same', run: 'b' }] }), 'Two entries would both be called x.same; give them different titles.');
  assert.equal(read({}), undefined);
  assert.equal(slug('Reseed dev DB'), 'reseed-dev-db');
  assert.equal(slug('  ⌘  '), 'untitled');
});

test('runCommand: output, exit codes, the time limit and the size cap', async () => {
  const cwd = tmpDir();
  const sh = ['/bin/sh', '-c'];
  const env = { PATH: '/usr/bin:/bin', TB_TEST: 'yes' };
  const ok = await runCommand('echo "in $PWD $TB_TEST"; echo err >&2', { cwd, env, shell: sh });
  assert.equal(ok.ok, true);
  assert.equal(ok.exitCode, 0);
  assert.equal(ok.truncated, false);
  assert.match(ok.text, new RegExp(`in ${fs.realpathSync(cwd)} yes`));
  assert.match(ok.text, /err/);
  const failed = await runCommand('echo nope; exit 3', { cwd, env, shell: sh });
  assert.equal(failed.ok, false);
  assert.equal(failed.exitCode, 3);
  assert.equal(failed.text.trim(), 'nope');
  const slow = await runCommand('echo start; sleep 5; echo never', { cwd, env, shell: sh, timeoutMs: 300 });
  assert.equal(slow.ok, false);
  assert.equal(slow.text, 'start\nStopped after 0.3 s.');
  assert.ok(slow.durationMs < 3000);
  const big = await runCommand('yes abcdefghij | head -c 200000', { cwd, env, shell: sh });
  assert.equal(big.ok, true);
  assert.equal(big.truncated, true);
  assert.equal(big.text.length, 64 * 1024);
  const missing = await runCommand('true', { cwd, env, shell: ['/no/such/shell', '-c'] });
  assert.equal(missing.ok, false);
  assert.match(missing.text, /ENOENT/);
});
