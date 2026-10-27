// Checks events and summaries against docs/protocol.md. Used by the unit
// tests and the real end-to-end suite, so both hold the runner to the same
// contract the app is built against.

type Obj = Record<string, any>;

const TOOL_KINDS = ['command', 'read', 'edit', 'write', 'search', 'web', 'mcp', 'task', 'todo', 'other'];
const STATUSES = ['idle', 'starting', 'running', 'waiting', 'error', 'stopped'];
const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max'];

function isStr(v: unknown): v is string {
  return typeof v === 'string';
}
function isNum(v: unknown): v is number {
  return typeof v === 'number' && Number.isFinite(v);
}
function isIso(v: unknown): boolean {
  return isStr(v) && !Number.isNaN(Date.parse(v)) && v.endsWith('Z');
}
function isImageRef(v: Obj): boolean {
  return v && isStr(v.path) && v.path.startsWith('/') && isStr(v.mediaType) && (v.width === undefined || isNum(v.width)) && (v.height === undefined || isNum(v.height));
}

const PERSISTED: Record<string, (e: Obj) => string | null> = {
  'user.message': (e) => (isStr(e.text) && Array.isArray(e.images) && e.images.every(isImageRef) ? null : 'text, images'),
  'assistant.text': (e) => (isStr(e.itemId) && isStr(e.text) ? null : 'itemId, text'),
  reasoning: (e) => (isStr(e.itemId) && isStr(e.text) ? null : 'itemId, text'),
  'tool.call': (e) =>
    isStr(e.itemId) && isStr(e.name) && TOOL_KINDS.includes(e.kind) && isStr(e.title) && !e.title.includes('\n') && e.input && typeof e.input === 'object'
      ? null
      : 'itemId, name, kind, title, input',
  'tool.result': (e) =>
    isStr(e.itemId) &&
    typeof e.ok === 'boolean' &&
    isStr(e.text) &&
    Buffer.byteLength(e.text) <= 64 * 1024 &&
    typeof e.truncated === 'boolean' &&
    (e.blobPath === undefined || isStr(e.blobPath)) &&
    Array.isArray(e.images) &&
    e.images.every(isImageRef)
      ? null
      : 'itemId, ok, text<=64KB, truncated, images',
  'edit.diff': (e) =>
    isStr(e.itemId) &&
    isStr(e.path) &&
    Array.isArray(e.hunks) &&
    e.hunks.every(
      (h: Obj) =>
        isNum(h.oldStart) &&
        isNum(h.oldLines) &&
        isNum(h.newStart) &&
        isNum(h.newLines) &&
        Array.isArray(h.lines) &&
        h.lines.every((l: unknown) => isStr(l) && [' ', '-', '+'].includes(l[0])),
    )
      ? null
      : 'itemId, path, hunks',
  'approval.requested': (e) =>
    isStr(e.approvalId) &&
    (e.itemId === undefined || isStr(e.itemId)) &&
    isStr(e.name) &&
    isStr(e.title) &&
    e.input &&
    Array.isArray(e.options) &&
    e.options.every((o: string) => ['allow', 'allowAlways', 'deny'].includes(o))
      ? null
      : 'approvalId, name, title, input, options',
  'question.requested': (e) =>
    isStr(e.approvalId) &&
    Array.isArray(e.questions) &&
    e.questions.every(
      (q: Obj) =>
        isStr(q.question) &&
        typeof q.multiSelect === 'boolean' &&
        (q.header === undefined || isStr(q.header)) &&
        Array.isArray(q.options) &&
        q.options.every((o: Obj) => isStr(o.label) && (o.description === undefined || isStr(o.description))),
    )
      ? null
      : 'approvalId, questions',
  'approval.resolved': (e) =>
    isStr(e.approvalId) && ['allow', 'allowAlways', 'deny', 'answered', 'expired'].includes(e.decision) && (e.message === undefined || isStr(e.message))
      ? null
      : 'approvalId, decision',
  'plan.updated': (e) =>
    Array.isArray(e.entries) && e.entries.every((x: Obj) => isStr(x.text) && ['pending', 'in_progress', 'completed'].includes(x.status)) ? null : 'entries',
  'turn.started': (e) => (isStr(e.turnId) ? null : 'turnId'),
  'turn.completed': (e) =>
    isStr(e.turnId) &&
    ['completed', 'interrupted', 'failed'].includes(e.outcome) &&
    isNum(e.durationMs) &&
    (e.costUsd === undefined || isNum(e.costUsd)) &&
    (e.error === undefined || isStr(e.error))
      ? null
      : 'turnId, outcome, durationMs',
  'system.note': (e) => (isStr(e.text) ? null : 'text'),
  error: (e) => (isStr(e.message) ? null : 'message'),
};

const TRANSIENT: Record<string, (e: Obj) => string | null> = {
  'assistant.text.delta': (e) => (isStr(e.itemId) && isStr(e.text) ? null : 'itemId, text'),
  'reasoning.delta': (e) => (isStr(e.itemId) && isStr(e.text) ? null : 'itemId, text'),
  'tool.output.delta': (e) => (isStr(e.itemId) && isStr(e.text) ? null : 'itemId, text'),
};

// Returns a list of problems (empty when the event is fine).
export function checkEvent(e: Obj): string[] {
  const problems: string[] = [];
  if (!isNum(e.seq) || e.seq < 0) problems.push('seq');
  if (!isIso(e.ts)) problems.push('ts');
  if (!isStr(e.threadId)) problems.push('threadId');
  if (e.turnId !== undefined && !isStr(e.turnId)) problems.push('turnId');
  const check = PERSISTED[e.type] ?? TRANSIENT[e.type];
  if (!check) problems.push(`unknown type ${e.type}`);
  else {
    const p = check(e);
    if (p) problems.push(`${e.type}: ${p}`);
  }
  return problems;
}

export function isTransient(e: Obj): boolean {
  return e.type in TRANSIENT;
}

// Persisted events must arrive in seq order with no gaps; transient ones
// carry the seq of the last persisted event.
export function checkSequence(events: Obj[], startAfter = 0): string[] {
  const problems: string[] = [];
  let last = startAfter;
  for (const e of events) {
    problems.push(...checkEvent(e).map((p) => `seq ${e.seq}: ${p}`));
    if (isTransient(e)) {
      if (e.seq !== last) problems.push(`transient ${e.type} has seq ${e.seq}, expected ${last}`);
    } else {
      if (e.seq !== last + 1) problems.push(`gap: ${e.type} has seq ${e.seq} after ${last}`);
      last = e.seq;
    }
  }
  return problems;
}

export function checkSummary(t: Obj): string[] {
  const problems: string[] = [];
  for (const k of ['id', 'title', 'cwd', 'accountId', 'preview']) if (!isStr(t[k])) problems.push(k);
  if (t.provider !== 'claude') problems.push('provider');
  if (t.permissionMode !== 'full' && t.permissionMode !== 'ask') problems.push('permissionMode');
  if (!STATUSES.includes(t.status)) problems.push('status');
  for (const k of ['live', 'needsYou']) if (typeof t[k] !== 'boolean') problems.push(k);
  for (const k of ['createdAt', 'updatedAt', 'lastActivityAt']) if (!isIso(t[k])) problems.push(k);
  for (const k of ['lastSeq', 'lastSeenSeq']) if (!isNum(t[k])) problems.push(k);
  if (t.preview.length > 140 || t.preview.includes('\n')) problems.push('preview too long or multi-line');
  if (t.title.length > 200) problems.push('title');
  for (const k of ['model', 'modelInUse', 'snoozedUntil', 'archivedAt', 'nativeSessionId']) if (t[k] !== undefined && !isStr(t[k])) problems.push(k);
  for (const k of ['effort', 'effortInUse']) if (t[k] !== undefined && !EFFORTS.includes(t[k])) problems.push(k);
  for (const k of ['contextTokens', 'costUsd']) if (t[k] !== undefined && !isNum(t[k])) problems.push(k);
  if (t.panels !== undefined) {
    if (!Array.isArray(t.panels) || t.panels.length === 0) problems.push('panels (absent when empty)');
    else for (const p of t.panels) problems.push(...checkPanel(p).map((x) => `panels: ${x}`));
  }
  const allowed = new Set([
    'id', 'title', 'cwd', 'accountId', 'provider', 'model', 'permissionMode', 'status', 'live', 'needsYou', 'createdAt', 'updatedAt',
    'lastActivityAt', 'snoozedUntil', 'archivedAt', 'preview', 'lastSeq', 'lastSeenSeq', 'nativeSessionId', 'contextTokens', 'costUsd',
    'effort', 'modelInUse', 'effortInUse', 'panels',
  ]);
  for (const k of Object.keys(t)) if (!allowed.has(k)) problems.push(`unexpected field ${k}`);
  return problems;
}

export function checkPanel(p: Obj): string[] {
  const problems: string[] = [];
  for (const k of ['id', 'title', 'patch']) if (!isStr(p[k])) problems.push(k);
  if (p.kind !== 'url' && p.kind !== 'image') problems.push('kind');
  if (p.kind === 'url' && !isStr(p.url)) problems.push('url (required for kind url)');
  for (const k of ['url', 'note']) if (p[k] !== undefined && !isStr(p[k])) problems.push(k);
  const allowed = new Set(['id', 'title', 'kind', 'url', 'patch', 'note']);
  for (const k of Object.keys(p)) if (!allowed.has(k)) problems.push(`unexpected field ${k}`);
  return problems;
}
