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
APP="$HOME/Applications/SoredemoSpikeA.app"
IDENTITY="${SPIKE_SIGN_IDENTITY:-Apple Development}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
xcrun swiftc -O -target arm64-apple-macos26.0 \
    -o "$APP/Contents/MacOS/SoredemoSpikeA" "$HERE/main.swift"
codesign --force --options runtime --sign "$IDENTITY" "$APP"

echo "built:  $APP"
codesign -dvv "$APP" 2>&1 | grep -E "Identifier=|Authority=Apple Development|flags="
echo
echo "Grant BOTH, to $APP:"
echo "  System Settings -> Privacy & Security -> Input Monitoring"
echo "  System Settings -> Privacy & Security -> Accessibility"
echo "Then run:  $APP/Contents/MacOS/SoredemoSpikeA"
echo "Not Screen Recording — that is spike B."

echo
echo "If the switch is ON in System Settings but the tap still fails to create:"
echo "  re-signing invalidates an existing grant while the checkbox keeps looking correct."
echo "  tccutil reset ListenEvent   video.soredemo.SpikeA"
echo "  tccutil reset Accessibility video.soredemo.SpikeA"
echo "then grant again. This is the failure that costs an afternoon."
