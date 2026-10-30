#!/bin/zsh
# Screenshots of the app on sample data (FakeBackend) in the simulator, into
# <dir> (default /tmp/tb-shots): the inbox, a few threads, New thread and the
# pair screen. Uses its own simulator, "Threadbear", made on first run, or
# SIM_NAME's (another thread may be using "Threadbear"). Pro Max sizes are
# the App Store's 6.9" (1320 x 2868); appstore-screenshots.mjs uploads them.
#
#   ios/scripts/sim-shots.sh [dir] [--dark]
#   SIM_NAME="Threadbear App Store" ios/scripts/sim-shots.sh ios/appstore/screenshots
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/tb-shots}
SIM_NAME=${SIM_NAME:-Threadbear}
mkdir -p "$OUT"
SIM=$(xcrun simctl list devices | grep " $SIM_NAME (" | grep -oE "[0-9A-F-]{36}" | head -1 || true)
if [[ -z "$SIM" ]]; then
  # Cloned from a stock 6.9" iPhone, since `simctl create` refuses some pairs.
  BASE=$(xcrun simctl list devices available | grep -E "iPhone 1[6-8] Pro Max" | grep -oE "[0-9A-F-]{36}" | head -1)
  SIM=$(xcrun simctl clone "$BASE" "$SIM_NAME")
fi
DD=/tmp/threadbear-dd-$SIM
xcodebuild -project Threadbear.xcodeproj -scheme Threadbear -configuration Debug -destination "id=$SIM" \
  -derivedDataPath "$DD" build | grep -E " error:|BUILD (SUCCEEDED|FAILED)"
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl ui "$SIM" appearance "$([[ "${2:-}" == --dark ]] && echo dark || echo light)"
xcrun simctl status_bar "$SIM" override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4
xcrun simctl uninstall "$SIM" com.mikecann.threadbear 2>/dev/null || true  # clears permission prompts from earlier runs
xcrun simctl install "$SIM" "$DD/Build/Products/Debug-iphonesimulator/Threadbear.app"
# shot <name> [launch args...]: on the sample threads, unless the first arg is --unpaired.
shot() {
  local name=$1; shift
  local args=(-ThreadbearFake)
  [[ "${1:-}" == --unpaired ]] && { args=(); shift; }
  xcrun simctl launch --terminate-running-process "$SIM" com.mikecann.threadbear "${args[@]}" "$@" >/dev/null
  sleep 3
  xcrun simctl io "$SIM" screenshot "$OUT/$name.png" >/dev/null 2>&1
  echo "$OUT/$name.png"
}
shot inbox
shot search -ThreadbearSearch settings
shot approval -ThreadbearOpen a1
shot question -ThreadbearOpen a2
shot reply -ThreadbearOpen a3
shot running -ThreadbearOpen a5
shot new-thread -ThreadbearCompose "Add a dark mode to the garden planner, matching the system setting"
shot pair --unpaired
