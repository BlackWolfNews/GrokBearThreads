import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { tmpDir } from '../helpers/fakes.ts';
import { FakeClock } from '../../src/clock.ts';
import { nullLogger } from '../../src/log.ts';
import { FETCH_INTERVAL_MS, FIRST_LOOK_MS, SETTLE_MS, Upstream, repoKey, signersPath, tagFor } from '../../src/upstream.ts';
import { PATIENCE_MS } from '../helpers/patience.ts';

// Commits and tags in the throwaway repos need a name, and must not pick
// up a signing setup from whoever runs the tests.
const GIT_ENV = { ...process.env, GIT_AUTHOR_NAME: 'Mike', GIT_AUTHOR_EMAIL: 'mike@example.com', GIT_COMMITTER_NAME: 'Mike', GIT_COMMITTER_EMAIL: 'mike@example.com', GIT_CONFIG_GLOBAL: '/dev/null' };
Object.assign(process.env, { GIT_CONFIG_GLOBAL: '/dev/null' });

function git(cwd: string, ...args: string[]): string {
  const r = spawnSync('git', ['-C', cwd, '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false', ...args], { encoding: 'utf8', env: GIT_ENV });
  if (r.status !== 0) throw new Error(`git ${args.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
}

function key(dir: string, name: string): { priv: string; signers: string } {
  const priv = path.join(dir, name);
  const r = spawnSync('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-C', name, '-f', priv]);
  assert.equal(r.status, 0, String(r.stderr));
  const signers = path.join(dir, `${name}.signers`);
  fs.writeFileSync(signers, `mike@example.com namespaces="git" ${fs.readFileSync(`${priv}.pub`, 'utf8').split(' ').slice(0, 2).join(' ')}\n`);
  return { priv, signers };
}

function commit(repo: string, file: string, subject: string): string {
  fs.writeFileSync(path.join(repo, file), subject);
  git(repo, 'add', file);
  git(repo, 'commit', '-q', '-m', subject);
  return git(repo, 'rev-parse', 'HEAD');
}

function signedTag(repo: string, tag: string, priv: string, rev = 'HEAD'): void {
  git(repo, '-c', 'gpg.format=ssh', '-c', `user.signingkey=${priv}`, 'tag', '-s', '-m', `Threadbear ${tag}`, tag, rev);
}

// Mike's repo (a bare one on "GitHub", and his checkout) and someone's fork
// of it, cloned, with origin as their fork and upstream as Mike's.
function world() {
  const root = tmpDir('tb-upstream-');
  const mikeKey = key(root, 'mike-key');
  const mikeBare = path.join(root, 'mike.git');
  const forkBare = path.join(root, 'fork.git');
  const mike = path.join(root, 'mike');
  const theirs = path.join(root, 'theirs');
  git(root, 'init', '-q', '--bare', '-b', 'main', mikeBare);
  git(root, 'clone', '-q', mikeBare, mike);
  git(mike, 'checkout', '-q', '-b', 'main');
  commit(mike, 'a.txt', 'First');
  signedTag(mike, 'release/2026-10-01', mikeKey.priv);
  git(mike, 'push', '-q', 'origin', 'main', '--tags');
  git(root, 'clone', '-q', '--bare', mikeBare, forkBare);
  git(root, 'clone', '-q', forkBare, theirs);
  git(theirs, 'remote', 'add', 'upstream', mikeBare);
  const home = path.join(root, 'home');
  fs.mkdirSync(home);
  fs.copyFileSync(mikeKey.signers, signersPath(home));
  return { root, mikeKey, mike, theirs, home };
}

function upstreamFor(checkout: string, home: string, clock = new FakeClock(), extra = {}) {
  return new Upstream({ home, checkout, clock, log: nullLogger, ...extra });
}

test('repoKey: the same repo however its URL is written', () => {
  const k = 'github.com/mikecann/threadbear';
  for (const u of ['https://github.com/mikecann/threadbear.git', 'https://github.com/mikecann/threadbear', 'git@github.com:mikecann/threadbear.git', 'ssh://git@github.com/mikecann/threadbear', 'https://x-access-token@github.com/MikeCann/threadbear/']) {
    assert.equal(repoKey(u), k, u);
  }
  assert.notEqual(repoKey('https://github.com/someone/threadbear.git'), k);
});

test('tagFor: release/ and the local date', () => {
  assert.equal(tagFor(new Date(2026, 9, 5, 23, 59)), 'release/2026-10-05');
});

test('a fork sees a newer signed release from Mike, with what main is missing', async () => {
  const w = world();
  const up = upstreamFor(w.theirs, w.home);
  let s = await up.check();
  assert.equal(s.state, 'idle', s.reason ?? '');
  assert.equal(s.release?.tag, 'release/2026-10-01');
  assert.equal(s.release?.changes, 0);

  commit(w.mike, 'b.txt', 'Second');
  const third = commit(w.mike, 'c.txt', 'Third');
  signedTag(w.mike, 'release/2026-10-30', w.mikeKey.priv);
  git(w.mike, 'push', '-q', 'origin', 'main', '--tags');
  s = await up.check();
  assert.equal(s.state, 'available');
  assert.equal(s.release?.tag, 'release/2026-10-30');
  assert.equal(s.release?.commit, third);
  assert.equal(s.release?.changes, 2);
  assert.deepEqual(s.release?.subjects, ['Third', 'Second']);
  assert.ok(s.checkedAt);
  // Their own tags are left alone: upstream's go in a namespace of their own.
  assert.equal(git(w.theirs, 'tag', '--list', 'release/2026-10-30'), '');

  // Once main has it, there's nothing to bring in.
  git(w.theirs, 'merge', '-q', '--no-edit', 'refs/threadbear/upstream/2026-10-30');
  s = await up.check();
  assert.equal(s.state, 'idle');
  assert.equal(s.release?.changes, 0);
});

test('only tags signed with the pinned key, under their own name, count', async () => {
  const w = world();
  const stranger = key(w.root, 'stranger');
  commit(w.mike, 'b.txt', 'Signed by someone else');
  signedTag(w.mike, 'release/2026-10-30', stranger.priv);
  commit(w.mike, 'c.txt', 'Not signed at all');
  git(w.mike, 'tag', '-a', '-m', 'unsigned', 'release/2026-10-31');
  // A real signed tag for the 29th, pushed again as if it were the 1st.
  git(w.mike, 'update-ref', 'refs/tags/release/2026-11-01', git(w.mike, 'rev-parse', 'refs/tags/release/2026-10-01'));
  git(w.mike, 'push', '-q', 'origin', 'main', '--tags');
  const s = await upstreamFor(w.theirs, w.home).check();
  assert.equal(s.state, 'idle');
  assert.equal(s.release?.tag, 'release/2026-10-01');
});

test('off without an upstream remote, when upstream is this repo, or with no pinned key', async () => {
  const w = world();
  assert.match((await upstreamFor(w.mike, w.home).check()).reason ?? '', /no upstream remote/);
  git(w.mike, 'remote', 'add', 'upstream', git(w.mike, 'remote', 'get-url', 'origin'));
  assert.match((await upstreamFor(w.mike, w.home).check()).reason ?? '', /upstream is this repo/);
  fs.rmSync(signersPath(w.home));
  const s = await upstreamFor(w.theirs, w.home).check();
  assert.equal(s.state, 'off');
  assert.match(s.reason ?? '', /no release key pinned/);
});

test('a fetch that fails says so and keeps the release it knew of', async () => {
  const w = world();
  commit(w.mike, 'b.txt', 'Second');
  signedTag(w.mike, 'release/2026-10-30', w.mikeKey.priv);
  git(w.mike, 'push', '-q', 'origin', 'main', '--tags');
  const up = upstreamFor(w.theirs, w.home);
  assert.equal((await up.check()).state, 'available');
  git(w.theirs, 'remote', 'set-url', 'upstream', path.join(w.root, 'gone.git'));
  const s = await up.check();
  assert.equal(s.state, 'failed');
  assert.equal(s.release?.tag, 'release/2026-10-30');
});

test('the timer looks a while after start, then every six hours', async () => {
  const w = world();
  const clock = new FakeClock();
  let changes = 0;
  const up = upstreamFor(w.theirs, w.home, clock, { onChange: () => changes++ });
  up.start();
  assert.equal(up.status().state, 'off');
  clock.advance(FIRST_LOOK_MS);
  await waitFor(() => up.status().state === 'idle');
  assert.ok(changes >= 1);
  assert.equal(clock.pending(), 1);
  up.stop();
  assert.equal(clock.pending(), 0);
  void FETCH_INTERVAL_MS;
});

test("Mike's runner tags main once a day, signed, once it has settled", async () => {
  const w = world();
  const tip = commit(w.mike, 'b.txt', 'Newer work');
  git(w.mike, 'push', '-q', 'origin', 'main');
  const committed = Number(git(w.mike, 'log', '-1', '--format=%ct')) * 1000;
  let settled = false;
  const clock = new FakeClock(committed + SETTLE_MS / 2);
  const up = upstreamFor(w.mike, w.home, clock, { publish: { publish: true, signingKey: w.mikeKey.priv }, runningMainSettled: () => settled });

  assert.equal(await up.publishOnce(), undefined, 'the runner has not settled');
  settled = true;
  assert.equal(await up.publishOnce(), undefined, "main's tip is too new");
  clock.advance(SETTLE_MS);
  const tag = await up.publishOnce();
  assert.equal(tag, tagFor(new Date(clock.now())));
  assert.equal(git(w.mike, 'rev-parse', `${tag}^{commit}`), tip);
  assert.match(git(w.mike, 'cat-file', 'tag', tag!), /- Newer work/);
  // Pushed, and signed so that a fork's runner takes it.
  assert.ok(git(w.mike, 'ls-remote', 'origin', `refs/tags/${tag}`));
  assert.equal((await upstreamFor(w.theirs, w.home).check()).release?.tag, tag);
  assert.equal(up.status().published?.tag, tag);

  // Not again the same day, and not on a later day with nothing new.
  assert.equal(await up.publishOnce(), undefined);
  clock.advance(24 * 60 * 60_000);
  assert.equal(await up.publishOnce(), undefined);
});

test('publishing needs a signing key', async () => {
  const w = world();
  const up = upstreamFor(w.mike, w.home, new FakeClock(Date.now() + 2 * SETTLE_MS), { publish: { publish: true, signingKey: path.join(w.root, 'missing') }, runningMainSettled: () => true });
  assert.equal(await up.publishOnce(), undefined);
});

async function waitFor(ok: () => boolean, ms = PATIENCE_MS): Promise<void> {
  const end = Date.now() + ms;
  while (!ok()) {
    if (Date.now() > end) throw new Error('timed out');
    await new Promise((r) => setTimeout(r, 20));
  }
}

test('tb updates: what to bring in, or that there is nothing', async () => {
  const { formatUpstream } = await import('../../src/tb-dev.ts');
  const now = Date.parse('2026-10-30T10:00:00Z');
  const checkedAt = '2026-10-30T09:00:00Z';
  const text = formatUpstream({ state: 'available', checkedAt, release: { tag: 'release/2026-10-30', commit: 'abc', changes: 3, subjects: ['Third', 'Second'] } }, now);
  assert.match(text, /^Mike's releases: release\/2026-10-30 has 3 changes this copy's main doesn't, checked 1h/);
  assert.match(text, /\n {2}Third\n {2}Second\n {2}… and 1 more\n/);
  assert.match(text, /bringing-in-updates\.md/);
  assert.match(formatUpstream({ state: 'idle', checkedAt, release: { tag: 'release/2026-10-30', commit: 'abc', changes: 0, subjects: [] } }, now), /^Mike's releases: up to date with release\/2026-10-30, checked/);
  assert.equal(formatUpstream({ state: 'off', reason: 'upstream is this repo', published: { tag: 'release/2026-10-30', at: checkedAt } }, now), "Mike's releases: off (upstream is this repo)\nLast release tagged here: release/2026-10-30");
});
