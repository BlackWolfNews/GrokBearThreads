#!/bin/bash
# Checks the runner and the app on the pinned Node 24: one line per step,
# the end of the log for each step that failed, and a nonzero exit if any
# did.
#
#   ./check.sh [--quick] [--e2e] [--shots DIR]
#
#   (no options)  runner typecheck, unit tests and deploy tests, then the
#                 app's swift build and swift test (about a minute)
#   --quick       runner typecheck and unit tests only
#   --e2e         also the runner's end-to-end tests: the real claude CLI on
#                 claude-haiku-5-5 and account claude-3, in temp folders
#                 (a few minutes, a few cents)
#   --shots DIR   also save the app's design screenshots to DIR
#                 (app/Tools/screenshots.sh; look at them afterwards)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE="${THREADBARE_NODE:-$HOME/.nvm/versions/node/v24.22.1/bin/node}"
QUICK=0
E2E=0
SHOTS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1 ;;
    --e2e) E2E=1 ;;
    --shots)
      [ $# -ge 2 ] || { echo "--shots needs a folder" >&2; exit 2; }
      case "$2" in /*) SHOTS="$2" ;; *) SHOTS="$PWD/$2" ;; esac
      shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ ! -x "$NODE" ]; then
  echo "No Node binary at $NODE. Set THREADBARE_NODE to a Node 24 binary." >&2
  exit 1
fi
export PATH="$(dirname "$NODE"):$PATH"
export THREADBARE_NODE="$NODE"
# Inside a Threadbare thread these name the live runner and the thread.
# Every test makes its own temp data dir; none may find the real one.
unset THREADBARE_HOME THREADBARE_DATA_DIR THREADBARE_PORT THREADBARE_URL THREADBARE_LOG \
  THREADBARE_THREAD_ID THREADBARE_RUNNER_VERSION THREADBARE_RUNNER_HOME

TMP_ROOT="${TMPDIR:-/tmp}"
LOGS="$(mktemp -d "${TMP_ROOT%/}/threadbare-check.XXXXXX")"
FAILED=""

# step <name> <dir> <command...>: runs it with its output in a log file.
step() {
  local name="$1" dir="$2"
  shift 2
  local log="$LOGS/$(printf '%s' "$name" | tr -c 'a-zA-Z0-9' '-').log"
  local start=$SECONDS
  if (cd "$dir" && "$@") >"$log" 2>&1; then
    printf 'ok    %-20s %4ss\n' "$name" "$((SECONDS - start))"
  else
    printf 'FAIL  %-20s %4ss  %s\n' "$name" "$((SECONDS - start))" "$log"
    FAILED="$FAILED$name|$log
"
  fi
}

if [ ! -d "$ROOT/runner/node_modules" ]; then
  step "runner packages" "$ROOT/runner" npm ci --no-audit --no-fund
fi
step "runner typecheck" "$ROOT/runner" npm run typecheck
step "runner unit tests" "$ROOT/runner" npm test
if [ "$QUICK" = 0 ]; then
  step "runner deploy tests" "$ROOT/runner" bash test/deploy/run.sh
  step "app build" "$ROOT/app" swift build
  step "app tests" "$ROOT/app" swift test
fi
[ "$E2E" = 0 ] || step "runner e2e" "$ROOT/runner" npm run test:e2e
[ -z "$SHOTS" ] || step "app screenshots" "$ROOT/app" bash Tools/screenshots.sh "$SHOTS"

if [ -n "$FAILED" ]; then
  printf '%s' "$FAILED" | while IFS='|' read -r name log; do
    echo
    echo "--- $name: end of $log"
    tail -n 30 "$log"
  done
  exit 1
fi
rm -rf "$LOGS"
[ -z "$SHOTS" ] || echo "Screenshots are in $SHOTS."
