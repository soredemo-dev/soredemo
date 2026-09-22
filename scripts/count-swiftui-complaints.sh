#!/bin/bash
# How many times SwiftUI complains while the editor opens a project.
#
# **Not a gate: a number, so a change can be judged against the run before it.** Two of the
# messages in this app's console are ours and neither has been located:
#
#   NSHostingView is being laid out reentrantly while rendering its SwiftUI content
#   [com.apple.attributegraph:error] Cycle detected through attribute: <id>
#
# **What was established on 2026-09-18, so the next attempt starts from evidence.** The cycle
# happens TWICE per editor open, and both occurrences sit immediately beside
# `AVAssetInspectorLoader loadValuesAsynchronously ... tracks` and the decoder being built and
# torn down — the composition rebuild, not the window opening. `AG_TRACE_CYCLES=1` and
# `SWIFTUI_DEBUG_CYCLES=1` were tried and neither produces the attribute chain on macOS 27, so
# the id is not resolvable from outside a debugger and nothing here names the view.
#
# **It reads the UNIFIED LOG, because that is where these go.** `NSLog` writes to stderr only
# when there is a tty; redirected to a file it goes to the unified log alone. A first attempt
# captured stderr, reported zero of everything, and was measuring nothing — which is why the
# line count is printed first and a run reporting no lines at all says so rather than passing.
# `/usr/bin/log` by its full path: zsh has a builtin `log` that shadows it.
set -euo pipefail
# No job-control notices: the two background jobs are killed on purpose and "Terminated: 15"
# over the numbers reads as a failure.
set +m
cd "$(dirname "$0")/.."

PROJECT=${1:-}
if [ -z "$PROJECT" ] || [ ! -d "$PROJECT" ]; then
  echo "usage: $0 <path to a .soredemo project>" >&2
  echo "" >&2
  echo "A project with real media, because the messages are about a composition being built." >&2
  echo "The synthesised fixture the full-screen gate makes is one media file and no" >&2
  echo "project.json, so the editor opens on 'no project' and nothing is measured." >&2
  exit 2
fi

APP=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Soredemo-*/Build/Products/Debug/Soredemo.app 2>/dev/null | head -1)
if [ -z "$APP" ]; then
  echo "No built Soredemo.app — run scripts/build-app-for-verification.sh first." >&2
  exit 1
fi

WORK=$(mktemp -d)
# **The log is KEPT, for the probe runner's reason.** This script deleted it on exit, so a run
# that printed six zeros left nothing to ask whether the app had done anything at all — and on
# 2026-09-22 a run did exactly that, reporting zeros for a play that never started. A count
# with no log behind it is a rumour.
KEEP="${SOREDEMO_COMPLAINT_LOG:-$WORK/unified.log}"
trap 'pkill -x Soredemo 2>/dev/null || true; [ "$KEEP" = "$KEEP" ] && rm -rf "$WORK"' EXIT

pkill -x Soredemo 2>/dev/null || true
for _ in $(seq 1 30); do pgrep -x Soredemo >/dev/null || break; sleep 0.5; done
sleep 1

/usr/bin/log stream --style compact --predicate 'process == "Soredemo"' > "$KEEP" 2>&1 &
STREAM=$!
disown "$STREAM" 2>/dev/null || true
sleep 2

"$APP/Contents/MacOS/Soredemo" --open-project "$PROJECT" > /dev/null 2>&1 &
disown $! 2>/dev/null || true

# **The editor is PLAYED, not merely opened, and that distinction was measured.** Opening one
# project produced 0 reentrant layout passes, 0 compositor refusals and 0 onChange re-entries —
# and a console paste from a person editing carried all three. `--open-project` reaches the
# window and stops; every message this script exists to count comes from the composition
# actually running. So Space is posted to the app, which is the transport's own shortcut and
# therefore the same path a person takes, rather than a back door into the player.
#
# Nothing here asserts the keypress landed. If it did not, the counts below are an opened
# editor's again — which is why the play window is reported separately rather than folded into
# one number nobody can take apart.
sleep 6
PLAY_SECONDS="${PLAY_SECONDS:-12}"
/usr/bin/swift - <<'SWIFT' >/dev/null 2>&1 || echo "NOTE: could not post the play key; counts below are an opened editor, not a playing one" >&2
import CoreGraphics
// 49 is the SPACE key's POSITION. Key codes are positions, not letters, which is why this is a
// number and not a character: on a Dvorak or AZERTY layout the character would move and the
// space bar would not.
if let down = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true),
   let up = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false) {
    down.post(tap: .cghidEventTap)
    usleep(60_000)
    up.post(tap: .cghidEventTap)
}
SWIFT
sleep "$PLAY_SECONDS"
pkill -x Soredemo 2>/dev/null || true
sleep 2
kill "$STREAM" 2>/dev/null || true
sleep 1

LINES=$(wc -l < "$KEEP" | tr -d ' ')
echo "unified log lines: $LINES"
if [ "$LINES" -lt 100 ]; then
  echo "" >&2
  echo "TOO FEW LINES to have measured anything. Opening an editor produces thousands." >&2
  echo "The stream did not attach, or the app did not launch. The counts below would be" >&2
  echo "zeros that mean 'nothing was watched', not 'nothing happened'." >&2
  exit 1
fi

printf 'reentrant layout passes: %s\n' "$(grep -c 'laid out reentrantly' "$KEEP" || true)"
printf 'attribute graph cycles:  %s\n' "$(grep -c 'Cycle detected through attribute' "$KEEP" || true)"
printf 'onChange re-entries:     %s\n' "$(grep -c 'tried to update multiple times per frame' "$KEEP" || true)"
# **The compositor's own refusals, counted here because nothing else counts them while a
# person is watching.** `StageCompositor.Diagnostics.refusals` has held a per-kind tally since
# the five causes were split apart, and exactly one place reads it: the sheet shown after an
# export. During PLAYBACK the same refusal reaches the console as one opaque line and nothing
# adds it up — which is how "the editor feels janky" and "the compositor dropped 400 frames"
# stay two unconnected observations. A count is not the cause, but it decides whether there is
# one to look for.
printf 'compositor refusals:     %s\n' "$(grep -c 'CustomVideoCompositor.*signalled err' "$KEEP" || true)"
printf 'file player errors:      %s\n' "$(grep -c 'FigFilePlayer.*signalled err' "$KEEP" || true)"
printf 'uncommitted CATransactions: %s\n' "$(grep -c 'uncommitted CATransaction' "$KEEP" || true)"
echo ""
echo "Measured 2026-09-18 on this machine, opening one project: 1-2 cycles, 0 of the other two."
echo "The three counts below that were added 2026-09-22 have no measured baseline yet: they were"
echo "added because a console paste carried one of each and nothing could say whether that was"
echo "one or four hundred."
echo "The run covers an open (6 s) and then a play (${PLAY_SECONDS}s), because opening alone"
echo "produced zeros for every count while a person editing saw all of them. A zero is still"
echo "'this path did not produce one' and not 'the app does not' — the caption editor, scrubbing"
echo "and the inspector panels are not reached by this script at all."
