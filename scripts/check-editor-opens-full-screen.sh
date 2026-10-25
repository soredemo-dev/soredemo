#!/bin/bash
# The editor opens, and fills the screen — as a window, or full screen if the app says so.
# docs/TESTING.md § 6.0.
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

# **Nothing else may be driving this app while this runs.**
#
# `run-app-tests.sh` launches Soredemo.app as its test host, and a run started while that is
# still settling measures a window somebody else opened. Observed: the check failed immediately
# after the app-test gate and passed on its own seconds later, twice. A gate that can be wrong
# about WHICH app it measured is not a gate — so this one waits for the machine to be quiet
# rather than reporting on whatever it finds.
#
# **Wait for it to be gone, not just ask.** `pkill` returns as soon as the signal is sent, and
# a second instance launched while the first is still quitting inherits its Space and never
# becomes key — measured: the window stayed at its default 900x492, the full-screen branch
# never ran, and the failure pointed at four causes none of which was "another copy was still
# running". A gate that can be wrong about which app it measured is not a gate.
pkill -x Soredemo 2>/dev/null || true
for _ in $(seq 1 30); do
  pgrep -x Soredemo >/dev/null || break
  sleep 0.5
done
if pgrep -x Soredemo >/dev/null; then
  echo "EDITOR FULL SCREEN: another Soredemo is running and would not quit." >&2
  echo "This check measures a window it opens itself; it will not report on somebody" >&2
  echo "else's. Quit the other copy and run it again." >&2
  exit 1
fi
# The window server needs a moment after the last instance goes, or the next one inherits its
# Space and never becomes key — which is the exact defect this check exists to catch, arriving
# from the wrong direction.
sleep 2

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
# **Since 2026-10-25 the editor opens as a window filling the screen**, not in full screen —
# docs/design/2026-10-25-the-editor-opens-as-a-window.md. The app says which it meant to do, and
# this asks AppKit whether that happened: the frame against the visible frame, and the alpha,
# because a window hidden until it grows and never grown is an editor nobody can see.
if grep -q "opensFullScreen=false" "$REPORT"; then
  if grep -q "fillsVisibleFrame=true" "$REPORT" && grep -q "^alpha=1" "$REPORT"; then
    echo "EDITOR OPENS: the window fills the screen's visible frame and is visible."
    exit 0
  fi
  echo "" >&2
  echo "EDITOR OPENS: FAILED. The report above is AppKit's answer. Read in this order:" >&2
  echo "  alpha=0            hidden and never grown: EditorOpening.present never ran, and the" >&2
  echo "                     reveal deadline did not show it either." >&2
  echo "  fillsVisibleFrame  false with alpha=1: shown, but not grown — the frame says where." >&2
  echo "  frame 900x492      the un-configured default: the window was never configured." >&2
  exit 1
fi
if ! grep -q "fullScreen=true" "$REPORT"; then
  echo "" >&2
  # **The four causes used to be listed and not distinguished, and that cost five launches.**
  # A red here was classified by re-running the gate until it went green, which is how an
  # intermittent failure becomes a rumour. `fullScreenStopped=` is now the app's own answer.
  echo "EDITOR FULL SCREEN: FAILED. AppKit says the window is not full screen; the report" >&2
  echo "above is what it said. Read fullScreenStopped= first — it says which ending:" >&2
  echo "  exhausted         the budget ran out with the window still not full screen. If" >&2
  echo "                    fullScreenAsks is at the budget AND the machine was busy, this" >&2
  echo "                    is the load case and the run is not evidence about the code." >&2
  echo "  windowNotVisible  the window went away under the retry: a second instance, or" >&2
  echo "                    alphaValue = 0, which AppKit treats as not on screen." >&2
  echo "  arrived           it DID reach full screen and something took it back out — an" >&2
  echo "                    even number of toggles, or .moveToActiveSpace contradicting it." >&2
  echo "  asking            still trying when this was read. The wait here is shorter than" >&2
  echo "                    FullScreenEntry's budget, which is a defect in this script." >&2
  echo "  notAsked          nothing ever asked; the editor window was never opened." >&2
  echo "" >&2
  # **The frame distinguishes two of these on its own, measured 2026-09-16.** Driving the
  # app with the budget set to zero — a positive control for these very fields — leaves the
  # window GROWN: (0, 84, 1512, 865). So an `exhausted` red still shows a configured window.
  # A report carrying the un-configured 900x492 default means the editor window was never
  # set up at all, which is a different defect and the shape both reds of 2026-09-16 had.
  echo "The frame is a second reading: an exhausted budget still leaves a GROWN window" >&2
  echo "(measured 1512x865). A frame of 900x492 is the un-configured default, so that is" >&2
  echo "not a budget that ran out — it is an editor window that was never configured." >&2
  exit 1
fi
echo "EDITOR FULL SCREEN: the window AppKit reports is full screen."
