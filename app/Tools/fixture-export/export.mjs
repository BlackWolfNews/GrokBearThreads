#!/usr/bin/env node
// Turns real Claude Code JSONL transcripts into Threadbare protocol event
// fixtures for perf runs and the mock runner. Output goes to app/.fixtures/,
// which is gitignored: these contain Mike's private conversations.
//
//   node export.mjs --pick 87,451,2114,4100      pick sessions near these row counts
//   node export.mjs --session <file.jsonl> [--name my-fixture]
//   node export.mjs --count <file.jsonl>         just print the display row count
//
// Each fixture is a folder like the runner's own thread folders:
//   <name>/thread.json     a ThreadSummary
//   <name>/events.ndjson   persisted events, one per line
//   <name>/media/          images pulled out of the transcript

import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const outRoot = path.resolve(here, '../../.fixtures');
const home = process.env.HOME ?? '';
const roots = [path.join(home, '.claude/projects')];
const accountsDir = path.join(home, 'Library/Application Support/Token Stats/Accounts');
if (fs.existsSync(accountsDir)) {
  for (const name of fs.readdirSync(accountsDir)) {
    if (/^claude-\d+$/.test(name)) roots.push(path.join(accountsDir, name, 'projects'));
  }
}

const TOOL_INPUT_LIMIT = 16 * 1024;
const TOOL_RESULT_LIMIT = 64 * 1024;

// ------------------------------------------------------------------ convert

/** Converts one JSONL transcript into protocol events. */
export async function convert(file, { threadId, mediaDir } = {}) {
  const events = [];
  let seq = 0;
  let turn = null; // { id, start, last, outcome, cost }
  let turnCount = 0;
  const seenUsage = new Set();
  const blockIndex = new Map();
  const questionIds = new Set();
  let title = '';
  let cwd = '';
  let firstTs = null;
  let lastTs = null;
  let imageCount = 0;

  const push = (fields, ts) => {
    events.push({ seq: ++seq, ts: ts ?? lastTs ?? new Date(0).toISOString(), threadId, ...(turn ? { turnId: turn.id } : {}), ...fields });
  };
  const endTurn = () => {
    if (!turn) return;
    push({
      type: 'turn.completed', turnId: turn.id, outcome: turn.outcome,
      durationMs: Math.max(0, Date.parse(turn.last) - Date.parse(turn.start)) || 0,
      ...(turn.cost > 0 ? { costUsd: Math.round(turn.cost * 10000) / 10000 } : {}),
    }, turn.last);
    turn = null;
  };
  const startTurn = (ts) => {
    endTurn();
    turnCount += 1;
    turn = { id: `turn_${turnCount}`, start: ts, last: ts, outcome: 'completed', cost: 0 };
  };
  const saveImage = (block) => {
    const source = block.source ?? {};
    if (source.type !== 'base64' || !source.data) return null;
    // Probing (no media folder) still returns a ref, so row counts include
    // the image rows the app will show.
    if (!mediaDir) return { path: '', mediaType: source.media_type ?? 'image/png' };
    const ext = { 'image/png': '.png', 'image/jpeg': '.jpg', 'image/gif': '.gif', 'image/webp': '.webp' }[source.media_type] ?? '.png';
    fs.mkdirSync(mediaDir, { recursive: true });
    const name = `img_${++imageCount}${ext}`;
    const buffer = Buffer.from(source.data, 'base64');
    fs.writeFileSync(path.join(mediaDir, name), buffer);
    return { path: `media/${name}`, mediaType: source.media_type ?? 'image/png', ...imageSize(buffer) };
  };

  const lines = readline.createInterface({ input: fs.createReadStream(file), crlfDelay: Infinity });
  for await (const line of lines) {
    if (!line.trim()) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    if (o.isSidechain) continue;
    const ts = o.timestamp ?? lastTs;
    if (o.timestamp) {
      firstTs ??= o.timestamp;
      lastTs = o.timestamp;
      if (turn) turn.last = o.timestamp;
    }
    if (!cwd && o.cwd) cwd = o.cwd;

    if (o.type === 'system') {
      if (o.subtype === 'compact_boundary') push({ type: 'system.note', text: 'Compacted the conversation' }, ts);
      continue;
    }
    if (o.type !== 'user' && o.type !== 'assistant') continue;
    const message = o.message;
    if (!message) continue;

    if (o.type === 'user') {
      if (o.isMeta || o.isCompactSummary || o.isVisibleInTranscriptOnly) continue;
      const content = typeof message.content === 'string' ? [{ type: 'text', text: message.content }] : (message.content ?? []);
      const texts = [];
      const images = [];
      for (const block of content) {
        if (block.type === 'tool_result') {
          const parts = typeof block.content === 'string' ? [{ type: 'text', text: block.content }] : (block.content ?? []);
          let text = parts.filter((p) => p.type === 'text').map((p) => p.text).join('\n');
          const resultImages = parts.filter((p) => p.type === 'image').map(saveImage).filter(Boolean);
          const truncated = Buffer.byteLength(text) > TOOL_RESULT_LIMIT;
          if (truncated) text = text.slice(0, TOOL_RESULT_LIMIT);
          if (questionIds.has(block.tool_use_id)) {
            push({ type: 'approval.resolved', approvalId: block.tool_use_id, decision: 'answered', message: text.slice(0, 500) }, ts);
          }
          push({ type: 'tool.result', itemId: block.tool_use_id, ok: !block.is_error, text, truncated, images: resultImages }, ts);
        } else if (block.type === 'text') {
          texts.push(block.text);
        } else if (block.type === 'image') {
          const image = saveImage(block);
          if (image) images.push(image);
        }
      }
      let text = texts.join('\n\n').trim();
      if (!text && !images.length) continue;
      if (/^\[Request interrupted by user/.test(text)) {
        if (turn) turn.outcome = 'interrupted';
        continue;
      }
      if (text.startsWith('<local-command-stdout>') || text.startsWith('<local-command-stderr>')) {
        const inner = text.replace(/<\/?local-command-std(out|err)>/g, '').trim();
        if (inner) push({ type: 'system.note', text: inner.slice(0, 500) }, ts);
        continue;
      }
      const command = text.match(/<command-name>([^<]*)<\/command-name>/);
      if (command) {
        const argsMatch = text.match(/<command-args>([\s\S]*?)<\/command-args>/);
        text = `${command[1]}${argsMatch && argsMatch[1].trim() ? ' ' + argsMatch[1].trim() : ''}`;
      }
      if (/^<(system-reminder|task-notification|bash-|user-memory)/.test(text)) continue;
      startTurn(ts);
      if (!title) title = text.split('\n')[0].trim().slice(0, 60);
      push({ type: 'user.message', text, images }, ts);
      push({ type: 'turn.started', turnId: turn.id }, ts);
      continue;
    }

    // assistant: one content block per line, grouped by message.id
    if (!turn) startTurn(ts);
    const id = message.id ?? o.uuid;
    if (message.usage && !seenUsage.has(id)) {
      seenUsage.add(id);
      turn.cost += estimateCost(message.usage);
    }
    if (o.isApiErrorMessage) {
      const text = (message.content ?? []).map((b) => b.text ?? '').join(' ').trim();
      push({ type: 'error', message: text || 'API error' }, ts);
      continue;
    }
    for (const block of message.content ?? []) {
      const index = blockIndex.get(id) ?? 0;
      blockIndex.set(id, index + 1);
      if (block.type === 'text') {
        if (block.text?.trim()) push({ type: 'assistant.text', itemId: `${id}:${index}`, text: block.text }, ts);
      } else if (block.type === 'thinking') {
        if (block.thinking?.trim()) push({ type: 'reasoning', itemId: `${id}:${index}`, text: block.thinking }, ts);
      } else if (block.type === 'tool_use') {
        const input = truncateStrings(block.input ?? {});
        push({ type: 'tool.call', itemId: block.id, name: block.name, kind: toolKind(block.name), title: toolTitle(block.name, block.input ?? {}), input }, ts);
        const diff = editDiff(block.id, block.name, block.input ?? {});
        if (diff) push({ type: 'edit.diff', ...diff }, ts);
        if (block.name === 'TodoWrite' && Array.isArray(block.input?.todos)) {
          push({ type: 'plan.updated', entries: block.input.todos.map((t) => ({ text: t.content ?? t.activeForm ?? '', status: t.status ?? 'pending' })) }, ts);
        }
        if (block.name === 'AskUserQuestion' && Array.isArray(block.input?.questions)) {
          questionIds.add(block.id);
          push({ type: 'question.requested', approvalId: block.id, questions: block.input.questions.map((q) => ({
            question: q.question ?? '', header: q.header, multiSelect: Boolean(q.multiSelect),
            options: (q.options ?? []).map((opt) => ({ label: opt.label ?? String(opt), description: opt.description })),
          })) }, ts);
        }
      }
    }
  }
  endTurn();
  return { events, title, cwd, firstTs, lastTs };
}

/** Display rows the app's reducer makes from these events (mirrors TranscriptModel). */
export function countRows(events) {
  const rows = new Set();
  const planTurns = new Set();
  let count = 0;
  const add = (id) => { if (!rows.has(id)) { rows.add(id); count++; } };
  for (const e of events) {
    switch (e.type) {
      case 'user.message': add(`u:${e.seq}`); break;
      case 'assistant.text': if (e.text) add(`a:${e.itemId}`); break;
      case 'reasoning': if (e.text?.trim()) add(`r:${e.itemId}`); break;
      case 'tool.call': add(`t:${e.itemId}`); break;
      case 'tool.result': add(`t:${e.itemId}`); if (e.images?.length) add(`i:${e.itemId}`); break;
      case 'approval.requested': add(`ap:${e.approvalId}`); break;
      case 'question.requested': add(`q:${e.approvalId}`); break;
      case 'plan.updated': if (!planTurns.has(e.turnId)) { planTurns.add(e.turnId); count++; } break;
      case 'turn.completed': add(`f:${e.turnId}`); break;
      case 'system.note': case 'error': count++; break;
    }
  }
  return count;
}

// ------------------------------------------------------------------ tools

function toolKind(name) {
  if (name.startsWith('mcp__')) return 'mcp';
  return {
    Bash: 'command', BashOutput: 'command', KillShell: 'command', Read: 'read', NotebookRead: 'read',
    Edit: 'edit', MultiEdit: 'edit', NotebookEdit: 'edit', Write: 'write', Grep: 'search', Glob: 'search',
    LS: 'search', WebFetch: 'web', WebSearch: 'web', Task: 'task', Agent: 'task', TodoWrite: 'todo',
  }[name] ?? 'other';
}

function toolTitle(name, input) {
  const short = (p) => String(p ?? '').replace(home, '~');
  switch (name) {
    case 'Bash': return firstLine(input.description || input.command || 'Command');
    case 'Read': return `Read ${short(input.file_path)}`;
    case 'Edit': case 'MultiEdit': return `Edit ${short(input.file_path)}`;
    case 'Write': return `Write ${short(input.file_path)}`;
    case 'Grep': return `Search for ${firstLine(input.pattern ?? '')}`;
    case 'Glob': return `Find ${input.pattern ?? ''}`;
    case 'WebFetch': return `Fetch ${input.url ?? ''}`;
    case 'WebSearch': return `Search the web for ${input.query ?? ''}`;
    case 'Task': case 'Agent': return input.description ? `Agent: ${input.description}` : 'Agent';
    case 'TodoWrite': return 'Update the plan';
    default: {
      const hint = input.command ?? input.query ?? input.url ?? input.file_path ?? input.path ?? '';
      return hint ? `${name} ${firstLine(String(hint))}` : name;
    }
  }
}

function firstLine(text) {
  const line = String(text).split('\n')[0];
  return line.length > 160 ? line.slice(0, 159) + '…' : line;
}

function truncateStrings(value) {
  if (typeof value === 'string') return value.length > TOOL_INPUT_LIMIT ? value.slice(0, TOOL_INPUT_LIMIT) : value;
  if (Array.isArray(value)) return value.map(truncateStrings);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, truncateStrings(v)]));
  return value;
}

function editDiff(itemId, name, input) {
  const file = input.file_path ?? '';
  if (name === 'Edit' && typeof input.old_string === 'string') {
    return { itemId, path: file, hunks: hunks(lines(input.old_string), lines(input.new_string ?? '')) };
  }
  if (name === 'MultiEdit' && Array.isArray(input.edits)) {
    return { itemId, path: file, hunks: input.edits.flatMap((e) => hunks(lines(e.old_string ?? ''), lines(e.new_string ?? ''))) };
  }
  if (name === 'Write' && typeof input.content === 'string') {
    const added = lines(input.content).slice(0, 2000);
    return { itemId, path: file, hunks: added.length ? [{ oldStart: 0, oldLines: 0, newStart: 1, newLines: added.length, lines: added.map((l) => '+' + l) }] : [] };
  }
  return null;
}

function lines(text) {
  const out = String(text).split('\n');
  if (out.at(-1) === '') out.pop();
  return out;
}

/** Line diff (LCS) grouped into unified hunks with 3 lines of context. */
export function hunks(a, b, context = 3) {
  if (a.length * b.length > 4_000_000) {
    // Too big to diff cheaply: show it as a replacement.
    return [{ oldStart: 1, oldLines: a.length, newStart: 1, newLines: b.length, lines: [...a.map((l) => '-' + l), ...b.map((l) => '+' + l)] }];
  }
  const n = a.length, m = b.length;
  const table = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) {
    table[i][j] = a[i] === b[j] ? table[i + 1][j + 1] + 1 : Math.max(table[i + 1][j], table[i][j + 1]);
  }
  const script = [];
  let i = 0, j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && a[i] === b[j]) { script.push([' ', i, j]); i++; j++; }
    else if (j < m && (i >= n || table[i][j + 1] >= table[i + 1][j])) { script.push(['+', i, j]); j++; }
    else { script.push(['-', i, j]); i++; }
  }
  const out = [];
  let k = 0;
  while (k < script.length) {
    while (k < script.length && script[k][0] === ' ') k++;
    if (k >= script.length) break;
    const start = Math.max(0, k - context);
    let end = k;
    let cursor = k;
    while (cursor < script.length) {
      if (script[cursor][0] !== ' ') { end = cursor; cursor++; continue; }
      let next = cursor;
      while (next < script.length && script[next][0] === ' ') next++;
      if (next < script.length && next - end <= context * 2) cursor = next; else break;
    }
    const stop = Math.min(script.length, end + context + 1);
    const hunkLines = [];
    let oldCount = 0, newCount = 0;
    for (const [mark, oi, ni] of script.slice(start, stop)) {
      if (mark === '-') { hunkLines.push('-' + a[oi]); oldCount++; }
      else if (mark === '+') { hunkLines.push('+' + b[ni]); newCount++; }
      else { hunkLines.push(' ' + a[oi]); oldCount++; newCount++; }
    }
    const [, oi, ni] = script[start];
    out.push({ oldStart: oldCount ? oi + 1 : oi, oldLines: oldCount, newStart: newCount ? ni + 1 : ni, newLines: newCount, lines: hunkLines });
    k = stop;
  }
  return out;
}

function estimateCost(usage) {
  // Rough Opus-class prices per million tokens; only used for the footer.
  const input = usage.input_tokens ?? 0;
  const output = usage.output_tokens ?? 0;
  const write = usage.cache_creation_input_tokens ?? 0;
  const read = usage.cache_read_input_tokens ?? 0;
  return (input * 5 + output * 25 + write * 6.25 + read * 0.5) / 1_000_000;
}

function imageSize(b) {
  if (b[0] === 0x89 && b[1] === 0x50 && b.length > 24) return { width: b.readUInt32BE(16), height: b.readUInt32BE(20) };
  if (b[0] === 0x47 && b[1] === 0x49) return { width: b.readUInt16LE(6), height: b.readUInt16LE(8) };
  if (b[0] === 0xff && b[1] === 0xd8) {
    let i = 2;
    while (i + 9 < b.length) {
      if (b[i] !== 0xff) { i++; continue; }
      const marker = b[i + 1];
      const length = b.readUInt16BE(i + 2);
      if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) return { width: b.readUInt16BE(i + 7), height: b.readUInt16BE(i + 5) };
      i += 2 + length;
    }
  }
  return {};
}

// ------------------------------------------------------------------ export

async function exportSession(file, name, rowsHint) {
  const threadId = `fx_${name.replace(/[^a-z0-9]+/gi, '_')}`;
  const dir = path.join(outRoot, name);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  const { events, title, cwd, firstTs, lastTs } = await convert(file, { threadId, mediaDir: path.join(dir, 'media') });
  const rows = countRows(events);
  if (rowsHint !== undefined && rowsHint !== rows) console.warn(`${name}: probe counted ${rowsHint} rows, export has ${rows}`);
  const summary = {
    id: threadId, title: title || name, cwd: cwd || path.join(home, 'dev/me/misc'), accountId: 'claude-main', provider: 'claude',
    permissionMode: 'full', status: 'idle', live: false, needsYou: false,
    createdAt: firstTs ?? new Date().toISOString(), updatedAt: lastTs ?? new Date().toISOString(), lastActivityAt: lastTs ?? new Date().toISOString(),
    preview: lastPreview(events), lastSeq: events.length, lastSeenSeq: events.length,
  };
  fs.writeFileSync(path.join(dir, 'thread.json'), JSON.stringify(summary, null, 2));
  fs.writeFileSync(path.join(dir, 'events.ndjson'), events.map((e) => JSON.stringify(e)).join('\n') + '\n');
  fs.writeFileSync(path.join(dir, 'source.txt'), `${file}\nrows: ${rows}\nevents: ${events.length}\n`);
  console.log(`${name}: ${rows} rows, ${events.length} events -> ${dir}`);
}

function lastPreview(events) {
  for (let i = events.length - 1; i >= 0; i--) {
    if (events[i].type === 'assistant.text') return events[i].text.replace(/\s+/g, ' ').slice(0, 140);
  }
  return '';
}

function listSessions() {
  const files = [];
  const walk = (dir, depth) => {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      // Subagent transcripts live in <session>/subagents; only main sessions make threads.
      if (entry.isDirectory() && depth < 1) walk(full, depth + 1);
      else if (entry.isFile() && entry.name.endsWith('.jsonl')) files.push({ file: full, size: fs.statSync(full).size });
    }
  };
  for (const root of roots) walk(root, 0);
  return files;
}

async function pick(targets) {
  const sessions = listSessions().filter((s) => s.size > 20_000);
  console.log(`${sessions.length} sessions in ${roots.length} folders`);
  const used = new Set();
  const counted = new Map();
  let bytesPerRow = 12_000;
  const count = async (s) => {
    if (!counted.has(s.file)) {
      const { events } = await convert(s.file, { threadId: 'probe' });
      const rows = countRows(events);
      counted.set(s.file, rows);
      if (rows > 20) bytesPerRow = bytesPerRow * 0.7 + (s.size / rows) * 0.3;
    }
    return counted.get(s.file);
  };
  for (const target of targets) {
    let best = null;
    for (let round = 0; round < 4 && !(best && Math.abs(best.rows - target) / target < 0.01); round++) {
      const guess = target * bytesPerRow;
      const candidates = sessions.filter((s) => !used.has(s.file))
        .sort((x, y) => Math.abs(Math.log(x.size / guess)) - Math.abs(Math.log(y.size / guess)))
        .slice(0, 150);
      for (const s of candidates) {
        const rows = await count(s);
        if (!best || Math.abs(rows - target) < Math.abs(best.rows - target)) best = { ...s, rows };
      }
    }
    if (!best) continue;
    used.add(best.file);
    await exportSession(best.file, `rows-${String(target).padStart(4, '0')}`, best.rows);
  }
}

async function main() {
  const argv = process.argv.slice(2);
  const option = (name) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
  if (option('--pick')) return pick(option('--pick').split(',').map(Number));
  if (option('--session')) {
    const file = option('--session');
    return exportSession(file, option('--name') ?? path.basename(file, '.jsonl'));
  }
  if (option('--count')) {
    const { events } = await convert(option('--count'), { threadId: 'probe' });
    console.log(`${countRows(events)} rows, ${events.length} events`);
    return;
  }
  console.log('Usage: node export.mjs --pick 87,451,2114,4100 | --session <file.jsonl> [--name n] | --count <file.jsonl>');
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => { console.error(error); process.exit(1); });
}
