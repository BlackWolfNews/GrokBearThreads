#!/usr/bin/env bash
# Builds a release app into a temp folder, starts the mock runner with the
# fixtures (app/.fixtures from Tools/fixture-export, plus the synthetic ones
# and 16 filler threads), runs `Threadbare --perf-run` and prints the report.
# The report is also saved to app/.fixtures/perf/.
#   perf-run.sh [--stream-seconds 60]
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$TOOLS_DIR/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/threadbare-perf.XXXXXX")"
DATA_DIR="$WORK/data"
OUT_DIR="$APP_ROOT/.fixtures/perf"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DATA_DIR" "$OUT_DIR"

if [[ ! -d "$APP_ROOT/.fixtures" ]] || ! ls "$APP_ROOT/.fixtures" | grep -q '^rows-'; then
  echo "No fixtures yet. Run: node Tools/fixture-export/export.mjs --pick 87,451,2114,4100" >&2
  exit 1
fi
if [[ ! -d "$TOOLS_DIR/mock-runner/node_modules" ]]; then
  (cd "$TOOLS_DIR/mock-runner" && npm install --silent)
fi

THREADBARE_APP_DIR="$WORK/Threadbare.app" THREADBARE_BUILD_CONFIGURATION=release bash "$APP_ROOT/build-app.sh" >/dev/null

# 16 copies of the three biggest fixtures (same events and media, their own
# thread ids), so the 20-thread memory step loads real-size threads rather
# than small synthetic ones. The copies only exist in this temp folder.
COPIES="$WORK/copies"
mkdir -p "$COPIES"
SOURCES=()
for name in rows-4100 rows-2114 rows-0451; do
  [[ -f "$APP_ROOT/.fixtures/$name/thread.json" ]] && SOURCES+=("$name")
done
if [[ ${#SOURCES[@]} -gt 0 ]]; then
  for i in $(seq 1 16); do
    src="${SOURCES[$(( (i - 1) % ${#SOURCES[@]} ))]}"
    dir="$COPIES/copy-$(printf '%02d' "$i")"
    mkdir -p "$dir"
    ln -s "$APP_ROOT/.fixtures/$src/events.ndjson" "$dir/events.ndjson"
    [[ -d "$APP_ROOT/.fixtures/$src/media" ]] && ln -s "$APP_ROOT/.fixtures/$src/media" "$dir/media"
    node -e '
      const fs = require("fs");
      const [from, to, n] = process.argv.slice(1);
      const t = JSON.parse(fs.readFileSync(from, "utf8"));
      t.id = `fx_copy_${n}_${t.id}`;
      t.title = `Copy ${n} of ${t.title}`;
      fs.writeFileSync(to, JSON.stringify(t));
    ' "$APP_ROOT/.fixtures/$src/thread.json" "$dir/thread.json" "$i"
  done
fi

node "$TOOLS_DIR/mock-runner/server.mjs" --data-dir "$DATA_DIR" --filler 16 --quiet \
  --fixtures "$TOOLS_DIR/mock-runner/fixtures" --fixtures "$APP_ROOT/.fixtures" --fixtures "$COPIES" &
MOCK_PID=$!
cleanup() {
  kill "$MOCK_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for _ in $(seq 1 200); do
  [[ -f "$DATA_DIR/runner.json" ]] && break
  sleep 0.05
done

"$WORK/Threadbare.app/Contents/MacOS/Threadbare" --data-dir "$DATA_DIR" --perf-run \
  --perf-report "$OUT_DIR/perf-$STAMP.json" "$@"
echo ""
echo "Saved $OUT_DIR/perf-$STAMP.json and .txt"
