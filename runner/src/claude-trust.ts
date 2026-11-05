// A folder's Claude Code settings that run commands by themselves
// (docs/protocol.md, "Trusting a folder's Claude Code hooks").
//
// The runner starts Claude with the folder's own settings
// (`.claude/settings.json` and `.claude/settings.local.json`) and its
// `.mcp.json`. In a terminal, Claude Code asks whether you trust a folder
// before any of that runs; the SDK never asks, so a cloned repo's
// SessionStart hook, status line or MCP server would run as the thread's
// first turn started. This finds the parts that run a command, and the
// env block (which can point Claude at another server), hashes them with
// the scripts they name, and says what Claude should be started with while
// they aren't trusted: the same settings without those parts.
//
// Trust itself is kept with the patches' (patch-trust.ts), per folder,
// under the same folder key, so a worktree counts as its main checkout.
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// The id the folder's entry has in a thread's `patches`.
export const CLAUDE_PATCH_ID = 'claude-settings';

// Settings keys whose value is a command Claude Code runs by itself, from
// the SDK's Settings type (0.3.310). Left out: those Claude only reads
// from user or managed settings (processWrapper, policyHelper,
// sshHostCommands), and enabledPlugins, which only turns on plugins you
// installed yourself. extraKnownMarketplaces is in: a marketplace can be
// fetched by a command, or with a headersHelper.
export const COMMAND_KEYS = [
  'hooks',
  'statusLine',
  'subagentStatusLine',
  'fileSuggestion',
  'apiKeyHelper',
  'proxyAuthHelper',
  'awsCredentialExport',
  'awsAuthRefresh',
  'gcpAuthRefresh',
  'otelHeadersHelper',
  'extraKnownMarketplaces',
] as const;

// Asked about with the commands, though nothing in it runs by itself:
// `env`, which Claude sets for the session and everything it starts. Any
// variable there can send Mike's prompts and login elsewhere
// (ANTHROPIC_BASE_URL, ANTHROPIC_API_KEY, HTTPS_PROXY,
// CLAUDE_CODE_USE_BEDROCK with its endpoint, OTEL_* exporters) or load
// code (NODE_OPTIONS, PATH), and new ones come with each release, so the
// whole block counts rather than a list of known ones.
export const ASK_KEYS = [...COMMAND_KEYS, 'env'] as const;

// Settings Claude ignores when a repo sets them but takes from flag
// settings (SDK 0.3.310's Settings docs), which is how the rest of an
// untrusted folder's settings reach the session: so they're dropped from
// that copy, or a repo would get them through it. `sandbox` ones are paths
// under it; ripgrep is a command.
const PROJECT_IGNORED = ['autoMemoryDirectory', 'modelPicker', 'footerLinksRegexes', 'spellcheck'];
const PROJECT_IGNORED_SANDBOX = [
  ['ripgrep'],
  ['filesystem', 'disabled'],
  ['network', 'strictAllowlist'],
  ['credentials', 'allowPlaintextInject'],
  ['credentials', 'awsPairs'],
  ['credentials', 'sigv4'],
];

const SETTINGS_FILES = ['.claude/settings.json', '.claude/settings.local.json'];

// At most this many scripts named by the commands are hashed.
const MAX_NAMED = 100;

export type ClaudeCommands = {
  // The files that have something that runs (absolute), settings first.
  files: string[];
  // Scripts the commands name, inside the folder (absolute), hashed too.
  named: string[];
  hash: string;
  // Each of those files by the hash of the bytes the hash was made from,
  // so an agent's edit can be matched to exactly what it wrote.
  read: Record<string, string>;
};

// What in `cwd`'s Claude Code settings runs a command, or undefined when
// nothing does (no prompt, nothing changes). `home` bounds the search for
// `.mcp.json`, which Claude reads from the folder and the ones above it.
export function claudeCommands(cwd: string, home: string = os.homedir()): ClaudeCommands | undefined {
  const dir = path.resolve(cwd);
  // In home, the folder's settings are Mike's own user settings.
  if (realpath(dir) === realpath(path.resolve(home))) return undefined;
  const parts: Record<string, unknown> = {};
  const files: string[] = [];
  const shas: Record<string, string> = {};
  for (const rel of SETTINGS_FILES) {
    const file = path.join(dir, rel);
    const read = readJson(file);
    if (read === undefined) continue;
    // One Claude may read differently than JSON.parse (a comment, a stray
    // comma) is asked about whole: what it would run can't be told apart.
    const found = read.ok ? commandParts(read.value) : { unreadable: read.text };
    if (!found) continue;
    parts[rel] = found;
    files.push(file);
    shas[file] = read.sha256;
  }
  for (const file of mcpFiles(dir, home)) {
    const read = readJson(file);
    if (read === undefined) continue;
    const found = read.ok ? mcpCommandParts(read.value) : { unreadable: read.text };
    if (!found) continue;
    parts[path.relative(dir, file)] = found;
    files.push(file);
    shas[file] = read.sha256;
  }
  if (!files.length) return undefined;
  const named = namedScripts(parts, dir);
  // Relative to the folder, so a worktree and its main checkout agree.
  const lines = named
    .map((f) => {
      const h = sha256(readOr(f));
      shas[f] ??= h;
      return `${path.relative(dir, f)} ${h}`;
    })
    .sort();
  const hash = sha256(Buffer.from(['threadbear-claude-1', stableJson(parts), ...lines].join('\n')));
  return { files, named, hash, read: shas };
}

// The folder's project and local settings merged, without the parts that
// run a command or set the environment: what Claude is given (as flag
// settings) while they aren't trusted, so permissions and the rest still
// apply.
export function claudeSettingsWithoutCommands(cwd: string): Record<string, unknown> {
  let out: Record<string, unknown> = {};
  for (const rel of SETTINGS_FILES) {
    const read = readJson(path.join(path.resolve(cwd), rel));
    if (!read?.ok || !isObject(read.value)) continue;
    const rest = { ...read.value };
    for (const k of [...ASK_KEYS, ...PROJECT_IGNORED]) delete rest[k];
    // Not settings: the schema link editors use.
    delete rest.$schema;
    if (isObject(rest.sandbox)) rest.sandbox = withoutPaths(rest.sandbox, PROJECT_IGNORED_SANDBOX);
    out = merge(out, rest);
  }
  return out;
}

// `obj` without the keys at `paths`, copying only what it changes.
function withoutPaths(obj: Record<string, unknown>, paths: string[][]): Record<string, unknown> {
  const out = { ...obj };
  for (const [head, ...tail] of paths) {
    if (!(head in out)) continue;
    if (!tail.length) delete out[head];
    else if (isObject(out[head])) out[head] = withoutPaths(out[head], [tail]);
  }
  return out;
}

// Whether `file` is one claudeCommands reads for `cwd`.
export function isClaudeSettingsFile(file: string, cwd: string, home: string = os.homedir()): boolean {
  const target = path.resolve(file);
  const dir = path.resolve(cwd);
  return SETTINGS_FILES.some((rel) => path.join(dir, rel) === target) || mcpFiles(dir, home).includes(target);
}

function commandParts(value: unknown): Record<string, unknown> | undefined {
  if (!isObject(value)) return undefined;
  const out: Record<string, unknown> = {};
  for (const k of ASK_KEYS) if (hasContent(value[k])) out[k] = value[k];
  return Object.keys(out).length ? out : undefined;
}

// The servers in an .mcp.json that Claude starts as a local command, or
// fetches headers for with one.
function mcpCommandParts(value: unknown): Record<string, unknown> | undefined {
  const servers = isObject(value) && isObject(value.mcpServers) ? value.mcpServers : undefined;
  if (!servers) return undefined;
  const out: Record<string, unknown> = {};
  for (const [name, s] of Object.entries(servers)) {
    if (isObject(s) && (hasContent(s.command) || hasContent(s.headersHelper))) out[name] = s;
  }
  return Object.keys(out).length ? { mcpServers: out } : undefined;
}

// `.mcp.json` in the folder and each one above it, below home.
function mcpFiles(dir: string, home: string): string[] {
  const stop = path.resolve(home);
  const out: string[] = [];
  for (let d = dir; d !== stop && d !== path.dirname(d); d = path.dirname(d)) {
    const f = path.join(d, '.mcp.json');
    if (isFile(f)) out.push(f);
  }
  return out;
}

// Files inside the folder that a command names (`bun .claude/hooks/x.mjs`,
// `"$CLAUDE_PROJECT_DIR"/scripts/y.sh`, an MCP server's args), hashed as
// they are and not followed, as patch trust hashes the scripts a patch
// names: a pull that changes only the script asks again.
function namedScripts(parts: unknown, dir: string): string[] {
  const out = new Set<string>();
  const strings: string[] = [];
  const walk = (v: unknown) => {
    if (typeof v === 'string') strings.push(v);
    else if (Array.isArray(v)) v.forEach(walk);
    else if (isObject(v)) Object.values(v).forEach(walk);
  };
  walk(parts);
  for (const s of strings) {
    const text = s.replace(/\$\{?CLAUDE_PROJECT_DIR\}?/g, dir);
    for (const raw of text.split(/[\s'"`;&|()<>=]+/)) {
      if (!raw.includes('/') || raw.startsWith('~')) continue;
      const target = path.resolve(dir, raw);
      if (!isInside(target, dir) || !isFile(target)) continue;
      out.add(target);
      if (out.size >= MAX_NAMED) return [...out];
    }
  }
  return [...out];
}

function readJson(file: string): { ok: true; value: unknown; sha256: string } | { ok: false; text: string; sha256: string } | undefined {
  let bytes: Buffer;
  try {
    bytes = fs.readFileSync(file);
  } catch {
    return undefined;
  }
  const text = bytes.toString('utf8');
  try {
    return { ok: true, value: JSON.parse(text), sha256: sha256(bytes) };
  } catch {
    return text.trim() ? { ok: false, text, sha256: sha256(bytes) } : undefined;
  }
}

// Objects merge key by key, lists join (Claude's own merge of permission
// rules across settings files), anything else the later wins.
function merge(a: Record<string, unknown>, b: Record<string, unknown>): Record<string, unknown> {
  const out = { ...a };
  for (const [k, v] of Object.entries(b)) {
    const was = out[k];
    if (isObject(was) && isObject(v)) out[k] = merge(was, v);
    else if (Array.isArray(was) && Array.isArray(v)) out[k] = [...was, ...v.filter((x) => !was.some((y) => JSON.stringify(y) === JSON.stringify(x)))];
    else out[k] = v;
  }
  return out;
}

function hasContent(v: unknown): boolean {
  if (v === undefined || v === null || v === false || v === '') return false;
  if (Array.isArray(v)) return v.some(hasContent);
  if (isObject(v)) return Object.values(v).some(hasContent);
  return true;
}

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function stableJson(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(stableJson).join(',')}]`;
  if (isObject(v)) return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${stableJson(v[k])}`).join(',')}}`;
  return JSON.stringify(v) ?? 'null';
}

function isFile(p: string): boolean {
  try {
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
}

function isInside(p: string, dir: string): boolean {
  const rel = path.relative(dir, p);
  return rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel);
}

function realpath(p: string): string {
  try {
    return fs.realpathSync(p);
  } catch {
    return p;
  }
}

function readOr(file: string): Buffer {
  try {
    return fs.readFileSync(file);
  } catch {
    return Buffer.from('missing');
  }
}

function sha256(data: Buffer): string {
  return crypto.createHash('sha256').update(data).digest('hex');
}
