# Tilting the card

**Decided 2026-09-25.** Shotbase sells "turn flat recordings into cinematic 3D" as a headline.
Soredemo's stage is flat: an axis-aligned rounded rectangle on a background. This adds the one
thing that is missing — a perspective tilt — and records what it deliberately does not add.

## What is being added, and what is not

**Added: a static tilt of the card.** Two angles and a viewing distance. The recording, its
rounded corners, its border and its shadow all turn together, because they are one object.

**Not added: motion.** "Cinematic 3D" in the competitor's copy also implies the tilt *changing*
over the clip. That is a second thing — it needs a track, keyframes, a retiming story and an
interaction — and building it inside this row would make the row's name a lie. A tilt that can be
set is worth shipping on its own; a tilt that animates is its own row.

**Not added: real depth.** No thickness, no lighting on the edges, no reflection. The card is a
plane, projected.

## Why a perspective transform and not a scale

An affine transform cannot foreshorten. `CGAffineTransform` maps a rectangle to a parallelogram —
the far edge stays the same length as the near one, which reads as a sheared rectangle, not a
turned one. Core Image's `CIPerspectiveTransform` takes the four destination corners and does the
projective map, which is what makes the far edge shorter.

So the package's job is to produce **four corner points**, and the renderer's job is to hand them
to the filter. That split is also what keeps the maths testable: `StageTilt.quad(for:)` is pure
arithmetic on `Double`s, and rule 2 forbids `CGPoint` in the package anyway.

## The projection

The card is a plane at z = 0, centred at the origin, corners at (±w/2, ±h/2). Yaw turns it about
the vertical axis, pitch about the horizontal one, and a pinhole at distance `d` on +z projects it:

    Ry(yaw)   x₁ = x·cos(yaw)              z₁ = −x·sin(yaw)
    Rx(pitch) y₂ = y·cos(pitch) − z₁·sin(pitch)
              z₂ = y·sin(pitch) + z₁·cos(pitch)
    project   s = d / (d − z₂)             (px, py) = (x₁·s, y₂·s)

`d` is `distance × max(w, h)`, so the same tilt looks the same on a 1080p card and a 4K one —
the strength of a perspective is a ratio, not a number of pixels.

**No point can land behind the camera, and that is arranged rather than checked.** The angles are
clamped to ±60° and the distance to at least 1.2 card-widths at construction, so the deepest a
corner can go is half the card's diagonal — at most 0.708 × max(w, h) — against a camera never
closer than 1.2 × max(w, h). `d − z₂` is therefore always positive and the projection always
finite, which is why `quad(for:)` returns a value and never an optional. Clamping in `init` is
the same move `CropRect` makes, and for the same reason: sliders and decoders both arrive here.

## Where it applies in the frame

The tilt is applied to the **finished card** — content, rounded mask and border — not to the
content before masking. Masking first and turning afterwards means the corners and the edge turn
with the picture, which is what a turned object does; turning first would leave an axis-aligned
mask cutting across a turned image.

The shadow turns with it, because a shadow that stayed square under a turned card is the tell that
the 3D is a sticker.

## What it costs

One more Core Image filter on the card's branch of every frame, for every recording that uses it.
`StageTilt.flat` short-circuits: `isFlat` is checked before the filter is built, so a project that
never touches the control pays nothing, which is the same arrangement `CropRect.isWhole` has.

## Open

- **Whether ±60° is the right clamp.** It is generous enough for the effect and tight enough to
  keep the projection well-conditioned; nobody has sat in front of a 60° card to say whether it is
  usable or absurd.
- **Whether the default distance reads as a lens somebody would choose.** 2.5 card-widths is a
  mild wide-angle. It has not been compared against anything.
