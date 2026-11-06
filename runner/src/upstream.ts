// Mike's releases, for everyone's own copy of Threadbear
// (docs/setup-and-updates.md section 2.3).
//
// Everyone else's copy is a fork: `origin` is theirs and `upstream` is
// mikecann/threadbear. Their runner fetches upstream's release tags every
// six hours and says when there's a newer one than their main has, for the
// Updates panel's "new changes from Mike" and `tb updates`. Bringing it in
// is a thread they start (docs/bringing-in-updates.md); nothing here ever
// changes their main.
//
// Only tags signed with the key setup pinned (<home>/upstream-signers,
// copied from scripts/release-signers at setup) count. The pinned copy is
// the one that matters: a key changed in the repo, or a hijacked GitHub
// account, can't get code onto anyone's Mac this way. So the check is an
// SSH signature by that key and nothing else: the runner splits the tag
// itself and asks ssh-keygen, never `git verify-tag`, which hands a PGP or
// X.509 signature to gpg and the whole keyring whatever gpg.format says
// (Gautam's scan, 6 Nov 2026, F5).
//
// Tags are fetched into a staging namespace nobody merges from, and copied
// to refs/threadbear/upstream/ only once they verify; a release there is
// never moved to another object, so a tag swapped upstream after it was
// checked can't change what a bring-in thread merges (F31). Those threads
// are told the verified commit id, and merge that.
//
// Mike's own runner (runner.json `releases.publish`) makes the tags: once
// a day, if main has moved since the last one, it tags main's tip as
// release/YYYY-MM-DD, signed, and pushes the tag. Only a main it's safe to
// hand on: the runner it's running is main's, has been marked good and up
// for an hour, and main's tip is an hour old, so a commit that crashes
// the runner or is about to be followed by its fix isn't what goes out.
import { execFile, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { Clock, TimerHandle } from './clock.ts';
import type { Logger } from './log.ts';

export const FETCH_INTERVAL_MS = 6 * 60 * 60_000;
export const PUBLISH_INTERVAL_MS = 60 * 60_000;
// The first look, a while after the runner starts: never in the way of a
// start that's about to be rolled back.
export const FIRST_LOOK_MS = 2 * 60_000;
// How long main's tip and the running release must have settled before
// Mike's runner tags it.
export const SETTLE_MS = 60 * 60_000;
export const TAG_PREFIX = 'release/';
// Where upstream's release tags are fetched to, as they are: unchecked,
// and moved by every fetch. Nothing merges from here.
const INCOMING_NS = 'refs/threadbear/upstream-incoming/';
// The releases that verified, copied from INCOMING_NS and never moved once
// there. Their own namespaces, so the fork's own tags are never touched.
const REF_NS = 'refs/threadbear/upstream/';
const MAX_SUBJECTS = 50;
// What a release's name is after release/: the local date it was tagged
// (tagFor). Nothing else is ever looked at.
const RELEASE_NAME = /^\d{4}-\d{2}-\d{2}$/;
// How far past today's date (UTC) a release's date can be: Mike's day can
// start well before the fork's.
const FUTURE_SLACK_MS = 2 * 24 * 60 * 60_000;
const MAX_ANSWERS = 10_000;
// The most tags one check reads that it hasn't read before.
const MAX_READS = 20;

// A release tag's message lists at most 200 subjects (publishOnce), a few
// tens of KB; a bigger tag object is turned down unread.
const MAX_TAG_BYTES = 1024 * 1024;

type Ref = { oid: string; type: string; size: number };

function readable(ref: Ref): boolean {
  return ref.type === 'tag' && ref.size > 0 && ref.size <= MAX_TAG_BYTES;
}

export type UpstreamRelease = {
  tag: string; // release/2026-10-30
  commit: string;
  date?: string; // the tag's date, ISO
  changes: number; // commits in it that main doesn't have, merges left out
  subjects: string[]; // their subject lines, newest first, at most 50
  // Commits in it Mike marked with an `Important:` trailer (a security or
  // data fix), saying why. They're covered by the tag's signature, as the
  // signed tag names the commit and so its whole history. bring-in.ts
  // starts a thread for these straight away rather than on its timer.
  important?: { commit: string; why: string }[];
};

// runner.status's `upstream`, and RunnerUpdates' (docs/protocol.md).
export type UpstreamStatus = {
  // off: no upstream remote, upstream is this repo, or no pinned key;
  // idle: main has the newest release; available: it doesn't.
  state: 'off' | 'idle' | 'checking' | 'available' | 'failed';
  reason?: string;
  checkout?: string;
  checkedAt?: string;
  // The newest signed release, whether or not main has it.
  release?: UpstreamRelease;
  // Mike's runner: the last release tag it made, and when it next looks.
  published?: { tag: string; at: string };
};

export type PublishConfig = { publish: boolean; signingKey?: string };

export type UpstreamDeps = {
  home: string;
  // The repo this runner's release follows (release.json's checkout).
  checkout?: string;
  clock: Clock;
  log: Logger;
  publish?: PublishConfig;
  // Whether main's tip is what this runner runs, and it has been marked
  // good and up for SETTLE_MS (main.ts). Only asked when publishing.
  runningMainSettled?: () => boolean;
  onChange?: () => void;
  // After every check that got as far as the releases, with what it found
  // (bring-in.ts decides from it whether to start a thread).
  onChecked?: (status: UpstreamStatus) => void;
  // Replaced in tests.
  git?: (cwd: string, args: string[]) => Promise<string>;
  gitBytes?: (cwd: string, args: string[]) => Promise<Buffer>;
};

export function signersPath(home: string): string {
  return path.join(home, 'upstream-signers');
}

export function gitAsync(cwd: string, args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    // GIT_TERMINAL_PROMPT=0: a fetch that wants a password fails rather
    // than hanging the runner on a prompt nobody sees.
    execFile('git', ['-C', cwd, ...args], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, env: { ...process.env, GIT_TERMINAL_PROMPT: '0' } }, (err, stdout, stderr) => {
      if (err) reject(new Error(`git ${args.join(' ')} failed: ${String(stderr).trim() || err.message}`));
      else resolve(stdout.trim());
    });
  });
}

// github.com/mikecann/threadbear, however the URL is written (https, ssh,
// with or without .git), so origin and upstream can be compared.
export function repoKey(url: string): string {
  return url
    .trim()
    .replace(/^git@([^:]+):/, '$1/')
    .replace(/^[a-z+]+:\/\/(?:[^@/]+@)?/, '')
    .replace(/\.git\/?$/, '')
    .replace(/\/$/, '')
    .toLowerCase();
}

// `git log --format=%H%x1f<Important trailers>` as the commits that have one.
export function parseImportant(out: string): { commit: string; why: string }[] {
  return out
    .split('\n')
    .map((line) => line.split('\x1f'))
    .filter(([commit, why]) => commit && why?.trim())
    .map(([commit, why]) => ({ commit: commit.trim(), why: why.trim().slice(0, 200) }));
}

// release/2026-10-30 for a local date.
export function tagFor(d: Date): string {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${TAG_PREFIX}${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

export class Upstream {
  private st: UpstreamStatus = { state: 'off' };
  private timer: TimerHandle | undefined;
  private publishTimer: TimerHandle | undefined;
  private running: Promise<UpstreamStatus> | undefined;
  private stopped = false;
  // verified()'s answers, by signers file, object and name.
  private readonly answers = new Map<string, SignedTag | null>();
  private readonly git: (cwd: string, args: string[]) => Promise<string>;
  private readonly deps: UpstreamDeps;

  constructor(deps: UpstreamDeps) {
    this.deps = deps;
    this.git = deps.git ?? gitAsync;
    if (deps.checkout) this.st.checkout = deps.checkout;
  }

  status(): UpstreamStatus {
    return { ...this.st };
  }

  start(): void {
    if (!this.deps.checkout) {
      this.set({ state: 'off', reason: 'this runner runs from source, not a release' });
      return;
    }
    this.stopped = false;
    this.timer ??= this.deps.clock.setTimeout(() => this.tick(), FIRST_LOOK_MS);
    if (this.deps.publish?.publish) this.publishTimer ??= this.deps.clock.setTimeout(() => this.publishTick(), FIRST_LOOK_MS);
  }

  stop(): void {
    this.stopped = true;
    this.timer?.cancel();
    this.publishTimer?.cancel();
    this.timer = this.publishTimer = undefined;
  }

  private tick(): void {
    this.timer = undefined;
    void this.check().finally(() => {
      if (!this.stopped) this.timer = this.deps.clock.setTimeout(() => this.tick(), FETCH_INTERVAL_MS);
    });
  }

  private publishTick(): void {
    this.publishTimer = undefined;
    void this.publishOnce()
      .catch((e) => this.deps.log.warn('could not tag a release', { error: String(e) }))
      .finally(() => {
        if (!this.stopped) this.publishTimer = this.deps.clock.setTimeout(() => this.publishTick(), PUBLISH_INTERVAL_MS);
      });
  }

  // Fetches upstream's release tags and works out what main is missing.
  // `tb updates check` and the timer share one check at a time.
  check(): Promise<UpstreamStatus> {
    this.running ??= this.checkNow().finally(() => (this.running = undefined));
    return this.running;
  }

  private async checkNow(): Promise<UpstreamStatus> {
    const checkout = this.deps.checkout;
    if (!checkout) return this.status();
    const urls = await this.remotes(checkout);
    if (!urls.upstream) return this.set({ state: 'off', reason: "this copy has no upstream remote (Mike's repo), so it has no releases to follow" });
    if (urls.origin && repoKey(urls.origin) === repoKey(urls.upstream)) return this.set({ state: 'off', reason: 'upstream is this repo' });
    const signers = signersPath(this.deps.home);
    if (!fs.existsSync(signers)) return this.set({ state: 'off', reason: `no release key pinned at ${signers}; run ./threadbear setup again` });
    this.set({ state: 'checking' });
    const checkedAt = new Date(this.deps.clock.now()).toISOString();
    try {
      // Before the fetch, so an upstream that's gone (or made to fail)
      // can't keep an unverified ref there.
      await this.sweep(checkout, signers);
      await this.git(checkout, ['fetch', '-q', '--no-tags', '--prune', 'upstream', `+refs/tags/${TAG_PREFIX}*:${INCOMING_NS}*`]);
      await this.promote(checkout, signers);
      const release = await this.newestSigned(checkout, signers);
      if (!release) return this.set({ state: 'idle', checkedAt, reason: 'no signed releases yet' });
      const state = release.changes > 0 ? 'available' : 'idle';
      if (state === 'available' && this.st.release?.tag !== release.tag) this.deps.log.info('a newer release from upstream', { tag: release.tag, changes: release.changes });
      const status = this.set({ state, checkedAt, release });
      try {
        this.deps.onChecked?.(status);
      } catch (e) {
        this.deps.log.warn('could not act on the release check', { error: String(e) });
      }
      return status;
    } catch (e) {
      this.deps.log.warn('could not check upstream for releases', { error: String(e) });
      return this.set({ state: 'failed', checkedAt, reason: String((e as Error).message ?? e).slice(0, 300) });
    }
  }

  private async remotes(checkout: string): Promise<{ origin?: string; upstream?: string }> {
    const get = (name: string) => this.git(checkout, ['remote', 'get-url', name]).catch(() => undefined);
    const [origin, upstream] = await Promise.all([get('origin'), get('upstream')]);
    return { origin, upstream };
  }

  // Takes out anything in REF_NS that doesn't verify: a runner from before
  // this check fetched straight into it, unverified, and so can a
  // rolled-back one. Whatever the name, so nothing is in the way of a
  // release's (refs/threadbear/upstream/2026-11-06/x blocks 2026-11-06).
  private async sweep(checkout: string, signers: string): Promise<void> {
    for (const [name, ref] of await this.refs(checkout, REF_NS)) {
      if (await this.verified(checkout, ref, TAG_PREFIX + name, signers)) continue;
      this.deps.log.warn('removed an upstream release ref that is not signed with the pinned key', { tag: TAG_PREFIX + name });
      await this.git(checkout, ['update-ref', '-d', REF_NS + name, ref.oid]).catch(() => undefined);
    }
  }

  // Copies the newest fetched tag that verifies into REF_NS. Upstream can
  // push any number of tags, so what it can make the runner read is
  // bounded: only names Mike's runner makes (a date, tagFor), no later
  // than a couple of days from now and no earlier than the newest release
  // kept; only tag objects (a tag pointing straight at a commit is turned
  // down without a read); newest first, stopping at the first that
  // verifies; and at most MAX_READS tags read per check. A name already
  // kept keeps its object: a different tag served later under it is a
  // re-tag nobody should merge, so it's said in the log and left out.
  private async promote(checkout: string, signers: string): Promise<void> {
    const kept = await this.refs(checkout, REF_NS);
    const newest = [...kept.keys()].filter((n) => RELEASE_NAME.test(n)).sort().at(-1) ?? '';
    const latest = new Date(this.deps.clock.now() + FUTURE_SLACK_MS).toISOString().slice(0, 10);
    const incoming = [...(await this.refs(checkout, INCOMING_NS))]
      .filter(([name, ref]) => RELEASE_NAME.test(name) && name >= newest && name <= latest && ref.type === 'tag' && kept.get(name)?.oid !== ref.oid)
      .sort(([a], [b]) => (a < b ? 1 : -1));
    let reads = 0;
    for (const [name, ref] of incoming) {
      const tag = TAG_PREFIX + name;
      if (!this.answered(ref, tag, signers) && ++reads > MAX_READS) {
        this.deps.log.warn('more upstream release tags than one check reads; the rest wait for the next', { from: tag });
        break;
      }
      if (!(await this.verified(checkout, ref, tag, signers))) {
        this.deps.log.warn('skipped an upstream release tag that is not signed with the pinned key', { tag });
        continue;
      }
      const have = kept.get(name);
      if (have) {
        this.deps.log.warn('upstream serves a different tag under a release name already verified here; keeping the one verified first', { tag, kept: have.oid, offered: ref.oid });
        continue;
      }
      // Only if the name is still free (a ref that turned up in between
      // isn't overwritten). A clash with another ref's name fails this one
      // copy, not the whole check.
      const ok = await this.git(checkout, ['update-ref', REF_NS + name, ref.oid, ''])
        .then(() => true)
        .catch((e) => (this.deps.log.warn('could not keep a verified release', { tag, error: String(e) }), false));
      // The newest is the one that counts; older ones needn't be read.
      if (ok) break;
    }
  }

  // name (after the namespace) -> the object the ref points at, and its type.
  private async refs(checkout: string, ns: string): Promise<Map<string, Ref>> {
    const out = await this.git(checkout, ['for-each-ref', '--format=%(objectname) %(objecttype) %(objectsize) %(refname)', ns]);
    const map = new Map<string, Ref>();
    for (const line of out.split('\n')) {
      const [oid, type, size, ...rest] = line.split(' ');
      const refname = rest.join(' ');
      if (oid && type && refname.startsWith(ns)) map.set(refname.slice(ns.length), { oid, type, size: Number(size) });
    }
    return map;
  }

  // The newest release in REF_NS that verifies against the pinned key and
  // names itself what it's kept as (so an old signed tag pushed under a
  // newer name can't pass for the newer release), with what main doesn't
  // have. Each is checked again here, by its object id, and the commit is
  // the one its signed text names.
  private async newestSigned(checkout: string, signers: string): Promise<UpstreamRelease | undefined> {
    const refs = [...(await this.refs(checkout, REF_NS))].sort(([a], [b]) => (a < b ? 1 : a > b ? -1 : 0));
    for (const [name, ref] of refs) {
      const tag = TAG_PREFIX + name;
      const signed = await this.verified(checkout, ref, tag, signers);
      // Only a ref that turned up since promote took out the rest.
      if (!signed) continue;
      const { commit, date } = signed;
      const range = `refs/heads/main..${commit}`;
      const [count, log, trailers] = await Promise.all([
        this.git(checkout, ['rev-list', '--count', '--no-merges', range]),
        this.git(checkout, ['log', '--no-merges', `--max-count=${MAX_SUBJECTS}`, '--format=%s', range]),
        // One line per commit: its id, then any Important: trailer's text.
        this.git(checkout, ['log', '--no-merges', '--format=%H%x1f%(trailers:key=Important,valueonly,separator=%x20)', range]),
      ]);
      const important = parseImportant(trailers);
      return { tag, commit, ...(date ? { date } : {}), changes: Number(count) || 0, subjects: log.split('\n').filter(Boolean), ...(important.length ? { important } : {}) };
    }
    return undefined;
  }

  // The tag object `oid`, if it is signed by the pinned key as `tag`.
  // Throws when ssh-keygen can't be run at all, so the check fails and says
  // why rather than calling every release unsigned (and taking them out).
  // An object's bytes never change, so each answer is kept (for the
  // pinned file as it is now): a check reads only tags it hasn't seen.
  // Only answers are kept: git or ssh-keygen failing to run throws, so the
  // check fails and says why, and the tag is read again next time.
  private async verified(checkout: string, ref: Ref, tag: string, signers: string): Promise<SignedTag | undefined> {
    // Not a tag object (a commit or anything else), or one far bigger than
    // any Mike's runner makes, is just not signed: never read.
    if (!readable(ref)) return undefined;
    const key = this.answerKey(ref, tag, signers);
    if (this.answers.has(key)) return this.answers.get(key) ?? undefined;
    const raw = await (this.deps.gitBytes ?? gitBytes)(checkout, ['cat-file', 'tag', ref.oid]);
    const split = splitSignedTag(raw, tag);
    const signed = split && (await sshVerified(split, signers)) ? split : undefined;
    if (this.answers.size >= MAX_ANSWERS) this.answers.delete(this.answers.keys().next().value!);
    this.answers.set(key, signed ?? null);
    return signed;
  }

  private answered(ref: Ref, tag: string, signers: string): boolean {
    return !readable(ref) || this.answers.has(this.answerKey(ref, tag, signers));
  }

  private answerKey(ref: Ref, tag: string, signers: string): string {
    return `${createHash('sha256').update(fs.readFileSync(signers)).digest('hex')} ${ref.oid} ${tag}`;
  }

  // Mike's runner: tags main's tip as today's release when it's moved since
  // the last one and has settled (above). Returns the tag it made.
  async publishOnce(): Promise<string | undefined> {
    const { checkout, publish } = this.deps;
    if (!checkout || !publish?.publish) return undefined;
    if (!publish.signingKey || !fs.existsSync(publish.signingKey)) {
      this.deps.log.warn('releases.publish is on but releases.signingKey is missing', { signingKey: publish.signingKey });
      return undefined;
    }
    if (!(this.deps.runningMainSettled?.() ?? false)) return undefined;
    const now = this.deps.clock.now();
    const tip = await this.git(checkout, ['rev-parse', 'refs/heads/main']);
    const committed = Number(await this.git(checkout, ['log', '-1', '--format=%ct', tip])) * 1000;
    if (now - committed < SETTLE_MS) return undefined;
    // Tags made on another Mac, or by hand, count too.
    await this.git(checkout, ['fetch', '-q', '--no-tags', 'origin', `+refs/tags/${TAG_PREFIX}*:refs/tags/${TAG_PREFIX}*`]);
    const tag = tagFor(new Date(now));
    const tags = (await this.git(checkout, ['tag', '--list', '--sort=-refname', `${TAG_PREFIX}*`])).split('\n').filter(Boolean);
    if (tags.includes(tag)) return undefined;
    const last = tags[0];
    if (last && (await this.isAncestor(checkout, tip, last))) return undefined;
    const subjects = (await this.git(checkout, ['log', '--no-merges', '--format=- %s', last ? `${last}..${tip}` : tip, '--max-count=200'])).trim();
    // Important commits lead the message, so the release says so wherever
    // it's read (forks find them from the commits' trailers themselves).
    const important = parseImportant(await this.git(checkout, ['log', '--no-merges', '--format=%H%x1f%(trailers:key=Important,valueonly,separator=%x20)', last ? `${last}..${tip}` : tip, '--max-count=200']));
    const lead = important.length ? important.map((i) => `Important: ${i.why}`).join('\n') + '\n\n' : '';
    const message = `Threadbear ${tag.slice(TAG_PREFIX.length)}\n\n${lead}${subjects}\n`;
    const file = path.join(this.deps.home, 'runner', 'release-tag-message.txt');
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, message);
    await this.git(checkout, ['-c', 'gpg.format=ssh', '-c', `user.signingkey=${publish.signingKey}`, 'tag', '-s', '-F', file, tag, tip]);
    try {
      await this.git(checkout, ['push', '-q', 'origin', `refs/tags/${tag}`]);
    } catch (e) {
      // Taken back, so the next look tries the push again.
      await this.git(checkout, ['tag', '-d', tag]).catch(() => undefined);
      throw e;
    }
    this.deps.log.info('tagged a release', { tag, commit: tip });
    this.set({ ...this.st, published: { tag, at: new Date(now).toISOString() } });
    return tag;
  }

  private async isAncestor(checkout: string, a: string, b: string): Promise<boolean> {
    try {
      await this.git(checkout, ['merge-base', '--is-ancestor', a, b]);
      return true;
    } catch {
      return false;
    }
  }

  private set(next: UpstreamStatus): UpstreamStatus {
    const keep = { ...(this.deps.checkout ? { checkout: this.deps.checkout } : {}), ...(this.st.published && !next.published ? { published: this.st.published } : {}) };
    // A failed or in-progress check keeps the last release it knew of.
    const release = next.release ?? (next.state === 'checking' || next.state === 'failed' ? this.st.release : undefined);
    const st: UpstreamStatus = { ...next, ...keep, ...(release ? { release } : {}) };
    const changed = JSON.stringify(st) !== JSON.stringify(this.st);
    this.st = st;
    if (changed) this.deps.onChange?.();
    return this.status();
  }
}

export type SignedTag = { payload: Buffer; signature: string; commit: string; date?: string };

// A tag object's raw bytes, as `git cat-file tag` gives them: exact, as the
// signature covers every byte.
export function gitBytes(cwd: string, args: string[]): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    execFile('git', ['-C', cwd, ...args], { encoding: 'buffer', maxBuffer: 16 * 1024 * 1024, env: { ...process.env, GIT_TERMINAL_PROMPT: '0' } }, (err, stdout, stderr) => {
      if (err) reject(new Error(`git ${args.join(' ')} failed: ${String(stderr).trim() || err.message}`));
      else resolve(stdout);
    });
  });
}

const SSH_BEGIN = '-----BEGIN SSH SIGNATURE-----\n';
const SSH_BLOCK = /^-----BEGIN SSH SIGNATURE-----\n(?:[A-Za-z0-9+/=]{1,76}\n){1,64}-----END SSH SIGNATURE-----\n$/;
const OBJECT_ID = /^[0-9a-f]{40}$|^[0-9a-f]{64}$/;

// A release tag split into the text it signs and its signature, or
// undefined unless it is exactly what Mike's runner makes: the four tag
// headers in git's order (object, a commit, `tag` naming this release,
// tagger), a message, and one SSH signature at the end. Any other armor
// (PGP, X.509, a second block) fails, so there's nothing for git or gpg to
// pick a different verifier from. Armor counts where git looks for it, at
// the start of a line; the message's lines all start "- " or "Important:"
// (publishOnce), so a commit subject that mentions armor can't trip this.
export function splitSignedTag(raw: Buffer, tag: string): SignedTag | undefined {
  // latin1 keeps one char per byte, so offsets are byte offsets.
  const text = raw.toString('latin1');
  const lines = text.split('\n');
  if (lines.filter((l) => l.startsWith('-----BEGIN ')).length !== 1 || lines.filter((l) => l.startsWith('-----END ')).length !== 1) return undefined;
  const at = text.indexOf('\n' + SSH_BEGIN);
  if (at < 0) return undefined;
  const signature = text.slice(at + 1);
  if (!SSH_BLOCK.test(signature)) return undefined;
  const payload = text.slice(0, at + 1);
  const headEnd = payload.indexOf('\n\n');
  const head = (headEnd < 0 ? payload.slice(0, -1) : payload.slice(0, headEnd)).split('\n');
  if (head.length !== 4) return undefined;
  const [object, type, name, tagger] = head;
  const commit = object.startsWith('object ') ? object.slice('object '.length) : '';
  if (!OBJECT_ID.test(commit) || type !== 'type commit' || name !== `tag ${tag}` || !tagger.startsWith('tagger ')) return undefined;
  const when = / (\d{1,12}) [+-]\d{4}$/.exec(tagger);
  const date = when ? new Date(Number(when[1]) * 1000).toISOString() : undefined;
  return { payload: Buffer.from(payload, 'latin1'), signature, commit, ...(date ? { date } : {}) };
}

// Whether ssh-keygen finds the signature good for the `git` namespace, by a
// key in the pinned allowed-signers file (what `git verify-tag` does for an
// SSH signature, without git choosing the verifier).
async function sshVerified(signed: SignedTag, signers: string): Promise<boolean> {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tb-release-sig-'));
  try {
    const sig = path.join(dir, 'tag.sig');
    fs.writeFileSync(sig, signed.signature, { mode: 0o600 });
    const found = await run('ssh-keygen', ['-Y', 'find-principals', '-f', signers, '-s', sig]);
    if (found.code !== 0) return false;
    for (const principal of found.stdout.split('\n').map((l) => l.trim()).filter(Boolean)) {
      const v = await run('ssh-keygen', ['-Y', 'verify', '-f', signers, '-I', principal, '-n', 'git', '-s', sig], signed.payload);
      if (v.code === 0) return true;
    }
    return false;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// Its exit code and output; rejects if it couldn't be started or was
// killed (not there, or hung), which is no answer about the signature.
function run(cmd: string, args: string[], input?: Buffer): Promise<{ code: number; stdout: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: ['pipe', 'pipe', 'ignore'], timeout: 60_000 });
    let stdout = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (d: string) => (stdout += d));
    child.on('error', (e) => reject(new Error(`${cmd} could not run: ${e.message}`)));
    child.on('close', (code, signal) => (code === null ? reject(new Error(`${cmd} was stopped (${signal})`)) : resolve({ code, stdout })));
    child.stdin.on('error', () => undefined);
    child.stdin.end(input ?? Buffer.alloc(0));
  });
}
