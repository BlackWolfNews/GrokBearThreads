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
# It replaces a running copy only when no thread is busy (a turn, or
# background shells and subagents), since that stops them; --force does it
# anyway. If the new runner doesn't come up, the old plist is put back.
#
# Options:
#   --from-source  run src/main.ts straight from this checkout instead, as
#                  before releases (for debugging the runner itself)
#   --force        replace the running copy even if threads are busy
#   --allow-branch build the first release from a HEAD that isn't main's tip
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
FORCE=0
ALLOW_BRANCH=0
HOME_GIVEN=0
MODE="install"
ARGS=("$@")

while [ $# -gt 0 ]; do
  case "$1" in
    --print) MODE="print" ;;
    --uninstall) MODE="uninstall" ;;
    --from-source) FROM_SOURCE=1 ;;
    --force) FORCE=1 ;;
    --allow-branch) ALLOW_BRANCH=1 ;;
    --home) DATA_HOME="$2"; HOME_GIVEN=1; shift ;;
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

# The pid in <home>/run/runner.pid (plain, or JSON with the pid first).
runner_pid() {
  [ -f "$1/run/runner.pid" ] || return 1
  grep -o '[0-9][0-9]*' "$1/run/runner.pid" 2>/dev/null | head -n 1
}

# True if pid $1 is an ancestor of this script: a CLI that runner started
# ran it, directly or through a shell or a dev runner.
is_ancestor() {
  local p="$PPID" n=0
  while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$n" -lt 200 ]; do
    [ "$p" = "$1" ] && return 0
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    n=$((n + 1))
  done
  return 1
}

# Reinstalling or removing the runner a thread runs on ends that thread's
# turn, so an agent hands it to Mike instead. That's decided by the process
# tree (which works under any runner, and whatever an agent exported) and
# by THREADBARE_RUNNER_HOME, which the runner sets and nothing tells an
# agent to change. THREADBARE_HOME is the one agents point at dev runners,
# so it can't be trusted for this. The real runner is refused from any
# thread at all.
if [ "$MODE" != "print" ]; then
  IN_THREAD=0
  PID="$(runner_pid "$DATA_HOME" || true)"
  if [ -n "$PID" ] && is_ancestor "$PID"; then IN_THREAD=1; fi
  if [ -n "${THREADBARE_THREAD_ID:-}" ]; then
    if [ "$SANDBOX" = 0 ] || same_dir "${THREADBARE_RUNNER_HOME:-${THREADBARE_HOME:-${THREADBARE_DATA_DIR:-$DEFAULT_HOME}}}" "$DATA_HOME"; then IN_THREAD=1; fi
  fi
  if [ "$IN_THREAD" = 1 ]; then
    echo "This would stop the runner this thread runs on and end this turn. Ask Mike to run it from a terminal:" >&2
    printf '  %q' "$RUNNER_DIR/scripts/install-runner.sh" ${ARGS[@]+"${ARGS[@]}"} >&2
    echo >&2
    exit 1
  fi
fi
# deploy-runner.sh takes its data dir from THREADBARE_HOME; this script
# doesn't, so someone counting on it would reinstall the real runner.
if [ "$HOME_GIVEN" = 0 ] && [ -n "${THREADBARE_HOME:-}" ] && ! same_dir "$THREADBARE_HOME" "$DEFAULT_HOME"; then
  echo "THREADBARE_HOME is $THREADBARE_HOME, but install-runner.sh only goes by --home (default $DEFAULT_HOME). Pass --home." >&2
  exit 1
fi

if [ "$MODE" = "uninstall" ]; then
  if [ "$FORCE" = 0 ] && "$LAUNCHCTL" print "$DOMAIN/$LABEL" >/dev/null 2>&1 && [ -x "$NODE" ] \
    && ! THREADBARE_NODE="$NODE" bash "$RUNNER_DIR/scripts/deploy-runner.sh" --home "$DATA_HOME" --label "$LABEL" --check-idle; then
    echo "Not removing $LABEL while threads are busy: they'd be cut short. Run it again once they finish, or add --force." >&2
    exit 1
  fi
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

# Stops the job and starts it again from the plist.
reload() {
  "$LAUNCHCTL" bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  # bootout returns before the old job is gone; bootstrap fails until it is.
  for _ in $(seq 1 100); do
    "$LAUNCHCTL" print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
    sleep 0.25
  done
  "$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST"
  "$LAUNCHCTL" kickstart "$DOMAIN/$LABEL" 2>/dev/null || true
}

if [ "$FROM_SOURCE" = 1 ]; then
  if [ ! -d "$RUNNER_DIR/node_modules/@anthropic-ai/claude-agent-sdk" ] || [ ! -d "$RUNNER_DIR/node_modules/ws" ]; then
    echo "Installing the runner's packages..."
    (cd "$RUNNER_DIR" && PATH="$(dirname "$NODE"):$PATH" npm ci)
  fi
else
  mkdir -p "$DATA_HOME/runner"
  if [ -L "$DATA_HOME/runner/current" ]; then
    echo "Keeping release $(basename "$(readlink "$DATA_HOME/runner/current")"). Ship a new one with scripts/deploy-runner.sh."
  else
    BRANCH_ARG=()
    [ "$ALLOW_BRANCH" = 0 ] || BRANCH_ARG=(--allow-branch)
    deploy --no-restart ${BRANCH_ARG[@]+"${BRANCH_ARG[@]}"}
  fi
  # Only once there's a release for it to start: deploy-runner.sh takes
  # launch.mjs being here to mean the LaunchAgent runs releases.
  cp "$RUNNER_DIR/launch.mjs" "$DATA_HOME/runner/.launch.mjs.tmp"
  mv "$DATA_HOME/runner/.launch.mjs.tmp" "$DATA_HOME/runner/launch.mjs"
fi

# Replacing a running copy stops its CLIs, and every turn and background
# job with them, so only when nothing is busy.
LOADED=0
"$LAUNCHCTL" print "$DOMAIN/$LABEL" >/dev/null 2>&1 && LOADED=1
if [ "$LOADED" = 1 ] && [ "$FORCE" = 0 ] && ! deploy --check-idle; then
  echo "Not replacing the running $LABEL while threads are busy: they'd be cut short. Run this again once they finish, or add --force." >&2
  exit 1
fi

mkdir -p "$AGENTS_DIR" "$(dirname "$LOG")" "$DATA_HOME/runner"
# The plist this replaces, to put back if the new one doesn't come up.
# Kept in the data dir: launchd reads every file in LaunchAgents.
PREV="$DATA_HOME/runner/previous-launchagent.plist"
rm -f "$PREV"
[ ! -f "$PLIST" ] || cp "$PLIST" "$PREV"
TMP="$(mktemp "$PLIST.XXXXXX")"
plist > "$TMP"
plutil -lint "$TMP" >/dev/null
mv "$TMP" "$PLIST"

# The runner stops its CLIs on SIGTERM; threads that were mid-turn show as
# stopped and resume on the next message.
reload

echo "Installed $LABEL"
echo "  node:   $NODE"
echo "  runner: $PROGRAM"
echo "  data:   $DATA_HOME"
echo "  log:    $LOG"
if [ "$FROM_SOURCE" = 1 ]; then
  # So nothing takes this data dir to run releases (deploy-runner.sh
  # refuses to ship to it); installing without --from-source copies it in
  # again.
  [ ! -f "$DATA_HOME/runner/launch.mjs" ] || mv "$DATA_HOME/runner/launch.mjs" "$DATA_HOME/runner/launch.mjs.unused"
else
  if ! deploy --check; then
    if [ -f "$PREV" ]; then
      echo "The runner didn't come up on its release, so the LaunchAgent goes back to the plist it had." >&2
      mv "$PREV" "$PLIST"
      reload
      echo "Back on the old plist. The log above says what went wrong; fix it and run this again." >&2
    else
      echo "The runner didn't come up on its release. To run it from this checkout instead:" >&2
      printf '  %q' "$RUNNER_DIR/scripts/install-runner.sh" --from-source ${ARGS[@]+"${ARGS[@]}"} >&2
      echo >&2
    fi
    exit 1
  fi
  if [ "$SANDBOX" = 1 ]; then
    echo "Ship changes with: scripts/deploy-runner.sh --home $(printf '%q' "$DATA_HOME") --label $LABEL"
  else
    echo "Ship changes with: scripts/deploy-runner.sh"
  fi
fi
rm -f "$PREV"
echo "Restart it with: launchctl kickstart -k $DOMAIN/$LABEL"
