# A read is stale only after the release

Gate 3 of [the framing gates](2026-08-19-framing-gates.md) refused a click whose accessibility
hit-test took longer than 4 ms, as *the window may have moved during the check*. On the README's
real take (2026-11-01) it refused two and three of six clicks in two runs, on a Chrome window that
never moved, and sent each to the pointer under a reason that was false. This settles what gate 3
should ask.

## What was measured

**The 4 ms was never a measurement.** `FramingGate.stalenessBudget` said so in its own comment —
"uncalibrated … an order of magnitude above the sub-millisecond answers a responsive app gives" —
and the 2026-08-19 document listed it as a calibration constant awaiting real data.

**At rest, the hit-test is fast and its tail is long.** `scripts/measure-hit-test-latency.swift`
asks the system-wide element what is at a 6 × 5 grid in every window on screen, the call
`LiveAXElementSource.hitTest` makes, and times each answer. On this Mac, 2026-11-04, four windows
(Chrome, a terminal, Safari, Mail), 120 answers: p50 0.43 ms, p90 0.67 ms, max 31.4 ms; four answers
over 4 ms, from Safari and Chrome.

**At a click it is slower, because the app is busy with the click.** The committed fixture
(`HeadlessFixtures/segment-00-redacted.jsonl`, a real recording) has three clicks. Measured from
the button going down:

| Click | Hit-test | Read ends | Button released | Gate 3 at 4 ms |
| --- | --- | --- | --- | --- |
| 1 | 36.6 ms | 37.1 ms | 82.7 ms | refused |
| 2 | 6.8 ms | 7.6 ms | 91.7 ms | refused |
| 3 | 3.1 ms | 4.4 ms | 112.5 ms | passed |

The hit-test starts 0.4–1.0 ms after the button goes down (`CaptureSession` enqueues on `.down`).
Every read finished long before the button came up.

## The question gate 3 is actually asking

A frame is a fact about one moment. The click is about another. The gate exists because the two
can disagree: if what was under the pointer changed between the click and the read, the frame
describes something the person did not press.

**What changes what is under the pointer is the click's own action**, and almost every control
acts when the button is RELEASED — a button, a link, a checkbox, a tab. Until the release, the
person is still holding the button down over the thing they chose; nothing has been activated. A
window cannot be dragged by a click on a control either: the drag is the same button, held on the
title bar.

So the duration of the read was a proxy, and a poor one. A 36 ms read that ends 46 ms before the
release describes exactly what was clicked. A 2 ms read that started late — after the release —
could describe a page that has already navigated.

## Decision

**A read is stale when it ended after the click's release.** The read ends at the later of the
hit-test's end and the hit element's own read (the frame is read there, after the hit-test), and
the release is the first `up` of the same button after the click's `down`, in the same boot epoch.

- **Ended before the release** — not stale, whatever it cost.
- **Ended after the release** — `staleObservation`, now worded for what happened: *the app
  answered after the click was let go, so what it reported may already have changed*.
- **No release in the log** — a new refusal, `releaseNotObserved`: the take ended with the button
  held, or the release fell in a blind interval. A missing release is not evidence of a fast read,
  and treating it as one would be a measurement failing into a legal answer.

`FramingGate.decide(for:releasedAt:)` takes the release from its caller; the pairing is one
function, `ClickRelease.instant(for:in:)`, which both readers of the log call — the compositor and
`FramingPlanReader` — so the zoom that plays and the zoom the review lists cannot disagree about
when a click was let go. `stalenessBudget` is deleted rather than left unused.

## Alternatives rejected

- **Calibrate the budget — 50 ms, say, past this fixture's 36.6.** A number from three clicks is
  still a guess with a tail, and it keeps asking the wrong question: a fast read after the
  release would pass and a slow one before it would fail.
- **Drop gate 3 and rely on gate 5**, which checks the frame contains the click. Gate 5 catches a
  frame that moved away from the click; it cannot catch a NEW element that has appeared under it —
  a page that navigated, a sheet that opened — which is exactly what a post-release read can return.
- **Hit-test again after the release and compare.** Twice the accessibility calls on every click,
  and the second answer is about the post-click world the gate is trying to avoid.

## What this does not cover

**Controls that act on the button going DOWN** — a pop-up button, a menu bar item, a web page's
`onmousedown` — can change what is under the pointer before the release. The release rule does
not see that; nor did the duration rule, except by accident when the app was slow. Gate 5 still
catches a frame that is not under the click. If real recordings show such clicks framing the wrong
element, the next measurement is the hit element's role against the down-acting kinds.

## Effect on the recordings already measured

The fixture's three clicks: click 1 is still refused by gate 1 (nothing was under it); click 2,
no longer stale, is refused by gate 8 as `tooLarge` (an `AXGroup` over 0.92 × 0.87 of the screen) —
which is what `theRecordingsAXChainsProduceExactlyOneZoom` first asserted before gate 3 pre-empted
it; click 3 is framed. One zoom, as before, and every reason now true.
