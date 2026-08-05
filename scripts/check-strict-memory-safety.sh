#!/bin/bash
# Fails if an incremental `swift build` emits any `StrictMemorySafety` warning.
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
# nothing to keep in sync — it greps a build for the diagnostic's own tag and
# fails on any hit, so there is no count to let drift.
#
# **Incremental, not clean** — this runs plain `swift build`, not `rm -rf .build &&
# swift build`. A clean build is minutes; an incremental one is the cost every other
# gate here already pays. This is sound for the property the gate exists to hold —
# "the count cannot climb again" — because a warning can only newly APPEAR in a file
# that was just compiled, and any edit forces its own file to recompile whether or
# not the rest of `.build` is warm; there is nothing an incremental build can hide
# from a change made to the file it is hiding in. It does NOT independently prove
# the whole tree is clean from a cold cache — that claim was established once, by
# hand, with `rm -rf .build && swift build`, to produce this task's own report, and
# reaching for that command again is the right move if this script's soundness is
# ever in doubt. Task 3's fix round 2 corrected this file's own header, which
# previously said "fresh" and meant "I happened to run it after `rm -rf .build`" —
# a description that outlived the command it described the moment the loop below
# was written to run plain `swift build`.
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

# **"Verified clean" and "measured nothing" are different outcomes, and this gate
# must not confuse them** — the same hole `scripts/count-tests.sh` already guards
# against ("silence and zero both read as an answer"), now closed here too. Two
# failure modes short of a real pass, checked in order and each with its own exit
# code so a caller can tell which one fired without re-reading the log:
#
#   - an empty log (a build whose output never reached `tee` — `set -euo pipefail`
#     already fails closed on a nonzero exit, but a build that exits 0 while
#     printing nothing is a silent success this loop must not trust) — exit 2;
#   - a non-empty log with no "Build complete!" marker (`swift build` DID produce
#     output but never reported success — the run didn't finish, or finished some
#     other way this script doesn't recognise) — exit 2 as well, distinct message;
#   - a `StrictMemorySafety` hit anywhere in a log that DID report success — exit 1,
#     the actual finding this gate exists to catch.
#
# Verified round-trip (fix round 2): `true | tee "$LOG"` in place of the real build
# left `$LOG` empty, and before this guard existed the script printed "STRICT
# MEMORY SAFETY: zero warnings" and exited 0 — a gate reporting a verified-clean
# build having verified nothing. The guard below is what that observation produced.
if [ ! -s "$LOG" ]; then
    echo "FAILED: swift build's log is empty — nothing was measured, and an empty" >&2
    echo "log reads as a clean pass unless something refuses it outright. This is" >&2
    echo "not a clean build; it is an unobserved one." >&2
    exit 2
fi

if ! grep -q 'Build complete!' "$LOG"; then
    echo "FAILED: swift build produced output but no 'Build complete!' marker — a" >&2
    echo "clean pass was never confirmed, only the absence of the warning tag in" >&2
    echo "whatever output there was. Treat this as unverified, not as clean." >&2
    exit 2
fi

if grep -q 'StrictMemorySafety' "$LOG"; then
    echo
    echo "FAILED: swift build emitted a StrictMemorySafety warning (see above)." >&2
    echo "Every unsafe construct must be marked 'unsafe' at its own expression —" >&2
    echo "with a comment at the site saying why it is safe here, if it is — not" >&2
    echo "left as an unmarked warning for the next reader to not read." >&2
    exit 1
fi

echo "STRICT MEMORY SAFETY: zero warnings (verified against a build that reported success)"
