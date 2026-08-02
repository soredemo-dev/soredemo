#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/SoredemoSpikeB.app"
IDENTITY="${SPIKE_SIGN_IDENTITY:-Apple Development}"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
xcrun swiftc -O -target arm64-apple-macos26.0 -parse-as-library \
    -o "$APP/Contents/MacOS/SoredemoSpikeB" "$HERE/main.swift"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
echo "built: $APP"
codesign -dvv "$APP" 2>&1 | grep -E "Identifier=|Authority=Apple Development"
