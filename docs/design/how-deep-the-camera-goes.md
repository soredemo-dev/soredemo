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
