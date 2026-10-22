# A camera that reads the presenter

2026-10-23. Asked for as: research how to make the automatic zoom in and out better.

## Where the camera is today

Read in `ZoomBlock`, `CameraMotion`, `FramingDepth` and their design notes:

- **Clicks are the only trigger.** Each click that passes the gates opens a block that starts
  `preRoll` = 0.4 s before it and holds `hold` = 1.0 s after; overlapping blocks merge; blocks
  under `chainedPanGap` = 1.35 s apart pan instead of zooming out and in.
- **Depth** from the clicked element's size, on a logarithmic curve, clamped by the output's
  coverage and an intensity dial.
- **Motion**: a critically damped spring at a fixed natural frequency (Gentle / Standard /
  Snappy, ω = 6 / 10 / 16), stepped at a fixed 8 ms and baked once; inside a zoom the camera
  follows the presented cursor with a 25 % margin.

**Two of the numbers that decide every zoom are marked in the source as uncalibrated**:
`preRoll` and `hold`. `AGENTS.md` asks for calibration constants to be tested against measured
distributions; these were never measured against anything.

## What the research says

**Games solved "follow the action without making anyone sick" first** (Itay Keren, "Scroll
Back", GDC 2015). The principles that carry over: curb motion — move only when necessary;
smooth changes of speed and direction; frame what the player is about to need; respect the
vestibular system, so motion must be predictable. The techniques that carry over: a *camera
window* the subject can move inside without the camera moving; *platform snapping* — hold during
a jump, re-frame on landing; *look-ahead*; *cue focus* — an attractor the camera is pulled
toward; *region focus* — frame the room, not the character's every step.

**The optimal zoom-and-pan path is known** (van Wijk & Nuij, "Smooth and efficient zooming and
panning", InfoVis 2003; Reach & North, "Smooth, efficient, and interruptible zooming and
panning", 2018). Perceptual cost is distance moved divided by the camera's altitude — so a pan
while zoomed in is expensive, and the cheapest way between two far zoomed views is to pull back,
pan, and push in, along a geodesic of hyperbolic space. Their user study preferred the trade-off
parameter ρ ≈ 1.42 ≈ √2. The 2018 paper keeps velocity continuous when the target changes
midway — which is exactly this camera's situation every time a second click arrives while it is
still travelling to the first.

**Motion design**: duration should grow with the distance travelled; entering motion
decelerates, leaving motion may be quicker (Material motion guidance).

**What one published open-source rule set does** (read for the numbers, not the code): clicks
under 3 s apart share a zoom if they fit; 0.5 s early, held 1.5 s after the last click and
never under 1.8 s; at least 1.5 s of the whole screen between two zooms; the first 2.5 s and the
last 1 s stay wide; a zoom never spans a cut; a person's zooms are kept and new ones keep clear of
them. Its hold is half again Soredemo's.

## The advantage nobody else has

Every recorder above guesses timing from constants. **Soredemo can read the presenter's own
rhythm from the observation log**: when the pointer set off towards the target, when it arrived,
when it left after the click. A post-production camera also knows the future — the next click is
already on disk — which a game camera never does. The improvements below are all that one idea.

## Proposals, in order

### 1. Timed by the hand, not by constants

- **Start when the hand sets off.** The zoom begins at the pointer's final approach to the
  target (the last moment its speed rose from rest before the click), bounded to 0.25–1.2 s
  before the click. A long, slow reach gets a long lead; a flick gets a short one.
- **Hold until the hand moves on.** The person stops looking at the result when they move the
  pointer away; the zoom holds until then, plus a short tail, bounded to 0.8–4 s.
- **Calibrate the bounds from recordings, not intuition**: measure approach and dwell times
  across a set of real takes, and set the bounds at percentiles of what was measured. This is
  the calibration `preRoll` and `hold` have been waiting for.

### 2. Frame the region, not every click

Consecutive clicks inside one accessibility container — one sheet, one settings pane, one
inspector — become one zoom that frames the container and pans inside it, instead of zooming
in, out and in again. The container comes from the click's `ancestors`, which only Soredemo
records. This is region focus from game cameras with the region named by the app itself.

### 3. A calmer timeline

- A minimum stretch of the whole screen between zooms; anything shorter either pans (if the
  targets are near) or stays zoomed (if they share a region).
- The opening and the ending stay wide, so the viewer is oriented before the first zoom and
  after the last.
- A zoom never spans a cut (to check: the current retiming may already guarantee it).

### 4. The perceptually optimal path

When the camera travels between two zoomed views, it follows the hyperbolic geodesic (ρ = √2):
pull back, pan, push in — the cheapest path for the eye. Its **duration is proportional to the
path's hyperbolic length**, so a short hop is quick and a long one is unhurried, instead of
today's spring, which takes the same time for any distance and so moves fastest exactly when
the move is largest. Retargeting mid-flight keeps velocity continuous (Reach & North).
The three paces stay as a speed multiplier on that duration.

### 5. In fast, out gently? No — in gently, out sooner

A zoom in decelerates into the target (the viewer is reading); a zoom out may leave a little
quicker (nothing new is being shown). An asymmetry of about 15 %, to be judged by eye against
recordings rather than chosen here.

### 6. Beyond clicks — proposed, never forced

Drags framed by their whole path; scrolling followed inside its scroll view rather than zooming
on it; a pointer held still over something while the narration names it (the transcript says
*"this button"*) proposed as a zoom the person can accept. Typing would want the same treatment
and needs a decision first: knowing *when* typing happens means observing key timing, which the
privacy rule currently forbids.

### 7. Frame what changed after the click

A click that opens a sheet, a popover or a dialog changes a region of the screen larger than
the button that was clicked, and a camera still framing the button cuts the new content off.
After a click, the region of the picture that changed in the next ~0.8 s — Soredemo already
measures picture change for still-stretch detection — widens the frame to include it, bounded
so an unrelated change elsewhere (a clock, a notification) does not pull the camera across the
screen. A good camera reframes on the *result* of an action, not only on the action.

### 8. Read the activity, then choose the shot

Segment the take by what the presenter is doing — a single click, a run of clicks moving through
one area (navigating), a drag, a scroll, a switch between apps, a long pause — and give each its
own depth range and lead: a run of nearby clicks is one medium shot rather than a zoom per
click; a switch between apps is a wide shot; a long pause decays gently toward the whole screen
while keeping its centre, so the next zoom does not start from the far side. The segmentation
is a pure function of the log and is shown on the timeline, so a person can see *why* a stretch
was framed the way it was — the review panel the clicks already have, extended to shots.

## What the research did not find

No published work studies an automatic camera for screen recordings specifically. Video
saliency research (the NTIRE 2026 and AIM 2024 challenges) predicts where people look in
natural video, not in software. The products in this space all describe rules, not
measurements. A camera whose constants come from measured presenter timing, with a reason
attached to every shot, would be ahead of the field, not catching up to it.

## How each will be verified

- Timing (1): fixtures with known pointer paths — a slow reach and a flick — give different
  leads; a hand that moves away early ends the hold early. Mutation: constants back in place.
- Regions (2): two clicks in one container make one zoom; the same two clicks in two windows
  make two. Positive control with no ancestors.
- Path (4): pure functions in `Core/Framing`, tested against the paper's identities —
  `geo(x, y, 0) = x`, `geo(x, y, dist(x, y)) = y`, a pure zoom is exponential in time — with
  footprints away from zero and both zoom directions, so no fixture sits at an identity.
- And looked at: every change here is visual, so each ends with a person watching the same three
  recordings before and after. A camera is judged by eye or not at all.

## Sources

- Itay Keren, "Scroll Back: The Theory and Practice of Cameras in Side-Scrollers" — https://www.gamedeveloper.com/design/scroll-back-the-theory-and-practice-of-cameras-in-side-scrollers
- A. M. Reach and C. North, "Smooth, Efficient, and Interruptible Zooming and Panning" (2018) — https://arxiv.org/abs/1801.09358 (read: § 3–5, including the √2 user-study value from van Wijk & Nuij)
- J. J. van Wijk and W. A. A. Nuij, "Smooth and efficient zooming and panning", IEEE InfoVis 2003 (cited via the above, and implemented by d3's `interpolateZoom` — https://d3js.org/d3-interpolate/zoom)
- Material Design, motion duration and easing — https://m1.material.io/motion/duration-easing.html
- Screen Studio, auto zoom guide — https://screen.studio/guide/auto-zoom
- NTIRE 2026 Challenge on Video Saliency Prediction — https://arxiv.org/abs/2604.14816 (general video, not software; cited for the gap)
