#!/bin/bash
# Runs this working tree's runner in the foreground on a throwaway data dir,
# to try a change without touching the installed runner.
#
#   scripts/dev-runner.sh [--home DIR] [--port N]
#
#   --home DIR   data dir (default: a new temp folder). The real one, and any
#                data dir an installed runner uses, are refused.
#   --port N     port (default 0: a free one, written to <home>/runner.json
#                where tb and the app find it)
#
# It prints the line that points tb at it and the --data-dir for the app,
# then runs until Ctrl-C, which stops it and the CLIs it started.
set -euo pipefail

RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE="${THREADBARE_NODE:-$HOME/.nvm/versions/node/v24.22.1/bin/node}"
DEFAULT_HOME="$HOME/Library/Application Support/Threadbare"
DATA_HOME=""
PORT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --home) DATA_HOME="$2"; shift ;;
    --port) PORT="$2"; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ ! -x "$NODE" ]; then
  echo "No Node binary at $NODE. Set THREADBARE_NODE to a Node 24 binary." >&2
  exit 1
fi

# The folder with symlinks resolved, or as given if it doesn't exist yet.
real_dir() {
  if [ -d "$1" ]; then (cd "$1" && pwd -P); else printf '%s' "${1%/}"; fi
}

if [ -z "$DATA_HOME" ]; then
  TMP_ROOT="${TMPDIR:-/tmp}"
  DATA_HOME="$(mktemp -d "${TMP_ROOT%/}/threadbare-dev.XXXXXX")"
fi
case "$DATA_HOME" in /*) ;; *) DATA_HOME="$PWD/$DATA_HOME" ;; esac
if [ "$(real_dir "$DATA_HOME")" = "$(real_dir "$DEFAULT_HOME")" ]; then
  echo "That's the real runner's data dir. Leave --home out to get a temp one." >&2
  exit 1
fi
mkdir -p "$DATA_HOME"
DATA_HOME="$(real_dir "$DATA_HOME")"
# A data dir with releases belongs to an installed runner (a sandbox
# install, say); its lock would stop this one anyway, but say why.
if [ -e "$DATA_HOME/runner/launch.mjs" ]; then
  echo "$DATA_HOME belongs to an installed runner. Use another --home." >&2
  exit 1
fi

if [ ! -d "$RUNNER_DIR/node_modules/@anthropic-ai/claude-agent-sdk" ] || [ ! -d "$RUNNER_DIR/node_modules/ws" ]; then
  echo "Installing the runner's packages..."
  (cd "$RUNNER_DIR" && PATH="$(dirname "$NODE"):$PATH" npm ci)
fi

LOG="$DATA_HOME/runner.log"
echo "Dev runner: $RUNNER_DIR (working tree)"
echo "  data: $DATA_HOME"
echo "  log:  $LOG (also shown here)"
echo "For tb:      export THREADBARE_HOME=$(printf '%q' "$DATA_HOME")"
echo "For the app: --data-dir $(printf '%q' "$DATA_HOME")"
echo "Ctrl-C stops it."
echo

cd "$RUNNER_DIR"
# Inside a thread these name the live runner and that thread; the dev
# runner sets its own for the CLIs it starts.
exec env -u THREADBARE_DATA_DIR -u THREADBARE_URL -u THREADBARE_THREAD_ID -u THREADBARE_RUNNER_VERSION \
  THREADBARE_HOME="$DATA_HOME" THREADBARE_PORT="$PORT" THREADBARE_LOG="$LOG" THREADBARE_LOG_STDERR=1 \
  "$NODE" src/main.ts
