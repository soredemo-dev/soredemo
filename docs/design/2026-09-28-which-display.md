# Which display a window or a region belongs to

2026-09-28. Found while pulling `CaptureSource`'s geometry out into something testable.

## Three rules for one fact

Choosing what to record reaches a display three ways, and each decided the host display itself:

| Path | When the rectangle's centre is on a display | When it is on none |
| --- | --- | --- |
| the system picker (`CaptureSource.init(pickerFilter:)`) | that display | a display it overlaps, else none |
| pointing at a window (`WindowTargets.source(for:)`) | that display | **the first display, overlapping or not** |
| dragging out a region (`RegionTargets.source(for:)`) | that display | **none** — the region is refused |

`WindowTargets` said in its comment that it used `CaptureSource`'s rule. It did not. A window
pushed so its middle is past an edge — into the gap under a shorter display — was recorded
against whichever display the system lists first, a screen it may not be on: the source rect then
lies outside the display and the recording is of the wrong place. The same region, dragged,
was refused though it overlapped a display.

The buffer size disagreed too. The picker floored `points × scale` to even; pointing at a window
rounded first. A 100.8-point window at 2× was 200 pixels one way and 202 the other.

## Decision

**`DisplayHost.index(for:among:)` — the centre's display, then any display overlapped, then
none — is the one rule, and all three paths call it.** Pure over `PointRect`s, because an
`SCDisplay` cannot be built in a test and the decision is where the risk is. Its tests run on two
displays of different heights with the second at a non-zero origin, and include both old
fallbacks as mutations: "the first display" and "no overlap fallback" each redden a test.

**Buffers use `RegionCapture.buffer`** — floor to even, at least 2 — the rule the picker always
used and the one already tested.

Behaviour that changes: pointing at a window whose centre is on no display now records the
display it overlaps, or refuses; a dragged region whose centre falls in a gap now records the
display it overlaps. Both were wrong before in the direction that produces a recording of the
wrong thing.

**Not covered by a unit test:** that `WindowTargets.source` and `RegionTargets.source` call
`DisplayHost`. Both need a live `SCShareableContent`; the calls are one line each and read in
review, and the cross-boundary probe runs the region path.
