#!/bin/zsh
# Builds and opens the BearDock demo. BEARDOCK_FRESH=1 ignores the saved layout.
set -euo pipefail
cd "$(dirname "$0")"
swift build --product DockDemo
exec .build/debug/DockDemo
