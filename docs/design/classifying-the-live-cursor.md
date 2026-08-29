# Classifying the live cursor

*Measured 2026-08-30. Code: `Soredemo/DesignSystem/SystemCursorShape.swift`.*

The drawn cursor changes shape as the pointer crosses a text field or a link,
which means something has to say *which* shape the system cursor was at each
sample. This is that.

## Every cursor was `.other` until a measurement was retaken in the right place

The comment this replaces said the class cursors' images are 0×0 and their
`tiffRepresentation` is `nil`, so no comparison could ever succeed. The
measurement was real and it was taken in the wrong place: a bare command-line
binary that never touches `NSApplication`.

**AppKit populates the class cursors' images when the application object is
created.** Until `NSApplication.shared` exists, `NSCursor.arrow.image` really is
0×0. It is a documented requirement of `NSCursor`, and it is why this file forces
the application object before it samples.

Re-measured inside an application, all seventeen class cursors have real images
and distinct digests:

```
arrow           28×40   583248 bytes   57a1d610…
iBeam           23×22   263952         3de4a52b…
pointingHand    32×32    20892         65d626a5…
crosshair       24×24    11932         c5bc204d…
resizeLeftRight 30×24    14812         b94c84b1…
resizeUpDown    24×28    13852         b3b52be9…
```

**Size alone cannot do it and the digest can.** `pointingHand`, `openHand` and
`closedHand` are all 32×32 with 20,892 bytes of TIFF; `operationNotAllowed`,
`dragCopy`, `contextualMenu` and `disappearingItem` are all 28×40 with 22,812.
Only the digests tell those families apart.

## The table is built at runtime, which is the whole point

The common approach is to hash the live cursor against a table of *literal*
digests. Anyone doing that has to maintain more than one — the artwork changed at
macOS 26, so a table written before it is wrong after — and a literal table is a
fact about an OS version pinned inside an application. It goes stale silently: an
unrecognised cursor draws as an arrow and nothing reports it.

This asks the running system instead. Every class cursor is hashed once, and the
live cursor is looked up in what came back. A macOS that redraws its cursors
changes both sides of the comparison at once, so there is nothing to update and
nothing to go stale. The digests above match published tables for this OS version
exactly, which is as close to a second opinion as this can get.

The table is built once and held: hashing ten images is a few milliseconds and the
reader runs ten times a second.

## Four resize cursors reported as two

`resizeLeft`, `resizeRight`, `resizeUp` and `resizeDown` are each reported as the
two-headed shape on their own axis. A deliberate approximation, and the smaller of
two errors: this app draws two resize shapes and not four, and a viewer who saw a
horizontal resize affordance is shown a horizontal one rather than the arrow
`.other` would give them. `openHand`, `closedHand`, `contextualMenu` and the rest
have no art here and stay honestly `.other`.

## The readers never block and never assert

They are called from `InputObserver`'s poll queue, never the main thread, and that
is a requirement rather than an accident: the poll timer exists to notice the tap
callback's thread being stuck, so it deliberately does not share a thread with it.

An earlier version wrapped the read in `MainActor.assumeIsolated` — an assertion
that the caller *is* on the main actor — and a real run trapped with
`EXC_BREAKPOINT` on the poll thread. The doc comment there even claimed "the poll
timer hops here" while nothing hopped.

So the readers return the last value sampled and schedule the next sample on the
main actor. `DispatchQueue.main.sync` is the obvious alternative and is worse: the
main thread can be inside AppKit waiting on something the poll is meant to detect,
and a sync hop would deadlock precisely then.

The cost is one poll interval of staleness, 100 ms. A cursor shape changes when
the pointer crosses a control boundary, so a sample 100 ms behind is the same
answer nearly always, and being briefly behind is a better failure than trapping.
`theShapeReaderIsCalledOffTheMainThread` pins the contract from the package side.
