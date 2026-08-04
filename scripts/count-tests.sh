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
#         scripts/count-tests.sh --split  the two populations, partition verified
set -euo pipefail
cd "$(dirname "$0")/.."

# --split: the two populations, and the invariant that makes them two counts rather
# than two numbers.
#
# `swift test` now holds suites with different guarantees. The deterministic targets
# answer the same on any machine; HeadlessTests may need a GPU, may be time-sensitive,
# and may answer differently elsewhere. Reporting one "N tests pass" silently changes
# what that number means — one symbol for two things is the shape this project has
# caught most often.
#
# The sum check is the load-bearing part. Two filtered runs alone could double-count a
# suite or drop one and both numbers would still look plausible; only the total says
# the partition is a partition. Cost: three full test runs. That is why --split is
# opt-in and the default stays one run.
if [ "${1:-}" = "--split" ]; then
    count_run() {
        local output
        output=$(swift test "$@" 2>&1) || {
            echo "swift test $* FAILED — no count. Its output:" >&2
            echo "$output" | tail -40 >&2
            exit 1
        }
        printf '%s\n' "$output" | grep -oE "Test run with [0-9]+ tests?" \
            | grep -oE "[0-9]+" | awk '{s+=$1} END {print s+0}'
    }

    DETERMINISTIC=$(count_run --skip HeadlessTests)
    HEADLESS=$(count_run --filter HeadlessTests)
    EVERYTHING=$(count_run)

    # The partition check runs BEFORE anything is printed. Printing three numbers and
    # letting the reader add them up is how two instruments answering different
    # questions get read as agreeing — and here all three numbers would look equally
    # plausible whichever way it broke. So the relation is enforced, and the output
    # says it was enforced rather than inviting anyone to check.
    if [ $((DETERMINISTIC + HEADLESS)) -ne "$EVERYTHING" ]; then
        echo "the two populations do not partition the suite: $DETERMINISTIC + $HEADLESS != $EVERYTHING" >&2
        echo "either a suite is counted twice or one is counted by neither filter. The split is not a split." >&2
        echo "no numbers printed: a partition that is not one has no two counts to report." >&2
        exit 3
    fi

    printf '  swift test — deterministic  %6d passed\n' "$DETERMINISTIC"
    printf '  swift test — headless       %6d passed    (GPU / timing sensitive)\n' "$HEADLESS"
    printf '  ---------------------------------------\n'
    printf '  %6d  total (partition verified: %d + %d)\n' \
        "$EVERYTHING" "$DETERMINISTIC" "$HEADLESS"
    exit 0
fi

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
