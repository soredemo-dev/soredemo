#!/bin/bash
# How many tests does this package have?
#
# This exists because the number was got wrong three times by hand, always the
# same way: a `grep` with a hardcoded plural.
#
#     grep -oE "Test run with [0-9]+ tests"      # misses "1 test"
#
# Swift Testing prints "Test run with 1 test" for a single-test target, and this
# package has two of those. So the ad-hoc command silently undercounts by 2, and
# the wrong number then goes into a commit message, a ledger entry and a report,
# where nothing recomputes it. The count was reported as 226 against a real 229
# in Phase 1 and as 336 against a real 338 in Phase 2 — the second time AFTER
# the rule "a number in a report should be executable" was written down. The
# rule did not fail because anyone forgot it; it failed because there was
# nothing to run.
#
# Usage:  scripts/count-tests.sh          per-target breakdown and the total
#         scripts/count-tests.sh --total  the total alone, for scripting
set -euo pipefail
cd "$(dirname "$0")/.."

OUTPUT=$(swift test 2>&1) || {
    echo "swift test FAILED — no count. Its output:" >&2
    echo "$OUTPUT" | tail -40 >&2
    # A failed run must not print a number. A count of 0, or a stale count, is
    # exactly the "measurement with no safe default" this project keeps being
    # bitten by: silence and zero both read as an answer.
    exit 1
}

# `tests?` — the whole point. Both forms, deliberately, with a comment so the
# next person to edit this line knows why the `?` is load-bearing.
COUNTS=$(printf '%s\n' "$OUTPUT" | grep -oE "Test run with [0-9]+ tests?" | grep -oE "[0-9]+")

if [ -z "$COUNTS" ]; then
    echo "swift test succeeded but reported no 'Test run with N test(s)' lines." >&2
    echo "Swift Testing's output format has changed, or nothing ran. Not printing a number." >&2
    exit 2
fi

TOTAL=$(printf '%s\n' "$COUNTS" | awk '{s+=$1} END {print s}')

if [ "${1:-}" = "--total" ]; then
    echo "$TOTAL"
    exit 0
fi

# The breakdown as well as the total, so the total can be checked rather than
# trusted. A per-suite line of "1 test" is what the hardcoded plural dropped.
echo "per-target test counts, in the order swift test reported them:"
printf '%s\n' "$COUNTS" | awk '{printf "  %6d\n", $1}'
echo "  ------"
printf '  %6d  total across %d target(s)\n' "$TOTAL" "$(printf '%s\n' "$COUNTS" | wc -l | tr -d ' ')"
