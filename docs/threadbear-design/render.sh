#!/bin/zsh
# Renders every N-*.html mockup in this folder to N-*.png at 2x using the
# Playwright headless Chromium already on the machine (no Playwright
# install needed, it's driven straight from the command line).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
shell="$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-mac-arm64/chrome-headless-shell | sort -V | tail -1)"
tmp="$(mktemp -d)"
for html in "$here"/[0-9]-*.html; do
  png="${html%.html}.png"
  # width/height from a "<!-- size: WxH -->" comment, default to the window size
  size="$( (grep -o "size: [0-9]*x[0-9]*" "$html" || true) | head -1 | sed "s/size: //")"
  size="${size:-1440x900}"
  "$shell" --headless --disable-gpu --hide-scrollbars --no-sandbox \
    --user-data-dir="$tmp" --force-device-scale-factor=2 \
    --window-size="${size/x/,}" --screenshot="$png" "file://$html" 2>/dev/null
  echo "$(basename "$png")"
done
rm -rf "$tmp"
