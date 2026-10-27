// Patches: what a thread's folder gives the app beyond the transcript
// (docs/threadbear-design/README.md): panels beside it and actions above
// the composer. Two kinds:
//
// - Built in, worked out from the folder alone: a `convex/` folder gives
//   the dashboard, an Xcode project the Simulator.
// - Patch files, `.threadbear/patches/*.ts` (or .js, .mjs) in the project
//   and in `~/.threadbear/patches/` for every project. Each is a module
//   whose default export says what it adds:
//
//     export default {
//       actions: [
//         { title: "Reseed dev DB", run: "npx convex run seed:reset" },
//         { title: "Explain the schema", prompt: "Read convex/schema.ts and explain it." },
//       ],
//       panels: [{ title: "Storybook", url: "http://localhost:6006" }],
//       hooks: [{ title: "Typecheck", on: "turn.end", run: "npx tsc --noEmit", edited: "**/*.ts" }],
//     }
//
//   The runner imports the file (Node runs TypeScript as it is) and reads
//   that object; a file that can't be loaded is listed with its error and
//   gives nothing. Loading a project's module is the same trust as `npm
//   install` in it, and these are Mike's own repos.
//
// Patches are found by walking up from the thread's folder to the home
// folder, so a thread started in a package of a monorepo still gets the
// project's; a parent folder's patches apply to every project under it.
//
// A thread in projects (projects.ts) also gets the patches of every folder
// of those projects, found the same way from each. Those are tagged with
// the folder and project, and their commands run in that folder rather
// than the thread's: a thread in ~/dev/me/misc that's about Poddle gets
// Poddle's dashboard and chips, and Poddle's Reseed runs in Poddle.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { execFile, spawn } from 'node:child_process';
import type { Action, Hook, ImageRef, Panel, PanelItem, PatchInfo } from './protocol.ts';
import { LIMITS } from './protocol.ts';
import { imageRefFor } from './media.ts';

export const CONVEX_DASHBOARD = 'https://dashboard.convex.dev';
// `npx convex dev` on an anonymous (no account) deployment serves the
// dashboard itself, from this port unless it's taken.
export const CONVEX_LOCAL_DASHBOARD = 'http://127.0.0.1:6790';
export const PATCH_DIR = path.join('.threadbear', 'patches');
export const PATCH_EXTENSIONS = ['.ts', '.js', '.mjs'];

// Everything the folder's patches give a thread.
export type PatchSet = { panels: Panel[]; actions: Action[]; hooks: Hook[]; patches: PatchInfo[] };
export const EMPTY_PATCH_SET: PatchSet = { panels: [], actions: [], hooks: [], patches: [] };

// Loaded patch files by path, so a summary refresh doesn't import a file
// whose mtime hasn't moved. One per runner.
export type PatchCache = Map<string, { mtimeMs: number; loaded: LoadedPatch }>;
type LoadedPatch = { info: PatchInfo; panels: Panel[]; actions: Action[]; hooks: Hook[] };

// A folder of one of the thread's projects.
export type ProjectFolder = { folder: string; projectId: string };

export async function loadPatchSet(cwd: string, home: string = os.homedir(), cache: PatchCache = new Map(), projectFolders: ProjectFolder[] = []): Promise<PatchSet> {
  const set: PatchSet = { panels: [], actions: [], hooks: [], patches: [] };
  const roots = projectRoots(cwd, projectFolders);
  // Built in first, so their panels come first: the thread's own, then
  // its projects'.
  for (const b of builtins(cwd, home, roots)) addPatch(set, b);
  // Then the files: the thread's own chain (home's folder first), then
  // each project folder's chain, each patch folder once.
  const seen = new Set<string>();
  for (const { dir, source } of patchDirs(cwd, home)) {
    seen.add(dir);
    for (const file of patchFiles(dir)) addPatch(set, await loadPatchFile(file, source, cache));
  }
  for (const root of roots) {
    for (const { dir, source } of patchDirs(root.folder, home)) {
      if (seen.has(dir) || source === 'home') continue;
      seen.add(dir);
      for (const file of patchFiles(dir)) addPatch(set, inFolder(await loadPatchFile(file, source, cache), root));
    }
  }
  return set;
}

// The project folders that add anything: not the thread's own folder or
// one it's inside (its own chain already covers those), each once.
function projectRoots(cwd: string, projectFolders: ProjectFolder[]): ProjectFolder[] {
  const own = path.resolve(cwd);
  const out: ProjectFolder[] = [];
  for (const pf of projectFolders) {
    const folder = path.resolve(pf.folder);
    if (isInside(own, folder) || out.some((r) => r.folder === folder)) continue;
    out.push({ folder, projectId: pf.projectId });
  }
  return out;
}

// The built-in patches: the thread's folder's, then each project folder's
// that isn't the same project as one already found.
function builtins(cwd: string, home: string, roots: ProjectFolder[]): LoadedPatch[] {
  const out: LoadedPatch[] = [];
  const found = new Set<string>();
  const add = (start: string, root?: ProjectFolder) => {
    const convexDir = findUp(start, home, isConvexProject);
    if (convexDir && !found.has('convex@' + convexDir)) {
      found.add('convex@' + convexDir);
      out.push(inFolder({ info: { id: 'convex', source: 'builtin' }, panels: [convexPanel(convexDir)], actions: [], hooks: [] }, root, convexDir));
    }
    const xcodeDir = findUp(start, home, hasXcodeProject);
    if (xcodeDir && !found.has('xcode@' + xcodeDir)) {
      found.add('xcode@' + xcodeDir);
      out.push(inFolder({ info: { id: 'xcode', source: 'builtin' }, panels: [simulatorPanel(xcodeDir)], actions: [], hooks: [] }, root, xcodeDir));
    }
  };
  add(cwd);
  for (const root of roots) add(root.folder, root);
  return out;
}

// Tags a patch from a project folder with where it came from and where
// its commands run. The thread's own patches are left as they were.
function inFolder(loaded: LoadedPatch, root: ProjectFolder | undefined, infoFolder?: string): LoadedPatch {
  if (!root) return loaded;
  const tag = { projectId: root.projectId };
  return {
    info: { ...loaded.info, folder: infoFolder ?? root.folder, ...tag },
    panels: loaded.panels.map((p) => ({ ...p, ...tag })),
    actions: loaded.actions.map((a) => ({ ...a, folder: root.folder, ...tag })),
    hooks: loaded.hooks.map((h) => ({ ...h, folder: root.folder, ...tag })),
  };
}

// Adds a patch to the set; one whose name is already taken gets its
// folder's name in front ("web:convex"), and so do its items' ids.
function addPatch(set: PatchSet, loaded: LoadedPatch): void {
  let patch = loaded;
  if (set.patches.some((p) => p.id === loaded.info.id)) {
    const folder = loaded.info.folder ?? (loaded.info.file ? path.dirname(path.dirname(path.dirname(loaded.info.file))) : undefined);
    const prefix = folder ? path.basename(folder) : 'other';
    let id = `${prefix}:${loaded.info.id}`;
    for (let n = 2; set.patches.some((p) => p.id === id); n++) id = `${prefix}:${loaded.info.id}-${n}`;
    patch = renamePatch(loaded, id);
  }
  set.patches.push(patch.info);
  set.panels.push(...patch.panels);
  set.actions.push(...patch.actions);
  set.hooks.push(...patch.hooks);
}

function renamePatch(loaded: LoadedPatch, id: string): LoadedPatch {
  const from = loaded.info.id;
  const item = <T extends { id: string; patch: string }>(x: T): T => ({ ...x, id: id + x.id.slice(from.length), patch: id });
  return {
    info: { ...loaded.info, id },
    panels: loaded.panels.map(item),
    actions: loaded.actions.map(item),
    hooks: loaded.hooks.map(item),
  };
}

// Whether `dir` is `parent` or somewhere under it.
export function isInside(dir: string, parent: string): boolean {
  const rel = path.relative(parent, dir);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

// The patch folders that apply to `cwd`: the home one, then each folder
// from the top down to `cwd` itself (a deeper file wins a clash of ids, as
// the later one in the list).
export function patchDirs(cwd: string, home: string): { dir: string; source: 'home' | 'project' }[] {
  const out: { dir: string; source: 'home' | 'project' }[] = [];
  const homeDir = path.join(path.resolve(home), PATCH_DIR);
  if (isDir(homeDir)) out.push({ dir: homeDir, source: 'home' });
  const chain: string[] = [];
  findUp(cwd, home, (dir) => {
    chain.unshift(dir);
    return false;
  });
  for (const dir of chain) {
    const patchDir = path.join(dir, PATCH_DIR);
    if (patchDir !== homeDir && isDir(patchDir)) out.push({ dir: patchDir, source: 'project' });
  }
  return out;
}

function patchFiles(dir: string): string[] {
  let names: string[];
  try {
    names = fs.readdirSync(dir);
  } catch {
    return [];
  }
  return names
    .filter((n) => PATCH_EXTENSIONS.includes(path.extname(n)) && !n.endsWith('.d.ts') && !n.startsWith('.'))
    .sort()
    .map((n) => path.join(dir, n));
}

async function loadPatchFile(file: string, source: 'home' | 'project', cache: PatchCache): Promise<LoadedPatch> {
  const id = path.basename(file, path.extname(file));
  let mtimeMs: number;
  try {
    mtimeMs = fs.statSync(file).mtimeMs;
  } catch (e) {
    return { info: { id, source, file, error: String((e as Error).message ?? e) }, panels: [], actions: [], hooks: [] };
  }
  const hit = cache.get(file);
  if (hit && hit.mtimeMs === mtimeMs) return hit.loaded;
  let loaded: LoadedPatch;
  try {
    // The query makes Node load the file again after an edit: a module URL
    // is loaded once per process.
    const mod = (await import(`${pathToFileURL(file).href}?mtime=${mtimeMs}`)) as { default?: unknown };
    loaded = readPatchModule(id, source, file, mod.default);
  } catch (e) {
    loaded = { info: { id, source, file, error: firstLine(e) }, panels: [], actions: [], hooks: [] };
  }
  cache.set(file, { mtimeMs, loaded });
  return loaded;
}

// Turns a patch module's default export into actions and panels, with ids
// from the patch's name and each title. Anything malformed is an error
// for the whole file: a half-loaded patch would be confusing.
export function readPatchModule(id: string, source: 'home' | 'project', file: string, value: unknown): LoadedPatch {
  const info: PatchInfo = { id, source, file };
  const problem = (text: string): LoadedPatch => ({ info: { ...info, error: text }, panels: [], actions: [], hooks: [] });
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return problem('The default export should be an object with actions and/or panels.');
  }
  const v = value as { actions?: unknown; panels?: unknown; hooks?: unknown };
  const actions: Action[] = [];
  const panels: Panel[] = [];
  const hooks: Hook[] = [];
  if (v.actions !== undefined) {
    if (!Array.isArray(v.actions)) return problem('actions should be an array.');
    for (const [i, raw] of v.actions.entries()) {
      const a = raw as { title?: unknown; run?: unknown; prompt?: unknown; note?: unknown };
      if (!a || typeof a !== 'object' || typeof a.title !== 'string' || !a.title.trim()) return problem(`actions[${i}] needs a title.`);
      const run = typeof a.run === 'string' && a.run.trim() ? a.run : undefined;
      const prompt = typeof a.prompt === 'string' && a.prompt.trim() ? a.prompt : undefined;
      if (!run && !prompt) return problem(`actions[${i}] ("${a.title}") needs run (a command) or prompt (a message).`);
      if (run && prompt) return problem(`actions[${i}] ("${a.title}") should have run or prompt, not both.`);
      const action: Action = { id: `${id}.${slug(a.title)}`, title: a.title.trim(), kind: run ? 'command' : 'prompt', patch: id };
      if (run) action.command = run;
      if (prompt) action.prompt = prompt;
      if (typeof a.note === 'string' && a.note.trim()) action.note = a.note.trim();
      actions.push(action);
    }
  }
  if (v.panels !== undefined) {
    if (!Array.isArray(v.panels)) return problem('panels should be an array.');
    for (const [i, raw] of v.panels.entries()) {
      const p = raw as { title?: unknown; url?: unknown; note?: unknown; icon?: unknown; items?: unknown };
      if (!p || typeof p !== 'object' || typeof p.title !== 'string' || !p.title.trim()) return problem(`panels[${i}] needs a title.`);
      if (p.icon !== undefined && (typeof p.icon !== 'string' || !p.icon.trim())) return problem(`panels[${i}] ("${p.title}") has an icon that isn't an SF Symbol name.`);
      const panelId = `${id}.${slug(p.title)}`;
      let panel: Panel;
      if (typeof p.items === 'function') {
        // A list panel: rows drawn by the app, from the function, called
        // when the app asks (panels.render).
        if (p.url !== undefined) return problem(`panels[${i}] ("${p.title}") should have url or items, not both.`);
        panel = { id: panelId, title: p.title.trim(), kind: 'list', patch: id };
        listFunctions.set(listKey(file, panelId.slice(id.length)), p.items as ItemsFunction);
      } else {
        // A page the web view can open: a scheme with //, or a data: page.
        if (typeof p.url !== 'string' || !/^([a-z][a-z0-9+.-]*:\/\/\S|data:)/i.test(p.url.trim())) return problem(`panels[${i}] ("${p.title}") needs a url, or an items function.`);
        panel = { id: panelId, title: p.title.trim(), kind: 'url', url: p.url.trim(), patch: id };
      }
      if (typeof p.icon === 'string') panel.icon = p.icon.trim();
      if (typeof p.note === 'string' && p.note.trim()) panel.note = p.note.trim();
      panels.push(panel);
    }
  }
  if (v.hooks !== undefined) {
    if (!Array.isArray(v.hooks)) return problem('hooks should be an array.');
    for (const [i, raw] of v.hooks.entries()) {
      const h = raw as { title?: unknown; on?: unknown; run?: unknown; edited?: unknown; tell?: unknown; note?: unknown };
      if (!h || typeof h !== 'object' || typeof h.title !== 'string' || !h.title.trim()) return problem(`hooks[${i}] needs a title.`);
      if (h.on !== 'turn.end') return problem(`hooks[${i}] ("${h.title}") needs on: "turn.end" (the one trigger so far).`);
      if (typeof h.run !== 'string' || !h.run.trim()) return problem(`hooks[${i}] ("${h.title}") needs run (a command).`);
      if (h.tell !== undefined && h.tell !== 'failures' && h.tell !== 'always' && h.tell !== 'never') {
        return problem(`hooks[${i}] ("${h.title}") has tell "${String(h.tell)}"; it's "failures" (the default), "always" or "never".`);
      }
      if (h.edited !== undefined && (typeof h.edited !== 'string' || !h.edited.trim())) return problem(`hooks[${i}] ("${h.title}") has an edited that isn't a glob.`);
      const hook: Hook = { id: `${id}.${slug(h.title)}`, title: h.title.trim(), on: 'turn.end', command: h.run, tell: (h.tell as Hook['tell']) ?? 'failures', patch: id };
      if (typeof h.edited === 'string') hook.edited = h.edited.trim();
      if (typeof h.note === 'string' && h.note.trim()) hook.note = h.note.trim();
      hooks.push(hook);
    }
  }
  const ids = new Set<string>();
  for (const x of [...actions, ...panels, ...hooks]) {
    if (ids.has(x.id)) return problem(`Two entries would both be called ${x.id}; give them different titles.`);
    ids.add(x.id);
  }
  return { info, panels, actions, hooks };
}

// Whether a turn's edits make a hook run: no filter, or one of the edited
// paths (relative to the thread's folder) matches its glob. A hook from a
// project folder only sees edits inside that folder, and needs one.
export function hookApplies(hook: Hook, editedPaths: Iterable<string>, cwd: string): boolean {
  if (!hook.edited && !hook.folder) return true;
  const base = hook.folder ?? cwd;
  for (const p of editedPaths) {
    const rel = path.relative(base, path.resolve(cwd, p));
    if (rel.startsWith('..') || path.isAbsolute(rel)) continue;
    if (!hook.edited || path.matchesGlob(rel, hook.edited)) return true;
  }
  return false;
}

export function slug(title: string): string {
  return title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '') || 'untitled';
}

function firstLine(e: unknown): string {
  const text = String((e as Error)?.message ?? e);
  return text.split('\n').find((l) => l.trim()) ?? 'Unknown error';
}

// The built-in set alone, synchronous: what the first summary of a thread
// shows before its patch files have been read.
export function projectPanels(cwd: string, home: string = os.homedir(), projectFolders: ProjectFolder[] = []): Panel[] {
  const set: PatchSet = { panels: [], actions: [], hooks: [], patches: [] };
  for (const b of builtins(cwd, home, projectRoots(cwd, projectFolders))) addPatch(set, b);
  return set.panels;
}

// The Convex dashboard for the project's deployment. `.env.local` (what
// `convex dev` writes) wins over `.env`.
function convexPanel(dir: string): Panel {
  const deployment = readEnvValue(dir, 'CONVEX_DEPLOYMENT');
  const { url, note } = convexDashboardUrl(deployment);
  const panel: Panel = { id: 'convex.dashboard', title: 'Convex', kind: 'url', url, icon: 'cylinder.split.1x2', patch: 'convex' };
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

// A folder with its functions in convex/ and a package.json or convex.json
// beside them. A bare folder called convex isn't enough: ~/dev/convex is a
// folder of repos, and every thread under ~/dev got a dashboard panel.
export function isConvexProject(dir: string): boolean {
  if (!isDir(path.join(dir, 'convex'))) return false;
  return fs.existsSync(path.join(dir, 'package.json')) || fs.existsSync(path.join(dir, 'convex.json'));
}

function simulatorPanel(dir: string): Panel {
  return { id: 'xcode.simulator', title: 'Simulator', kind: 'image', icon: 'iphone', patch: 'xcode', note: path.basename(dir) };
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

export type PanelRender = { image?: ImageRef; items?: PanelItem[]; note?: string };

// ------------------------------------------------------------ list panels

// What a list panel's `items` gets: where it applies, and `sh` to run a
// command there (resolves with what it printed, rejects on failure).
export type ItemsContext = { cwd: string; threadId: string; sh: (command: string) => Promise<string> };
type ItemsFunction = (ctx: ItemsContext) => unknown;

// The `items` functions of loaded patch files, by file and the panel's id
// without the patch's name (".worktrees"), which stays the same when
// addPatch puts a folder's name in front of the patch's. Kept out of the
// Panel itself, which goes over the wire. A file that loads again
// replaces its entries.
const listFunctions = new Map<string, ItemsFunction>();
const listKey = (file: string, suffix: string) => `${file}\u0000${suffix}`;

export const LIST_ITEMS_KEPT = 200;
export const LIST_TIMEOUT_MS = 20_000;

// Fills a list panel by calling its patch's function. A throw, a timeout
// or something that isn't a list of rows is a note instead.
export async function renderListPanel(
  panel: Panel,
  set: PatchSet,
  ctx: { cwd: string; threadId: string; run: (command: string, cwd: string) => Promise<CommandOutcome>; timeoutMs?: number },
): Promise<PanelRender> {
  const info = set.patches.find((p) => p.id === panel.patch);
  const fn = info?.file ? listFunctions.get(listKey(info.file, panel.id.slice(panel.patch.length))) : undefined;
  if (!fn) return { note: 'This panel has nothing to show.' };
  // A project folder's patch runs in that folder, as its actions do.
  const cwd = info?.folder ?? ctx.cwd;
  const sh = async (command: string) => {
    const out = await ctx.run(command, cwd);
    if (!out.ok) throw new Error(`${command} failed${out.exitCode !== undefined ? ` (exit ${out.exitCode})` : ''}: ${out.text.trim().split('\n').pop() ?? ''}`);
    return out.text;
  };
  let timer: NodeJS.Timeout | undefined;
  try {
    const value = await Promise.race([
      Promise.resolve().then(() => fn({ cwd, threadId: ctx.threadId, sh })),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`took over ${Math.round((ctx.timeoutMs ?? LIST_TIMEOUT_MS) / 1000)} seconds`)), ctx.timeoutMs ?? LIST_TIMEOUT_MS);
      }),
    ]);
    if (!Array.isArray(value)) return { note: "The panel's items function didn't return a list." };
    return { items: value.slice(0, LIST_ITEMS_KEPT).map(panelItem).filter((x): x is PanelItem => x !== undefined) };
  } catch (e) {
    return { note: `Couldn't fill this panel: ${firstLine(e)}` };
  } finally {
    clearTimeout(timer);
  }
}

function panelItem(raw: unknown): PanelItem | undefined {
  if (typeof raw === 'string') return raw.trim() ? { title: raw.trim().slice(0, 300) } : undefined;
  if (!raw || typeof raw !== 'object') return undefined;
  const r = raw as Record<string, unknown>;
  if (typeof r.title !== 'string' || !r.title.trim()) return undefined;
  const item: PanelItem = { title: r.title.trim().slice(0, 300) };
  for (const k of ['detail', 'url', 'path', 'icon'] as const) if (typeof r[k] === 'string' && (r[k] as string).trim()) item[k] = (r[k] as string).trim().slice(0, 2000);
  if (r.tone === 'attention' || r.tone === 'failed' || r.tone === 'done') item.tone = r.tone;
  return item;
}

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

// --------------------------------------------------------------- actions

export type CommandOutcome = { ok: boolean; exitCode?: number; text: string; truncated: boolean; durationMs: number };

// How long a command action may run. Long enough for a test suite, short
// enough that a dev server started by mistake doesn't hold on for ever.
export const ACTION_TIMEOUT_MS = 10 * 60_000;

// Runs a command action's command in the thread's folder through a login
// shell (so Mike's PATH, nvm and the like apply, as in a terminal), with the
// thread's own variables, and collects what it printed. Tests pass a plain
// shell and a short timeout.
export function runCommand(
  command: string,
  opts: { cwd: string; env: Record<string, string | undefined>; shell?: string[]; timeoutMs?: number },
): Promise<CommandOutcome> {
  const started = Date.now();
  const [bin, ...args] = opts.shell ?? ['/bin/zsh', '-lc'];
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    let size = 0;
    let truncated = false;
    const limit = LIMITS.toolResultText;
    const take = (chunk: Buffer) => {
      if (size >= limit) {
        truncated = true;
        return;
      }
      const room = limit - size;
      if (chunk.length > room) {
        chunks.push(chunk.subarray(0, room));
        size += room;
        truncated = true;
      } else {
        chunks.push(chunk);
        size += chunk.length;
      }
    };
    let child;
    try {
      child = spawn(bin, [...args, command], { cwd: opts.cwd, env: opts.env as NodeJS.ProcessEnv, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
    } catch (e) {
      resolve({ ok: false, text: String((e as Error).message ?? e), truncated: false, durationMs: Date.now() - started });
      return;
    }
    const timeoutMs = opts.timeoutMs ?? ACTION_TIMEOUT_MS;
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      // The whole process group: a shell's children too.
      try {
        process.kill(-child.pid!, 'SIGTERM');
      } catch {
        child.kill('SIGTERM');
      }
    }, timeoutMs);
    child.stdout.on('data', take);
    child.stderr.on('data', take);
    const finish = (code: number | null, error?: string) => {
      clearTimeout(timer);
      let text = Buffer.concat(chunks).toString('utf8');
      if (error) text = text ? `${text}\n${error}` : error;
      if (timedOut) {
        const seconds = timeoutMs >= 10_000 ? String(Math.round(timeoutMs / 1000)) : String(timeoutMs / 1000);
        text = text.replace(/\n$/, '');
        text = `${text}${text ? '\n' : ''}Stopped after ${seconds} s.`;
      }
      resolve({
        ok: code === 0 && !timedOut && !error,
        exitCode: code ?? undefined,
        text,
        truncated,
        durationMs: Date.now() - started,
      });
    };
    child.on('error', (e) => finish(null, e.message));
    child.on('close', (code) => finish(code));
  });
}
