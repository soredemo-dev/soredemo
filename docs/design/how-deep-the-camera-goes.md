# How deep the camera goes

*Code: `Core/Sources/Framing/FramingDepth.swift`. The gate that decides *whether*
to zoom is in `2026-08-19-framing-gates.md`; this is only about how far.*

## Why the curve is logarithmic

Control sizes span roughly 35× on a 1080p recording — a 16 px checkbox against a
700 px pane — and any linear rule saturates at one end of that range. The obvious
formulation, "zoom until the control fills half the frame", puts every control
under about 4% of the screen at the ceiling, and most controls are under 4%: the
mapping degenerates to two values, which is exactly what the `framing-depth`
ROADMAP row warns against.

Measured across seven realistic sizes before the curve was written: the linear
rule produced four distinct depths with three of them pinned at the ceiling; the
logarithmic curve produces seven.

Depth is a pure function of *size*, per that row. Nothing reads the target's
position, its role, or anything about the click.

## Which frame's size — a defect until 2026-08-26

The size that matters is the one a viewer sees, and a variant that does not match
the recording's shape shrinks it. `StagePlanner` fits and never crops, so a 16:9
recording covers about 0.32 of a 9:16 frame and every control in it is 0.56 of
the length it had in landscape.

Depth was computed from the extent *within the recording*, so a portrait export
inherited landscape's depths unchanged and its controls came out a little over
half the size. `coverage` is now a parameter with no default: the defect this
parameter exists to fix was a silent inheritance, and a defaulted `1` would be
that same silence spelled differently.

Coverage is an *area* ratio and a control's extent is a *length*, so the two are
related by a square root, not by coverage itself — hence `linearShare`.

**Only the curve's input moves; the context clamp keeps the raw extent.** The
curve asks "how big does this look", a question about the output frame. The clamp
asks "does the target still fit inside the viewport this depth implies", a
question inside the recording's own coordinates — a target is cropped or not
regardless of what shape it is exported to. Feeding the shrunken extent to the
clamp would let a portrait zoom crop the very control it is framing, and the
clamp binds *more* often in portrait precisely because the depths are deeper
there.

## The magnification ceiling is not a constant

A zoom magnifies the recording's own pixels, and nothing can put detail into a
pixel that was not recorded: past about 1.5× a Lanczos upscale of text reads as
soft, past 2.5× as smeared.

Measured on this project's own table (design note 2026-08-25): a 3024 px Retina
capture on a 2661 px card is still 1:1 at zoom 1.14 and 1.32× at zoom 1.5 —
invisible — while zoom 3 is 2.64×; a 1920 px capture on the same card is past
1.5× at zoom 1.08. So the ceiling is a function of **pixel density**, not a
constant: the same control on a 1× display gets a shallower zoom than on a Retina
one. A card wider than the recording's pixels can carry — a 720p capture in a 4K
stage — gives a ceiling below 1, which is "no zoom", clamped rather than trapped
because both sizes arrive from a picker.

`maximumMagnification` itself is 1.5 and is **uncalibrated**, like every other
constant in the file.

## Quantisation

Depths land on multiples of 0.25. Quantisation is what stops the camera making
small pointless adjustments: two clicks on buttons a few pixels apart produce one
depth, so there is nothing to animate between them.

## Intensity

One dial — "increase zoom for detailed UI work, decrease it where the full screen
matters more" — and it is the one control the per-block adjustments could not
stand in for: correcting forty blocks one at a time to say "less, everywhere" is
not the same act.

Written `1 + (depth − 1) × intensity`, not `depth × intensity`, because depth 1
means "do not zoom" and multiplying it by 0.5 would give 0.5 — a zoom *out*,
showing more of the screen than the recording contains.

The ceiling is 2 because past it the curve's own `maximumZoom` binds for every
realistic control and the dial stops doing anything, which is worse than not
going further.

**Applied before the context clamp and before quantisation.** Before the clamp so
a dialled-up zoom still cannot crop the control it is framing — the safety bound
is not a person's to turn off. Before quantisation so the result still lands on
the 0.25 grid; applying it afterwards would put every depth between two steps and
give the camera small pointless adjustments to animate, which is what quantising
exists to prevent.

## Why the label is not `%.1f`

Depths land on multiples of 0.25, so one decimal cannot represent half the values
the function produces — and the way it fails is worse than truncation:
`String(format: "%.1f", 2.25)` is "2.2" and 1.25 is "1.2", because the formatter
rounds half to even. The timeline's zoom lane was labelling a 2.25× block "2.2×"
and a 1.25× block "1.2×", neither of which is a depth the pipeline can produce,
which reads as the numbers being made up rather than as a rounding.

It is built from integers rather than `String(format:)`, and that is a build gate
rather than a preference: `String(format:)` is a C-variadic call, which
`check-strict-memory-safety.sh` reports as an unmarked unsafe site, and marking it
would be a marker on the very API whose rounding this function exists to avoid.
Hundredths are enough for any multiple of 0.25, and integer arithmetic cannot
round half to even behind anyone's back.

It lives beside the curve rather than in the view because the reason it is subtle
is `quantisationStep`, which lives there — and because a formatter in the app tier
could not be tested.

## How the camera moves

*Moved out of `Core/Sources/Framing/CameraMotion.swift`'s header 2026-08-30.*

The camera, integrated from zoom blocks by a critically damped spring.

**Fixed timestep, and that is the load-bearing decision.** A spring stepped by whatever
interval the caller happens to ask for accumulates differently on a 60 Hz preview and a
24 fps export — the same recording would produce two different camera paths, and
`render-parity`'s claim that one compositor drives both would quietly become false in
the one place nobody thinks to look. The path is integrated at a fixed `timestep`, so
the answer is a function of the instant alone (`theSameInstantAlwaysYieldsTheSameState`).

**Baked once in `init`, read by binary search — and that is a correctness fix twice
over.** The first draft integrated from absolute zero per query and never finished on six
seconds of a real recording; the second started at the first block, which was still a
full re-integration PER FRAME: the frame at minute ten paid 75,000 steps, each scanning
the block list, on `AVPlayer`'s real-time path. That is the stutter a long recording
showed on every zoom. `state(at:)` now costs a binary search whatever the instant.

**Critically damped, not tuned by feel.** `camera-motion`'s row says "settles without
overshoot", and for a spring-mass-damper that is exactly ζ = 1 — not a value found by
watching footage. The one free knob left is ω, chosen so the move settles to within 2%
in ~0.9 s: slower than `ZoomBlock.preRoll`, so the camera is still moving when the click
lands, which is what makes the motion read as following the action rather than
anticipating it.

**Inside a zoom the camera follows the cursor, by the least it can.** A block aims at
the clicked control; a cursor that then travels toward the edge of the zoomed viewport
pushes the aim along with it only once it crosses into `followMargin`'s band, and only
by the excess — so the camera holds still while a person reads and moves when they
leave. The complaint this answers is a menu opening beside a button and leaving the
frame; the rule is a dead-zone follow, and the motion is this spring's.

**The target is eased before the spring sees it.** A block's aim is a step function —
one centre and depth until the next block, then another — and a spring fed a step has a
discontinuous acceleration at the step: a jerk, which the eye reads as a lurch even when
the position curve looks fine. `targetTimeConstant` low-passes the aim first, so the
spring's input is C1 and its output C2. Good transitions read as one motion
rather than a start and a stop for this reason.

## Aligning the camera with the screen

*Moved out of `Core/Sources/Compositing/CameraComposition.swift` 2026-08-30 — a set of measured decisions is a document.*

The screen recording with the camera's video laid alongside it.

**They do not both start at zero, and `cameraStartOffset` is the difference.** This used
to insert both at the same instant and say in this comment that it was an approximation
pending the camera's first-frame host time. That time is now recorded —
`CameraRecorder.firstFrameHostTimeNanos` beside
`CaptureSession.Diagnostics.firstFrameHostTimeNanos` — which is the same anchor
`openObservationLog(atFirstFrame:)` takes for the pointer.

It need not be approximate: a recording can carry a
`start_time`, and `calculate_audio_offsets` aligns them all to whichever began LAST.
The same number, applied as a seek on the camera element.

**Positive means the camera started LATER**, so its picture belongs that far into the
recording and the overlay is simply absent before then — which is true, and is what the
person saw. Negative means the camera started FIRST, so that much of its head is footage
of a screen recording that had not begun, and it is trimmed off.

A camera is a slow device: it takes hundreds of milliseconds to wake and expose, so this
offset is usually the camera being late by more than a frame. On a small overlay a few
frames of error is visible in a hand wave; that is the error this closes.

Returns the screen asset untouched when there is no camera, so the common path builds no
composition at all.
@MainActor

## Placing the camera overlay

*Moved out of `Core/Sources/Render/CameraOverlay.swift` 2026-08-30 — a set of measured decisions is a document.*

The camera's rectangle in output pixels, given the source's aspect.

**A circle is square before it is masked.** Fitting a 4:3 camera into a circle by using
its own aspect would give an ellipse; the frame is squared and the source is cropped to
fill it, which is what every video-call application does with a round self-view.

**Held inside the frame, which it was not.** `x` and `y` place the camera's CENTRE and
are clamped to 0…1, so `x = 1` hung half a face off the right edge of the export — and
the self-view writes exactly that value when somebody drags into a corner, which is where
people put cameras. Placing the overlay inside `container − overlay − margin × 2` makes
a half-cropped camera unreachable at any setting.

Clamped rather than remapped, deliberately. Remapping would change what a stored `x`
MEANS, and a project saved before this would open with its camera somewhere else — the
producer-value rule broken to fix a rendering bug. A drag that saturates at the edge is
also what a person dragging expects.

A camera too big for the frame is centred rather than clamped to a corner: with no room
to satisfy both margins, the symmetric answer is the only one that is not arbitrary.

`contentZoom` is the stage's zoom for this frame; the camera keeps `scaleDuringZoom` of
its width while the stage is zoomed in, interpolated so it shrinks as the zoom rises
rather than snapping the moment a zoom starts.
