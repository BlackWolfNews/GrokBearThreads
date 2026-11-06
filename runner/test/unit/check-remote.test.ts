// scripts/check-remote.sh losing the race for a free check host. On 6 Nov
// an app check's copy took 22 minutes over a slow uplink, another check took
// Tinker Desk meanwhile, and the run deleted its finished copy and copied
// again. Now a lost race keeps the copy: after a slow copy it waits on that
// host, after a quick one it chooses again and only copies if it moves.
// Runs the real script from a temp checkout, with a fake ssh that answers
// the probe and the lock from files and runs everything else locally, and
// an rsync that copies to "host:path" as plain local paths.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { tmpDir } from '../helpers/fakes.ts';

const SCRIPT = path.join(import.meta.dirname, '..', '..', '..', 'scripts', 'check-remote.sh');

// ssh: drops its -o options, takes the host, and answers the probe and
// the lock from files: a host's state file says free or busy, its "lose"
// file how many lock-without-waiting tries to refuse (75), each of which
// leaves the host busy, as another check has it. Each host's home is a
// folder under $FAKE, and everything else (mkdir, the copy from the
// mirror, rm -rf, find) really runs there. A run says whether its copy is there.
// rsync: drops -e and its command, takes host:path as path, and logs an
// upload to a host's mirror as that host's copy.
const FAKE_RSYNC = `#!/bin/bash
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -e) shift ;;
    *:/*) h="\${1%%:*}"; p="\${1#*:}"; case "$p" in */mirror/*) echo "$h" >>"$FAKE/copies.log" ;; esac; args+=("$p") ;;
    *) args+=("$1") ;;
  esac
  shift
done
exec /usr/bin/rsync "\${args[@]}"
`;

const FAKE_SSH = `#!/bin/bash
while [ "$1" = -o ]; do shift 2; done
host="$1"; shift
cmd="$*"
d="$FAKE/$host"
echo "$host $cmd" >>"$FAKE/ssh.log"
run_copy() {
  script="$(printf '%s' "$cmd" | grep -oE "$d/home/[^ \\\\']*/scripts/check-remote.sh" | head -1)"
  if [ -n "$script" ] && [ -f "$script" ] && [ -f "$(dirname "$script")/../.check-changed" ]; then
    echo "ran on $host $1 from $script"
    [ -z "$PEEK" ] || (cd "$(dirname "$script")/.." && bash -c "$PEEK") >"$FAKE/peek"
  else echo "no copy on $host for: $cmd"; exit 1; fi
}
case "$cmd" in
  *"uname -s"*) printf '%s\\n%s\\n%s\\n' "$d/home/.cache/threadbear-check" Darwin "$(cat "$d/state")" ;;
  *"lockf -t 0 -k"*)
    n="$(cat "$d/lose" 2>/dev/null || echo 0)"
    if [ "$n" -gt 0 ]; then echo $((n - 1)) >"$d/lose"; [ -f "$d/looks-free" ] || echo busy >"$d/state"; exit 75; fi
    run_copy now ;;
  *"lockf -k"*) run_copy "after waiting" ;;
  *) bash -c "$cmd" ;;
esac
`;

// looksFree: the probe still says free after each lost race (another check
// keeps grabbing it between the probe and the lock).
function setup(hosts: Record<string, { state: string; lose?: number; looksFree?: boolean }>) {
  const tmp = tmpDir('check-remote-');
  const fake = path.join(tmp, 'fake');
  const bin = path.join(tmp, 'bin');
  const repo = path.join(tmp, 'repo');
  fs.mkdirSync(bin, { recursive: true });
  fs.mkdirSync(path.join(repo, 'scripts'), { recursive: true });
  fs.writeFileSync(path.join(repo, 'a.txt'), 'a\n');
  fs.writeFileSync(path.join(bin, 'ssh'), FAKE_SSH, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, 'rsync'), FAKE_RSYNC, { mode: 0o755 });
  for (const [h, s] of Object.entries(hosts)) {
    fs.mkdirSync(path.join(fake, h, 'home'), { recursive: true });
    fs.writeFileSync(path.join(fake, h, 'state'), s.state);
    if (s.lose) fs.writeFileSync(path.join(fake, h, 'lose'), String(s.lose));
    if (s.looksFree) fs.writeFileSync(path.join(fake, h, 'looks-free'), '');
  }
  fs.copyFileSync(SCRIPT, path.join(repo, 'scripts', 'check-remote.sh'));
  const git = (...args: string[]) => execFileSync('git', ['-C', repo, ...args], { stdio: 'ignore' });
  git('init', '-q', '-b', 'main');
  git('add', '-A');
  git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'x');
  return {
    fake,
    repo,
    // peek: a command run in the copy as its check starts, its output kept.
    run(hostList: string, staySecs: number, peek = '') {
      const r = spawnSync('bash', [path.join(repo, 'scripts', 'check-remote.sh'), hostList, '--quick'], {
        encoding: 'utf8',
        env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, FAKE: fake, PEEK: peek, THREADBEAR_CHECK_STAY_SECS: String(staySecs) },
      });
      const read = (f: string) => (fs.existsSync(path.join(fake, f)) ? fs.readFileSync(path.join(fake, f), 'utf8') : '');
      // The copies left on each host afterwards.
      const left = (h: string) => {
        const runs = path.join(fake, h, 'home', '.cache', 'threadbear-check', 'runs');
        return fs.existsSync(runs) ? fs.readdirSync(runs) : [];
      };
      return { ...r, ssh: read('ssh.log'), copies: read('copies.log').trim().split('\n').filter(Boolean), left, peek: read('peek') };
    },
  };
}

test('a slow copy that loses the race waits on its host with the same copy, even with another free', () => {
  const s = setup({ h1: { state: 'free', lose: 1 }, h2: { state: 'free' } });
  const r = s.run('h1,h2', 0);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /ran on h1 after waiting from .*\/runs\/[^/]+-0\/scripts/);
  assert.match(r.stdout, /waiting for it there/);
  assert.deepEqual(r.copies, ['h1']);
  // h1 was free first, so h2 was never even probed.
  assert.doesNotMatch(r.ssh, /^h2 /m);
});

test('a quick copy that loses the race chooses again and reuses the copy on the same host', () => {
  const s = setup({ h1: { state: 'free', lose: 1 } });
  const r = s.run('h1', 3600);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /its copy is already there/);
  assert.match(r.stdout, /ran on h1 after waiting from .*-0\/scripts/);
  assert.deepEqual(r.copies, ['h1']);
  assert.deepEqual(r.left('h1'), []);
});

test('a quick copy that loses the race moves to a free host and deletes the first copy', () => {
  const s = setup({ h1: { state: 'free', lose: 1 }, h2: { state: 'free' } });
  const r = s.run('h1,h2', 3600);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /ran on h2 now from .*\/h2\/home\/.*-1\/scripts/);
  assert.deepEqual(r.copies, ['h1', 'h2']);
  assert.deepEqual(r.left('h1'), []);
  assert.deepEqual(r.left('h2'), []);
});

test('losing three times in a row waits in line rather than trying forever', () => {
  const s = setup({ h1: { state: 'free', lose: 5, looksFree: true } });
  const r = s.run('h1', 3600);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.equal((r.stdout.match(/choosing again/g) ?? []).length, 3);
  assert.match(r.stdout, /ran on h1 after waiting/);
  assert.deepEqual(r.copies, ['h1']);
});

test('the copy carries the checkout, untracked files included, and .check-changed', () => {
  const s = setup({ h1: { state: 'free' } });
  fs.writeFileSync(path.join(s.repo, 'untracked.txt'), 'u\n');
  fs.writeFileSync(path.join(s.repo, 'ignored.log'), 'i\n');
  fs.writeFileSync(path.join(s.repo, '.gitignore'), '*.log\n');
  fs.writeFileSync(path.join(s.repo, 'tool.sh'), '#!/bin/sh\n', { mode: 0o755 });
  fs.symlinkSync('a.txt', path.join(s.repo, 'link'));
  // docs/ and site/ pictures stay behind; site's JSON goes (TourTests reads it).
  fs.mkdirSync(path.join(s.repo, 'docs'));
  fs.mkdirSync(path.join(s.repo, 'site'));
  fs.writeFileSync(path.join(s.repo, 'docs', 'shot.png'), 'png');
  fs.writeFileSync(path.join(s.repo, 'site', 'tour.json'), '{}');
  const r = s.run('h1', 3600, 'find . -mindepth 1 | sed "s#^\\./##" | sort; [ -x tool.sh ] && echo "tool.sh runs"; echo "link -> $(readlink link)"');
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.deepEqual(r.copies, ['h1']);
  const listed = r.peek.trim().split('\n');
  for (const f of ['a.txt', 'untracked.txt', '.gitignore', 'tool.sh', 'link', 'scripts', 'scripts/check-remote.sh', '.check-changed',
    'tool.sh runs', 'link -> a.txt', 'site/tour.json']) {
    assert.ok(listed.includes(f), `${f} in ${listed.join(',')}`);
  }
  assert.ok(!listed.includes('ignored.log'), listed.join(','));
  assert.ok(!listed.includes('docs/shot.png'), listed.join(','));
});

test('a .check-changed in the checkout never has the real one written through it, and modes are kept', () => {
  const s = setup({ h1: { state: 'free' } });
  const victim = path.join(s.fake, 'victim');
  fs.writeFileSync(victim, 'untouched\n');
  fs.symlinkSync(victim, path.join(s.repo, '.check-changed'));
  fs.writeFileSync(path.join(s.repo, 'shared.sh'), '#!/bin/sh\n');
  fs.chmodSync(path.join(s.repo, 'shared.sh'), 0o775);
  const r = s.run('h1', 3600, '[ -L .check-changed ] && echo "is a link"; cat .check-changed; ls -l shared.sh | cut -c1-10');
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.equal(fs.readFileSync(victim, 'utf8'), 'untouched\n');
  assert.doesNotMatch(r.peek, /is a link/);
  // The changed list (here the untracked files) is what's there.
  assert.match(r.peek, /^shared\.sh$/m);
  // Modes as they are here, not as the receiver's umask would leave them.
  assert.match(r.peek, /-rwxrwxr-x/);
});
