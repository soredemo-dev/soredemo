# Clock-domain types — making `1a98402`'s class a compile error

*Phase 3A-2. The goal is stated as a checkable outcome, not a preference: reintroducing the class
of defect `1a98402` belonged to must fail to typecheck, where today it compiles and one test
catches it. A test is edited by whoever finds it inconvenient; a type is not.*

## The defect class

`1a98402`: `StageCompositor.pointerPlacement` queried an absolute-host-clock track with a
composition-relative time. Both sides were bare `Nanoseconds`, so `let time = offset` (instead of
`anchor.hostTime + offset`) compiled, matched nothing on every frame of every recording, and
survived 450 tests, 350 probe checks and three review rounds, because the probe's fixture stamped
its samples in the same wrong frame of reference.

The samples were never ambiguous — `PointerSample.instant` is a `HostInstant`, which carries its
`BootEpoch`. The queries were: `PointerTrack.position(at: Nanoseconds)` and
`ClickTrack.ripplePhase(at: Nanoseconds)` accept any number of any domain, and the compositor
discarded the `HostInstant` structure at exactly the seam where the domains met.

## The two shapes ROADMAP offered, and the choice

**A `CompositionOffset` wrapper** (make the composition-side value a distinct type) protects one
argument position at one call site and leaves the tracks epoch-blind: any other bare `Nanoseconds`
— a constant, a test fixture, a future caller's arithmetic — still passes. Rejected.

**`position(at: HostInstant)`** (push the domain into the query) is chosen: callers of the track
API can no longer hold a bare `Nanoseconds` of ambiguous domain at all. The conversion
composition-offset → host-instant gets exactly one home, `EpochAnchor.instant(atOffset:)`, and
`StageCompositor` goes from `anchor.hostTime + offset` to `anchor.instant(atOffset: offset)` — the
`1a98402` shape (`position(at: offset)`) becomes a type error. A deliberate
`HostInstant(epoch:hostTime:)` construction can still defeat it; the target is the accidental
class, and no wrapper type stops a determined author — this is the same grade of claim
`CursorOverride.epoch`'s own doc comment already makes.

This is also the deferred half of a decision already recorded: `CursorOverride.epoch` was added
"while zero files exist" with the explicit note that it changes no behaviour until
`position(at:)` takes a `HostInstant`. This work is that note coming due.

## Epoch mismatch: skip, not trap

With `HostInstant` at the query, epoch comparison becomes possible, and the question is what a
mismatch means. `HostInstant.<` traps across epochs because comparing them is a programming error.
A track query is different: a recording can legitimately span a reboot, so "this sample belongs to
another boot session" is a data condition, not a programming error — the same distinction
`HostRange.contains` already draws ("returns `false` because asking it is legitimate"). So:

- a sample from another epoch is not the most-recent sample — skipped;
- an override from another epoch does not suppress — the behaviour change
  `CursorOverride.epoch`'s doc promised;
- a click from another epoch has no ripple in flight.

The silences stay loud through the existing reading cases (`.noObservationYet` etc.), which exist
precisely so absence is distinguishable.

## Out of scope, stated

`BlindInterval` carries no epoch. Giving it one is a persisted-format change with the same
"while zero files exist" migration window argument `CursorOverride` used — it deserves its own
decision, not a rider on this one. Until then `position(at:)` compares blind intervals by
`hostTime` alone, documented at the site. `PointerTrack.blindFraction(over: Range<Nanoseconds>)`
likewise keeps its shape; it is a duration statistic, not an instant query, and no domain confusion
has been observed through it.

## Test order

1. `EpochAnchor.instant(atOffset:)` — behavioural red first (stub returns the anchor unchanged,
   test demands the offset applied and the epoch carried), then green.
2. The signature migration compiles with epochs ignored; the suite re-greens (fixtures gain a
   shared test epoch — same numbers, now stated in a domain).
3. Epoch-mismatch tests red (epochs still ignored), then the filtering makes them green.
4. The `1a98402` shape is reintroduced by hand once — `pointer.position(at: anchor.hostTime +
   offset)` — the type error is observed, and the edit reverted. That observation is the outcome
   this document exists to make checkable.
