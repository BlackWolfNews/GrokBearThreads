// Sessions already on disk, and opening one as a thread that will resume.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { listGrokSessions, readGrokSession } from '../../src/adapters/grok/sessions.ts';
import { FakeAccounts, FakeAdapter, makeHarness, tmpDir } from '../helpers/fakes.ts';
import { RpcError, type Account } from '../../src/protocol.ts';

function writeSession(root: string, group: string, id: string, summary: Record<string, unknown>, cwdFile?: string): void {
  const dir = path.join(root, group, id);
  fs.mkdirSync(dir, { recursive: true });
  if (cwdFile !== undefined) fs.writeFileSync(path.join(root, group, '.cwd'), cwdFile);
  fs.writeFileSync(path.join(dir, 'summary.json'), JSON.stringify(summary));
}

test('list reads summaries, skips what it cannot trust, and sorts newest first', () => {
  const home = tmpDir();
  const root = path.join(home, 'sessions');
  fs.mkdirSync(root);
  const older = '2026-11-01T00:00:00.000Z';
  const newer = '2026-11-08T08:05:19.745696Z';
  writeSession(root, encodeURIComponent('/tmp/alpha'), 'id-old', {
    info: { id: 'id-old' },
    generated_title: 'Older one',
    updated_at: older,
  });
  const work = '/tmp/real-work';
  writeSession(root, encodeURIComponent('/tmp/encoded-ignored'), 'id-new', {
    info: { id: 'id-new', cwd: work },
    generated_title: 'Newer one',
    session_summary: 'not the title',
    updated_at: newer,
    created_at: '2026-11-08T08:04:59.793797Z',
    current_model_id: 'grok-4.7',
    reasoning_effort: 'xhigh',
    num_messages: 14,
  });
  writeSession(root, 'slug-hash', 'id-marked', { info: { id: 'id-marked' }, updated_at: '2026-11-07T00:00:00.000Z' }, '/tmp/from-marker\n');
  fs.writeFileSync(path.join(root, encodeURIComponent('/tmp/alpha'), 'id-old', 'updates.jsonl'), '{"not":"read"}\n');
  fs.mkdirSync(path.join(root, encodeURIComponent('/tmp/broken'), 'id-bad'), { recursive: true });
  fs.writeFileSync(path.join(root, encodeURIComponent('/tmp/broken'), 'id-bad', 'summary.json'), '{');
  const outside = path.join(home, 'outside');
  fs.mkdirSync(path.join(outside, 'id-leak'), { recursive: true });
  fs.writeFileSync(path.join(outside, 'id-leak', 'summary.json'), JSON.stringify({
    info: { id: 'id-leak', cwd: '/tmp/leak' },
    generated_title: 'Should not list',
    updated_at: '2099-01-01T00:00:00.000Z',
  }));
  fs.symlinkSync(outside, path.join(root, 'linked-group'));
  const holder = path.join(root, encodeURIComponent('/tmp/holder'), 'id-hold');
  fs.mkdirSync(holder, { recursive: true });
  fs.writeFileSync(path.join(home, 'secret-summary.json'), JSON.stringify({
    info: { id: 'id-secret', cwd: '/tmp/secret' },
    generated_title: 'Secret',
    updated_at: '2099-01-01T00:00:00.000Z',
  }));
  fs.symlinkSync(path.join(home, 'secret-summary.json'), path.join(holder, 'summary.json'));

  const listed = listGrokSessions(root);
  assert.deepEqual(listed.map((s) => s.id), ['id-new', 'id-marked', 'id-old']);
  const newest = listed[0]!;
  assert.equal(newest.cwd, work);
  assert.equal(newest.title, 'Newer one');
  assert.equal(newest.model, 'grok-4.7');
  assert.equal(newest.effort, 'xhigh');
  assert.equal(newest.messageCount, 14);
  assert.equal(newest.createdAt, '2026-11-08T08:04:59.793797Z');
  assert.equal(listed[1]!.cwd, '/tmp/from-marker');
  assert.equal(listed[1]!.title, 'id-marked');
  assert.equal(listed[2]!.cwd, '/tmp/alpha');
  assert.equal(readGrokSession(root, 'id-old')?.title, 'Older one');
  assert.equal(readGrokSession(root, 'missing'), undefined);
  assert.equal(readGrokSession(root, 'id-leak'), undefined);
  assert.equal(readGrokSession(root, 'id-secret'), undefined);
  assert.deepEqual(listGrokSessions(path.join(home, 'no-such')), []);
});

function grokRunner(accounts?: Account[]) {
  const home = tmpDir();
  const grokHome = path.join(home, 'grok-home');
  const sessions = path.join(grokHome, 'sessions');
  fs.mkdirSync(sessions, { recursive: true });
  const work = path.join(home, 'work');
  fs.mkdirSync(work, { recursive: true });
  const grok = new FakeAdapter('grok');
  const list = accounts ?? [{ id: 'grok-main', provider: 'grok', title: 'Grok', configDir: grokHome }];
  const h = makeHarness(home, { grokMainDir: grokHome }, { adapters: { grok }, accounts: new FakeAccounts(list) });
  return { h, grok, sessions, work, home };
}

function onDisk(sessions: string, id: string, cwd: string, title = 'Already going'): void {
  writeSession(sessions, encodeURIComponent(cwd), id, {
    info: { id, cwd },
    generated_title: title,
    updated_at: '2026-11-08T08:05:19.745696Z',
    current_model_id: 'grok-4.7',
    reasoning_effort: 'xhigh',
    num_messages: 3,
  });
}

test('opening a session makes an idle thread that will resume, and refuses a bad open', () => {
  const { h, grok, sessions, work, home } = grokRunner();
  const id = '01a1ba30-7306-7f91-b9ff-2baa5b9a1fc6';
  onDisk(sessions, id, work);
  const { thread, turnId } = h.runner.create({ text: '', grokSessionId: id });
  assert.equal(turnId, '');
  assert.equal(thread.nativeSessionId, id);
  assert.equal(thread.cwd, path.resolve(work));
  assert.equal(thread.title, 'Already going');
  assert.equal(thread.status, 'idle');
  assert.equal(thread.provider, 'grok');
  assert.equal(thread.accountId, 'grok-main');
  assert.equal(thread.model, 'grok-4.7');
  assert.equal(thread.effort, 'xhigh');
  assert.equal(thread.live, false);
  assert.equal(grok.sessions.length, 0);
  const rec = h.runner.threads.get(thread.id)!.rec;
  assert.equal(rec.sessionUsed, true);
  assert.equal(rec.titleSet, true);
  assert.equal(rec.worktreePending, undefined);

  const id2 = '01a1ba30-7306-7f91-b9ff-2baa5b9a1fc7';
  onDisk(sessions, id2, work, 'Carry on');
  const sent = h.runner.create({ text: 'keep going', grokSessionId: id2 });
  assert.ok(sent.turnId);
  assert.equal(grok.last.opts.resume, true);
  assert.equal(grok.last.opts.sessionId, id2);
  assert.equal(grok.last.opts.cwd, path.resolve(work));
  assert.equal(grok.last.opts.model, 'grok-4.7');
  assert.equal(grok.last.opts.effort, 'xhigh');
  assert.ok(h.events(sent.thread.id).some((e) => e.type === 'system.note' && e.text === 'Resumed session'));

  assert.throws(() => h.runner.create({ text: '', grokSessionId: id, cwd: path.join(home, 'other') }), (e: unknown) => {
    assert.ok(e instanceof RpcError);
    assert.match(e.message, new RegExp(work.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
    return true;
  });
  assert.throws(() => h.runner.create({ text: '', grokSessionId: id }), /already thread/);
  assert.throws(() => h.runner.create({ text: 'x', grokSessionId: 'missing' }), /No Grok session/);
  assert.throws(() => h.runner.create({ text: '', grokSessionId: id2, poolId: 'main' }), /pool/);
  assert.throws(() => h.runner.create({ text: '' }), /text or images required/);

  const fresh = h.runner.create({ text: 'brand new', accountId: 'grok-main' });
  assert.equal(grok.last.opts.resume, false);
  assert.notEqual(grok.last.opts.sessionId, id);
  assert.equal(fresh.thread.nativeSessionId, undefined);
});

test('a session opens on the Grok login, and a Claude login is refused', () => {
  const home = tmpDir();
  const grokHome = path.join(home, 'grok-home');
  const accounts: Account[] = [
    { id: 'claude-main', provider: 'claude', title: 'Claude', configDir: path.join(home, 'claude') },
    { id: 'grok-main', provider: 'grok', title: 'Grok', configDir: grokHome },
  ];
  const { h, sessions, work } = grokRunner(accounts);
  const id = '01a1ba30-7306-7f91-b9ff-2baa5b9a1fc8';
  onDisk(sessions, id, work);
  const { thread } = h.runner.create({ text: '', grokSessionId: id });
  assert.equal(thread.accountId, 'grok-main');
  const otherId = '01a1ba30-7306-7f91-b9ff-2baa5b9a1fca';
  onDisk(sessions, otherId, work, 'On Claude');
  assert.throws(() => h.runner.create({ text: '', grokSessionId: otherId, accountId: 'claude-main' }), /Grok login/);

  const onlyClaude = grokRunner([{ id: 'claude-main', provider: 'claude', title: 'Claude', configDir: path.join(home, 'claude') }]);
  const other = '01a1ba30-7306-7f91-b9ff-2baa5b9a1fc9';
  onDisk(onlyClaude.sessions, other, onlyClaude.work);
  assert.throws(() => onlyClaude.h.runner.create({ text: '', grokSessionId: other }), /No Grok login/);
});
