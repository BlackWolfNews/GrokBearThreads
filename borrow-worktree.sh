#!/bin/bash
# For a thread started outside this repo (like ~/dev/me/misc), which gets
# no worktree from the runner: borrows one of the spares the runner keeps
# for new threads (docs/thread-worktrees.md, "Reusing worktrees"), with its
# Swift build caches, so the app builds in under a minute rather than the
# 5 to 10 a fresh `git worktree add` takes. With no spare it makes a new
# slot, which becomes one when it's given back.
#
#   ./borrow-worktree.sh              prints the worktree's path: on a new
#                                     thread/borrow-<slot>-<time> branch from
#                                     main, set up, yours till you give it back.
#                                     Commit there and `tb land` it (tb land
#                                     only lands a thread/ branch).
#   ./borrow-worktree.sh --give-back DIR
#                                     once everything in it is on main: back
#                                     in the pool for the next thread, and its
#                                     borrow branch deleted
#
# Unlocking a spare is the claim, the same as the runner's, so a thread and
# the runner never take the same one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN="$(git -C "$ROOT" worktree list --porcelain | awk '
  /^worktree / { path = substr($0, 10) }
  /^branch refs\/heads\/main$/ && !found { print path; found = 1 }
')"
[ -n "$MAIN" ] || { echo "No checkout of this repo has main checked out." >&2; exit 1; }
THREADS="$(dirname "$MAIN")/$(basename "$MAIN")-threads"
SPARE="threadbear spare"
# The patch's worktree.keep (.threadbear/patches/checks.ts).
KEEP=(-e /app/.build -e /dock/.build)

if [ "${1:-}" = "--give-back" ]; then
  dir="${2:?--give-back needs the folder to give back}"
  if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then
    echo "$dir has uncommitted changes; commit and land them, or git -C $dir reset --hard, first." >&2
    exit 1
  fi
  if ! git -C "$dir" merge-base --is-ancestor HEAD main; then
    echo "$dir has commits that aren't on main; land them first." >&2
    exit 1
  fi
  branch="$(git -C "$dir" symbolic-ref -q --short HEAD || true)"
  git -C "$dir" checkout -q --detach
  # Only the branch this script made; it's all on main (checked above).
  case "$branch" in thread/borrow-*) git -C "$MAIN" branch -q -D "$branch" ;; esac
  git -C "$MAIN" worktree lock --reason "$SPARE" "$dir"
  echo "$dir is a spare again."
  exit 0
fi

# A thread/ branch of its own, as a runner-made worktree has, so `tb land`
# takes it (landTargetFromGit in runner/src/worktrees.ts). The time keeps
# it from meeting a branch an earlier borrow never gave back.
borrow_branch() { echo "thread/borrow-$(basename "$1")-$(date +%Y%m%d-%H%M%S)"; }

claimed=""
for dir in $(git -C "$MAIN" worktree list --porcelain | awk -v RS= -v d="$THREADS/" '
  /\nlocked threadbear spare/ { sub(/^worktree /, ""); sub(/\n.*/, ""); if (index($0, d) == 1) print }'); do
  if git -C "$MAIN" worktree unlock "$dir" 2>/dev/null; then
    claimed="$dir"
    break
  fi
done

if [ -n "$claimed" ]; then
  git -C "$claimed" reset -q --hard
  git -C "$claimed" clean -ffdxq "${KEEP[@]}"
  git -C "$claimed" checkout -q -b "$(borrow_branch "$claimed")" main
else
  mkdir -p "$THREADS"
  n=1
  until claimed="$THREADS/slot-$n"; [ ! -e "$claimed" ] && git -C "$MAIN" worktree add -q -b "$(borrow_branch "$claimed")" "$claimed" main 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -le 50 ] || { echo "Couldn't make a worktree in $THREADS." >&2; exit 1; }
  done
fi

"$claimed/worktree-setup.sh" >&2
echo "$claimed"
