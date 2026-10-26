# The daruma tips and rights itself, flies into the notch, and paints its eye

The owner asked how the daruma could appear better, and chose three of six proposals (2026-10-27):
poke it and it tips and stands back up; at the end of the countdown it flies into the notch; and
the record eye is painted in, as a daruma's is, rather than switched on.

## 1. Poked, it tips and rights itself

**The question:** what does a click on the character do where a click has no other job?

**Chosen:** it tips away from the side it was touched on and rocks back upright on its round base,
squeezing its eyes shut for the first moment — 七転び八起き, which is what それでも means. The
rock is a damped swing, `angle(t) = A·e^(−t/τ)·sin(ωt)`: it starts upright, goes the pushed way
first, swings back past upright, and settles. A pure function in Core (`DarumaRock`), so the shape
is tested without a screen: never beyond 18°, settled to under 0.3° by 2.2 s.

Where: the permissions page, the empty editor, the menu bar panel's header and Settings'
character previews (where the same tap also chooses the colour — a simultaneous gesture, so
neither swallows the other). **Not** the notch, whose clicks are read by the presenter's monitors
and open the surface, nor the countdown, which is a moment to wait through. Reduce Motion: no rock,
only the squeeze.

**Rejected:** a physics simulation with mass and a contact point — the same curve for many more
parameters, and not deterministic per frame; a hover wobble — something that moves whenever the
pointer passes is noise, not a response.

## 2. The countdown's daruma flies into the notch

**The question:** the countdown panel vanishes and the notch's daruma appears; two characters, or
one?

**Chosen:** one. When the count ends the panel's daruma hops along an arc to the notch's wing,
shrinking to the notch mark's size, and fades as it lands while the notch shows its own. The flight
runs **beside** the start of the capture, not before it: Soredemo's own windows are excluded from
every capture filter (`CaptureSource.filter`), so the flight is never in the recording and costs
the take no time. Without a notch hosting the take there is no mark on screen to land on — a
`MenuBarExtra` label gives no frame — so it rises toward the top of the screen and fades. Reduce
Motion: it fades where it is.

The panel grows, centred on itself, to cover the path, so the content stays put while it does;
the flight's arc and scale are a pure function (`CountdownFlight`), tested at its ends and its top.

## 3. The record eye is painted

**The question:** the last second lit the record eye at once. A daruma's eye is painted by hand.

**Chosen:** in the last second the right eye stays an ink pill while the ring drains, and over its
last 0.4 s a brush paints the red in — one clockwise sweep from twelve o'clock, as wide as the eye's
radius, trimmed to the progress and clipped to the eye, so it fills like a clock hand going round,
the way the ring drained — finishing as the ring closes; the ink eye goes in the brush's first
eighth. The painting is the pose's (`DarumaFace.recordPaint`, `DarumaPose.counting`), drawn by
`DarumaView` through a bridged sweep (`CGGeometryBridge.brushSweep`). The menu bar, at 18 points,
keeps its switch.

**Rejected, after a look:** a spiral from the rim inward. Half-painted it drew a hook like a question
mark, and the ink eye fading under it the whole way mixed with the red into brown.
A round-capped sweep read as a bean, and an ink eye fading over a third of the sweep was still
brown; the band is butt-capped — a clean wedge — and the ink eye goes in the first eighth.
