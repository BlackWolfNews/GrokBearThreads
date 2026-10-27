#!/usr/bin/env bash
# Builds Threadbare.app and stages it in ~/Applications (or THREADBARE_APP_DIR).
#
# THREADBARE_BUILD_CONFIGURATION  release (default) or debug
# THREADBARE_SCRATCH_PATH         swift build's scratch path, instead of
#                                 the package's own .build (the app's
#                                 self-update builds in its own one)
# THREADBARE_SOURCE_CHECKOUT      the checkout recorded in the bundle's
#                                 build.json, whose main the installed app
#                                 follows (default: this script's repo)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_CONFIGURATION="${THREADBARE_BUILD_CONFIGURATION:-release}"
APP_NAME="Threadbare"
BUNDLE_ID="com.mikerosoft.threadbare"
FINAL_DIR="${THREADBARE_APP_DIR:-$HOME/Applications/$APP_NAME.app}"
STAGE_DIR="$(dirname "$FINAL_DIR")/.$APP_NAME.app.staging"
OLD_DIR="$(dirname "$FINAL_DIR")/.$APP_NAME.app.old"
ICON_SOURCE="$SCRIPT_DIR/icons/threadbare.png"

if ! command -v swift >/dev/null 2>&1; then
  echo "ERROR: swift is not on PATH. Install Xcode or Command Line Tools first."
  exit 1
fi

SCRATCH_ARGS=()
if [[ -n "${THREADBARE_SCRATCH_PATH:-}" ]]; then
  SCRATCH_ARGS=(--scratch-path "$THREADBARE_SCRATCH_PATH")
fi
echo "Building Threadbare ($BUILD_CONFIGURATION)..."
swift build --package-path "$SCRIPT_DIR" ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"} -c "$BUILD_CONFIGURATION" --product Threadbare
BIN_DIR="$(swift build --package-path "$SCRIPT_DIR" ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"} -c "$BUILD_CONFIGURATION" --show-bin-path)"
BINARY="$BIN_DIR/Threadbare"
if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: built binary not found at $BINARY"
  exit 1
fi

echo "Staging $FINAL_DIR..."
mkdir -p "$(dirname "$FINAL_DIR")"
rm -rf "$STAGE_DIR" "$OLD_DIR"
mkdir -p "$STAGE_DIR/Contents/MacOS" "$STAGE_DIR/Contents/Resources"
cp "$BINARY" "$STAGE_DIR/Contents/MacOS/Threadbare"
cp "$SCRIPT_DIR/Resources/Info.plist" "$STAGE_DIR/Contents/Info.plist"
chmod +x "$STAGE_DIR/Contents/MacOS/Threadbare"

# What this bundle was built from, for the app's self-update
# (AppUpdate.swift): the commit, the tree hash of app/ at it (only a change
# under app/ changes what runs) and the checkout whose main to follow. The
# update script goes in too, so the app runs the copy it was built with.
SOURCE_CHECKOUT="${THREADBARE_SOURCE_CHECKOUT:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
COMMIT="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || true)"
SHORT="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
APP_TREE="$(git -C "$SCRIPT_DIR" rev-parse HEAD:app 2>/dev/null || true)"
python3 - "$STAGE_DIR/Contents/Resources/build.json" "$COMMIT" "$SHORT" "$APP_TREE" "$SOURCE_CHECKOUT" "$BUILD_CONFIGURATION" <<'PY'
import json, sys, datetime
path, commit, short, tree, checkout, configuration = sys.argv[1:]
json.dump({
    "commit": commit, "short": short, "appTree": tree, "checkout": checkout,
    "configuration": configuration,
    "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
}, open(path, "w"), indent=2)
PY
cp "$SCRIPT_DIR/stage-update.sh" "$STAGE_DIR/Contents/Resources/stage-update.sh"
chmod +x "$STAGE_DIR/Contents/Resources/stage-update.sh"

if [[ -f "$ICON_SOURCE" ]]; then
  ICONSET="$(mktemp -d)/threadbare.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$STAGE_DIR/Contents/Resources/threadbare.icns"
  rm -rf "$(dirname "$ICONSET")"
fi

# Sign with the first Apple Development identity so the app keeps the same
# identity across rebuilds (notification and other privacy permissions
# stick). Falls back to ad hoc; then the designated requirement is pinned to
# the bundle id, because an ad hoc one is the binary's hash and changes on
# every build.
SIGN_IDENTITY="${THREADBARE_SIGN_IDENTITY:-$({
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
    | head -n 1
} || true)}"
SIGNING_REQUIREMENTS=()
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
  SIGNING_REQUIREMENTS=(--requirements "=designated => identifier \"$BUNDLE_ID\"")
fi
codesign --force --timestamp=none --sign "$SIGN_IDENTITY" \
  ${SIGNING_REQUIREMENTS[@]+"${SIGNING_REQUIREMENTS[@]}"} "$STAGE_DIR" >/dev/null

# Two renames: the old bundle is gone for an instant, never half there.
if [[ -e "$FINAL_DIR" ]]; then mv "$FINAL_DIR" "$OLD_DIR"; fi
mv "$STAGE_DIR" "$FINAL_DIR"
rm -rf "$OLD_DIR"
echo "Built $FINAL_DIR (signed: $SIGN_IDENTITY)"
