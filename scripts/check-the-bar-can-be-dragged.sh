#!/bin/bash
# The recording bar can be dragged — docs/TESTING.md § 6.4.
#
# **This exists because the bar could not be dragged for as long as it had existed, and
# nothing anywhere would have said so.** Two separate causes, both invisible to every other
# check in this repository:
#
#   * `isMovableByWindowBackground` does not survive an `NSHostingView`. Measured with
#     synthesised events: the same panel moved 88 points with a plain `NSView` in it and zero
#     with SwiftUI in it.
#   * AppKit discards the mouse-down that arrives at an INACTIVE application's window. The bar
#     is never the frontmost app — it floats over what is being recorded — so every click on it
#     was a first click and every one was thrown away. One press and drag moved it zero points;
#     a click followed by the identical drag moved it 140.
#
# The oracle is the app's own window frame, read from AppKit and printed by
# `--show-recording-bar`, which also exits 3 when the frame did not change. Nothing here
# believes a screenshot or an impression.
#
# **It needs permission to post events.** A Mac where this executable cannot inject mouse
# events reports that and skips rather than failing: a check that cannot press the button has
# not learned anything about the button.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Soredemo-*/Build/Products/Debug/Soredemo.app 2>/dev/null | head -1)
if [ -z "$APP" ]; then
  echo "No built Soredemo.app — run scripts/build-app-for-verification.sh first." >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; pkill -x Soredemo 2>/dev/null || true' EXIT

# Same rule as the full-screen check: this measures a window it opens itself, never somebody
# else's, and a second instance launched while the first is quitting inherits its state.
pkill -x Soredemo 2>/dev/null || true
for _ in $(seq 1 30); do pgrep -x Soredemo >/dev/null || break; sleep 0.5; done
if pgrep -x Soredemo >/dev/null; then
  echo "BAR DRAG: another Soredemo is running and would not quit." >&2
  exit 1
fi
sleep 2

# The drag. Grabs the pill where `RecordingBarPanel.placeAtBottomOfActiveScreen` puts it —
# left of centre, clear of the buttons on the right — and reports whether it could post at all.
cat > "$WORK/drag.swift" <<'SWIFT'
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Can this process inject events? Asked by moving the cursor and reading it back, because
// `AXIsProcessTrusted` answers about the accessibility grant and posting is a separate one.
let start = NSEvent.mouseLocation
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
        mouseCursorPosition: CGPoint(x: 400, y: 400), mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(300_000)
if NSEvent.mouseLocation == start {
    print("cannot post events")
    exit(7)
}

let screen = NSScreen.main!
let visible = screen.visibleFrame
// RecordingBarPanel: the pill is centred on the visible frame, `bottomInset` above its bottom.
let bottomInset = 76.0, barHeight = 44.0, barWidth = 392.0
// **Where to grab, and it is not the middle in both states.** The panel is not opaque, so the
// window server hit-tests against rendered alpha: a click on a transparent part of it reaches
// the desktop and AppKit never asks the view. Expanded the pill fills the bar; COLLAPSED it is
// a small capsule at the leading edge and everything else is transparent — grabbing the middle
// there measured nothing at all, and read as "the pointer never reached the window".
let collapsed = CommandLine.arguments.contains("collapsed")
let x = collapsed ? (visible.midX - barWidth / 2 + 28) : (visible.midX - 80)
let y = screen.frame.maxY - (visible.minY + bottomInset + barHeight / 2)
func post(_ t: CGEventType, _ px: Double, _ py: Double) {
    CGEvent(mouseEventSource: nil, mouseType: t,
            mouseCursorPosition: CGPoint(x: px, y: py), mouseButton: .left)?.post(tap: .cghidEventTap)
}
post(.mouseMoved, x, y); usleep(250_000)
post(.leftMouseDown, x, y); usleep(300_000)
for step in stride(from: 10.0, through: 150.0, by: 10.0) {
    post(.leftMouseDragged, x + step, y - step); usleep(40_000)
}
post(.leftMouseUp, x + 150, y - 150); usleep(400_000)
print("dragged from (\(x), \(y))")
exit(0)
SWIFT
/usr/bin/xcrun swiftc -O "$WORK/drag.swift" -o "$WORK/drag" >/dev/null

# **Both states, because the collapsed one is where this defect hid.** Collapsed, the bar is
# one control and nothing else; a `Button` takes the mouse for the whole press, so the drag
# surface behind it never saw one. Expanded it worked the whole time, which is why nothing
# caught it. `$1` is the state's name, for the failure message.
run_one() {
  local label="$1"; shift
  local report="$WORK/bar-$label.txt"
  "$APP/Contents/MacOS/Soredemo" --show-recording-bar 10 "$@" > "$report" 2>&1 &
  APP_PID=$!
  sleep 3
  REPORT="$report"
  STATE="$label"
}

run_one expanded

set +e
"$WORK/drag" > "$WORK/drag.txt" 2>&1
DRAG_STATUS=$?
set -e
if [ "$DRAG_STATUS" -eq 7 ]; then
  kill "$APP_PID" 2>/dev/null || true
  echo "BAR DRAG: SKIPPED — this executable cannot inject mouse events, so the bar was" >&2
  echo "never pressed. Grant Accessibility to whatever runs this and try again. Skipped" >&2
  echo "rather than passed: a check that cannot press the bar has learned nothing." >&2
  exit 0
fi

# **`set +e` around the wait, and it was not there first time.** The app exits 3 when the bar
# did not move, and under `set -e` that status ended the script on this line — before the
# report was printed. The check was correct and could not show its evidence, which this
# project has already paid for once; see docs/TESTING.md § 3.
set +e
wait "$APP_PID"
STATUS=$?
set -e
cat "$REPORT"
if [ "$STATUS" -ne 0 ]; then
  echo "" >&2
  echo "BAR DRAG ($STATE): FAILED. The bar's window is where it started, so the drag did nothing." >&2
  echo "Read the two counters above first:" >&2
  echo "  hit tests 0 on the bar   the pointer never reached the window. The bar is not" >&2
  echo "                           where this check grabbed — check bottomInset and the" >&2
  echo "                           visible frame — or another window is over it." >&2
  echo "  hit tests > 0, changes 0 the window saw the pointer and SwiftUI never started the" >&2
  echo "                           gesture. This is what acceptsFirstMouse being false looks" >&2
  echo "                           like: AppKit throws away the mouse-down at an inactive" >&2
  echo "                           app's window, and this app is never the active one." >&2
  echo "  changes > 0              the gesture ran and the move did not take. BarDrag's" >&2
  echo "                           arithmetic, or a window that refuses setFrameOrigin." >&2
  exit 1
fi
echo "BAR DRAG ($STATE): the bar moved where it was dragged."

# The same check again, collapsed.
pkill -x Soredemo 2>/dev/null || true
for _ in $(seq 1 30); do pgrep -x Soredemo >/dev/null || break; sleep 0.5; done
sleep 1
run_one collapsed --bar-collapsed
set +e
"$WORK/drag" collapsed > "$WORK/drag-collapsed.txt" 2>&1
DRAG_STATUS=$?
wait "$APP_PID"
STATUS=$?
set -e
cat "$REPORT"
if [ "$STATUS" -ne 0 ]; then
  echo "" >&2
  echo "BAR DRAG (collapsed): FAILED. Expanded passed and collapsed did not, which is the" >&2
  echo "shape this state was added for: collapsed the bar is ONE control, and a control that" >&2
  echo "takes the mouse leaves nothing for a drag. Read the counters above the same way." >&2
  exit 1
fi
echo "BAR DRAG (collapsed): the bar moved where it was dragged."
