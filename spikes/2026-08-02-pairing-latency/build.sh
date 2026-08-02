#!/bin/bash
# Builds Spike A as a signed .app at a FIXED install path.
#
# Not a bare executable, for two measured reasons:
#   * a TCC grant is bound to signing identity + bundle identifier, and a bare
#     binary has neither in a stable form;
#   * on macOS 26.1 a bare executable no longer appears in the Screen Recording
#     list at all, and the same has been reported for other TCC categories.
# A fixed path matters too: the monthly re-approval state is keyed on the
# executable's path, so a DerivedData build re-prompts every time it moves.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
APP="$HOME/Applications/SoredemoSpikeA.app"
IDENTITY="${SPIKE_SIGN_IDENTITY:-Apple Development}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
# Compiles the REAL app sources, not copies, under the SAME language-mode
# flags `Soredemo.xcodeproj` uses — the same reasoning
# `scripts/run-cross-boundary-probe.sh` and Spike C's build script carry:
# without them this builds under DIFFERENT isolation semantics from the code it
# is checking, and a `nonisolated` mistake passes here and fails `xcodebuild`.
# This spike measured its own inline tap and inline AX walk until Task 10; a
# spike that measures a copy measures the copy.
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
    -o "$APP/Contents/MacOS/SoredemoSpikeA" \
    "$REPO/Soredemo/Support/Minting.swift" \
    "$REPO/Soredemo/App/BuildProvenance.swift" \
    "$REPO/Soredemo/Capture/CGGeometryBridge.swift" \
    "$REPO/Soredemo/Capture/CaptureError.swift" \
    "$REPO/Soredemo/Capture/CapturePermissions.swift" \
    "$REPO/Soredemo/Capture/InputObserver.swift" \
    "$REPO/Soredemo/Capture/AXObserver.swift" \
    "$REPO/spikes/shared/VerificationStep.swift" \
    "$HERE/main.swift"
codesign --force --options runtime --sign "$IDENTITY" "$APP"

echo "built:  $APP"
codesign -dvv "$APP" 2>&1 | grep -E "Identifier=|Authority=Apple Development|flags="
echo
echo "Grant BOTH, to $APP:"
echo "  System Settings -> Privacy & Security -> Input Monitoring"
echo "  System Settings -> Privacy & Security -> Accessibility"
echo "Then run:  $APP/Contents/MacOS/SoredemoSpikeA [seconds]   # default 45"
echo "Not Screen Recording — that is spike B."

echo
echo "If the switch is ON in System Settings but the tap still fails to create:"
echo "  re-signing invalidates an existing grant while the checkbox keeps looking correct."
echo "  tccutil reset ListenEvent   video.soredemo.SpikeA"
echo "  tccutil reset Accessibility video.soredemo.SpikeA"
echo "then grant again. This is the failure that costs an afternoon."
