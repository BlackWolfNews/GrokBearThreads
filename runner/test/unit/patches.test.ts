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
