#!/bin/bash
# Sets up a thread's own worktree of Threadbear (docs/thread-worktrees.md):
# node_modules for the runner and the mock runner. The runner runs it in
# the new worktree before the thread's first turn
# (.threadbear/patches/checks.ts); it's safe to run again.
#
# Where the main checkout has the same package-lock.json and has installed
# it, node_modules is a symlink to the main checkout's: a moment, rather
# than an npm ci of some 350 MB for every thread. The symlinks are
# gitignored (.gitignore's node_modules matches them). Otherwise, or if the
# main checkout has nothing installed, it's a real npm ci here.
#
# A thread that changes a package.json or package-lock.json replaces the
# link with its own install first: `rm runner/node_modules` (no trailing
# slash: that removes the link, not the main checkout's files), then
# `npm ci` there. Never npm install through the link.
set -euo pipefail

# THREADBARE_* was the old name for these variables: each stands in for its new name.
for v in $(compgen -e | grep '^THREADBARE_' || true); do n="THREADBEAR_${v#THREADBARE_}"; [ -n "${!n+x}" ] || export "$n=${!v}"; done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE="${THREADBEAR_NODE:-$HOME/.nvm/versions/node/v24.22.1/bin/node}"
NPM="$(dirname "$NODE")/npm"
[ -x "$NPM" ] || NPM="npm"

# The checkout with main checked out, from git's own list.
MAIN="$(git -C "$ROOT" worktree list --porcelain | awk '
  /^worktree / { path = substr($0, 10) }
  /^branch refs\/heads\/main$/ { print path; exit }
')"

for dir in runner app/Tools/mock-runner; do
  here="$ROOT/$dir"
  there="${MAIN:+$MAIN/$dir}"
  if [ -e "$here/node_modules" ] || [ -L "$here/node_modules" ]; then
    echo "$dir: node_modules is already there"
  elif [ -n "$there" ] && [ "$MAIN" != "$ROOT" ] && [ -d "$there/node_modules" ] \
    && cmp -s "$here/package-lock.json" "$there/package-lock.json"; then
    ln -s "$there/node_modules" "$here/node_modules"
    echo "$dir: node_modules linked to $there/node_modules"
  else
    echo "$dir: npm ci (nothing matching in the main checkout to link to)"
    (cd "$here" && "$NPM" ci --no-audit --no-fund --loglevel=error)
  fi
done
