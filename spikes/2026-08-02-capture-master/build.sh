#!/bin/bash
# Extended for Task 8: this spike now drives the real `CaptureSession`
# (Soredemo/Capture/CaptureSession.swift), not SCRecordingOutput, so it must
# compile against the same app sources and the SAME language-mode flags as
# `Soredemo.xcodeproj` — matching `scripts/run-cross-boundary-probe.sh`'s own
# comment on why: without them, code can pass this build under DIFFERENT
# isolation semantics than the real app and disagree with `xcodebuild`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
APP="$HOME/Applications/SoredemoSpikeB.app"
IDENTITY="${SPIKE_SIGN_IDENTITY:-Apple Development}"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"

(cd "$REPO" && swift build)

xcrun swiftc -O -target arm64-apple-macos26.0 -parse-as-library \
    -swift-version 6 \
    -default-isolation MainActor \
    -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -I "$REPO/.build/debug" \
    -L "$REPO/.build/debug" \
    -lSoredemoCore \
    -o "$APP/Contents/MacOS/SoredemoSpikeB" \
    "$REPO/Soredemo/Support/Minting.swift" \
    "$REPO/Soredemo/Capture/CGGeometryBridge.swift" \
    "$REPO/Soredemo/Capture/CaptureSource.swift" \
    "$REPO/Soredemo/Capture/AudioInterleave.swift" \
    "$REPO/Soredemo/Capture/CaptureSession.swift" \
    "$HERE/main.swift"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
echo "built: $APP"
codesign -dvv "$APP" 2>&1 | grep -E "Identifier=|Authority=Apple Development"
