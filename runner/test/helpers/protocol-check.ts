// Checks events and summaries against docs/protocol.md. Used by the unit
// tests and the real end-to-end suite, so both hold the runner to the same
// contract the app is built against.

type Obj = Record<string, any>;

const TOOL_KINDS = ['command', 'read', 'edit', 'write', 'search', 'web', 'mcp', 'task', 'todo', 'image', 'other'];
const STATUSES = ['idle', 'starting', 'running', 'waiting', 'error', 'stopped'];
const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'];
const PROVIDERS = ['claude', 'codex'];
const ERROR_KINDS = ['usageLimit', 'contextWindow', 'auth'];
const WINDOW_KINDS = ['five_hour', 'weekly', 'weekly_model', 'daily', 'monthly', 'allowance', 'other'];
const BACKGROUND_KINDS = ['agent', 'shell', 'monitor', 'other'];

function isStr(v: unknown): v is string {
  return typeof v === 'string';
}
function isNum(v: unknown): v is number {
  return typeof v === 'number' && Number.isFinite(v);
}
function isIso(v: unknown): boolean {
  return isStr(v) && !Number.isNaN(Date.parse(v)) && v.endsWith('Z');
}
// turn.completed's usage: token counts by name (Claude's and Codex's differ).
function isTokenCounts(v: unknown): boolean {
  return Boolean(v) && typeof v === 'object' && !Array.isArray(v) && Object.values(v as Obj).every(isNum);
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
    (e.usage === undefined || isTokenCounts(e.usage)) &&
    (e.error === undefined || isStr(e.error)) &&
    (e.errorKind === undefined || ERROR_KINDS.includes(e.errorKind))
      ? null
      : 'turnId, outcome, durationMs, usage, errorKind',
  'system.note': (e) => (isStr(e.text) ? null : 'text'),
  error: (e) => (isStr(e.message) ? null : 'message'),
  'action.run': (e) =>
    isStr(e.actionId) && isStr(e.patch) && isStr(e.title) && isStr(e.command) && typeof e.ok === 'boolean' &&
    (e.exitCode === undefined || isNum(e.exitCode)) && isStr(e.text) && typeof e.truncated === 'boolean' && isNum(e.durationMs) &&
    (e.trigger === undefined || e.trigger === 'turn.end')
      ? null
      : 'actionId, patch, title, command, ok, exitCode?, text, truncated, durationMs, trigger?',
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
  if (!PROVIDERS.includes(t.provider)) problems.push('provider');
  if (t.permissionMode !== 'full' && t.permissionMode !== 'ask') problems.push('permissionMode');
  if (!STATUSES.includes(t.status)) problems.push('status');
  for (const k of ['live', 'needsYou']) if (typeof t[k] !== 'boolean') problems.push(k);
  for (const k of ['createdAt', 'updatedAt', 'lastActivityAt']) if (!isIso(t[k])) problems.push(k);
  for (const k of ['lastSeq', 'lastSeenSeq']) if (!isNum(t[k])) problems.push(k);
  if (t.preview.length > 140 || t.preview.includes('\n')) problems.push('preview too long or multi-line');
  if (t.title.length > 200) problems.push('title');
  for (const k of ['model', 'modelInUse', 'snoozedUntil', 'archivedAt', 'nativeSessionId']) if (t[k] !== undefined && !isStr(t[k])) problems.push(k);
  if (t.snoozedUntilRestart !== undefined && (t.snoozedUntilRestart !== true || !isStr(t.snoozedUntil))) problems.push('snoozedUntilRestart');
  for (const k of ['effort', 'effortInUse']) if (t[k] !== undefined && !EFFORTS.includes(t[k])) problems.push(k);
  for (const k of ['contextTokens', 'contextWindow', 'costUsd']) if (t[k] !== undefined && !isNum(t[k])) problems.push(k);
  if (t.panels !== undefined) {
    if (!Array.isArray(t.panels) || t.panels.length === 0) problems.push('panels (absent when empty)');
    else for (const p of t.panels) problems.push(...checkPanel(p).map((x) => `panels: ${x}`));
  }
  if (t.actions !== undefined) {
    if (!Array.isArray(t.actions) || t.actions.length === 0) problems.push('actions (absent when empty)');
    else for (const a of t.actions) problems.push(...checkAction(a).map((x) => `actions: ${x}`));
  }
  if (t.hooks !== undefined) {
    if (!Array.isArray(t.hooks) || t.hooks.length === 0) problems.push('hooks (absent when empty)');
    else {
      for (const h of t.hooks) {
        if (!isStr(h.id) || !isStr(h.title) || !isStr(h.patch) || h.on !== 'turn.end' || !isStr(h.command) || !['failures', 'always', 'never'].includes(h.tell)) {
          problems.push('hooks: id, title, on, command, tell, patch');
        }
        for (const k of ['edited', 'note']) if (h[k] !== undefined && !isStr(h[k])) problems.push(`hooks: ${k}`);
        for (const k of Object.keys(h)) if (!['id', 'title', 'on', 'command', 'edited', 'tell', 'patch', 'note'].includes(k)) problems.push(`hooks: unexpected field ${k}`);
      }
    }
  }
  if (t.patches !== undefined) {
    if (!Array.isArray(t.patches) || t.patches.length === 0) problems.push('patches (absent when empty)');
    else {
      for (const p of t.patches) {
        if (!isStr(p.id) || !['builtin', 'home', 'project'].includes(p.source)) problems.push('patches: id, source');
        for (const k of ['file', 'error']) if (p[k] !== undefined && !isStr(p[k])) problems.push(`patches: ${k}`);
        for (const k of Object.keys(p)) if (!['id', 'source', 'file', 'error'].includes(k)) problems.push(`patches: unexpected field ${k}`);
      }
    }
  }
  if (t.background !== undefined) {
    const ok =
      Array.isArray(t.background) &&
      t.background.length > 0 &&
      t.background.every((b: Obj) => BACKGROUND_KINDS.includes(b.kind) && isStr(b.description) && (b.finished === undefined || b.finished === true));
    if (!ok) problems.push('background');
  }
  if (t.subagents !== undefined) {
    const SUB_STATUS = ['running', 'completed', 'failed', 'stopped'];
    const subAllowed = new Set(['id', 'itemId', 'parentId', 'description', 'agentType', 'status', 'background', 'activity', 'summary', 'toolUses', 'startedAt', 'endedAt']);
    const ok =
      Array.isArray(t.subagents) &&
      t.subagents.length > 0 &&
      t.subagents.length <= 20 &&
      t.subagents.every(
        (a: Obj) =>
          isStr(a.id) &&
          isStr(a.description) &&
          SUB_STATUS.includes(a.status) &&
          typeof a.background === 'boolean' &&
          isStr(a.startedAt) &&
          (a.status === 'running') === (a.endedAt === undefined) &&
          (a.activity === undefined || a.status === 'running') &&
          Object.keys(a).every((k) => subAllowed.has(k)),
      );
    if (!ok) problems.push('subagents');
  }
  const allowed = new Set([
    'id', 'title', 'cwd', 'accountId', 'provider', 'model', 'permissionMode', 'status', 'live', 'needsYou', 'createdAt', 'updatedAt',
    'lastActivityAt', 'snoozedUntil', 'snoozedUntilRestart', 'archivedAt', 'preview', 'lastSeq', 'lastSeenSeq', 'nativeSessionId', 'contextTokens', 'costUsd',
    'effort', 'modelInUse', 'effortInUse', 'contextWindow', 'panels', 'actions', 'hooks', 'patches', 'background', 'subagents',
  ]);
  for (const k of Object.keys(t)) if (!allowed.has(k)) problems.push(`unexpected field ${k}`);
  return problems;
}

function checkModelChoice(m: Obj): string[] {
  const problems: string[] = [];
  for (const k of ['id', 'model', 'title']) if (!isStr(m?.[k])) problems.push(k);
  if (m?.description !== undefined && !isStr(m.description)) problems.push('description');
  if (m?.effortLevels !== undefined && !(Array.isArray(m.effortLevels) && m.effortLevels.every((l: unknown) => EFFORTS.includes(l as string)))) {
    problems.push('effortLevels');
  }
  if (m?.defaultEffort !== undefined && !EFFORTS.includes(m.defaultEffort)) problems.push('defaultEffort');
  return problems.map((p) => `models[${m?.id}].${p}`);
}

function checkUsage(u: Obj): string[] {
  const problems: string[] = [];
  if (!u || typeof u !== 'object') return ['usage'];
  if (!Array.isArray(u.windows)) problems.push('usage.windows');
  else {
    for (const w of u.windows) {
      if (!WINDOW_KINDS.includes(w?.kind)) problems.push('usage.windows.kind');
      if (!isStr(w?.title)) problems.push('usage.windows.title');
      if (!isNum(w?.remainingPercent) || w.remainingPercent < 0 || w.remainingPercent > 100) problems.push('usage.windows.remainingPercent');
      if (w?.resetsAt !== undefined && !isIso(w.resetsAt)) problems.push('usage.windows.resetsAt');
      if (w?.detail !== undefined && !isStr(w.detail)) problems.push('usage.windows.detail');
    }
  }
  if (!isIso(u.readAt)) problems.push('usage.readAt');
  if (u.source !== 'tokenStats' && u.source !== 'live') problems.push('usage.source');
  for (const k of ['stale', 'blocked']) if (u[k] !== undefined && typeof u[k] !== 'boolean') problems.push(`usage.${k}`);
  if (u.notice !== undefined && !isStr(u.notice)) problems.push('usage.notice');
  return problems;
}

export function checkAccount(a: Obj): string[] {
  const problems: string[] = [];
  for (const k of ['id', 'title', 'configDir']) if (!isStr(a[k])) problems.push(k);
  if (!PROVIDERS.includes(a.provider)) problems.push('provider');
  for (const k of ['defaultModel', 'email', 'plan', 'note']) if (a[k] !== undefined && !isStr(a[k])) problems.push(k);
  if (a.defaultEffort !== undefined && !EFFORTS.includes(a.defaultEffort)) problems.push('defaultEffort');
  if (a.models !== undefined) {
    if (!Array.isArray(a.models)) problems.push('models');
    else for (const m of a.models) problems.push(...checkModelChoice(m));
  }
  if (a.usage !== undefined) problems.push(...checkUsage(a.usage));
  return problems;
}

export function checkCliStatus(c: Obj): string[] {
  const problems: string[] = [];
  if (!PROVIDERS.includes(c.provider)) problems.push('provider');
  if (!isStr(c.path)) problems.push('path');
  if (!['threadbare', 'cli', 'none'].includes(c.managedBy)) problems.push('managedBy');
  if (!['current', 'behind', 'held', 'unknown', 'missing'].includes(c.status)) problems.push('status');
  if (!['auto', 'notify', 'off'].includes(c.policy)) problems.push('policy');
  for (const k of ['installedVersion', 'latestVersion', 'previousVersion']) if (c[k] !== undefined && !isStr(c[k])) problems.push(k);
  if (c.checkedAt !== undefined && !isIso(c.checkedAt)) problems.push('checkedAt');
  if (!Array.isArray(c.inUse) || !c.inUse.every((u: Obj) => isStr(u?.version) && Array.isArray(u.threadIds) && u.threadIds.every(isStr))) {
    problems.push('inUse');
  }
  if (c.hold !== undefined) {
    const h = c.hold;
    if (!isStr(h?.version) || !isStr(h?.reason) || (h.missing !== undefined && !(Array.isArray(h.missing) && h.missing.every(isStr)))) problems.push('hold');
  }
  if (c.update !== undefined) {
    const u = c.update;
    if (!['waiting', 'running', 'succeeded', 'unchanged', 'failed'].includes(u?.state)) problems.push('update.state');
    if (u?.finishedAt !== undefined && !isIso(u.finishedAt)) problems.push('update.finishedAt');
    for (const k of ['targetVersion', 'message']) if (u?.[k] !== undefined && !isStr(u[k])) problems.push(`update.${k}`);
    if (u?.waitingFor !== undefined && !(Array.isArray(u.waitingFor) && u.waitingFor.every(isStr))) problems.push('update.waitingFor');
  }
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

export function checkAction(a: Obj): string[] {
  const problems: string[] = [];
  for (const k of ['id', 'title', 'patch']) if (!isStr(a[k])) problems.push(k);
  if (a.kind !== 'command' && a.kind !== 'prompt') problems.push('kind');
  if (a.kind === 'command' && !isStr(a.command)) problems.push('command (required for kind command)');
  if (a.kind === 'prompt' && !isStr(a.prompt)) problems.push('prompt (required for kind prompt)');
  for (const k of ['command', 'prompt', 'note']) if (a[k] !== undefined && !isStr(a[k])) problems.push(k);
  const allowed = new Set(['id', 'title', 'kind', 'command', 'prompt', 'patch', 'note']);
  for (const k of Object.keys(a)) if (!allowed.has(k)) problems.push(`unexpected field ${k}`);
  return problems;
}
