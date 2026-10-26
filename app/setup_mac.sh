#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${THREADBARE_APP_DIR:-$HOME/Applications/Threadbare.app}"

THREADBARE_BUILD_CONFIGURATION=release bash "$SCRIPT_DIR/build-app.sh"
echo ""
echo "Threadbare is installed at $APP_DIR"
echo "Launch it with: threadbare"
