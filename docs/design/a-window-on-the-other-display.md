# A window on the other display

Two defects in the window-recording path, both invisible on a single-display Mac, both found on
2026-09-16 within twenty minutes of a second monitor being plugged in. One of them stops the
cursor being drawn at all.

## The arrangement that found them

| | frame | scale | notch |
|---|---|---|---|
| Built-in Retina Display | (0, 0, 1512, 982) | 2.0 | 32 pt |
| LS24AG32x | **(-1920, -63, 1920, 1080)** | **1.0** | none |

A negative origin and a different scale. Nothing exotic — a laptop with a monitor to its left —
and neither condition can exist on a machine with one screen, which is why everything below
had been passing for months.

## Defect 1 — the recorded rectangle was placed a display away

`SCWindow.frame` is **global**. `WindowCapture.sourceRect` means **display-local** — its own doc
comment says so, and `CaptureSource.init(pickerFilter:availableDisplays:)` rebases onto the
display before storing it, with a comment saying it must. `WindowTargets.source(for:)` — the
other constructor of the same value, used by "record a window by pointing at it" — did not.

`viewport(scale:displayUUID:)` then computes `globalOriginX: displayBounds.x + sourceRect.x`, so
a global rectangle is counted twice. Measured, with the probe's own window at global (-1200, 326)
on the external display: the recording was placed at **(-3120, 263)** — 1,920 points left, one
whole display.

**The symptom is not a cursor slightly off. It is no cursor at all.**
`CaptureViewport.normalise` returns `nil` rather than clamping — deliberately, because a pointer
that was not in shot has no position in the recording — so every sample is discarded and the
compositor draws nothing for the length of the take.

`WindowFollower` does not rescue it. It reports only when the frame **changes**, and its
`lastFrame` is seeded with the same global rectangle, so a window nobody drags is never
corrected. Drag the window once and it fixes itself, because `windowMoved(to:displayBounds:)`
does the rebase properly — which would have made this a maddening bug report.

**Rebased, not clipped.** `RegionTargets.localRect(of:inDisplay:)` clips to the display, which is
right for a region and wrong here: a window may hang off the edge, and `bufferWidth` is sized
from the full window. Clipping would leave the viewport smaller than the buffer it describes.

## Defect 2 — the recorded scale was the main display's

`RecordingCoordinator.sizingDisplayID(for:)` answered `CGMainDisplayID()` for a window, on the
written grounds that "a `.window` belongs to no single display". This codebase had already
outgrown that premise: `WindowCapture` carries the display whose bounds contain the window's
centre, and `WindowTargets` sizes the buffer with **that** display's scale. Two halves of one
recording, disagreeing.

**The first account of what this cost was wrong, and the correction is the useful part.** It was
written here, and in the source, that the wrong scale multiplies every pointer sample by
`mainScale / trueScale` — 2× on this arrangement. The test written to prove it failed.
`CaptureViewport` does not divide by the geometry's pixel extent; it rebuilds the divisor as
`widthInPoints * geometry.scale`, so the scale appears once above and once below and cancels —
in `normalise` and in `globalPoint(of:)` alike.

So the wrong scale does not move the cursor. What it leaves is a recorded fact that is not true:
the `DisplayGeometry` in the project's geometry registry, and the `GeometryRevision` digested
from it, name a scale the display does not run at. Nothing reads it back today, which is exactly
how it sat wrong. It is fixed on the principle that a recorded fact should be true before
something starts depending on it — not on a symptom that turned out not to exist.

## How they are held

Two halves, because neither is sufficient alone.

**`cross-boundary-digest-probe` § 29** drives the real capture stack: it puts one of its own
windows on **each** attached non-main display in turn, asks `WindowTargets.source(for:)` for a
source, and checks five things per display — that the stack agrees which display owns the window,
that the recorded scale is that display's, that rebasing `sourceRect` recovers the global frame,
that a pointer at the window's centre is inside the recording at all, and that it is at (0.5,
0.5) of it. Reverting either fix turns it red: the scale fix takes 29.2, the origin fix takes
29.3 and 29.4, and 29.4 prints *"nil — every sample falls outside the viewport"*, which is the
symptom in one line. On a one-screen machine it skips, by name, in the verdict.

**`Core/Tests/GeometryTests/WindowOnAnyDisplayTests.swift`** is the half that needs no hardware:
the same rule over eleven panel sizes (1280×720 to 5120×2880, at 1×, 1.5× and 2×) crossed with
eight placements (left, right, above, below, negative, offset). It asserts the centre rule, a
metamorphic relation — moving the whole arrangement must change no normalised sample — a round
trip through `globalPoint(of:)`, the scale cancellation, and, as the control that makes the rest
mean anything, that feeding a **global** rectangle where a local one belongs does put every
sample off the recording.

The oracle in both is the same and it is a property rather than a formula: **the centre of the
recorded window is the centre of the recording**, whatever the display's size, scale or position.

## What is still open

**A window dragged between differently-scaled displays mid-recording keeps the scale it opened
with.** The geometry — and so the revision every sample is stamped with — is fixed for the life
of a segment, so following that means opening a new segment on a scale change, not changing a
number. `WindowFollower` re-reads the frame; it does not re-read the display.

**Neither defect could have been a compile error, and that is the deeper finding.** This project
already separates points from pixels in the type system (`PointRect`, `PixelRect`), and that
distinction has caught real mistakes. It does not separate **global** points from
**display-local** points, and both defects above are exactly that confusion — one at a
constructor, one at a call site. A `GlobalPointRect` distinct from a `DisplayLocalPointRect`
would have made `WindowTargets.source(for:)` fail to compile. Reading around: the Rust recorder keeps
`LogicalPosition`/`PhysicalSize` as distinct types and computes a window's scale from the
window's own display, which is the same conclusion reached here from the other direction.
