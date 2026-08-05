#!/bin/bash
# Fails if a fresh `swift build` emits any `StrictMemorySafety` warning.
#
# `Package.swift`'s `strict` array carries `.strictMemorySafety()` on every regular
# target, which turns each unmarked unsafe-construct call site into a compiler
# WARNING — not an error, and `swift build`/`xcodebuild` both exit 0 with warnings
# present. Left unchecked, that is ambient noise nobody reads, which is the exact
# failure the flag exists to prevent, arriving through the flag itself: measured at
# the start of Phase 3A-1 Task 3's fix round, one pre-existing warning
# (`Sources/Project/ObservationLog.swift`) had sat unremarked, and the task's own
# move added three more before anyone looked.
#
# Zero, not a maintained count: a number written down here that had to match a
# number written down in a comment somewhere else is the shape this project has
# gotten wrong before (`scripts/count-tests.sh`'s own header). This script has
# nothing to keep in sync — it greps a fresh build for the diagnostic's own tag
# and fails on any hit, so there is no count to let drift.
#
# Not folded into `scripts/run-cross-boundary-probe.sh`: that script's `swift build`
# exists only to produce link products for the `xcrun swiftc` step after it, and is
# meant to be read as "the package built"; conflating that with this gate would make
# a probe failure ambiguous between "the cross-boundary check found a real bug" and
# "someone left an unsafe construct unmarked" — two different things a reader would
# have to re-derive from the log either way. A dedicated script keeps the failure
# message attached to the actual cause.
#
# Nothing runs this automatically — same position `run-cross-boundary-probe.sh`
# takes and for the same reason (no CI in this repo yet). Run it wherever
# `swift build` is one of the gates.
set -euo pipefail
cd "$(dirname "$0")/.."

# Matches `run-cross-boundary-probe.sh`'s own reasoning: `swift build` resolves its
# SDK through xcrun, and an inherited SDKROOT can point it at a different one than
# xcrun's default, so unset it here rather than assume the caller's shell already has.
unset SDKROOT

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

swift build 2>&1 | tee "$LOG"

if grep -q 'StrictMemorySafety' "$LOG"; then
    echo
    echo "FAILED: swift build emitted a StrictMemorySafety warning (see above)." >&2
    echo "Every unsafe construct must be marked 'unsafe' at its own expression —" >&2
    echo "with a comment at the site saying why it is safe here, if it is — not" >&2
    echo "left as an unmarked warning for the next reader to not read." >&2
    exit 1
fi

echo "STRICT MEMORY SAFETY: zero warnings"
