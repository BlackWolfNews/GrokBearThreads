#!/bin/bash
# Installs the Threadbare runner as a launchd LaunchAgent
# (com.mikerosoft.threadbare.runner) that starts at login and is restarted
# if it ever exits.
#
#   scripts/install-runner.sh              install (or reinstall) and start it
#   scripts/install-runner.sh --print      print the plist and change nothing
#   scripts/install-runner.sh --uninstall  stop it and remove the plist
#
# The runner runs from a release, never from this checkout: the plist
# starts <home>/runner/launch.mjs, which starts the release
# <home>/runner/current points at. The first release is built here; after
# that, ship changes with scripts/deploy-runner.sh.
#
# Options:
#   --from-source  run src/main.ts straight from this checkout instead, as
#                  before releases (for debugging the runner itself)
#   --home DIR     data dir (default ~/Library/Application Support/Threadbare)
#   --label LABEL  launchd label (default com.mikerosoft.threadbare.runner)
#   --port N       port to listen on (default: the one in runner.json, else
#                  8797). A sandbox next to the real runner needs its own
#                  --home and --label; its port defaults to 0, a free one.
#   --node PATH    Node 24 binary to pin in the plist
#                  (default: $THREADBARE_NODE, else ~/.nvm/versions/node/v24.22.1/bin/node)
#   --path PATH    PATH for the runner and the agents it starts
#                  (default: your login shell's PATH, captured now)
#
# THREADBARE_LAUNCHCTL and THREADBARE_LAUNCH_AGENTS_DIR replace launchctl
# and ~/Library/LaunchAgents (the tests use both).
set -euo pipefail

DEFAULT_LABEL="com.mikerosoft.threadbare.runner"
DEFAULT_HOME="$HOME/Library/Application Support/Threadbare"
RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE="${THREADBARE_NODE:-$HOME/.nvm/versions/node/v24.22.1/bin/node}"
LAUNCHCTL="${THREADBARE_LAUNCHCTL:-launchctl}"
AGENTS_DIR="${THREADBARE_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
LABEL="$DEFAULT_LABEL"
DATA_HOME="$DEFAULT_HOME"
PORT=""
AGENT_PATH=""
FROM_SOURCE=0
MODE="install"
ARGS=("$@")

while [ $# -gt 0 ]; do
  case "$1" in
    --print) MODE="print" ;;
    --uninstall) MODE="uninstall" ;;
    --from-source) FROM_SOURCE=1 ;;
    --home) DATA_HOME="$2"; shift ;;
    --label) LABEL="$2"; shift ;;
    --port) PORT="$2"; shift ;;
    --node) NODE="$2"; shift ;;
    --path) AGENT_PATH="$2"; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

case "$DATA_HOME" in /*) ;; *) DATA_HOME="$PWD/$DATA_HOME" ;; esac
DATA_HOME="${DATA_HOME%/}"

# Same folder, even through a symlink (/tmp is /private/tmp).
same_dir() {
  [ "$1" = "$2" ] && return 0
  [ -d "$1" ] && [ -d "$2" ] && [ "$(cd "$1" && pwd -P)" = "$(cd "$2" && pwd -P)" ]
}

SANDBOX=0
same_dir "$DATA_HOME" "$DEFAULT_HOME" || SANDBOX=1
# A sandbox under the real label would replace the real runner, and a
# second label on the real data dir would be a second runner fighting
# for its lock.
if [ "$SANDBOX" = 1 ] && [ "$LABEL" = "$DEFAULT_LABEL" ]; then
  echo "A runner on another data dir needs its own --label (say $DEFAULT_LABEL.devtest), or it would replace the real one." >&2
  exit 1
fi
if [ "$SANDBOX" = 0 ] && [ "$LABEL" != "$DEFAULT_LABEL" ]; then
  echo "$DATA_HOME belongs to $DEFAULT_LABEL; give a second runner its own --home." >&2
  exit 1
fi
if [ "$SANDBOX" = 1 ]; then
  [ -n "$PORT" ] || PORT=0
  LOG="$DATA_HOME/runner.log"
else
  LOG="$HOME/Library/Logs/threadbare-runner.log"
fi
PLIST="$AGENTS_DIR/$LABEL.plist"
DOMAIN="gui/$(id -u)"

# Reinstalling or removing the runner a thread runs on ends that thread's
# turn, so an agent hands it to Mike instead.
if [ "$MODE" != "print" ] && [ -n "${THREADBARE_THREAD_ID:-}" ] \
  && same_dir "${THREADBARE_HOME:-${THREADBARE_DATA_DIR:-$DEFAULT_HOME}}" "$DATA_HOME"; then
  echo "This would stop the runner this thread runs on and end this turn. Ask Mike to run it from a terminal:" >&2
  printf '  %q' "$RUNNER_DIR/scripts/install-runner.sh" ${ARGS[@]+"${ARGS[@]}"} >&2
  echo >&2
  exit 1
fi

if [ "$MODE" = "uninstall" ]; then
  "$LAUNCHCTL" bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed $LABEL. The data in $DATA_HOME (releases included) is untouched."
  exit 0
fi

if [ ! -x "$NODE" ]; then
  echo "No Node binary at $NODE. Pass --node /path/to/node (Node 24 or newer)." >&2
  exit 1
fi
NODE_MAJOR="$("$NODE" -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 24 ]; then
  echo "$NODE is Node $NODE_MAJOR; the runner needs Node 24 or newer (it runs TypeScript directly)." >&2
  exit 1
fi

if [ -z "$AGENT_PATH" ]; then
  # launchd starts jobs with a bare PATH. Agents run shell commands, so give
  # them the PATH a terminal would have. Markers skip anything the shell's
  # startup files print.
  AGENT_PATH="$("${SHELL:-/bin/zsh}" -ilc 'printf "__TBPATH__%s__TBPATH__" "$PATH"' </dev/null 2>/dev/null \
    | sed -n 's/.*__TBPATH__\(.*\)__TBPATH__.*/\1/p' || true)"
  [ -n "$AGENT_PATH" ] || AGENT_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
fi
# The pinned Node and the claude CLI (~/.local/bin) always come first.
AGENT_PATH="$(dirname "$NODE"):$HOME/.local/bin:$AGENT_PATH"

if [ "$FROM_SOURCE" = 1 ]; then
  PROGRAM="$RUNNER_DIR/src/main.ts"
  WORKDIR="$RUNNER_DIR"
else
  PROGRAM="$DATA_HOME/runner/launch.mjs"
  WORKDIR="$DATA_HOME/runner"
fi

# sed rather than ${s//</&lt;}: bash 5.2 reads & in a replacement as the
# match, so that would differ between /bin/bash and Homebrew's.
xml() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

env_entry() {
  printf '\t\t<key>%s</key>\n\t\t<string>%s</string>\n' "$1" "$(xml "$2")"
}

plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$(xml "$LABEL")</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(xml "$NODE")</string>
		<string>$(xml "$PROGRAM")</string>
	</array>
	<key>WorkingDirectory</key>
	<string>$(xml "$WORKDIR")</string>
	<key>EnvironmentVariables</key>
	<dict>
$(env_entry PATH "$AGENT_PATH")
$(env_entry LANG en_US.UTF-8)
EOF
  if [ "$SANDBOX" = 1 ]; then
    env_entry THREADBARE_HOME "$DATA_HOME"
    env_entry THREADBARE_LOG "$LOG"
  fi
  [ -z "$PORT" ] || env_entry THREADBARE_PORT "$PORT"
  cat <<EOF
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>5</integer>
	<key>ExitTimeOut</key>
	<integer>20</integer>
	<key>StandardOutPath</key>
	<string>$(xml "$LOG")</string>
	<key>StandardErrorPath</key>
	<string>$(xml "$LOG")</string>
</dict>
</plist>
EOF
}

if [ "$MODE" = "print" ]; then
  plist
  exit 0
fi

# deploy-runner.sh, on the Node the plist pins.
deploy() {
  THREADBARE_NODE="$NODE" bash "$RUNNER_DIR/scripts/deploy-runner.sh" --home "$DATA_HOME" --label "$LABEL" "$@"
}

if [ "$FROM_SOURCE" = 1 ]; then
  if [ ! -d "$RUNNER_DIR/node_modules/@anthropic-ai/claude-agent-sdk" ] || [ ! -d "$RUNNER_DIR/node_modules/ws" ]; then
    echo "Installing the runner's packages..."
    (cd "$RUNNER_DIR" && PATH="$(dirname "$NODE"):$PATH" npm ci)
  fi
else
  mkdir -p "$DATA_HOME/runner"
  cp "$RUNNER_DIR/launch.mjs" "$DATA_HOME/runner/.launch.mjs.tmp"
  mv "$DATA_HOME/runner/.launch.mjs.tmp" "$DATA_HOME/runner/launch.mjs"
  if [ -L "$DATA_HOME/runner/current" ]; then
    echo "Keeping release $(basename "$(readlink "$DATA_HOME/runner/current")"). Ship a new one with scripts/deploy-runner.sh."
  else
    deploy --no-restart
  fi
fi

mkdir -p "$AGENTS_DIR" "$(dirname "$LOG")"
TMP="$(mktemp "$PLIST.XXXXXX")"
plist > "$TMP"
plutil -lint "$TMP" >/dev/null
mv "$TMP" "$PLIST"

# Replace a running copy. The runner stops its CLIs on SIGTERM; threads
# that were mid-turn show as stopped and resume on the next message.
"$LAUNCHCTL" bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout returns before the old job is gone; bootstrap fails until it is.
for _ in $(seq 1 100); do
  "$LAUNCHCTL" print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  sleep 0.25
done
"$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST"
"$LAUNCHCTL" kickstart "$DOMAIN/$LABEL" 2>/dev/null || true

echo "Installed $LABEL"
echo "  node:   $NODE"
echo "  runner: $PROGRAM"
echo "  data:   $DATA_HOME"
echo "  log:    $LOG"
if [ "$FROM_SOURCE" = 0 ]; then
  deploy --check
  if [ "$SANDBOX" = 1 ]; then
    echo "Ship changes with: scripts/deploy-runner.sh --home $(printf '%q' "$DATA_HOME") --label $LABEL"
  else
    echo "Ship changes with: scripts/deploy-runner.sh"
  fi
fi
echo "Restart it with: launchctl kickstart -k $DOMAIN/$LABEL"
