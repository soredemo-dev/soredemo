#!/bin/bash
# Builds Spike E as a signed .app at a fixed path, for the same reasons the
# other spikes do — see Spike A's build.sh. Needs no TCC grant; the bundle is
# identity hygiene, so a throwaway tool can never run under the product's id.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
APP="$HOME/Applications/SoredemoSpikeE.app"
IDENTITY="${SPIKE_SIGN_IDENTITY:-Apple Development}"

# The login profile exports SDKROOT pointing at the CommandLineTools SDK, which
# is a different one from what `swift build` uses. Inheriting it fails the link
# in a way that reads like a source error — measured, nineteen times, by
# scripts/run-cross-boundary-probe.sh before it was fixed there.
unset SDKROOT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
(cd "$REPO" && swift build)

# Same language-mode flags as Soredemo.xcodeproj: without them this compiles
# under different isolation semantics from the code it is reasoning about, and
# a `nonisolated` mistake passes here and fails xcodebuild.
xcrun swiftc -O -target arm64-apple-macos26.0 -parse-as-library \
    -swift-version 6 \
    -default-isolation MainActor \
    -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -I "$REPO/.build/debug" \
    -L "$REPO/.build/debug" \
    -lSoredemoCore \
    -o "$APP/Contents/MacOS/SoredemoSpikeE" \
    "$REPO/spikes/shared/VerificationStep.swift" \
    "$HERE/main.swift"
codesign --force --options runtime --sign "$IDENTITY" "$APP"

echo "built:  $APP"
codesign -dvv "$APP" 2>&1 | grep -E "Identifier=|Authority=Apple Development"
echo
echo "Needs no permission. Reads cursor-visibility signals; hides the cursor briefly."
echo "Run:  $APP/Contents/MacOS/SoredemoSpikeE"
