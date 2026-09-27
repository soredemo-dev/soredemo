# Edges that line up

2026-09-27. an Electron recorder snaps what is dragged on its timeline. This one already had snapping —
`SnapEngine`, sticky, with the playhead easier to reach and a probe per edge — **but only the
range selection used it.** The feature-gap list called timeline snapping missing; that was wrong,
from a search for `snapGuide|snapping|snapsTo` that did not match `SnapEngine`. The real gap was
narrower: trimming a clip and dragging a zoom did not line up with anything.

## Decision

**Through `SnapEngine`, the rule the selection already uses**, so a selection, a trim and a zoom
line up by one rule and hold the same way. A second implementation was written and deleted within
the hour, once the first was found.

- **Targets** gain zoom edges (`Target.Kind.zoomEdge`, the clip edge's reach). A cut that stops a
  hair before a zoom ends leaves a flash of it; lining the two up is the point.
- **The dragged thing's own edges are excluded** (`targets(in:…excluding:)`). A snap holds, so an
  edge able to find its own starting position would stick there and a small trim could not be made.
- **A trim** probes its one edge; **a zoom moved whole** probes both ends and whichever is nearer
  wins, the one delta keeping its length; **a zoom resized** probes its end.
- **⌘ held** places anything exactly where the hand is — every drag, the selection included —
  the modifier editors use for that.
- The line a snap took hold at is the one the selection already drew.

## Tested, and the order it was done in

The model-level tests were written after the code, against this project's rule. Each was then
shown to be able to fail by a mutation: dropping the exclusion held a small trim at its start;
dropping the trim's snap left it 50 ms off the playhead; dropping the zoom's snap left its end
short. `SnapEngine`'s two new behaviours (zoom edges, exclusion) were red before they were
implemented.

## Not looked at

The on-screen check was abandoned: the synthetic drag went to another application that was in
front at the time. The behaviour is covered by the tests above; nobody has watched it on screen.
