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

OUTPUT=$(xcodebuild -project Soredemo.xcodeproj -scheme Soredemo \
                    -destination 'platform=macOS' test 2>&1) || {
  echo "APP TESTS FAILED. The failures:" >&2
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
