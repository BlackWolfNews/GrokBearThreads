#!/bin/zsh
# Screenshots of the app on sample data (FakeBackend) in the simulator, into
# <dir> (default /tmp/tb-shots): the inbox and a few threads. Uses its own
# simulator, "Threadbear", made on first run.
#
#   ios/scripts/sim-shots.sh [dir] [--dark]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/tb-shots}
mkdir -p "$OUT"
SIM=$(xcrun simctl list devices | grep " Threadbear (" | grep -oE "[0-9A-F-]{36}" | head -1 || true)
if [[ -z "$SIM" ]]; then
  # Cloned from a stock iPhone, since `simctl create` refuses some pairs.
  BASE=$(xcrun simctl list devices available | grep -E "iPhone 1[5-8] Pro Max" | grep -oE "[0-9A-F-]{36}" | head -1)
  SIM=$(xcrun simctl clone "$BASE" Threadbear)
fi
xcodebuild -project Threadbear.xcodeproj -scheme Threadbear -configuration Debug -destination "id=$SIM" \
  -derivedDataPath /tmp/threadbear-dd build | grep -E " error:|BUILD (SUCCEEDED|FAILED)"
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl ui "$SIM" appearance "$([[ "${2:-}" == --dark ]] && echo dark || echo light)"
xcrun simctl status_bar "$SIM" override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4
xcrun simctl uninstall "$SIM" com.mikecann.threadbear 2>/dev/null || true  # clears permission prompts from earlier runs
xcrun simctl install "$SIM" /tmp/threadbear-dd/Build/Products/Debug-iphonesimulator/Threadbear.app
shot() {
  xcrun simctl launch --terminate-running-process "$SIM" com.mikecann.threadbear -ThreadbearFake "${@:2}" >/dev/null
  sleep 3
  xcrun simctl io "$SIM" screenshot "$OUT/$1.png" >/dev/null 2>&1
  echo "$OUT/$1.png"
}
shot inbox
shot approval -ThreadbearOpen a1
shot question -ThreadbearOpen a2
shot reply -ThreadbearOpen a3
shot running -ThreadbearOpen a5
