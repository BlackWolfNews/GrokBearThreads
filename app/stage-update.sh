#!/usr/bin/env bash
# Builds the checkout's main into the staged update bundle, which the
# installed app swaps in when it next quits or launches (AppUpdate.swift).
# The app runs its bundled copy of this a few minutes after app/ changes on
# main; it's fine to run by hand too:
#
#   app/stage-update.sh [<checkout>] [--next <dir>]
#
# <checkout> is the repo whose main to build (default: this script's own
# repo). --next is where the bundle goes (default:
# ~/Applications/.Threadbare.app.next, beside the installed app). The clone
# it builds from, the build folder and the lock live under
# ~/Library/Caches/Threadbare/update, so an agent's own swift build in the
# checkout is never waited on or disturbed, and a dirty working tree never
# gets into the app: only what's committed on main is built.
#
# Exit 0 with the bundle staged, 3 if another run holds the lock, 1 on a
# failed build (an earlier staged bundle, if any, is left as it was).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CHECKOUT=""
NEXT_DIR="${THREADBARE_UPDATE_DIR:-$HOME/Applications/.Threadbare.app.next}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --next) NEXT_DIR="$2"; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) CHECKOUT="$1" ;;
  esac
  shift
done
if [[ -z "$CHECKOUT" ]]; then
  CHECKOUT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [[ -z "$CHECKOUT" || ! -d "$CHECKOUT/.git" && ! -f "$CHECKOUT/.git" ]]; then
  echo "No checkout to build from (give the repo's path)." >&2
  exit 2
fi

# Launched from the app, PATH is the bare system one; swift, git, codesign
# and the rest are all under /usr/bin.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
CACHE="$HOME/Library/Caches/Threadbare/update"
SRC="$CACHE/src"
LOCK="$CACHE/lock"
mkdir -p "$CACHE"

# One build at a time. A lock older than an hour is from a run that died.
if [[ -d "$LOCK" ]] && [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]]; then
  rmdir "$LOCK" 2>/dev/null || true
fi
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Another update build is running (lock: $LOCK)." >&2
  exit 3
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

MAIN="$(git -C "$CHECKOUT" rev-parse --verify -q refs/heads/main)" || {
  echo "$CHECKOUT has no main branch." >&2
  exit 2
}
echo "Staging main ($(git -C "$CHECKOUT" rev-parse --short "$MAIN")) from $CHECKOUT into $NEXT_DIR"

# A clone of the checkout, moved to its main: only the files that changed
# get new mtimes, so the release build is incremental.
if [[ ! -d "$SRC/.git" ]]; then
  rm -rf "$SRC"
  git clone -q --no-checkout "$CHECKOUT" "$SRC"
fi
git -C "$SRC" fetch -q "$CHECKOUT" "refs/heads/main"
git -C "$SRC" checkout -q --detach FETCH_HEAD
git -C "$SRC" clean -qfd -e .build

THREADBARE_BUILD_CONFIGURATION=release \
THREADBARE_SCRATCH_PATH="$CACHE/build" \
THREADBARE_APP_DIR="$NEXT_DIR" \
THREADBARE_SOURCE_CHECKOUT="$CHECKOUT" \
  bash "$SRC/app/build-app.sh"
echo "Staged $NEXT_DIR; the app swaps it in when it next quits or launches."
