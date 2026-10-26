#!/usr/bin/env bash
# Saves the design screenshots (Sources/Threadbare/Screenshots.swift) from a
# debug build running against the mock runner's demo threads. Nothing touches
# the real runner, the staged app in ~/Applications or its settings (the
# build gets a bundle id of its own, removed afterwards), and the window
# stays behind whatever you're working in.
#   Tools/screenshots.sh <out dir> [--only <prefix>] [--appearance light|dark]
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$TOOLS_DIR/.." && pwd)"
OUT_DIR="${1:?usage: Tools/screenshots.sh <out dir> [--only <prefix>]}"
shift
WORK="$(mktemp -d "${TMPDIR:-/tmp}/threadbare-shots.XXXXXX")"
DATA_DIR="$WORK/data"
mkdir -p "$DATA_DIR" "$OUT_DIR"

if [[ ! -d "$TOOLS_DIR/mock-runner/node_modules" ]]; then
  (cd "$TOOLS_DIR/mock-runner" && npm install --silent)
fi

# A bundle (not the bare binary) so the app has its Info.plist, staged in the
# temp folder rather than over the app Mike is using.
THREADBARE_APP_DIR="$WORK/Threadbare.app" THREADBARE_BUILD_CONFIGURATION=debug \
  bash "$APP_ROOT/build-app.sh" >/dev/null
# Its own bundle id, so its own settings: with the installed app's id it
# read Mike's saved sidebar width and account, and left the shots' window
# size in his preferences. Re-signed ad hoc, since the plist is sealed.
SHOTS_ID="com.mikerosoft.threadbare.shots.$$"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SHOTS_ID" "$WORK/Threadbare.app/Contents/Info.plist"
codesign --force --sign - "$WORK/Threadbare.app" >/dev/null 2>&1

# Only the demo threads: private fixtures (real transcripts, tb exports)
# must never end up in screenshots that go on GitHub.
node "$TOOLS_DIR/mock-runner/server.mjs" --data-dir "$DATA_DIR" --fixtures "$TOOLS_DIR/mock-runner/fixtures" --quiet &
MOCK_PID=$!
cleanup() {
  kill "$MOCK_PID" 2>/dev/null || true
  rm -rf "$WORK"
  defaults delete "$SHOTS_ID" >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Preferences/$SHOTS_ID.plist" "$HOME/Library/Saved Application State/$SHOTS_ID.savedState" \
    "$(getconf DARWIN_USER_TEMP_DIR)$SHOTS_ID.savedState" "$HOME/Library/Caches/$SHOTS_ID"
}
trap cleanup EXIT

for _ in $(seq 1 100); do
  [[ -f "$DATA_DIR/runner.json" ]] && break
  sleep 0.05
done

"$WORK/Threadbare.app/Contents/MacOS/Threadbare" --data-dir "$DATA_DIR" --screenshots "$OUT_DIR" "$@"
