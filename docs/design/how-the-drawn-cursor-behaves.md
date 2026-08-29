# How the drawn cursor behaves

*Code: `Core/Sources/Render/CursorLoop.swift`, `CursorPress.swift`,
`ClickTrack.swift`.*

The recorded pointer and the drawn cursor are not the same thing. `PointerTrack`
keeps the stepwise truth for the review path; everything here is presentation,
applied one layer out in the compositor, and nothing here touches a track.

## Reacting to a press

The app drew a ripple *around* the cursor and left the cursor itself inert. A
viewer reads a press as the pointer moving, not as a ring appearing beside it,
which is why a recording with the ripple on still looked like nothing happened.
The cursor now shrinks while a button is held and springs back on release.

Three phases, and the hold is the one that needs the release edge. A curve driven
by the press alone would have to guess a duration, and a drag would spring back
mid-drag while the button was still down. That is why `ClickTrack` keeps `.up`
events at all — see below.

`CursorPress.scale(sincePress:sinceRelease:)` is a pure function of two elapsed
times. Nothing in it reads a clock, holds state, or knows what a `HostInstant`
is: `ClickTrack` owns finding the two edges, `CursorPress` owns what they look
like.

**Every constant here is uncalibrated.** `pressedScale` 0.82, `pressSeconds`
0.10, `releaseSeconds` 0.25 — chosen by eye, and each would still "work" at
another value in the sense that nothing downstream would misbehave. The shapes
were reasoned about, not measured:

- The press is gentler than the usual quarter because this app draws its own
  cursor art at a size a person chose, and a quarter off it reads as the pointer
  changing shape rather than as a press.
- The release is longer than the press deliberately: a press is an event, a
  release is a recovery, and matching them makes the pair read as a flicker.
- The spring overshoots by 4% on the way back and the press does not. Returning
  to 1 without passing it reads as the cursor inflating. Four per cent for
  `TextAnimation.pop`'s reason: the same curve at 20% is a bounce, which is a
  different and more annoying thing.

## The ripple

`ClickTrack` is a separate type from `PointerTrack`, not a fifth thing bolted
onto it. A pointer *position* and a ripple *phase* answer different questions —
"where was the pointer" and "is a click still animating" — from different record
streams (`PointerSample` versus `ButtonEvent`). `PointerTrack` already carries
four reading cases, a blind-interval list and an override list; a `ripplePhase`
field folded into `PointerReading` would make `.drawn` two things at once and
force `.blind`, `.suppressedByReviewer` and `.noObservationYet` to say something
about ripples they have no opinion on.

`rippleDuration` is 400 ms, and it is a look-and-feel value chosen by eye. Unlike
`NormalizedPoint` or `HostRange`, nothing about it comes from a spec, a
measurement or a convention. It is a constant because it has to be *some* fixed
number, not because 400 ms answers a question that was asked.

**Overlapping clicks: the later click's ripple wins outright** — not a blend, not
the longer-running of the two. The first click's ripple is not finished early and
not visible again; it is simply not the one reported once a later click exists at
or before the time asked about. This mirrors `PointerTrack.position(at:)`'s rule
that the most recent sample at or before the time is authoritative. A caller
wanting two concurrent ripples would need a different type.

### Why `.up` events are kept

They were once discarded, and the paragraph saying why is worth keeping: "a
ripple that started on release rather than on press would visibly lag a fast
click-and-release, and nothing about 'the ripple marks where a click happened'
needs the release edge at all." Every word of that is still true *of the ripple*.
It stopped being a reason to discard the events when the type was asked a second
question — the press scale above, whose held state cannot be known from the down
edge alone.

## Returning home so a loop does not jump

A demo embedded in a README plays on repeat, and at the seam the cursor teleports
from wherever the recording left it back to wherever it started — the one frame
in the loop where the viewer's eye is yanked. The final stretch glides the cursor
back to its opening position so the last frame and the first agree.

`leadSeconds` is 0.8 and is uncalibrated: long enough that the return reads as a
deliberate movement rather than a snap, short enough that it does not eat the end
of a demo, where the last click is usually the payoff.

**A pure function of output time, and it has to be.** The last frame of an
*export* is what must match the first, and an export's last frame is at the
edit's output duration, not the recording's. A loop computed in source time would
return the cursor to the start of a take whose first two seconds were cut, which
is not where the exported video begins.

### The last frame is not the last instant, and the difference cost a red test

A video of duration D has no frame *at* D — its last frame is at D − Δ, one frame
duration earlier, and `EditTimeline` is half-open so an offset of D maps to no
source time at all (`pastTheEndOfTheEditThereIsNoSourcePosition`). A glide
reaching home only at D would leave the last frame that actually exists a
fraction short of it: a small jump at the seam instead of a large one. So the
glide ends at D − Δ, and Δ is a parameter with no default — a measurement has no
safe default, and a caller that does not know its own frame rate should say so
where it calls this.

Anything within half a frame of the last frame is fully home. The offset arrives
from a `CMTime` converted to nanoseconds while D − Δ is computed in seconds; the
two disagree at the tenth decimal, and an eased 0.9999999996 is exactly the
residual the exactness promise is about. Half a frame is the natural quantum: no
request can be closer to the last frame than that without being it.

The lead is capped at half the video, for the reason `TextItem.animationState`
caps its own: a two-second clip with an 0.8 s return is fine, and a one-second
clip must not spend most of itself gliding home.

### Two forms of the same lerp, and only one is exact

The blend is written `(1 − e)·a + e·h`, not `a + (h − a)·e`. The second is the
form everybody writes and it is **not** exact at `e == 1`: `0.8 + (0.1 − 0.8) × 1`
comes out at `0.10000000000000003`, because `0.1 − 0.8` is already rounded before
the add. `atFullProgressTheCursorIsExactlyHome` went red on it. The first form
multiplies `actual` by an exact zero and `home` by an exact one, and `0 + h` is
`h` — exact at both ends by construction, whatever the operands.

Easing is ease-in-out, not linear and not the ease-out `TextAnimation` uses. The
cursor is already moving under the spring when the glide begins, and a glide
starting at full speed would kink its path visibly. Easing in lets the return take
over gradually; easing out lets it settle on home rather than arriving at speed
and stopping dead, which is the other visible kink.
