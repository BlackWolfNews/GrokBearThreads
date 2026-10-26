#!/usr/bin/env bash
# Runs the app against the mock runner, with a temp data folder so nothing
# touches the real runner. Extra arguments go to the mock runner
# (for example --filler 16).
#   THREADBARE_BIN=path/to/Threadbare  use a specific binary (default: the staged app)
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${THREADBARE_APP_DIR:-$HOME/Applications/Threadbare.app}"
BIN="${THREADBARE_BIN:-$APP_DIR/Contents/MacOS/Threadbare}"
DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/threadbare-mock.XXXXXX")"

if [[ ! -x "$BIN" ]]; then
  echo "No app at $BIN. Run ./build-app.sh first or set THREADBARE_BIN." >&2
  exit 1
fi
if [[ ! -d "$TOOLS_DIR/mock-runner/node_modules" ]]; then
  (cd "$TOOLS_DIR/mock-runner" && npm install --silent)
fi

node "$TOOLS_DIR/mock-runner/server.mjs" --data-dir "$DATA_DIR" "$@" &
MOCK_PID=$!
cleanup() {
  kill "$MOCK_PID" 2>/dev/null || true
  rm -rf "$DATA_DIR"
}
trap cleanup EXIT

for _ in $(seq 1 100); do
  [[ -f "$DATA_DIR/runner.json" ]] && break
  sleep 0.05
done

"$BIN" --data-dir "$DATA_DIR"
