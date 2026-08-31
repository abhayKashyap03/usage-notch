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

# Sign with a stable identity if one exists. An ad-hoc signature changes its code
# hash on every build, which voids every keychain and TCC grant the app was given —
# so permissions have to be re-approved after each rebuild. A self-signed
# code-signing certificate fixes that. Create one with:
#   openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
#     -keyout dev.key -out dev.crt -subj "/CN=Notch Widgets Dev" \
#     -addext "basicConstraints=critical,CA:false" \
#     -addext "keyUsage=critical,digitalSignature" \
#     -addext "extendedKeyUsage=critical,codeSigning"
#   openssl pkcs12 -export -out dev.p12 -inkey dev.key -in dev.crt \
#     -name "Notch Widgets Dev" -passout pass:PASS \
#     -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg SHA1
#   security import dev.p12 -k ~/Library/Keychains/login.keychain-db -P PASS -T /usr/bin/codesign -A
#   security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db dev.crt
IDENTITY="${NOTCH_SIGN_IDENTITY:-Notch Widgets Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null 2>&1 \
        || echo "warning: signing with \"$IDENTITY\" failed"
else
    echo "note: \"$IDENTITY\" not found; falling back to ad-hoc (permissions will not persist)"
    codesign --force --sign - "$APP" 2>/dev/null || echo "warning: ad-hoc codesign failed"
fi

echo "built $APP"
