#!/bin/bash
# Fails if an incremental `swift build --build-tests` emits any `StrictMemorySafety`
# warning.
#
# **`--build-tests`, and it was NOT here through Phase 3A-1 Task 6 — corrected at that
# task's code review, item 3.** `Package.swift`'s `strict` array is applied to the
# eleven TEST targets as well as to the library targets, but plain `swift build`
# compiles none of them, so for this gate's whole life it verified rule 9 over roughly
# half the sources the rule is declared over — and reported "zero warnings" without
# ever naming the half it had not looked at. A test file could carry any number of
# unmarked unsafe constructs and this script would have passed, every time, silently.
# Measured at the correction: adding `--build-tests` compiles all eleven test targets
# and still reports zero, so the number did not move — but it now means what it says.
# The extra cost on a warm `.build` is seconds.
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
# **Incremental, not clean** — this runs `swift build --build-tests`, not `rm -rf
# .build && swift build --build-tests`. A clean build is minutes; an incremental one
# is the cost every other gate here already pays. This is sound for the property the
# gate exists to hold — "the count cannot climb again" — because a warning can only
# newly APPEAR in a file that was just compiled, and any edit forces its own file to
# recompile whether or not the rest of `.build` is warm; there is nothing an
# incremental build can hide from a change made to the file it is hiding in.
#
# **That argument is only as wide as the set of files the build compiles at all**, and
# that is precisely where this paragraph was false before Task 6's review: it argued
# incrementality while the command underneath compiled no test target at any warmth,
# so "any edit forces its own file to recompile" simply did not apply to a test file —
# not because the build was warm, but because the build never reached it. The
# soundness claim and the command now cover the same set. It does NOT independently prove
# the whole tree is clean from a cold cache — that claim was established once, by
# hand, with `rm -rf .build && swift build` (library targets only; the cold-cache
# claim has never been made over the test targets), and reaching for
# `rm -rf .build && swift build --build-tests` is the right move if this script's soundness is
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

swift build --build-tests 2>&1 | tee "$LOG"

# **"Verified clean" and "measured nothing" are different outcomes, and this gate
# must not confuse them** — the same hole `scripts/count-tests.sh` already guards
# against ("silence and zero both read as an answer"), now closed here too. THREE
# failure modes short of a real pass, checked in order and each with its own exit
# code so a caller can tell which one fired without re-reading the log:
#
#   - an empty log (a build whose output never reached `tee` — `set -euo pipefail`
#     already fails closed on a nonzero exit, but a build that exits 0 while
#     printing nothing is a silent success this loop must not trust) — exit 2;
#   - a non-empty log with no "Build complete!" marker (`swift build` DID produce
#     output but never reported success — the run didn't finish, or finished some
#     other way this script doesn't recognise) — exit 2 as well, distinct message;
#   - a "Build complete!" log with NO evidence any file was actually compiled or
#     linked — an up-to-date `.build` prints "Building for debugging...",
#     "[Computing dependencies]", "Build complete!" and nothing else, which
#     contains no `StrictMemorySafety` tag for the same reason it contains no
#     warning of any kind: nothing ran. `Build complete!` is a success marker for
#     the BUILD, not for the SCAN — exit 3, distinct message, distinct from both
#     exit 2 cases above because THIS one has a "Build complete!" marker and still
#     is not a clean pass;
#   - a `StrictMemorySafety` hit anywhere in a log that DID report success AND
#     show evidence of compiling — exit 1, the actual finding this gate exists to
#     catch.
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

# **"Build complete!" is a success marker for the BUILD, not for the SCAN.** On an
# already-up-to-date `.build` (nothing to compile or link) this run prints exactly
# three lines — "Building for debugging...", "[Computing dependencies]", "Build
# complete!" — and none of them is `StrictMemorySafety`, because nothing was
# compiled, not because nothing warned. Measured on this toolchain (swift-driver
# 1.168.5 / Swift 6.4, the modern SwiftPM build backend): a build that does real
# work prints per-task progress lines shaped `[N / M] <TargetName>` (the digits
# either side of `/` are separated by a THIN SPACE, U+2009, not an ASCII space —
# confirmed with `xxd`, which is why the pattern below does not require an ASCII
# space around the slash); a build with nothing to do prints none of those lines.
# Classic SwiftPM output (`Compiling <Module> <File>.swift`) is matched too, as a
# second, OR'd signal, since the exact wording differs across toolchain/build-
# backend combinations and this gate must not go blind to a warning just because
# it runs somewhere the line format differs from the one measured here.
#
# **This guard does not work, and the two factual claims above it are refuted.**
# Left in place, with its failure recorded, because deleting it would remove the
# only marker of where the repair goes. Measured after the final whole-branch
# review, on identical state with zero source edits:
#
#   * A no-op build DOES emit a progress line. One run printed
#     `[1 / 26] HeadlessTests-product`, the next printed a bare `[1 / 1]`, and
#     BOTH satisfied the pattern below and passed. SwiftPM emits a progress line
#     for a link task on a build that compiled no Swift file at all, so the
#     first alternative is satisfied by a line that says nothing about whether
#     anything was scanned. The paragraph above asserting "a build with nothing
#     to do prints none of those lines" is false.
#   * `Compiling ` NEVER appears on this toolchain, even on a genuine
#     multi-target recompile — verified by touching `CursorArt.swift` and seeing
#     only `[N / M] <Target>` lines. The second alternative is dead code, so the
#     whole "positive evidence" test reduces to a line shape that is identical
#     whether or not any Swift file was recompiled.
#   * Consequence: four consecutive runs on identical state exited 0, 3, 3, 0.
#     Nondeterministic, which is worse than a consistent false pass — a false
#     green is a stable error you can find; this is not stably anything.
#
# The verdict text at the bottom of this script now says so on every run. The
# repair — make the run genuinely recompile the test targets, delete the dead
# alternative, remove the nondeterminism — is 3A-2's first task, and it is
# ordered before clearing the 11 known sites for the reason ROADMAP states.
if ! grep -qE '^\[[0-9]+[^]]*/[^]]*[0-9]+\]|Compiling ' "$LOG"; then
    echo "FAILED: swift build reported success but compiled or linked nothing —" >&2
    echo "no per-task progress line and no 'Compiling' line appear anywhere in" >&2
    echo "its output. This build compiled nothing; it is an unobserved pass, not" >&2
    echo "a clean one. Run \`swift build --build-tests\` on its own first so this" >&2
    echo "gate has something to scan, or touch a file so the build has work to do." >&2
    exit 3
fi

if grep -q 'StrictMemorySafety' "$LOG"; then
    echo
    echo "FAILED: swift build emitted a StrictMemorySafety warning (see above)." >&2
    echo "Every unsafe construct must be marked 'unsafe' at its own expression —" >&2
    echo "with a comment at the site saying why it is safe here, if it is — not" >&2
    echo "left as an unmarked warning for the next reader to not read." >&2
    exit 1
fi

# **The verdict is narrowed to what was measured, and the gate declares its own
# limits on every run.** It previously read "zero warnings across library AND test
# targets". That sentence was false, and the gate was structurally incapable of
# noticing: see the three bullets it now prints. Narrowing a claim to its evidence
# does not require repairing the instrument first — the same move ROADMAP's row 14
# made when a citation turned out not to hold. Repair is 3A-2's first task, and it
# is ordered BEFORE clearing the sites, because clearing them while the gate is
# still blind lets the next batch in exactly the same way.
echo "STRICT MEMORY SAFETY: no StrictMemorySafety tag in THIS run's output."
echo
echo "  SCOPE — read this before treating the line above as a pass:"
echo
echo "  * Sources/ (the library targets): genuinely zero. Established"
echo "    2026-08-05 by a from-nothing \`swift build\` at a clean scratch path,"
echo "    not by this script. That claim holds."
echo
echo "  * Test targets: NOT COVERED by this run, despite --build-tests. A warm"
echo "    build does not recompile files it considers up to date, so their"
echo "    warnings cannot appear in this log at all. Measured 2026-08-05 from"
echo "    nothing: 11 unmarked SITES exist under Tests/ — 10 in"
echo "    HeadlessTests/PixelBufferSupport.swift, introduced by Phase 3A-1"
echo "    Task 3, and 1 pre-existing in ProjectTests/AXChainRecordTests.swift."
echo "    No run of this gate has ever reported one of them."
echo
echo "    SITES, and the unit is load-bearing. A site is a distinct"
echo "    file:line:column. The EMISSION count is higher — a module compiled"
echo "    for more than one product re-emits every warning it has — and the"
echo "    (file, line) count is lower, because line 31 of PixelBufferSupport"
echo "    carries two sites in different columns. All three can be called"
echo "    'the warning count' and no two of them agree. Four emissions on"
echo "    that build had no real file:line at all, attributed to a synthetic"
echo "    'macro expansion #require' buffer and resolving, via the compiler's"
echo "    'expanded code originates here' note, to two lines already inside"
echo "    the 11. When this gate is repaired it must report in sites."
echo
echo "  * This gate is NOT REPRODUCIBLE. Four consecutive runs on identical"
echo "    state, zero source edits: exit 0, 3, 3, 0. Something that answers"
echo "    differently on the same input is not a gate. A false green is a"
echo "    stable error; this is not even stably wrong. Do not read a pass here"
echo "    as evidence of anything until 3A-2 repairs it."
echo
echo "    That cuts BOTH ways, and the refusals are not the good half. Run"
echo "    on the Phase 3A-1 merge commit, this script exited 3 — the"
echo "    nothing-compiled branch. That is one more draw from the same"
echo "    distribution, NOT evidence that the guard works, and it must not be"
echo "    written down as though the gate had correctly refused. The repair"
echo "    (3A-2's first task) targets REPRODUCIBILITY, not strictness: done"
echo "    means N consecutive runs on identical state give one exit code, and"
echo "    a warning seeded into a test file reddens both a cold build and a"
echo "    warm one. The warm half is where it fails today."
