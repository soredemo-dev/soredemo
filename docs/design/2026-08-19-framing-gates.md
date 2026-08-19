# Framing — the zoom target, and every reason there isn't one

*Parity 4, first task. `ROADMAP.md` rows `framing-targets` and `framing-gates`.*

## Scope, stated before anything else

`framing-targets`'s ROADMAP row carries TWO things: choosing a zoom target, and being
"the first row that writes a producer", which makes architecture rule 7 stop being inert
and needs `Derived`'s provenance machinery. **This task does the first and not the second**,
and the row therefore does not tick.

The reason is the dependency, not convenience: the producer half needs `observation-ingest`
(☐) and `derivation-graph` (◐, types without a pipeline). The CHOOSING half needs neither —
it is a pure function from an `AXChainRecord` to a target or a named refusal, and it is what
recorder parity actually wants. Building it now in `Sources/Framing` (a one-line placeholder
since Phase 1) means the graph work later wraps provenance around a function that already
has its own tests, rather than the two being invented together.

## The shape

    AXChainRecord ──▶ FramingDecision
                        ├─ .framed(FramingTarget)      the element's frame, and which it was
                        └─ .rejected(FramingRejection) one of nine named codes

**A rejection is a value, never a `nil` and never a silent fallback to the pointer.** The
ROADMAP's own words: *every rejection names its reason*. `review-ui` shows which gate fired,
`framing-gates`'s codes are `String`-raw so they persist, and a caller that wants the
pointer fallback asks for it explicitly having seen the reason.

## The nine gates, in order, and why that order

Order matters where two could both fire: the FIRST one that fires is the reported reason, so
the order is a statement about which explanation is more useful to a person.

| # | Code | Fires when | Why here |
| --- | --- | --- | --- |
| 1 | `hitTestReturnedNothing` | `truncation == .hitTestReturnedNothing` | the chain has no element at all; every later gate would be asking about a `nil` |
| 2 | `noFrameRecorded` | the hit element has no `frame` | AX answered without geometry — nothing to frame, and distinct from a bad frame |
| 3 | `staleObservation` | `hitTestInterval.duration` exceeds the budget | the frame describes a window that may have moved before the read finished |
| 4 | `notComparable` | frame's `GeometryRevision` ≠ click's | two coordinate systems; comparing them is the `1a98402` family |
| 5 | `doesNotContainTheClick` | click outside the hit frame | a coordinate fault: the element AX returned is not where the user clicked |
| 6 | `degenerateRectangle` | zero or negative width/height | nothing to zoom to |
| 7 | `partlyOffscreen` | frame extends outside 0…1 | half the target is not on the recording |
| 8 | `tooLarge` | frame covers more than `maxTargetArea` of the screen | **a pane is not a control** — zooming to it is a no-op that looks like a bug |
| 9 | `bestCandidateOnTheTruncationBoundary` | the chosen element is the outermost recorded AND the chain was cut | Phase 2's F2-3: measured at 7–8% of clicks, so a normal path. A candidate sitting at the cut is indistinguishable on disk from one genuinely outermost, so the honest answer is refusal, not a guess |

Gate 8's threshold and gate 3's budget are **calibration constants, not measurements** —
named, documented as uncalibrated, and carried where `review-ui` and a real recording can
tune them. Stating that is the point: `framing-gates`'s row says "calibrate the size
threshold against real measurements", and this task does not have those measurements.

## What is deliberately not decided here

- **Pointer fallback** is the caller's, not this module's. A function that silently
  substituted the pointer would erase the reason it just computed.
- **Depth** (`framing-depth`) is the next row and reads `FramingTarget.frame.size`.
- **Which ancestor to prefer** when the hit element fails a gate: this task frames the HIT
  element or refuses. Walking outward to the first ancestor that passes is a real feature and
  a separate decision, because "the button failed, so zoom to its window" is often worse than
  not zooming.
