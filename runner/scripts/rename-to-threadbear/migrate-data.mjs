// One-off, 27 Oct 2026: the data side of renaming Threadbare to Threadbear
// (migrate.sh runs it). Two commands:
//
//   node migrate-data.mjs apply <backupDir>    rewrite paths, copy transcripts, trust the new folder in Codex
//   node migrate-data.mjs restore <backupDir>  put back every file apply changed
//
// apply runs after the checkout and the data dir have both moved. It
// rewrites the old checkout path and the old data dir path to the new ones
// in the runner's JSON (thread records, schedules, projects, runner.json),
// keeping each original in <backupDir> first. Transcripts (events.ndjson)
// are history and stay as they were.
//
// Claude keeps a session's transcript under projects/<cwd with every
// non-alphanumeric as ->, so a thread whose folder changed would start a new
// session instead of resuming. For each such folder and each Claude config
// dir, the old transcript folder is copied to the new name (copied, not
// moved: T3 and the archive may still read the old one).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const HOME = os.homedir();
const OLD_CHECKOUT = path.join(HOME, 'dev/me/threadbare');
const NEW_CHECKOUT = path.join(HOME, 'dev/me/threadbear');
const OLD_THREADS = path.join(HOME, 'dev/me/threadbare-threads');
const NEW_THREADS = path.join(HOME, 'dev/me/threadbear-threads');
const OLD_DATA = path.join(HOME, 'Library/Application Support/Threadbare');
const NEW_DATA = path.join(HOME, 'Library/Application Support/Threadbear');
const CODEX_CONFIG = path.join(HOME, '.codex/config.toml');
const CLAUDE_DIRS = [path.join(HOME, '.claude'), ...listDirs(path.join(HOME, 'Library/Application Support/Token Stats/Accounts'))];

const [cmd, backupDir] = process.argv.slice(2);
if (!backupDir || (cmd !== 'apply' && cmd !== 'restore')) {
  console.error('usage: node migrate-data.mjs apply|restore <backupDir>');
  process.exit(2);
}
const manifestFile = path.join(backupDir, 'manifest.json');

function log(msg) {
  console.log(`[migrate-data] ${msg}`);
}

function listDirs(dir) {
  try {
    return fs.readdirSync(dir).map((n) => path.join(dir, n)).filter((p) => fs.statSync(p).isDirectory());
  } catch {
    return [];
  }
}

// The path with the old checkout or data dir swapped for the new one; only
// the folder itself or something inside it (never ~/dev/me/threadbare-step4).
export function movePath(p) {
  for (const [from, to] of [[OLD_CHECKOUT, NEW_CHECKOUT], [OLD_THREADS, NEW_THREADS], [OLD_DATA, NEW_DATA]]) {
    if (p === from) return to;
    if (p.startsWith(from + '/')) return to + p.slice(from.length);
  }
  return p;
}

function rewrite(value, moved) {
  if (typeof value === 'string') {
    const next = movePath(value);
    if (next !== value) moved.push([value, next]);
    return next;
  }
  if (Array.isArray(value)) return value.map((v) => rewrite(v, moved));
  if (value && typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = rewrite(v, moved);
    return out;
  }
  return value;
}

function jsonFiles() {
  const files = ['runner.json', 'schedules.json', 'projects.json', 'librarian.json'].map((n) => path.join(NEW_DATA, n));
  for (const t of listDirs(path.join(NEW_DATA, 'threads'))) files.push(path.join(t, 'thread.json'));
  return files.filter((f) => fs.existsSync(f));
}

function projectDirName(cwd) {
  return cwd.replace(/[^a-zA-Z0-9]/g, '-');
}

function apply() {
  fs.mkdirSync(backupDir, { recursive: true });
  const manifest = { backups: [], created: [], codex: null };
  const cwds = new Set();
  let changedFiles = 0;
  for (const file of jsonFiles()) {
    let data;
    try {
      data = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (e) {
      log(`skipped ${file}: ${e.message}`);
      continue;
    }
    const moved = [];
    const next = rewrite(data, moved);
    if (!moved.length) continue;
    const backup = path.join(backupDir, 'files', String(manifest.backups.length));
    fs.mkdirSync(path.dirname(backup), { recursive: true });
    fs.copyFileSync(file, backup);
    manifest.backups.push({ file, backup });
    const tmp = `${file}.migrate-tmp`;
    fs.writeFileSync(tmp, JSON.stringify(next, null, 2));
    fs.renameSync(tmp, file);
    changedFiles++;
    for (const [from, to] of moved) if (!from.startsWith(OLD_DATA)) cwds.add(JSON.stringify([from, to]));
  }
  log(`rewrote paths in ${changedFiles} files`);

  let copied = 0;
  for (const pair of cwds) {
    const [from, to] = JSON.parse(pair);
    for (const dir of CLAUDE_DIRS) {
      const src = path.join(dir, 'projects', projectDirName(from));
      const dst = path.join(dir, 'projects', projectDirName(to));
      if (!fs.existsSync(src) || fs.existsSync(dst)) continue;
      fs.cpSync(src, dst, { recursive: true, preserveTimestamps: true });
      manifest.created.push(dst);
      copied++;
    }
  }
  log(`copied ${copied} Claude transcript folders`);

  // Codex asks before working in a folder it doesn't trust.
  try {
    const toml = fs.readFileSync(CODEX_CONFIG, 'utf8');
    const block = `[projects."${NEW_CHECKOUT}"]`;
    if (toml.includes(`[projects."${OLD_CHECKOUT}"]`) && !toml.includes(block)) {
      fs.copyFileSync(CODEX_CONFIG, path.join(backupDir, 'codex-config.toml'));
      fs.appendFileSync(CODEX_CONFIG, `\n${block}\ntrust_level = "trusted"\n`);
      manifest.codex = path.join(backupDir, 'codex-config.toml');
      log('trusted the new folder in Codex');
    }
  } catch (e) {
    log(`Codex config left alone: ${e.message}`);
  }
  fs.writeFileSync(manifestFile, JSON.stringify(manifest, null, 2));
}

function restore() {
  const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
  for (const { file, backup } of manifest.backups) {
    // The data dir may have moved back already.
    const target = fs.existsSync(path.dirname(file)) ? file : file.replace(NEW_DATA, OLD_DATA);
    fs.copyFileSync(backup, target);
  }
  for (const dst of manifest.created) fs.rmSync(dst, { recursive: true, force: true });
  if (manifest.codex) fs.copyFileSync(manifest.codex, CODEX_CONFIG);
  log(`restored ${manifest.backups.length} files, removed ${manifest.created.length} transcript copies`);
}

if (cmd === 'apply') apply();
else restore();
