# How fast the camera moves

2026-09-27. The MIT Electron recorder lets a person choose the easing of a zoom. Here the camera is a spring, so
the choice is a pace.

## Decision

**Three paces — Gentle, Standard, Snappy — as the spring's natural frequency: ω = 6, 10, 16.**
The damping stays at 1 for every pace. A spring's *shape* is its damping, and critical damping is
the one that approaches from one side and never overshoots; what a person means by "smoother" or
"snappier" is how long the move takes, which is ω. Standard is the ω the camera always had
(`CameraMotion.angularFrequency`, 10), so every existing project looks exactly as it did.

Rejected: **easing curves (ease-in-out, cubic…).** The camera is integrated, not tweened — it
follows the cursor inside a zoom and hands one block to the next with its velocity — and a curve
between two fixed framings has nothing to say about either.

**Arithmetic, not a measurement:** a critically damped spring is within 2% after about 5.8/ω,
plus the aim's 0.12 s easing, so Snappy should settle in roughly half a second — about when the
click lands, since the pre-roll is 400 ms — while Standard and Gentle are still moving then, which
is what "following rather than anticipating" was tuned for. The ordering below is measured; these
durations are not, and nobody has watched the three side by side yet.

## What it touched

- `CameraMotion(pace:)`, carried through `limited(toZoomCeiling:)` and re-baked by `pacing(_:)`.
- `StageCompositor.cameraPace`, which **re-bakes the camera an instance already built** when it
  changes — the cursor movement's precedent — so the preview responds without a rebuild. Paired
  cache tests: an unchanged pace gives the identical camera; a changed one gives a different one.
- **Found on the way: `zoomIntensity` was not in `StageCompositor.Settings`.** An export captures
  those settings when it is queued, because it runs later; the amount was missing, so an export
  queued at one amount rendered at whatever was set when it ran. Both are in it now, and a test
  holds them there (red before the fix).
- `EditState.cameraPace`, a raw `String` because `Project` cannot see `Framing`; absent and
  "standard" are not edits.

## Measured

Time for the zoom to cover 98% of its way, one fixture: Snappy < Standard < Gentle by more than
0.1 s each, and no pace's zoom exceeds its target at any sample.
