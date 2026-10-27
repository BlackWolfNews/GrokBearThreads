#!/bin/bash
# One-off, 27 Oct 2026: starts the Threadbare-to-Threadbear rename
# (migrate.sh) as a launchd job, from a copy outside the repo, so it carries
# on while the runner stops and the checkout moves. It waits for a quiet
# moment by itself. Progress: ~/Library/Logs/threadbear-rename.log
#
#   start.sh            start it
#   start.sh --cancel   stop it while it's still waiting (nothing has changed then)
set -euo pipefail

LABEL="com.mikerosoft.threadbear.rename"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STAGE="$HOME/Library/Application Support/threadbear-rename"
DOMAIN="gui/$(id -u)"
HERE="$(cd "$(dirname "$0")" && pwd)"
NODE_DIR="$HOME/.nvm/versions/node/v24.22.1/bin"

if [ "${1:-}" = "--cancel" ]; then
  if grep -q "stopping com.mikerosoft.threadbare.runner" "$HOME/Library/Logs/threadbear-rename.log" 2>/dev/null; then
    echo "It has already stopped the runner; cancelling now could leave things half moved. Let it finish or roll back." >&2
    exit 1
  fi
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Cancelled."
  exit 0
fi

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  echo "$LABEL is already loaded; start.sh --cancel first." >&2
  exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$HERE/migrate.sh" "$HERE/migrate-data.mjs" "$HERE/rename-tree.py" "$HERE/old-names.test.ts" "$HERE/start.sh" "$STAGE/"
chmod +x "$STAGE/migrate.sh"

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$STAGE/migrate.sh</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$NODE_DIR:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>HOME</key>
		<string>$HOME</string>
		<key>LANG</key>
		<string>en_US.UTF-8</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>LaunchOnlyOnce</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$HOME/Library/Logs/threadbear-rename.log</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/threadbear-rename.log</string>
</dict>
</plist>
EOF
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Started. It waits for every thread to be idle, then renames. Log: ~/Library/Logs/threadbear-rename.log"
