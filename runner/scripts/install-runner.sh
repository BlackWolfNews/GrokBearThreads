#!/bin/bash
# Installs the Threadbare runner as a launchd LaunchAgent
# (com.mikerosoft.threadbare.runner) that starts at login and is restarted
# if it ever exits.
#
#   scripts/install-runner.sh              install (or reinstall) and start it
#   scripts/install-runner.sh --print      print the plist and change nothing
#   scripts/install-runner.sh --uninstall  stop it and remove the plist
#
# Options:
#   --node PATH   Node 24 binary to pin in the plist
#                 (default: $THREADBARE_NODE, else ~/.nvm/versions/node/v24.22.1/bin/node)
#   --path PATH   PATH for the runner and the agents it starts
#                 (default: your login shell's PATH, captured now)
#
# The runner reads its data dir and port from ~/Library/Application
# Support/Threadbare/runner.json, so nothing else is pinned here.
set -euo pipefail

LABEL="com.mikerosoft.threadbare.runner"
RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/threadbare-runner.log"
NODE="${THREADBARE_NODE:-$HOME/.nvm/versions/node/v24.22.1/bin/node}"
AGENT_PATH=""
MODE="install"

while [ $# -gt 0 ]; do
  case "$1" in
    --print) MODE="print" ;;
    --uninstall) MODE="uninstall" ;;
    --node) NODE="$2"; shift ;;
    --path) AGENT_PATH="$2"; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

DOMAIN="gui/$(id -u)"

if [ "$MODE" = "uninstall" ]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed $LABEL. Thread data in ~/Library/Application Support/Threadbare is untouched."
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

xml() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(xml "$NODE")</string>
		<string>$(xml "$RUNNER_DIR/src/main.ts")</string>
	</array>
	<key>WorkingDirectory</key>
	<string>$(xml "$RUNNER_DIR")</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$(xml "$AGENT_PATH")</string>
		<key>LANG</key>
		<string>en_US.UTF-8</string>
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

if [ ! -d "$RUNNER_DIR/node_modules/@anthropic-ai/claude-agent-sdk" ] || [ ! -d "$RUNNER_DIR/node_modules/ws" ]; then
  echo "Installing the runner's packages..."
  (cd "$RUNNER_DIR" && PATH="$(dirname "$NODE"):$PATH" npm ci)
fi

mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
TMP="$(mktemp "$PLIST.XXXXXX")"
plist > "$TMP"
plutil -lint "$TMP" >/dev/null
mv "$TMP" "$PLIST"

# Replace a running copy. The runner stops its CLIs on SIGTERM; threads
# that were mid-turn show as stopped and resume on the next message.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout returns before the old job is gone; bootstrap fails until it is.
for _ in $(seq 1 100); do
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  sleep 0.25
done
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart "$DOMAIN/$LABEL" 2>/dev/null || true

echo "Installed $LABEL"
echo "  node:   $NODE"
echo "  runner: $RUNNER_DIR/src/main.ts"
echo "  log:    $LOG"
echo "Restart it with: launchctl kickstart -k $DOMAIN/$LABEL"
