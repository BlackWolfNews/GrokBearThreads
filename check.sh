#!/bin/bash
# Checks the runner and the app on the pinned Node 24: one line per step,
# what failed and the end of the log for each step that failed, and a
# nonzero exit if any did.
#
#   ./check.sh [--quick | --app] [--e2e] [--shots DIR]
#
#   (no options)  runner typecheck, unit tests and deploy tests, then the
#                 app's swift build and swift test (about two and a half
#                 minutes, most of it the deploy tests)
#   --quick       runner typecheck and unit tests only (about 10 seconds)
#   --app         the app's swift build and swift test only, for a change
#                 that doesn't touch runner/ (about 30 seconds)
#   --e2e         also the runner's end-to-end tests: the real claude CLI on
#                 claude-haiku-5-5 and account claude-3, then Codex on
#                 gpt-6-luna at low effort and a Codex install into a temp
#                 folder, all in temp folders (several minutes, a few cents;
#                 TB_E2E_SKIP_CODEX=1 leaves the Codex ones out)
#   --shots DIR   also save the app's design screenshots to DIR
#                 (app/Tools/screenshots.sh; look at them afterwards)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE="${THREADBEAR_NODE:-$HOME/.nvm/versions/node/v24.22.1/bin/node}"
QUICK=0
APP_ONLY=0
E2E=0
SHOTS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1 ;;
    --app) APP_ONLY=1 ;;
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

if [ "$QUICK" = 1 ] && [ "$APP_ONLY" = 1 ]; then
  echo "--quick is the runner's checks and --app the app's; pick one (or neither for both)." >&2
  exit 2
fi

if [ ! -x "$NODE" ]; then
  echo "No Node binary at $NODE. Set THREADBEAR_NODE to a Node 24 binary." >&2
  exit 1
fi
export PATH="$(dirname "$NODE"):$PATH"
export THREADBEAR_NODE="$NODE"
# Inside a Threadbear thread these name the live runner and the thread.
# Every test makes its own temp data dir; none may find the real one.
unset THREADBEAR_HOME THREADBEAR_DATA_DIR THREADBEAR_PORT THREADBEAR_URL THREADBEAR_LOG \
  THREADBEAR_THREAD_ID THREADBEAR_RUNNER_VERSION THREADBEAR_RUNNER_HOME
# And their old names, which the runner and tb would otherwise take for these.
for v in $(compgen -e | grep '^THREADBARE_' || true); do unset "$v"; done
# No runner a check starts may install or update a CLI.
export THREADBEAR_CLI_UPDATES=off
# Nor write to the real Convex project (the sync e2e points its own runner
# at a local deployment with THREADBEAR_SYNC_URL).
export THREADBEAR_SYNC=off

TMP_ROOT="${TMPDIR:-/tmp}"
LOGS="$(mktemp -d "${TMP_ROOT%/}/threadbear-check.XXXXXX")"
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

if [ "$APP_ONLY" = 0 ]; then
  if [ ! -d "$ROOT/runner/node_modules" ]; then
    step "runner packages" "$ROOT/runner" npm ci --no-audit --no-fund
  fi
  step "runner typecheck" "$ROOT/runner" npm run typecheck
  # The Convex functions (convex/), against the generated types in git.
  if [ ! -d "$ROOT/node_modules" ]; then
    step "convex packages" "$ROOT" npm ci --no-audit --no-fund
  fi
  step "convex typecheck" "$ROOT" npm run convex:typecheck
  step "web typecheck" "$ROOT" npm run web:typecheck
  step "runner unit tests" "$ROOT/runner" npm test
  [ "$QUICK" = 1 ] || step "runner deploy tests" "$ROOT/runner" bash test/deploy/run.sh
fi
if [ "$QUICK" = 0 ]; then
  # The app's MockRunnerTests run the real WebSocket client (and the
  # runner restart) against the mock, and skip without its packages: in a
  # fresh checkout or worktree they used to skip while this said ok.
  if [ ! -d "$ROOT/app/Tools/mock-runner/node_modules" ]; then
    step "mock runner packages" "$ROOT/app/Tools/mock-runner" npm ci --no-audit --no-fund
  fi
  step "app build" "$ROOT/app" swift build
  step "app tests" "$ROOT/app" env THREADBEAR_REQUIRE_MOCK=1 swift test
fi
if [ "$E2E" = 1 ]; then
  # Claude's first, then Codex's (codex*.e2e.test.ts: the conversation
  # tests and the install test), which TB_E2E_SKIP_CODEX=1 leaves out.
  E2E_RUN=(node --test --test-reporter=spec --test-concurrency=1 --test-timeout=600000)
  CLAUDE_E2E=()
  CODEX_E2E=()
  for f in "$ROOT"/runner/test/e2e/*.test.ts; do
    case "$(basename "$f")" in codex*) CODEX_E2E+=("$f") ;; *) CLAUDE_E2E+=("$f") ;; esac
  done
  step "runner e2e" "$ROOT/runner" "${E2E_RUN[@]}" "${CLAUDE_E2E[@]}"
  if [ "${TB_E2E_SKIP_CODEX:-0}" = 1 ]; then
    echo "skip  codex e2e            (TB_E2E_SKIP_CODEX=1)"
  elif [ "${#CODEX_E2E[@]}" -gt 0 ]; then
    step "codex e2e" "$ROOT/runner" "${E2E_RUN[@]}" "${CODEX_E2E[@]}"
  fi
fi
[ -z "$SHOTS" ] || step "app screenshots" "$ROOT/app" bash Tools/screenshots.sh "$SHOTS"

if [ -n "$FAILED" ]; then
  printf '%s' "$FAILED" | while IFS='|' read -r name log; do
    # The failures themselves first: swift test runs the core tests before
    # the app's, so a failing core test is hundreds of lines above the end
    # of its log (XCTest's "error:" and "failed (", Swift Testing's ✘, the
    # node test runner's ✖ and "not ok", tsc's "error TS").
    # (swift colours its output even into a file, so that comes off first.)
    failures="$(sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g' "$log" | grep -nE ': error[: ]|error TS[0-9]|'"'"' failed \(|^not ok|✖|✘' | head -n 20)"
    if [ -n "$failures" ]; then
      echo
      echo "--- $name: what failed (line: text) in $log"
      printf '%s\n' "$failures"
    fi
    echo
    echo "--- $name: end of $log"
    tail -n 30 "$log"
  done
  echo
  echo "Logs kept in $LOGS; rm -rf it when you're done."
  exit 1
fi
rm -rf "$LOGS"
[ -z "$SHOTS" ] || echo "Screenshots are in $SHOTS."
