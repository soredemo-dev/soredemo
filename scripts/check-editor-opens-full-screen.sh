#!/bin/bash
# The editor opens, and it is full screen — docs/TESTING.md § 6.0.
#
# **A script, not a test case, and that was arrived at rather than chosen.** Two earlier
# shapes were built and measured first:
#
#   * XCUITest reading the window's frame from the accessibility tree. Unreliable by
#     construction: a window entering full screen moves to its own Space and stops being
#     queryable while it does, so the same test passed, then reported "never readable", then
#     died inside its own failure message.
#   * An XCTest in the app's test target launching the app. The test host IS Soredemo.app, and
#     a second instance of the same bundle launched from inside it never receives its
#     arguments — the report was never written, forty-five seconds every run.
#
# Launching the app from outside any of it works, and the oracle is AppKit's own answer:
# `--report-window-state` writes what `styleMask.contains(.fullScreen)` says. The app is not
# marking its own homework — it is not asked what it MEANT, it is asked what the window system
# made of it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Soredemo-*/Build/Products/Debug/Soredemo.app 2>/dev/null | head -1)
if [ -z "$APP" ]; then
  echo "No built Soredemo.app — run scripts/build-app-for-verification.sh first." >&2
  exit 1
fi

WORK=$(mktemp -d)
REPORT="$WORK/window-state.txt"
trap 'rm -rf "$WORK"; pkill -x Soredemo 2>/dev/null || true' EXIT

# A project is a package with media in it. One frame is enough to open an editor, and
# synthesising it keeps a fixture from going stale against the format it is a fixture for.
mkdir -p "$WORK/project/media"
/usr/bin/xcrun swift - "$WORK/project/media/master-00.mov" <<'SWIFT' >/dev/null
import AVFoundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
    sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String:
        kCVPixelFormatType_32BGRA])
writer.add(input)
writer.startWriting(); writer.startSession(atSourceTime: .zero)
var buffer: CVPixelBuffer?
CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer)
adaptor.append(buffer!, withPresentationTime: .zero)
input.markAsFinished()
writer.endSession(atSourceTime: CMTime(value: 1, timescale: 30))
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
SWIFT

pkill -x Soredemo 2>/dev/null || true
open -n -a "$APP" --args --open-project "$WORK/project" --report-window-state "$REPORT"

# The app writes the report and terminates itself. The ceiling is generous because the
# transition is animated and this runs on whatever machine somebody has.
for _ in $(seq 1 60); do
  [ -f "$REPORT" ] && break
  sleep 1
done

if [ ! -f "$REPORT" ]; then
  echo "EDITOR FULL SCREEN: NO REPORT. The app never reached the point where the editor" >&2
  echo "window exists, so --open-project opened nothing." >&2
  exit 1
fi

cat "$REPORT"
if ! grep -q "fullScreen=true" "$REPORT"; then
  echo "" >&2
  echo "EDITOR FULL SCREEN: FAILED. AppKit says the window is not full screen; the report" >&2
  echo "above is what it said. This has meant, in order of how often: the toggle asked too" >&2
  echo "early and was ignored without an error, .moveToActiveSpace contradicting full screen," >&2
  echo "an even number of toggles from a duplicated observer, and alphaValue = 0." >&2
  exit 1
fi
echo "EDITOR FULL SCREEN: the window AppKit reports is full screen."
