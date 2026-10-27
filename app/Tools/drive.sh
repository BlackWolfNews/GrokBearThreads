#!/usr/bin/env bash
# Drives a debug build of the app launched with `--automation <log file>`
# (see Sources/Threadbear/Automation.swift) without bringing it to the front.
#
#   Tools/drive.sh '{"cmd":"select","id":"bea0"}'
#   Tools/drive.sh '{"cmd":"type","text":"hello"}' '{"cmd":"return"}'
#   Tools/drive.sh '{"cmd":"click","title":"Allow"}'
#   Tools/drive.sh '{"cmd":"status"}'
#
# Each command's result is a line in the log file the app was started with.
# THREADBEAR_AUTOMATION_ID=<id> reaches an app started with --automation-id
# <id>. Tools/dev-app.sh starts such apps and waits for each result.
set -euo pipefail
# THREADBARE_* was the old name for these variables: each stands in for its new name.
for v in $(compgen -e | grep '^THREADBARE_' || true); do n="THREADBEAR_${v#THREADBARE_}"; [ -n "${!n+x}" ] || export "$n=${!v}"; done
CHANNEL="com.mikerosoft.threadbear.automation${THREADBEAR_AUTOMATION_ID:+.$THREADBEAR_AUTOMATION_ID}"

if [[ $# -eq 0 ]]; then
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
for command in "$@"; do
  # JavaScript for Automation reaches Foundation without compiling anything.
  /usr/bin/osascript -l JavaScript - "$command" "$CHANNEL" >/dev/null <<'JXA' || { echo "couldn't post $command" >&2; exit 1; }
ObjC.import('Foundation');
function run(argv) {
  $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(
    argv[1], argv[0], $(), true);
}
JXA
  sleep 0.3
done
