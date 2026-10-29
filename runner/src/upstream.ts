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
// account, can't get code onto anyone's Mac this way.
//
// Mike's own runner (runner.json `releases.publish`) makes the tags: once
// a day, if main has moved since the last one, it tags main's tip as
// release/YYYY-MM-DD, signed, and pushes the tag. Only a main it's safe to
// hand on: the runner it's running is main's, has been marked good and up
// for an hour, and main's tip is an hour old, so a commit that crashes
// the runner or is about to be followed by its fix isn't what goes out.
import { execFile } from 'node:child_process';
import fs from 'node:fs';
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
// Where upstream's release tags are fetched to: their own namespace, so
// the fork's own tags are never touched.
const REF_NS = 'refs/threadbear/upstream/';
const MAX_SUBJECTS = 50;

export type UpstreamRelease = {
  tag: string; // release/2026-10-30
  commit: string;
  date?: string; // the tag's date, ISO
  changes: number; // commits in it that main doesn't have, merges left out
  subjects: string[]; // their subject lines, newest first, at most 50
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
  // Replaced in tests.
  git?: (cwd: string, args: string[]) => Promise<string>;
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
      await this.git(checkout, ['fetch', '-q', '--no-tags', '--prune', 'upstream', `+refs/tags/${TAG_PREFIX}*:${REF_NS}*`]);
      const release = await this.newestSigned(checkout, signers);
      if (!release) return this.set({ state: 'idle', checkedAt, reason: 'no signed releases yet' });
      const state = release.changes > 0 ? 'available' : 'idle';
      if (state === 'available' && this.st.release?.tag !== release.tag) this.deps.log.info('a newer release from upstream', { tag: release.tag, changes: release.changes });
      return this.set({ state, checkedAt, release });
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

  // The newest release tag that verifies against the pinned key and names
  // itself what it's fetched as (so an old signed tag pushed under a newer
  // name can't pass for the newer release), with what main doesn't have.
  private async newestSigned(checkout: string, signers: string): Promise<UpstreamRelease | undefined> {
    const refs = (await this.git(checkout, ['for-each-ref', '--sort=-refname', '--format=%(refname)', REF_NS])).split('\n').filter(Boolean);
    for (const ref of refs) {
      const tag = TAG_PREFIX + ref.slice(REF_NS.length);
      if (!(await this.verified(checkout, ref, tag, signers))) {
        this.deps.log.warn('skipped an upstream release tag that is not signed with the pinned key', { tag });
        continue;
      }
      const [commit, date] = (await this.git(checkout, ['for-each-ref', '--format=%(*objectname) %(taggerdate:iso-strict)', ref])).split(' ');
      const range = `refs/heads/main..${commit}`;
      const [count, log] = await Promise.all([
        this.git(checkout, ['rev-list', '--count', '--no-merges', range]),
        this.git(checkout, ['log', '--no-merges', `--max-count=${MAX_SUBJECTS}`, '--format=%s', range]),
      ]);
      return { tag, commit, ...(date ? { date } : {}), changes: Number(count) || 0, subjects: log.split('\n').filter(Boolean) };
    }
    return undefined;
  }

  private async verified(checkout: string, ref: string, tag: string, signers: string): Promise<boolean> {
    try {
      const body = await this.git(checkout, ['cat-file', 'tag', ref]);
      if (!body.split('\n').includes(`tag ${tag}`)) return false;
      await this.git(checkout, ['-c', 'gpg.format=ssh', '-c', `gpg.ssh.allowedSignersFile=${signers}`, 'verify-tag', ref]);
      return true;
    } catch {
      return false;
    }
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
    const message = `Threadbear ${tag.slice(TAG_PREFIX.length)}\n\n${subjects}\n`;
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
