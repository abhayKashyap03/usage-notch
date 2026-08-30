#!/usr/bin/env bash
# Builds UsageNotch.app without Xcode — SwiftPM plus a hand-assembled bundle.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG"

APP="build/UsageNotch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/UsageNotch" "$APP/Contents/MacOS/UsageNotch"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature keeps the keychain prompt and login item stable across rebuilds.
codesign --force --sign - "$APP" 2>/dev/null || echo "warning: ad-hoc codesign failed"

echo "built $APP"
