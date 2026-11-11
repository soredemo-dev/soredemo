# Caption line breaking and the pointer's spring, written again from specifications

**2026-11-11.** `CaptionBuilder` — the code that turns a transcript into caption lines and times
them — was replaced. Its earlier implementation could not be shown to be this project's own work:
part of it followed another program's code line for line. This document is the specification the
replacement was written from, by an agent that was given this document, the public API and the
tests, and nothing else.

## The rule for whoever implements it

Read this file, `Core/Sources/Overlays/CaptionBuilder.swift` (a stub: the public API and its
documentation), the types it uses (`Transcript`, `TranscribedSegment`, `TranscribedWord`,
`CaptionCue`, `CaptionMeasurement`, `CaptionScript`, `SilenceFinder.Span`), and the tests. **Do not
read any earlier version of `CaptionBuilder.swift`** — not through `git log -p`, `git show`, a diff
or a backup — and nothing under `~/Documents/opensource`. Design the algorithm yourself.

## What it has to do

The tests in `Core/Tests/OverlaysTests/CaptionBuilderTests.swift`, `CaptionEditingTests.swift` and
`CaptionRebuildBudgetTests.swift` are the acceptance criteria and win over any sentence here.

**Lines**

1. Every line passes `fits`, is no wider than its script's reading limit
   (`CaptionMeasurement.width(of:)` against `CaptionScript.of(text).longestLine`), and has at most
   `maximumWords` words when a cap is given.
2. Exceptions: a single word wider than the box is left whole rather than cut inside the word, and a
   script without spaces between words is not cut by the limit meant for spaced scripts.
3. The lines, joined with single spaces, are the segment's words in order — breaking never changes,
   drops or reorders a word.
4. Where a line must break: at the end of a sentence (`.`, `!` or `?` followed by a space) before a
   clause boundary (`,`, `;`, `:` followed by a space), and at a clause boundary before anywhere else.
   A full stop inside "U.S." or "3.14" is not a sentence end.
5. A clause of one word ("First,") is not left alone on a line; a sentence of one word ("Yes.") may
   be. Merging can collapse a split back into the original line, and that must terminate.
6. With no punctuation to use, the line breaks at a word boundary chosen for balance **by
   characters, not by word count**, avoiding a first half that ends on a word which leads into what
   follows ("how", "to", "the", "of"…) and avoiding a half of a single word. `breakAtMiddleWord(_:)`
   is that choice for one line into two, tested directly; a single word returns itself.

**Times**

7. With word timings, a line runs from its first word's start to its last word's end, and carries
   those words in `CaptionCue.words`. Recognisers' word runs do not always split on spaces
   (contractions, numbers, punctuation), so a line is matched to runs by the characters it contains,
   not by counting words. A segment is timed only against the words inside its own span.
8. Without word timings, the segment's span is shared across its lines in proportion to their
   length, back to back, and the last line ends where the segment ends.
9. A line shown for less than `minimumDisplay` is extended to it, but never past the start of the
   next line — including the first line of the next segment, so the floor is applied once over the
   whole list rather than per segment.

**A whole transcript**

10. Segments in order. A transcript with words but no segments is treated as one segment made of
    all its words; an empty transcript gives no lines rather than one empty line.
11. `pauses` are spans where the recording is silent. A segment is cut wherever a pause separates
    two of its words, into as many pieces as there are such pauses; a pause that separates no words
    cuts nothing.

**Cost**

12. Rebuilding a long transcript (the budget test: about 270 lines) has to be fast enough to follow
    a slider. `fits` may be expensive; call it no more than needed.

## A suggestion, not a requirement

Treat breaking a line as choosing a set of break points among the candidates (every space),
scoring each possible line — punctuation at its end lowers the cost, a forward-binding last word or a
one-word line raises it, a line over the limit is infeasible — and taking the cheapest set by dynamic
programming. It states the preferences above as costs in one place instead of as a sequence of
fallbacks, and it is a different construction from the one replaced.

## Constraints

`Core` is Foundation-only (architecture rule 1), names no CoreGraphics type (rule 2), and reads no
clock or randomness (rule 3). Swift 6 strict concurrency. Comments: at most 30 lines above a type and
16 anywhere else. Swift Testing for any new test. Verify with
`swift test --package-path Core --no-parallel --filter OverlaysTests`, and say what ran.

## The spring step, the same way

The same audit found `Spring.step` in `Core/Sources/Render/PointerPath.swift` — one exact step of
the damped oscillator the drawn pointer follows — written line for line like another program's,
with its variables renamed. It was replaced the same way. The specification was the equation
itself, x″ = −ω²(x − target) − 2ζω·x′, solved exactly at `dt` from a position and a velocity for
every ζ ≥ 0, overdamped included as its own solution rather than the critical one reused, with no
seam at ζ = 1. Its acceptance criteria are properties of that equation, in
`Core/Tests/RenderTests/SpringTests.swift`: the step satisfies the equation, its velocity is the
derivative of its position, two steps land where one of their sum does, energy never grows, only an
underdamped spring overshoots, and nothing jumps at ζ = 1.

The implementation writes all three regimes as one expression over a pair of functions that are
cos/sin, 1/t or cosh/sinh as ζ²−1 is negative, zero or positive, evaluated near ζ = 1 as one power
series in (ζ²−1)ω²t² — so there is no branch to have a seam — and the overdamped case as two
decaying exponentials, with the slow root computed without cancellation.

## How the two replacements were checked

Before either was merged: its tests, run by the implementer and again independently; and a
comparison with the code it replaced, line for line and with identifiers erased, at thresholds of
four lines — lower than `scripts/scan-for-borrowed-code.py` uses by default. Both came back with
nothing shared. The one four-line match the second comparison reports for `PointerPath.swift` is the
cubic Hermite basis, `2u³ − 3u² + 1` and its three companions, which is a definition rather than a
choice.

One behaviour changed on purpose: a damping ratio above 1, which the pointer's settings allow up to
2, now moves as an overdamped spring does. It used to move as a critically damped one.

