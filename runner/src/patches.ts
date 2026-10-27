// Patches: what a thread's folder gives the app beyond the transcript
// (docs/threadbear-design/README.md). This is the built-in set, worked out
// from the folder alone; patches written in the project come in step 3.
//
// A panel is found by walking up from the thread's folder to the home
// folder (or the root), so a thread started in a package of a monorepo
// still gets the project's panels. The first folder with a project wins
// for each patch.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import type { ImageRef, Panel } from './protocol.ts';
import { imageRefFor } from './media.ts';

export const CONVEX_DASHBOARD = 'https://dashboard.convex.dev';
// `npx convex dev` on an anonymous (no account) deployment serves the
// dashboard itself, from this port unless it's taken.
export const CONVEX_LOCAL_DASHBOARD = 'http://127.0.0.1:6790';

export function projectPanels(cwd: string, home: string = os.homedir()): Panel[] {
  const panels: Panel[] = [];
  const convexDir = findUp(cwd, home, (dir) => isDir(path.join(dir, 'convex')));
  if (convexDir) panels.push(convexPanel(convexDir));
  const xcodeDir = findUp(cwd, home, hasXcodeProject);
  if (xcodeDir) panels.push(simulatorPanel(xcodeDir));
  return panels;
}

// The Convex dashboard for the project's deployment. `.env.local` (what
// `convex dev` writes) wins over `.env`.
function convexPanel(dir: string): Panel {
  const deployment = readEnvValue(dir, 'CONVEX_DEPLOYMENT');
  const { url, note } = convexDashboardUrl(deployment);
  const panel: Panel = { id: 'convex.dashboard', title: 'Convex', kind: 'url', url, patch: 'convex' };
  if (note) panel.note = note;
  return panel;
}

// Mirrors the CLI's own `convex dashboard`: every deployment type is a
// page on dashboard.convex.dev, except an anonymous local one, which the
// CLI serves itself while `convex dev` runs.
export function convexDashboardUrl(deployment: string | undefined): { url: string; note?: string } {
  if (!deployment) return { url: CONVEX_DASHBOARD, note: 'No deployment in .env.local yet' };
  const colon = deployment.indexOf(':');
  const type = colon >= 0 ? deployment.slice(0, colon) : '';
  const name = colon >= 0 ? deployment.slice(colon + 1) : deployment;
  if (!name) return { url: CONVEX_DASHBOARD };
  if (type === 'anonymous') return { url: CONVEX_LOCAL_DASHBOARD, note: `${name}, local; the dashboard is up while convex dev runs` };
  return { url: `${CONVEX_DASHBOARD}/d/${encodeURIComponent(name)}`, note: type ? `${name} (${type})` : name };
}

function simulatorPanel(dir: string): Panel {
  return { id: 'xcode.simulator', title: 'Simulator', kind: 'image', patch: 'xcode', note: path.basename(dir) };
}

function hasXcodeProject(dir: string): boolean {
  let names: string[];
  try {
    names = fs.readdirSync(dir);
  } catch {
    return false;
  }
  return names.some((n) => n.endsWith('.xcodeproj') || n.endsWith('.xcworkspace'));
}

// The first folder from `start` up to and including `home` (or the root)
// that passes `test`. Folders above home are never a project of Mike's.
export function findUp(start: string, home: string, test: (dir: string) => boolean): string | undefined {
  let dir = path.resolve(start);
  const stopAt = path.resolve(home);
  for (;;) {
    if (test(dir)) return dir;
    if (dir === stopAt) return undefined;
    const parent = path.dirname(dir);
    if (parent === dir) return undefined;
    // Left home without passing through it (a folder outside it): stop at
    // the root, but don't climb into other users' folders.
    dir = parent;
  }
}

function isDir(p: string): boolean {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

// A dotenv value by name, unquoted; `.env.local` then `.env`. Only the one
// line is read and returned, never the file: the rest may hold secrets.
export function readEnvValue(dir: string, name: string): string | undefined {
  for (const file of ['.env.local', '.env']) {
    let text: string;
    try {
      text = fs.readFileSync(path.join(dir, file), 'utf8');
    } catch {
      continue;
    }
    const value = parseEnvValue(text, name);
    if (value !== undefined) return value;
  }
  return undefined;
}

export function parseEnvValue(text: string, name: string): string | undefined {
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const m = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
    if (!m || m[1] !== name) continue;
    let value = m[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    } else {
      // An unquoted value ends at a comment.
      value = value.replace(/\s+#.*$/, '').trim();
    }
    return value;
  }
  return undefined;
}

// ------------------------------------------------------------- rendering

export type PanelRender = { image?: ImageRef; note?: string };

// Takes a screenshot of the booted simulator into `file` (PNG). The real
// one runs simctl; tests pass their own.
export type Screenshot = (file: string) => Promise<void>;

export const simctlScreenshot: Screenshot = (file) =>
  new Promise((resolve, reject) => {
    execFile('xcrun', ['simctl', 'io', 'booted', 'screenshot', '--type=png', file], { timeout: 15_000 }, (err, _out, stderr) => {
      if (err) reject(new Error(String(stderr || err.message).trim()));
      else resolve();
    });
  });

// An image panel's picture, drawn fresh each time it's asked for. The
// Simulator panel is the last screenshot of the booted device; with none
// booted there's only a note. The file is the same each time (one per
// thread and panel, under `dir`), so a thread never collects screenshots.
export async function renderPanel(panel: Panel, dir: string, screenshot: Screenshot = simctlScreenshot): Promise<PanelRender> {
  if (panel.kind !== 'image') return { note: 'This panel has nothing to render.' };
  if (panel.patch !== 'xcode') return { note: `No renderer for ${panel.patch} panels.` };
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${panel.id}.png`);
  const tmp = `${file}.tmp`;
  try {
    await screenshot(tmp);
    fs.renameSync(tmp, file);
  } catch (e) {
    fs.rmSync(tmp, { force: true });
    const message = String((e as Error)?.message ?? e);
    // simctl's wording when nothing is running.
    if (/no devices are booted|Unable to lookup in current state|booted/i.test(message)) {
      return { note: 'No simulator is booted. Build and run, or open Simulator.' };
    }
    return { note: `Couldn't take a screenshot: ${message.split('\n')[0]}` };
  }
  return { image: imageRefFor(file, 'image/png') };
}
