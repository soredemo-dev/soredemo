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
trap 'rm -rf "$WORK"; pkill -x Soredemo 2>/dev/null || true' EXIT

pkill -x Soredemo 2>/dev/null || true
for _ in $(seq 1 30); do pgrep -x Soredemo >/dev/null || break; sleep 0.5; done
sleep 1

/usr/bin/log stream --style compact --predicate 'process == "Soredemo"' > "$WORK/unified.log" 2>&1 &
STREAM=$!
disown "$STREAM" 2>/dev/null || true
sleep 2

"$APP/Contents/MacOS/Soredemo" --open-project "$PROJECT" > /dev/null 2>&1 &
disown $! 2>/dev/null || true
sleep "${SECONDS_TO_WATCH:-18}"
pkill -x Soredemo 2>/dev/null || true
sleep 2
kill "$STREAM" 2>/dev/null || true
sleep 1

LINES=$(wc -l < "$WORK/unified.log" | tr -d ' ')
echo "unified log lines: $LINES"
if [ "$LINES" -lt 100 ]; then
  echo "" >&2
  echo "TOO FEW LINES to have measured anything. Opening an editor produces thousands." >&2
  echo "The stream did not attach, or the app did not launch. The counts below would be" >&2
  echo "zeros that mean 'nothing was watched', not 'nothing happened'." >&2
  exit 1
fi

printf 'reentrant layout passes: %s\n' "$(grep -c 'laid out reentrantly' "$WORK/unified.log" || true)"
printf 'attribute graph cycles:  %s\n' "$(grep -c 'Cycle detected through attribute' "$WORK/unified.log" || true)"
printf 'onChange re-entries:     %s\n' "$(grep -c 'tried to update multiple times per frame' "$WORK/unified.log" || true)"
echo ""
echo "Measured 2026-09-18 on this machine, opening one project: 1-2 cycles, 0 of the other two."
echo "The reentrant layout and the onChange re-entry were reported from a session that also"
echo "opened the caption editor and played the video; --open-project alone does not reach them,"
echo "so a zero here is 'this path did not produce one' and not 'the app does not'."
