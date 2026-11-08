// Grok sessions already on disk. `grok sessions list` only shows the
// folder it was started in, so this walks ~/.grok/sessions itself.
// summary.json is the index. updates.jsonl is the conversation, and
// this file does not read it: opening a session loads that log inside
// Grok, on the next message.
import fs from 'node:fs';
import path from 'node:path';

export type GrokSessionSummary = {
  id: string;
  cwd: string;
  title: string;
  updatedAt: string;
  createdAt?: string;
  model?: string;
  effort?: string;
  messageCount?: number;
};

const MAX_SUMMARY_BYTES = 1024 * 1024;

// Newest first. A summary that cannot be read is left out, as is anything
// that is not a real directory under `root` (a symlink out of the tree).
export function listGrokSessions(root: string): GrokSessionSummary[] {
  const base = realDir(root);
  if (!base) return [];
  let groups: fs.Dirent[];
  try {
    groups = fs.readdirSync(base, { withFileTypes: true });
  } catch {
    return [];
  }
  const out: GrokSessionSummary[] = [];
  for (const group of groups) {
    if (!group.isDirectory()) continue;
    const groupPath = path.join(base, group.name);
    const groupReal = realDir(groupPath);
    if (!groupReal || !inside(base, groupReal)) continue;
    const fallbackCwd = cwdFromGroup(groupReal, group.name);
    let sessions: fs.Dirent[];
    try {
      sessions = fs.readdirSync(groupReal, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const ent of sessions) {
      if (!ent.isDirectory()) continue;
      const dirReal = realDir(path.join(groupReal, ent.name));
      if (!dirReal || !inside(groupReal, dirReal)) continue;
      const info = readSummary(path.join(dirReal, 'summary.json'), dirReal, fallbackCwd);
      if (info) out.push(info);
    }
  }
  out.sort((a, b) => (b.updatedAt || '').localeCompare(a.updatedAt || '') || a.id.localeCompare(b.id));
  return out;
}

export function readGrokSession(root: string, id: string): GrokSessionSummary | undefined {
  const want = id.trim();
  if (!want) return undefined;
  return listGrokSessions(root).find((s) => s.id === want);
}

function readSummary(file: string, dirReal: string, fallbackCwd: string | undefined): GrokSessionSummary | undefined {
  let real: string;
  try {
    const st = fs.lstatSync(file);
    if (!st.isFile() && !st.isSymbolicLink()) return undefined;
    if (st.isFile() && st.size > MAX_SUMMARY_BYTES) return undefined;
    real = fs.realpathSync(file);
  } catch {
    return undefined;
  }
  // A summary that points outside this session's own folder is not listed.
  if (!inside(dirReal, real)) return undefined;
  let raw: string;
  try {
    const st = fs.statSync(real);
    if (!st.isFile() || st.size > MAX_SUMMARY_BYTES) return undefined;
    raw = fs.readFileSync(real, 'utf8');
  } catch {
    return undefined;
  }
  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch {
    return undefined;
  }
  if (!data || typeof data !== 'object') return undefined;
  const o = data as Record<string, unknown>;
  const info = o.info && typeof o.info === 'object' ? (o.info as Record<string, unknown>) : {};
  const id = text(info.id);
  if (!id) return undefined;
  const cwd = text(info.cwd) ?? fallbackCwd;
  if (!cwd) return undefined;
  const updatedAt = text(o.updated_at) ?? text(o.created_at) ?? '';
  const createdAt = text(o.created_at);
  const model = text(o.current_model_id);
  const effort = text(o.reasoning_effort);
  const messageCount = count(o.num_messages);
  const summary: GrokSessionSummary = {
    id,
    cwd,
    title: (text(o.generated_title) ?? text(o.session_summary) ?? id).replace(/\s+/g, ' '),
    updatedAt,
  };
  if (createdAt) summary.createdAt = createdAt;
  if (model) summary.model = model;
  if (effort) summary.effort = effort;
  if (messageCount !== undefined) summary.messageCount = messageCount;
  return summary;
}

// The group directory is the working directory, URL-encoded. A name that
// was too long to encode is a slug, and the path is in `.cwd` beside the
// session folders.
function cwdFromGroup(groupDir: string, name: string): string | undefined {
  try {
    const marked = fs.readFileSync(path.join(groupDir, '.cwd'), 'utf8').trim();
    if (marked) return marked;
  } catch {
    /* no marker: the directory name is the path */
  }
  try {
    const decoded = decodeURIComponent(name);
    if (decoded.startsWith('/')) return decoded;
  } catch {
    /* a name that is not encoded */
  }
  return undefined;
}

function realDir(p: string): string | undefined {
  try {
    const st = fs.lstatSync(p);
    if (!st.isDirectory()) return undefined;
    return fs.realpathSync(p);
  } catch {
    return undefined;
  }
}

function inside(root: string, real: string): boolean {
  return real === root || real.startsWith(root + path.sep);
}

function text(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined;
  const t = v.trim();
  return t || undefined;
}

function count(v: unknown): number | undefined {
  if (typeof v !== 'number' || !Number.isFinite(v) || v < 0) return undefined;
  return Math.floor(v);
}
