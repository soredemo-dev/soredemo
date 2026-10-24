# The zoom lane draws the camera

2026-10-25. First item of `docs/research/landscape.md`'s "What to take from it": zoom you can
read and shape on the timeline.

## What a person cannot see today

A zoom block on the lane is one rectangle from `start` to `end`. What the viewer sees is not that
rectangle: the camera is a critically damped spring (`CameraMotion`, ω = 10 at the standard pace)
that starts moving at `start`, is within 2% of the target about 0.9 s later, starts back at `end`
and is at rest about 0.9 s after that — and, between two blocks closer than
`ZoomBlock.chainedPanGap`, does not go back at all but pans. None of that is on the lane. A block
looks the same whether the camera reaches it or a 0.5 s block that it never reaches; two chained
blocks look the same as two that dip out between them.

Competitors draw ease-in, hold and ease-out as three fixed segments of a keyframed curve. **That
would be a drawing of a model this app does not have**: there are no keyframes here and the
ease is not a duration but a spring, whose arrival depends on the pace, the distance, and what
came before. Three fixed segments would disagree with the render, and a lane that disagrees with
the picture is worse than one that says less.

## The decision

**The lane draws the camera's own zoom over time, from the path the renderer reads.**
`CameraMotion.bakedPath(in:)` has said since it was written that it is "for a test or a timeline
that wants the curve rather than one point on it"; nothing has called it. A pure function in
`Framing`, `CameraMotion.zoomProfile(in:from:to:columns:)`, samples it into one value per pixel
column — the highest zoom in each column's span, so a short arrival is not lost between two
columns — and the lane draws those as an area under the blocks. Arrival, hold, return and the
pans between chained blocks are then on screen because they are what the camera does.

- **Built from the same inputs as the render's camera**: the adjusted blocks and the pace. Not
  the cursor, which moves the centre and never the depth. **Not the zoom ceiling**, which the
  compositor learns only when it knows the output card; under a ceiling the curve's height is
  higher than the picture's, never its timing. Said in the lane's comment rather than hidden.
- **Drawn as columns**, as `WaveformBars` draws audio, so no CoreGraphics geometry is named in
  the app (architecture rule 5) and the same `Equatable` + `drawingGroup()` arrangement keeps a
  scrub from re-laying it out.

**Both edges can be dragged.** Today the right quarter resizes and anywhere else moves. Now the
left quarter moves the start and keeps the end, the right quarter the end; a block too narrow
for three zones (under 18 points) only moves. `ZoomAdjustment` already carries both deltas: a
start drag is `movedBy(d).resizedBy(-d)`. Undo names it "Resize Zoom", as the right edge.

**A drag stops at its neighbour.** Moving or resizing a block into another block made two zooms
overlap, which the derivation never produces (`ZoomBlock.blocks` merges overlaps) and the camera
then aims at whichever it reaches first. The drag now stops at the neighbour's edge — the trim's
rule, "the last legal state stays on screen" — rather than refusing the whole drag, which would
throw away the part of it that was fine.

## How it is verified

- `zoomProfile`, in `FramingTests`, on blocks that do not start at the recording's start:
  rest before the first block; above 1 after it begins and near its depth before it ends; back to
  rest well after the last; **not back to rest in a chained gap** and back to rest in a long one;
  every value finite and ≥ 1; the requested number of columns. Mutations: the column's maximum
  replaced by its first sample; chaining disabled.
- The model, in `ZoomUndoTests`' fixture extended with a neighbour: a start drag keeps the end;
  a move stops at the neighbour's edge; a resize stops at it; a switched-off zoom is not in the
  way. Mutations: the start drag moving the end; the neighbour clamp removed.
- The lane is looked at.

## Where it ended

As decided, with one correction to this document: **a start dragged past the end is "no zoom
here"**, as an end dragged past the start already was (`ZoomAdjustment.applied(to:)`), not "the
last legal length". Two rules for one gesture in two directions would be the inconsistency.

The curve is normalised in the model — 0 at rest, 1 at the deepest zoom in view — and the camera
it is read from is cached on the zooms and the pace, because a bake integrates the whole
recording and a drag redraws the lane every frame. `cameraBakes` counts them for the cache pair
(`theCameraIsBakedOnceAndAgainWhenTheZoomsOrThePaceChange`). `TimelineEditorModel.cameraPace` is
kept in step with the editor's by the same `StageWindow` task that publishes it to the compositor.

Core: six tests of `zoomProfile`; two mutations, each red on its own test (a column keeping its
first sample; chaining disabled). App tests 307 → 314; six mutations, each red: the start drag
moving the end, either neighbour clamp removed, the cache ignoring the pace, the curve not
normalised, the left zone answering "move". Both tooltips now say either edge can be dragged, in
all ten languages.

**Not seen in the running app**: the curve under a recording's zooms, a chained pair drawn
without a dip, the left edge dragged both ways, a move stopping at a neighbour.
