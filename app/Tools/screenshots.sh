#!/usr/bin/env bash
# Saves the design screenshots (Sources/Threadbare/Screenshots.swift) from a
# debug build running against the mock runner's demo threads. Nothing touches
# the real runner or the staged app in ~/Applications, and the window stays
# behind whatever you're working in.
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

# Only the demo threads: private fixtures (real transcripts, tb exports)
# must never end up in screenshots that go on GitHub.
node "$TOOLS_DIR/mock-runner/server.mjs" --data-dir "$DATA_DIR" --fixtures "$TOOLS_DIR/mock-runner/fixtures" --quiet &
MOCK_PID=$!
cleanup() {
  kill "$MOCK_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

for _ in $(seq 1 100); do
  [[ -f "$DATA_DIR/runner.json" ]] && break
  sleep 0.05
done

"$WORK/Threadbare.app/Contents/MacOS/Threadbare" --data-dir "$DATA_DIR" --screenshots "$OUT_DIR" "$@"
