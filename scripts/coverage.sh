#!/bin/bash
# Line coverage over the package, and a floor under it.
#
# **What this number does NOT include, stated first, because the shape of the gap is the
# interesting part.** It is the coverage the TEST BUNDLES produce. `Capture` reads under half
# here and that figure is not what it looks like: it is the module whose behaviour needs a
# real display, so most of its checking lives in `cross-boundary-digest-probe.swift` and runs
# as a separate binary. Merging the two profiles was tried on 2026-09-15 — instrument the
# library, keep the probe's binary, merge the profraws — and `llvm-cov` would not attribute
# the probe's run to `Capture`'s sources, because the archive it links is built by a
# different invocation than the one carrying the mapping. Rather than ship a merge that
# quietly contributes nothing, the number says what it measures and § 1 of docs/TESTING.md
# says what else exists.
#
# The app target is excluded for the same honesty: the probe COMPILES every app source, so
# leaving them in would put 17,764 lines in the denominator that nothing here runs.
set -euo pipefail
cd "$(dirname "$0")/.."

FLOOR=${COVERAGE_FLOOR:-70}
# **Its own build directory.** An instrumented library left in `Core/.build` broke the probe's
# link on the very next gate — coverage counters need matching link flags, and the probe does
# not use them. A gate that changes another gate's preconditions is a gate that produces false
# reports about unrelated code.
SCRATCH=${COVERAGE_SCRATCH:-Core/.build-coverage}

# **The run's output is kept and named on failure.** It was `> /dev/null 2>&1` under `set -e`,
# so a failing test made this gate exit 1 having printed NOTHING — observed 2026-09-16, where
# the empty red was a consequence of gate 1's red and this gate could not say so. A gate that
# cannot show its evidence sends somebody back to re-run it; the probe and the full-screen
# check both had to learn this separately.
COVERAGE_LOG=$(mktemp -t soredemo-coverage)
# **`SOREDEMO_COVERAGE=1` tells the timing tests not to assert.** Instrumentation puts a
# counter on every branch, so a frame-time budget measured here is a number about the
# instrumented build and not about the product: measured 2026-09-18, a 1080p frame that takes
# 2.5 ms in gate 1 crossed its 8 ms budget under this one, and this gate went red while gate 1
# ran the same test and stayed green. They skip with a named reason rather than the budget
# being widened — a budget loose enough for an instrumented run cannot catch a real regression
# in the run that matters.
# Everything this run links is newer than this file; anything older is a previous run's.
RUN_STARTED=$(mktemp -t soredemo-coverage-start)
if ! (cd Core && SOREDEMO_COVERAGE=1 swift test --no-parallel --enable-code-coverage \
        --scratch-path "../$SCRATCH" > "$COVERAGE_LOG" 2>&1); then
  echo "COVERAGE: the test run FAILED, so there is no coverage to report." >&2
  echo "This is usually gate 1 failing too — fix that first, then come back. The run's own" >&2
  echo "output is at $COVERAGE_LOG; its last failures:" >&2
  grep -E "✘|error:" "$COVERAGE_LOG" | head -20 >&2
  exit 1
fi
rm -f "$COVERAGE_LOG"

# **Every test binary THIS run linked, and no other.** Until 2026-09-28 this took the first
# `SoredemoCorePackageTests.xctest` it found. The toolchain stopped building that combined bundle
# around 2026-09-15 — macOS 27 builds one bundle per test target — and the one in this directory
# was never deleted, so for thirteen days every figure this gate printed read today's counters
# through a thirteen-day-old binary's map: files added since were absent, files deleted since were
# present, and `MP4Exporter`'s export path, which every export test runs, read as never executed.
# The numbers stayed between 70 and 73, which is why nobody looked. A measurement that fails into
# the legal range is not a measurement (AGENTS.md).
# The test targets are read from the manifest, not listed here: a hand-written list goes stale by
# omission (AGENTS.md), and "newer than the run" would refuse an up-to-date build that relinked
# nothing. The stale combined bundle is not a target, so it is not chosen.
PROFDATA=$(find "$SCRATCH" -name default.profdata -newer "$RUN_STARTED" -print -quit)
rm -f "$RUN_STARTED"
TEST_TARGETS=$( (cd Core && swift package dump-package) \
  | python3 -c 'import json,sys; print("\n".join(t["name"] for t in json.load(sys.stdin)["targets"] if t["type"]=="test"))')
BINARIES=()
while IFS= read -r name; do
  executable=$(find "$SCRATCH" -path "*/$name.xctest/Contents/MacOS/$name" -print -quit)
  [ -n "$executable" ] && BINARIES+=("$executable")
done <<< "$TEST_TARGETS"
if [ -z "$PROFDATA" ] || [ ${#BINARIES[@]} -eq 0 ]; then
  echo "No coverage data from this run, or no test binary for any of the manifest's test targets," >&2
  echo "under $SCRATCH — refusing to report a number." >&2
  exit 1
fi
OBJECTS=()
for binary in "${BINARIES[@]:1}"; do OBJECTS+=(-object "$binary"); done

REPORT=$(xcrun llvm-cov report "${BINARIES[0]}" "${OBJECTS[@]}" \
  -instr-profile "$PROFDATA" \
  -ignore-filename-regex='(Tests/|\.build[^/]*/|scripts/|soredemo-main/Soredemo/)' 2>/dev/null)

# **The report must be about the sources on disk — all of them, and nothing else.** A file on
# disk missing from the report, or a file in the report no longer on disk, is exactly what a stale
# binary looks like, and it is the check that would have caught the thirteen days above.
# Inverted: these two are the files legitimately absent, each with the reason.
#   architecture-checker/main.swift — an executable target; no test bundle links it.
#   Capture/CaptureError.swift      — one enum and no executable code, so no counters exist.
EXEMPT='^Sources/(architecture-checker/main\.swift|Capture/CaptureError\.swift)$'
# Both sides as `Module/File.swift`: given several binaries, llvm-cov prints paths with their
# common prefix removed, so the report has no `Sources/` — the first version of this compared
# `Sources/X` with `X` and found every file "missing" and every file a "phantom".
REPORTED=$(echo "$REPORT" | awk 'NF>9 && $1!="TOTAL" && $1!="Filename" {print $1}' \
  | sed -E 's#^(.*/)?Sources/##' | sort)
ON_DISK=$( (cd Core && find Sources -name '*.swift') | grep -Ev "$EXEMPT" | sed 's#^Sources/##' | sort)
MISSING=$(comm -23 <(echo "$ON_DISK") <(echo "$REPORTED"))
PHANTOM=$(comm -13 <(echo "$ON_DISK") <(echo "$REPORTED"))
if [ -n "$MISSING" ] || [ -n "$PHANTOM" ]; then
  [ -n "$MISSING" ] && { echo "COVERAGE: sources on disk that the report does not mention:" >&2; echo "$MISSING" >&2; }
  [ -n "$PHANTOM" ] && { echo "COVERAGE: files in the report that are not on disk — a stale binary:" >&2; echo "$PHANTOM" >&2; }
  exit 1
fi
echo "  measured through ${#BINARIES[@]} test binaries from this run, $(echo "$REPORTED" | wc -l | tr -d ' ') source files"

echo ""
# Grouped by the module the file lives in, which is the directory under Sources/.
echo "$REPORT" | awk 'NR>2 && NF>6 {
    n=split($1,p,"/"); m=p[1]
    for (i=1;i<n;i++) if (p[i]=="Sources") m=p[i+1]
    t[m]+=$8; u[m]+=$9 }
  END {for (k in t) if (t[k]>0 && k!="TOTAL")
         printf "  %-14s %6d lines  %5.1f%%\n", k, t[k], 100*(t[k]-u[k])/t[k]}' | sort -k3 -n

TOTAL=$(echo "$REPORT" | awk '/^TOTAL/ {gsub("%","",$10); print $10}')
echo ""
echo "  TOTAL line coverage: ${TOTAL}%  (floor ${FLOOR}%)"

# Integers: a floor, not a target, and a tenth of a point is not a fact about the tests.
if [ "${TOTAL%%.*}" -lt "$FLOOR" ]; then
  echo "COVERAGE BELOW FLOOR." >&2
  exit 1
fi
