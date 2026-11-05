// Where the system tools the runner runs by absolute path live, per
// platform. A runner also runs on Linux (INSTALL.md, "A runner on Linux"),
// where macOS's paths aren't there: lsof is /usr/bin/lsof on Ubuntu, not
// /usr/sbin/lsof, and zsh isn't installed by default. A macOS-only path in
// a runner that runs everywhere failed the Linux runners' pre-install tests
// and stopped Hetzner's updating (5 Nov 2026); system-tools.test.ts checks every
// absolute tool path in src/ against a list.

import fs from 'node:fs';
import path from 'node:path';

type Probe = { platform?: NodeJS.Platform; executable?: (file: string) => boolean; env?: NodeJS.ProcessEnv };

function isExecutable(file: string): boolean {
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return fs.statSync(file).isFile();
  } catch {
    return false;
  }
}

function probe(p: Probe): Required<Probe> {
  return { platform: p.platform ?? process.platform, executable: p.executable ?? isExecutable, env: p.env ?? process.env };
}

// lsof: /usr/sbin on a Mac, /usr/bin on Debian and Ubuntu. Only these
// fixed, root-owned places, never PATH: handover.ts trusts what lsof says
// about who's on the other end of a socket before sending the token, and an
// `lsof` in a folder on PATH anyone can write to could say anything. When
// none is there, the path that isn't, so the check fails closed.
export function lsofPath(p: Probe = {}): string {
  const q = probe(p);
  if (q.platform === 'darwin') return '/usr/sbin/lsof';
  return ['/usr/bin/lsof', '/usr/sbin/lsof', '/bin/lsof'].find(q.executable) ?? '/usr/bin/lsof';
}

// The login shell command actions and patch panels run in, so PATH, nvm
// and the like apply as in a terminal. zsh on a Mac (its default since
// Catalina). On Linux, the user's own $SHELL if it's a POSIX-style one
// that's there (commands are written for sh, so not fish or csh), else
// bash, else sh: zsh isn't something a Linux runner can count on.
export function loginShell(p: Probe = {}): string[] {
  const q = probe(p);
  if (q.platform === 'darwin') return ['/bin/zsh', '-lc'];
  const own = q.env.SHELL;
  const posix = own && path.isAbsolute(own) && ['bash', 'zsh', 'sh', 'dash', 'ksh'].includes(path.basename(own));
  const candidates = [...(posix ? [own] : []), '/bin/bash', '/usr/bin/bash'];
  for (const f of candidates) if (q.executable(f)) return [f, '-lc'];
  return ['/bin/sh', '-lc'];
}
