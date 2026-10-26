#!/usr/bin/env bash
# Drives a debug build of the app launched with `--automation <log file>`
# (see Sources/Threadbare/Automation.swift) without bringing it to the front.
#
#   Tools/drive.sh '{"cmd":"select","id":"bea0"}'
#   Tools/drive.sh '{"cmd":"type","text":"hello"}' '{"cmd":"return"}'
#   Tools/drive.sh '{"cmd":"click","title":"Allow"}'
#   Tools/drive.sh '{"cmd":"status"}'
#
# Each command's result is a line in the log file the app was started with.
set -euo pipefail

if [[ $# -eq 0 ]]; then
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
for command in "$@"; do
  # JavaScript for Automation reaches Foundation without compiling anything.
  /usr/bin/osascript -l JavaScript - "$command" >/dev/null <<'JXA' || { echo "couldn't post $command" >&2; exit 1; }
ObjC.import('Foundation');
function run(argv) {
  $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(
    'com.mikerosoft.threadbare.automation', argv[0], $(), true);
}
JXA
  sleep 0.3
done
