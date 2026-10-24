# Splitting the notch surface

2026-10-24. `Soredemo/Recording/NotchSurfacePanel.swift` is 578 lines and holds four kinds of
thing under one name: the surface's observable model, its `NSPanel` and hosting view, the views
drawn in it, and the presenter that installs it and reads the pointer. Its pure half is
already apart (`NotchSurface.swift`: the state machine, the layout, the pointer rule). Read in
full before this was written.

## Found while reading

- **"Is this point on the surface" is answered three times.** The hosting view's `hitTest`, the
  presenter's `handle`, and `NotchSurfacePointer`'s nested `contains(_:grownBy:)` each compare a
  point against a `PointRect` by hand. Two are in the app's untested half. They are one
  question, and become one pure function, `NotchSurfacePointer.isInside(x:y:of:grownBy:)`,
  tested on a rectangle off the origin and with a margin that is not zero.
  - The hosting view's version bounds the top by 0 rather than by the surface's own top. The
    two are equal because the surface's top is the notch's, which is the screen's
    (`ScreenMetrics.notch`: `y: frame.y`, and the presenter passes a frame at `y: 0`). Using
    the surface's top is the same answer today and the right one if that ever changes.
- **A `_ =` with no reason.** The global monitor's handler discards whether the event was
  consumed. It has to — a global monitor cannot consume anything — and AGENTS.md says a bare
  `_ =` is a defect. The reason goes beside it.
- **Choosing "No camera" in the menu bar left a refusal on screen.** The menu bar's row wrote
  `camera.source = .off` directly; the notch's calls `camera.choose(.off)`, which also clears
  `wasRefused`. So after the camera was refused, choosing No camera from the menu bar kept
  "This Mac has not allowed Soredemo the camera" under a row reading "No camera".
  `CameraController.source` becomes `private(set)`, so the compiler refuses the bypass and
  `choose` is the one way in. Not covered by a behavioural test: a refusal comes from TCC, which
  no test here can produce; the compiler is the enforcement.
- Two comments name an open-source project as the origin of a shape and a spring. Left as they
  are: what to do with such mentions is the owner's open decision.

## The split

Into `Soredemo/Recording/Notch/`, with the pure file moved in beside them:

| File | Holds |
| --- | --- |
| `NotchSurface.swift` | moved, plus `isInside` |
| `NotchSurfaceModel.swift` | the observable state and its geometry |
| `NotchSurfacePanel.swift` | the `NSPanel` and the hosting view that passes clicks outside the shape |
| `NotchSurfaceView.swift` | the shape and what is drawn in it per state |
| `NotchControls.swift` | the open recorder's controls, a take's controls, the sound wing |
| `NotchSurfacePresenter.swift` | install, remove, the monitors, the screen lookup |

## How it is verified

- `isInside`: a point inside, each of the four edges just outside, the margin taking a point
  in, on a rectangle not at the origin. Mutations: an edge compared the wrong way, the margin
  ignored.
- The source rules naming `NotchSurfacePanel.swift` follow the views to `NotchControls.swift`
  and `NotchSurfaceView.swift`.
- App tests, the gates in order, explicit paths. The notch is looked at by a person, on the
  machine with one.

## Where it ended

As decided: six files in `Recording/Notch/`, the largest `NotchControls` at 176 lines. App tests
290 → 292. Four mutations of `isInside`, each red:

| Mutation | Red |
| --- | --- |
| the right edge exclusive | `aPointIsInsideBetweenItsEdgesAndOutsideJustPastEachOne` |
| the top measured from 0, not from the rectangle | the same, **and no other test** |
| the margin ignored on the left | `aMarginGrowsEveryEdge` |
| the bottom without the rectangle's own top | both |

**The second row is the finding.** Every notch fixture in `NotchSurfaceTests` puts the notch
at `y: 0`, because every real notch is at the top of its screen — which is the identity of the
very translation the hand-written hit test assumed away. Sixteen tests went green over a top
edge measured from the wrong origin; only the new fixture, off the origin, saw it. AGENTS.md's
non-identity rule, met by adding the fixture rather than by noticing.

**Not seen on the notch.** The surface is looked at by a person: wake it, open it, start a take
from it, expand the take.
