#!/usr/bin/env bash
# Rebuild and relaunch, replacing any running copy.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh "${1:-release}"
pkill -x UsageNotch 2>/dev/null || true
sleep 0.3
open build/UsageNotch.app
echo "UsageNotch running. Display, edge and position live in the menu-bar gauge icon"
echo "(or right-click the pill)."
