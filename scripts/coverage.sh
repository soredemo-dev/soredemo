#!/bin/bash
# Line coverage over the package, and a floor under it.
#
# **What this number does NOT include, stated first, because the shape of the gap is the
# interesting part.** It is the coverage the TEST BUNDLE produces. `Capture` reads at ~34%
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
BUILD=$SCRATCH/arm64-apple-macosx/debug

(cd Core && swift test --no-parallel --enable-code-coverage \
   --scratch-path "../$SCRATCH" > /dev/null 2>&1)

REPORT=$(xcrun llvm-cov report \
  "$BUILD/SoredemoCorePackageTests.xctest/Contents/MacOS/SoredemoCorePackageTests" \
  -instr-profile "$BUILD/codecov/default.profdata" \
  -ignore-filename-regex='(Tests/|\.build/|scripts/|soredemo-main/Soredemo/)' 2>/dev/null)

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
