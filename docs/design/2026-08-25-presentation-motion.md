# Presentation motion — the cursor, the camera, and the pixels between them

**Date:** 2026-08-25
**Status:** Implemented in the same change
**Extends:** 2026-08-19-recorder-parity.md (the review/presentation split), 2026-08-24-colour-pipeline.md (the export's bits)

## The complaint

Three things, from watching an export beside Screen Studio's:

1. the picture is soft;
2. a zoom lurches, and playback stutters on it;
3. the cursor moves like a hand, not like a demo.

Each turned out to have a cause that could be named in the code rather than a feel that had to be tuned, and the causes were not where the complaint pointed.

## 1. The picture

Four losses stacked, two of them large.

**The export defaulted to 1080p.** `ExportResolution.available` lists `.matchRecording` first and its doc comment says why; the `@State` behind the picker said `.p1080`, and so did two helper defaults. A 3024 × 1964 capture became 1662 × 1080 — six pixels in ten gone — before anything else happened. Fixed by making the default agree with the comment.

**The card resampled with the affine transform's bilinear sampler.** At the ~2× reduction a Retina capture needs, bilinear reads four source pixels per output pixel and skips every other row and column. On camera footage that is softness; on text and hairlines it is aliasing on top of softness. `RedactionArt` was already using `CILanczosScaleTransform` to make its blocks. The picture now goes through the same kernel (`CoreImageFrameRenderer.resampled`), clamped before and cropped after so the kernel's read past the edge does not darken the card's border. `theResampleDoesNotAliasAStripePattern` is the measurement: a 1 px stripe pattern scaled by 0.45 spreads across ~255 luminance levels through bilinear and a sliver of that through Lanczos.

**The card's edges were fractional.** `StagePlanner` fitted 1520.64 × 950.4 and placed it at a fractional origin, so at a 1:1 scale every pixel was resampled at a fractional phase — a uniform blur of a picture that needed none, in exactly the export a person asks for at the recording's size. The card is snapped to whole pixels now, size first and origin second, at a cost of at most half a pixel of aspect. `theCardIsSnappedToWholePixels` uses the fixture whose fit is fractional on every side.

**H.264's 4:2:0 chroma** is the fourth and is already measured in `ExportCodec.proRes4444`'s table. Nothing changed there; the picker offers 4444 and the note under it says what this Mac's encoder does with a coloured edge.

## 2. The camera

**Every frame re-integrated the whole path.** `CameraMotion.state(at:)` stepped a spring at 8 ms from the first block to the instant asked for, on every call, on `AVPlayer`'s render path. Frame *n* cost *n* steps and each step scanned the block list. The first draft integrated from absolute zero and was caught by the row-14 fixture; the fix moved the start to the first block and left the O(n²). At minute ten a frame paid 75,000 steps. That is the stutter.

The path is now baked once in `init` — the same integrator, the same 8 ms step, per boot epoch — and a query is a binary search over the stored steps, returning the same step the `while time < end` loop stopped at. `tenMinutesOfFramesIsQueriedInSeconds` walks 36,000 frames over 200 blocks inside two seconds. Determinism is stronger than before, not weaker: the whole path is one array.

**The target was a step, and a spring fed a step lurches.** A block's aim is one centre and one depth until the next block. The spring's acceleration at the step is `k × Δ` from a standing start — a jerk, which the eye reads as a lurch even when the position curve looks fine. The aim now passes through two cascaded first-order stages (`targetTimeConstant`, 120 ms in total) before the spring sees it: two, not one, because one stage rounds the step and still kinks, and the aim's *velocity* has to start at zero for the spring's acceleration to. Measured at the first 8 ms step against the move's peak acceleration: a step target puts the first step AT the peak, one stage at ~50 %, two stages at 19 %. `theAccelerationRampsInsteadOfJumpingAtABlockStart` asserts under a quarter.

ζ stays at 1. The row says "settles without overshoot" and critically damped IS that; the easing is on the input, not the spring.

**The edge is a wall.** A control at the screen's edge aims the camera past `confine`'s region; the position clamps and the spring's velocity kept winding up against it. Harmless until something read the velocity. Now zeroed per axis on the axis that hit, because something reads it:

**Motion blur.** `CameraState` carries velocities; `StageCompositor.motionBlur(for:card:outputHeight:frameSeconds:)` turns them into a `MotionBlur` in output pixels — a pan smear along the pan's direction and a radial smear about the card's centre — under a 180° shutter (half the frame's duration), skipped under 1.5 px, capped at 2 % of the output height. `Render` carries pixels rather than speeds because it does not know a frame rate; the compositor reads the composition's `frameDuration`, so a 30 fps export smears twice as far as a 60 fps one for the same motion (`theSmearScalesWithTheFrameDuration`). The renderer applies it to the content before the card's mask, clamped and cropped like the resample. The Swift recorder's `TransformApplicator.applyMotionBlur` is the precedent; the shutter framing is what makes the intensity a number with a reason.

**The zoom has a ceiling that follows pixel density.** A zoom magnifies recorded pixels and nothing can put detail into one that was not recorded. `FramingDepth.zoomCeiling(sourcePixels:cardPixels:)` is where `z × card / source` reaches `maximumMagnification` (1.5): a 3024 px Retina capture on a 2661 px card may zoom to ~1.7, a 1920 px capture on the same card to ~1.08, a 720p capture in a 4K stage not at all. `CameraMotion` applies it to the *aim* — never a clamp on the state, which would wind the spring's velocity against the clamp and smear a picture that had stopped (`theZoomStopsAtTheCeilingWithoutWindingUp`). The compositor knows the card only from its first frame, so `loadedTracks(zoomCeiling:)` re-bakes the camera once under the ceiling `cameraPlan` computes from the cropped source width and the card; the pointer queries pass no ceiling and never trigger a bake.

**What did not change.** `FramingDepth.quantisationStep` stays at 0.25: the 0.5 that would remove small pointless re-zooms leaves five possible depths, and `distinct.count >= 5` across seven realistic sizes would become a tautology.

## 3. The cursor

**The rendering path was a lerp, and a lerp keeps every turn the hand made.** `PointerTrack.smoothedPosition` interpolates between bracket samples: C0, velocity discontinuous at every sample, and the samples are the hand. The ROADMAP's `cursor-render` row records that spring smoothing was a considered rejection, on the argument that footage which looks fine deletes the signal saying someone should look. Recorder parity resolved that by splitting review from presentation, and the presentation half stopped at the lerp.

There are three queries now, one per consumer:

| Query | Consumer | Shape |
| --- | --- | --- |
| `position(at:)` | review | stepwise; never gentle |
| `smoothedPosition(at:)` | the lerp's own tests, and the presentation's floor | linear between brackets, three refusals |
| `presentedPosition(at:)` | the compositor | `PointerPath`, with the lerp wherever the path has no answer |

`PointerPath` follows the Swift recorder's design — interpolate the samples, then drive a spring toward them — with two of the Rust recorder's additions, baked once at a 4 ms step:

1. a time-parameterised cardinal spline through the samples (C1: a corner becomes an arc);
2. a spring at ζ = 0.9, response 60 ms shortened toward 24 ms with speed, solved analytically per step so a stiff profile cannot blow up at a coarse step;
3. idle stabilisation, so `PointerSampler`'s 60 Hz stream of a resting pointer renders as rest;
4. phase lead (the Rust recorder): the target is read `2ζ/ω` ahead, which cancels the spring's steady-state trail so the cursor sits where the real one was rather than behind it;
5. a stiffer spring for 175 ms before each button-down (the Rust recorder), so the cursor has arrived when the ripple starts.

**Its refusals are the lerp's refusals.** The spline does not cross a gap wider than `maxInterpolationGap` and does not cross a blind interval: the target holds, and the spring glides only after the next observation. That held one more constraint the first draft missed: the phase lead reached across a held gap and moved the cursor toward a position 17 ms before it was observed — 28 px on a jump after a silence in the row-14 recording, caught by `aRestingPointerIsDrawnExactlyWhereItRests`. The lead is now confined to the connected chain the instant sits in; within a chain every position it reads was observed, and the lead only chooses which observed position is drawn.

**The recorded-position test changed shape.** `aPointerIsDrawnAtTheRecordedPosition` asserted the placement equal to the lerp within a thousandth of a pixel. It now bounds the placement by `speed × worstCaseLag × 2 + 1 px`, with the speed re-derived from the fixture's bracket samples and the lag published by `PointerPath.Tuning`. The bound is `speed`-shaped on purpose: at rest it is one pixel, and `aRestingPointerIsDrawnExactlyWhereItRests` pins that case on its own against instants where the recording's pointer had been still — silent, for the tap-only era of the fixture; a stream of near-identical samples, for the sampler era.

## 4. The colour, checked by pixels rather than by tags

The colour-pipeline note (2026-08-24) established that every tag in the chain agrees with every other tag and concluded the chain was consistent. Asked whether the *values* were, a probe found two places they were not:

**Core Image honoured the master's 709 tag over sRGB pixels.** The capture asks ScreenCaptureKit for sRGB and the master is tagged 709 — the platform's convention. A decoded frame arrives with 709 attachments, `CIImage(cvPixelBuffer:)` converts it through 709's curve into the sRGB working space, the renderer writes sRGB, and the writer tags 709 again without converting back. Measured: 128 → 141, 200 → 208, on every frame, with the primaries untouched. `CoreImageFrameRenderer.screenImage` now declares the screen's buffer sRGB on the way in (the camera's frames keep their own tags, since a webcam really is the video its tag says), and the GIF path does the same. `theMidTonesSurviveTheExport` writes seven patches tagged as the master is, exports them, and reads them back within ±2.

**A writer with no colour properties infers a 601 matrix under a 709 tag.** Pure red left such a file as (234, 0, 3). `ExportQuality.colourProperties` now names Rec.709 primaries, transfer and matrix on every export, ProRes included. This is also what the `ExportCodec.proRes4444` table's "residual 21" was: not what a saturated red costs in YCbCr — neutrals pass under both matrices, which is why that reasoning looked sound — but the matrix. Remeasured with the properties on: 4444 is exact (255 / 0), and the 4:2:0 codecs sit at 154 / 101.

**The master had no bit rate.** `MasterQuality` restates `ExportQuality.best`'s arithmetic (`Capture` cannot import `Compositing`) and `CaptureSession` applies it; `theMasterSpendsWhatTheBestExportSpends` pins the two to one number.

## What a person sees

Nothing in this change adds a control. Every default moved toward what the reference tools ship: the recording's own size, a resampler that does not alias, a camera that arrives in one motion, a smear on a fast move, and a cursor that moves like a demo. The knobs exist (`PointerPath.Tuning`, `CameraMotion.targetTimeConstant`, the blur's shutter and cap) and are named as uncalibrated in this project's sense — chosen from the reference projects' shipped values, not from a measurement of this one.

## Aside: the gate that exited silently

`scripts/check-strict-memory-safety.sh` exited 1 with no output on this worktree. `find "$SCRATCH"` on a scratch directory that did not exist yet returned 1, and `pipefail` with `set -e` ended the script at that line. A silent 1 reads as "unsafe sites found" to anything checking the status. The directory is created first now, with the reason at the site.
