#!/bin/zsh
# Same headless Chromium approach as docs/threadbear-design/render.sh.
# Renders concept HTML, without installing packages or opening an app window.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
chromium="$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-mac-arm64/chrome-headless-shell | sort -V | tail -1)"
profile="$(mktemp -d)"
trap 'rm -rf "$profile"' EXIT
for html in "$here"/[0-9]-*.html; do
  "$chromium" --headless --disable-gpu --hide-scrollbars --no-sandbox \
    --user-data-dir="$profile" --force-device-scale-factor=2 \
    --window-size=1440,980 --timeout=10000 \
    --screenshot="${html%.html}.png" "file://$html" 2>/dev/null
done
