# Cutting the room out from behind a camera

*Measured 2026-08-29. Code: `Core/Sources/Compositing/PersonMask.swift`.*

A webcam bubble shows the wall, the bookshelf and whoever walks past. Every one of those is a
reason not to record at all.

## What the system already gives, and why that is not this

macOS ships Portrait mode, and `CameraEffects` puts it one click away. It **blurs** the
background, runs inside the camera pipeline, and is free. A second blur written by hand would be
slower and worse, so it is not reimplemented.

What Portrait mode cannot do is REMOVE the background, and that is a different picture rather than
a stronger version of the same one: the person stands on the screen recording itself instead of in
a soft-focus version of their room.

## Three measurements that decided the design

`VNGeneratePersonSegmentationRequest`, on an M-series Mac:

| quality | per frame | mask | verdict |
| --- | --- | --- | --- |
| fast | 7.85 ms | 256 × 192 | under-sampled at any realistic card width — not offered |
| balanced | 21.32 ms | 512 × 384 | the default |
| accurate | 55.90 ms | 2016 × 1512 | earned only by a camera wider than 512 output px |

1. **The mask's size does not depend on the input's.** A 1280×720 frame and a 640×360 frame
   produce the same 512×384 mask and take the same time. Downscaling before segmenting — the
   obvious optimisation — saves nothing.
2. **The mask does not preserve the input's ASPECT.** 1920×1080 gives 512×384, and so does a
   square 1000×1000; only portrait input flips it. So it must be stretched over the whole extent
   with X and Y scaled **independently**. Matching the aspect is the natural thing to write and
   puts the silhouette a fifth of a frame off the person, silently.
3. **The first request of each level costs 1–2 seconds** loading the model, and every request
   after it costs the table's number. `warmUp()` exists for that, and is called when the switch is
   turned on rather than on the frame somebody is waiting for.

`fast` is not offered: its 256×192 mask is smaller than the card it would be drawn into for any
camera bigger than a fifth of a 1280-wide frame, and a blocky edge around somebody's hair is what
this feature is judged on.

## How the mask is read, which is not what the documentation says

`CIBlendWithMask` is documented as blending on the mask's ALPHA. Measured against a
`OneComponent8` buffer — the format Vision is asked for — that is not what happens: CoreImage
reads such a buffer as grey with alpha 255 throughout, and the blend keys off the **luminance**.
Probed with a half-255/half-0 mask over a red image: the 255 half came back opaque red and the 0
half fully transparent, which would have been uniformly opaque if alpha were what was read.

`CIMaskToAlpha` — which every example inserts here — produced **pixel-identical** output. It is a
pass that costs time and explains nothing, and it is not in the pipeline.

## What an empty room looks like, and why no confidence floor

Measured on frames with no person in them — black, grey, and a gradient: Vision returns a full
mask every time, never nothing, and that mask's PEAK value is 2 to 5 out of 255. Under 2% opacity.
So a person who leans out of shot needs no detecting; the mask already answers "nobody" and the
camera goes very nearly transparent on its own.

**A confidence floor was considered and rejected.** Refusing below some peak — and drawing the
camera unaltered instead — would mean that the moment somebody steps out of frame, the room they
turned this on to hide appears in the corner of their recording. That is the one outcome the
feature exists to prevent, arriving at the one moment they are not there to catch it.

One measurement not acted on: given deliberate NOISE rather than a plausible frame, the model
hallucinates — 35% coverage with a peak of 196. A camera delivering corrupted frames will produce
a strange cut-out rather than an empty one.

## Two refinements considered and rejected, both by measurement

**A sigmoid on the raw mask**, to harden a mushy boundary. Plotted against a 0-to-255 ramp, a
contrast-4 sigmoid gives `0 → 30` and `255 → 225`: it never saturates, so it COMPRESSES the mask
rather than sharpening it, leaving background 12% opaque and the person 12% transparent. Sound for
a soft low-resolution mask; unnecessary for this one, which is decisive.

**A temporal average across frames**, which kills the edge shimmer an independently-computed mask
has. Right for a live camera where frames arrive in order, and wrong here: this renders a timeline
that is scrubbed, seeked and exported out of order, so a running average would make a frame's
appearance depend on how somebody arrived at it — the same frame different in the preview and in
the export, and different again on a second export.

**What refusing it costs:** the silhouette can shimmer slightly between frames. The deterministic
fix, if that proves visible, is a fixed window around the frame's own position — N-1, N and N+1,
which depends only on where the frame is. Three segmentations per output frame, 63 ms, and it is
not paid until somebody can show the shimmer is worth it.

## Vision belongs in the probe, and that is a deadlock

`VNImageRequestHandler.perform` is synchronous and pulls in CoreML, Espresso and the Apple Neural
Engine. `swift test` runs every target in ONE process with suites running concurrently, and
calling Vision from a unit test stalled the whole `CompositingTests` run at **0% CPU** — a target
that finishes in 14 seconds ran past ten minutes.

Two fixes were tried and neither was enough: `.serialized` on the suite fixed the suite in
isolation and not the target, and hopping every call onto a `DispatchQueue` did not help either. A
`sample` of the hung process showed all eight cooperative threads in `_pthread_cond_wait` and
thirteen unfinished tests, **only one of which was a Vision test**.

So § 22 of the cross-boundary probe runs the real segmentation, and the unit tests keep the
arithmetic. § 22.4 is the check that matters: it renders the result and reads the pixels back. A
grey frame with nobody in it comes back at a peak alpha of 1 out of 255 — the mask is applied, not
merely computed.
