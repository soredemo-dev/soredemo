# The strict-memory-safety gate repair — clean-per-run

*Phase 3A-2, first task. The ordering is binding (ROADMAP): repair the instrument before clearing
what it should have caught.*

## The question

`scripts/check-strict-memory-safety.sh` answered differently on identical input — 0, 3, 3, 0 across
four documented runs, and 1, 0, 0 at this repair's own baseline (2026-08-12, zero source edits
between runs). The disease: an incremental `swift build --build-tests` does not recompile files it
considers up to date, so a warning living in an unchanged file cannot reach the log; and the guard
meant to catch "nothing was compiled" keyed on log line shapes that SwiftPM does not emit reliably
(a no-op build DOES print a `[N / M]` progress line for a link task; `Compiling ` never appears on
this toolchain at all).

Repair target, from ROADMAP: **reproducibility, not strictness.** Done means N consecutive runs on
identical state give one exit code, and a warning seeded into a test file reddens the gate at any
cache warmth.

## Alternatives considered

**A. Keep the incremental build, fix the heuristics.** Rejected: there is no log shape that
distinguishes "compiled nothing" from "compiled something" on this toolchain — that is the measured
finding the broken guard already documents. Any repaired heuristic inherits the same class of
failure: it reasons about what the build *said*, not what it *did*.

**B. Scan the persisted serialized diagnostics (`.dia` files) instead of the log.** They survive
warm builds, so warmth stops mattering. Rejected: the format is unstable across toolchains, there is
no supported reader, and stale `.dia` from renamed or deleted files would need their own
invalidation story — a second cache to distrust, bolted onto a gate whose defect was trusting a
cache.

**C. Clean-per-run at a dedicated scratch path.** `swift package clean --scratch-path
.build-strict-gate && swift build --build-tests --scratch-path .build-strict-gate`. Every Swift
file in every target compiles on every run, so every warning is emitted on every run; the warm/cold
distinction — the exact place the old gate failed — is eliminated by construction rather than
detected by heuristic. Chosen.

## What made C affordable

The old header priced a clean build at "minutes" and chose incrementality for cost. Measured
2026-08-12 on this machine: **a from-nothing `swift build --build-tests` at the dedicated scratch
path is ~23 seconds**, and the package has **no external dependencies** (`.build/checkouts` is
empty), so the scratch path needs no network. `swift package clean` keeps the scratch directory's
metadata and removes all objects — verified: 105 `.o` files before, 0 after, full 35-emission
recompile following. The premise under the old design was re-measured and found expired; the whole
trade the old gate made was for a price that no longer exists.

The scratch path is separate from `.build` so the gate can neither corrupt the development cache
nor be corrupted by its warmth. It is gitignored.

## Compile evidence: artifacts, not log shapes

The replacement for the dead progress-line guard is a precondition/postcondition pair on the
filesystem: after `clean`, the scratch path must hold **zero** `.o` files (else the clean did not
clean — exit 2); after the build, it must hold **more than zero** (else nothing compiled — exit 3).
This is evidence of the thing itself, immune to output-format drift across toolchains. The
empty-log and missing-`Build complete!` guards stay, unchanged: they catch a different failure
(a build whose output never arrived) and were never the broken part.

## The unit is sites, and 11 became 13

The gate reports **distinct `file:line:column` positions**. Two extraction rules:

1. A primary warning line — `<path>:L:C: warning: … [#StrictMemorySafety]` — contributes its own
   position. Gutter-art repeats (`|- warning:`) and the footnote link line do not match.
2. A macro-buffer warning — `macro expansion #require:L:C: warning: …` — carries no real position
   of its own and resolves through the `note: expanded code originates here` line immediately
   following it.

Measured on the repaired instrument, 2026-08-12: **13 sites** — 12 in
`Tests/HeadlessTests/PixelBufferSupport.swift`, 1 in `Tests/ProjectTests/AXChainRecordTests.swift`.
ROADMAP's count of 11 (measured 2026-08-05) is not contradicted; two things moved underneath it.
The comment-compression commits shifted line numbers, and the two macro-resolved positions
(23:66, 41:65) no longer coincide column-exactly with any primary site (23:67, 41:66 exist; the
macro note lands one column over, on the call inside the macro argument — a genuinely distinct
unsafe expression the old count folded away). The instrument reports what it measures; the prose
follows the instrument, per the rule that numbers come from a script and never from a hand count.

## The credential

Recorded in ROADMAP's 3A-2 block once run. Red half: an unmarked unsafe construct seeded into a
test file must appear in the site list on two consecutive runs — at any warmth, which
clean-per-run makes a vacuous qualifier, and that vacuity is the repair. Stability half: five
consecutive runs on the unmodified tree must produce one exit code and one site list. Green half:
after the 13 sites are cleared (the second task, ordered after this one), five consecutive runs
must exit 0 — the pass path certificate the old gate never had, because on the old gate a pass was
indistinguishable from a blind run.
