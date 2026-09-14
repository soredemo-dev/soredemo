#!/bin/bash
# Runs the app target's own tests — the models in `Soredemo/`, which `swift test`
# cannot reach because they are not in the package.
#
# **A fifth gate, and it is deliberately its own.** Gate 1 is `swift test` over the
# package and gate 4 is a build of the app; between them sat 13,761 lines with no
# executable test at all (docs/TESTING.md § 5.4). These run in the app target, hosted
# by Soredemo.app, which is why they are not simply more of gate 1: they need the app
# built and signed, and `xcodebuild` is the only thing that does that.
#
# Sequential with the other gates, never alongside — see docs/TESTING.md § 3.
set -euo pipefail
cd "$(dirname "$0")/.."

# **`-only-testing:SoredemoTests`, and the scoping is the point.** The scheme also holds
# `SoredemoUITests`, which cannot start without an Accessibility grant — so without this the
# fifth gate would go red on a machine where nothing is wrong with the code. UI tests are
# their own gate, `run-ui-tests.sh`, which says what it needs.
OUTPUT=$(xcodebuild -project Soredemo.xcodeproj -scheme Soredemo \
                    -destination 'platform=macOS' \
                    -only-testing:SoredemoTests test 2>&1) || {
  # **The whole run is kept.** This script's own grep has twice thrown away the only line
  # worth reading — once because the failure said "Testing failed:" and nothing else, once
  # because a hand-typed `Test Case` did not match `Test case`. A gate that cannot show its
  # evidence sends somebody back to re-run it, which is how an intermittent failure becomes
  # a rumour. Same fix as `run-cross-boundary-probe.sh`.
  LOG="${TMPDIR:-/tmp}run-app-tests.log"
  printf '%s\n' "$OUTPUT" > "$LOG"
  echo "APP TESTS FAILED. The whole run is in $LOG. What matched:" >&2
  echo "$OUTPUT" | grep -E "error:|failed" >&2
  exit 1
}

# The count is READ BACK, not assumed: a scheme that stopped including the test target
# would still exit 0 with nothing run, which is the shape of a gate that passes
# vacuously.
PASSED=$(echo "$OUTPUT" | grep -c "Test case .* passed" || true)
if [ "$PASSED" -eq 0 ]; then
  echo "xcodebuild test succeeded but ran no tests — the target is not in the scheme." >&2
  exit 1
fi
echo "APP TESTS: $PASSED passed in the app target."
