#!/bin/bash
# Spike C — the human half of Task 9 (`input-observation`).
#
# Drives the REAL `Soredemo/Capture/InputObserver.swift`, not a copy, against
# the same language-mode flags `Soredemo.xcodeproj` uses — the same reasoning
# `scripts/run-cross-boundary-probe.sh` and Spike B's build script both carry:
# without them this compiles under DIFFERENT isolation semantics from the code
# it is checking, and a `nonisolated` mistake passes here and fails
# `xcodebuild`.
#
# It must be a signed .app, not a bare binary. Input Monitoring is attributed
# by TCC to the *responsible process*: a `swiftc`-compiled executable run from
# a shell inherits the shell's attribution, which is why the cross-boundary
# probe deliberately performs no permission-scoped check at all. Everything
# this spike measures is permission-scoped.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
APP="$HOME/Applications/SoredemoSpikeC.app"
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
    -o "$APP/Contents/MacOS/SoredemoSpikeC" \
    "$REPO/Soredemo/Support/Minting.swift" \
    "$REPO/Soredemo/App/BuildProvenance.swift" \
    "$REPO/Soredemo/Capture/CGGeometryBridge.swift" \
    "$REPO/Soredemo/Capture/CaptureError.swift" \
    "$REPO/Soredemo/Capture/CapturePermissions.swift" \
    "$REPO/Soredemo/Capture/InputObserver.swift" \
    "$REPO/spikes/shared/VerificationStep.swift" \
    "$HERE/main.swift"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
echo "built: $APP"
codesign -dvv "$APP" 2>&1 | grep -E "Identifier=|Authority=Apple Development"
echo
echo "run one step at a time:"
echo "  \"$APP/Contents/MacOS/SoredemoSpikeC\" 1   # pointer track"
echo "  \"$APP/Contents/MacOS/SoredemoSpikeC\" 2   # a click"
echo "  \"$APP/Contents/MacOS/SoredemoSpikeC\" 3   # the keyboard filter"
echo "  \"$APP/Contents/MacOS/SoredemoSpikeC\" 4   # secure input"
