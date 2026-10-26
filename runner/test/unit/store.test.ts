import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { EventLog, ThreadStore, type ThreadRecord } from '../../src/store.ts';
import { ensureHome, readToken, paths } from '../../src/config.ts';
import type { PersistedEvent } from '../../src/protocol.ts';
import { tmpDir } from '../helpers/fakes.ts';

function ev(seq: number, text = `m${seq}`): PersistedEvent {
  return { seq, ts: '2026-10-26T00:00:00.000Z', threadId: 't1', type: 'system.note', text };
}

test('event log appends with gapless seq and reads any range', () => {
  const file = path.join(tmpDir(), 'events.ndjson');
  const log = new EventLog(file);
  assert.equal(log.lastSeq, 0);
  for (let i = 1; i <= 50; i++) log.append(ev(i, `note ${i} ünïcødé`));
  assert.equal(log.lastSeq, 50);
  assert.deepEqual(
    log.read(10, 12).map((e) => e.seq),
    [10, 11, 12],
  );
  assert.equal(log.read(50, 999).length, 1);
  assert.equal(log.read(51, 60).length, 0);
  assert.equal((log.read(7, 7)[0] as { text: string }).text, 'note 7 ünïcødé');
  assert.throws(() => log.append(ev(52)), /out of order/);
  // A fresh instance rebuilds the index from the file.
  const again = new EventLog(file);
  assert.equal(again.lastSeq, 50);
  assert.deepEqual(again.read(1, 50).map((e) => e.seq), Array.from({ length: 50 }, (_, i) => i + 1));
});

test('a half-written last line from a crash is dropped on load', () => {
  const file = path.join(tmpDir(), 'events.ndjson');
  const log = new EventLog(file);
  log.append(ev(1));
  log.append(ev(2));
  fs.appendFileSync(file, '{"seq":3,"ts":"2026-10-2');
  const again = new EventLog(file);
  assert.equal(again.lastSeq, 2);
  again.append(ev(3));
  assert.deepEqual(new EventLog(file).read(1, 3).map((e) => e.seq), [1, 2, 3]);
});

test('thread store saves atomically and loads every thread', () => {
  const home = tmpDir();
  ensureHome(home);
  const store = new ThreadStore(home);
  const rec = {
    id: 'abc',
    title: 't',
    cwd: '/tmp',
    accountId: 'claude-main',
    provider: 'claude',
    permissionMode: 'full',
    status: 'idle',
    createdAt: 'x',
    updatedAt: 'x',
    lastActivityAt: 'x',
    preview: '',
    lastSeq: 0,
    lastSeenSeq: 0,
    lastTurnCompletedSeq: 0,
    queue: [],
    pendingApprovals: [],
  } as ThreadRecord;
  store.create(rec);
  assert.ok(fs.existsSync(path.join(home, 'threads', 'abc', 'media')));
  assert.ok(fs.existsSync(path.join(home, 'threads', 'abc', 'blobs')));
  rec.title = 'renamed';
  store.save(rec);
  const leftovers = fs.readdirSync(path.join(home, 'threads', 'abc')).filter((f) => f.endsWith('.tmp'));
  assert.deepEqual(leftovers, []);
  const { records: loaded, broken } = new ThreadStore(home).loadAll();
  assert.equal(loaded.length, 1);
  assert.equal(loaded[0].title, 'renamed');
  assert.deepEqual(broken, []);
});

test('data dir layout and a 0600 token', () => {
  const home = tmpDir();
  ensureHome(home);
  for (const d of ['threads', 'inbox', 'run', 'secrets']) assert.ok(fs.statSync(path.join(home, d)).isDirectory());
  const mode = fs.statSync(paths.token(home)).mode & 0o777;
  assert.equal(mode, 0o600);
  assert.equal(fs.statSync(paths.secrets(home)).mode & 0o777, 0o700);
  const token = readToken(home);
  assert.ok(token.length >= 40);
  ensureHome(home);
  assert.equal(readToken(home), token, 'token is kept across starts');
});

test('an append that fails leaves no half line behind for the next one', () => {
  const home = tmpDir();
  const file = path.join(home, 'events.ndjson');
  const log = new EventLog(file);
  log.append({ seq: 1, ts: '2026-10-26T00:00:00.000Z', threadId: 't', type: 'system.note', text: 'one' } as any);
  const size = fs.statSync(file).size;
  // A disk-full write that gets part way, then fails.
  const real = fs.appendFileSync;
  (fs as any).appendFileSync = (f: string, data: Buffer) => {
    real(f, data.subarray(0, 10));
    throw Object.assign(new Error('ENOSPC: no space left on device'), { code: 'ENOSPC' });
  };
  try {
    assert.throws(() => log.append({ seq: 2, ts: '2026-10-26T00:00:01.000Z', threadId: 't', type: 'system.note', text: 'two' } as any), /ENOSPC/);
  } finally {
    (fs as any).appendFileSync = real;
  }
  assert.equal(fs.statSync(file).size, size, 'cut back to the last whole line');
  log.append({ seq: 2, ts: '2026-10-26T00:00:01.000Z', threadId: 't', type: 'system.note', text: 'two' } as any);
  assert.deepEqual(new EventLog(file).read(1, 2).map((e: any) => e.text), ['one', 'two']);
});
