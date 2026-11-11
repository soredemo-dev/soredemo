# A window resized while the recording runs

**Decided 2026-09-18.** A window recording whose window is resized mid-take came out with a
black band down the right or along the bottom, or with the picture cut off. This records what
was measured, what the two candidate designs were, and why one of them was ruled out by Apple's
own guidance rather than by taste.

## What actually happens

A window capture configures `SCStreamConfiguration.width/height` once, from the window's size at
the moment recording starts, and sets `scalesToFit = true`. That buffer is then **fixed for the
whole segment**. When the window is resized underneath the running stream, ScreenCaptureKit
fits the new content into the old buffer and fills the remainder with the configured background.

`CaptureSession.windowMoved(to:displayBounds:)` already said so and treated it as correct:

> The stream is NOT reconfigured, and that is the point of the window filter.

That was right about the move case and silent about the resize case, which is where the band
comes from.

## The two designs

**1. Reconfigure the stream on resize** (or close the segment and open a new one).
Ruled out, and not by preference. WWDC22 session 10155, *Take ScreenCaptureKit to the next
level*:

> Frequently changing the stream's output dimension can lead to additional memory allocation and
> therefore **not recommended**. The stream's output dimension is mostly fixed and it does not
> resize with the source window.

**2. Record where the content went, and crop at composition time.** This is Apple's own
prescription from the same session:

> First, let's start by **cropping the content from its output using the content rect**. Next,
> **scale the content back up by dividing the content scale**.

Design 2 was chosen. It is also the shape this codebase already had: the compositor reads
`PointerTrack`, `ClickTrack` and `KeystrokeTrack` out of the observation log per frame, and
`CaptureSession.recordExtrinsicRects` was already reading `SCStreamFrameInfoContentRect` — and
throwing it into diagnostics.

## What the other implementations do

Read for ideas, not for code, from the local checkouts. None of the five solves this:

| | what it does about a mid-recording resize |
|---|---|
| The Rust recorder | nothing |
| The Swift recorder | exposes an `updateConfiguration`, but nothing calls it while recording; logs `contentRect`/`contentScale` and discards them |
| The AGPL Electron recorder | nothing |
| The MIT Electron recorder | nothing |
| The native editor | nothing |

## The measurement

The conversion from the attachment to a rectangle of buffer pixels is not obvious and three
candidates are in circulation: the rect as-is, times `scaleFactor`, times `contentScale`. They
differ by a factor of two on a Retina display, and a wrong one crops to the wrong place — which
looks exactly like the bug being fixed.

So it was measured rather than reasoned about. A white window was captured into a 1600×1064
buffer on a 2× display and resized underneath the running stream; ground truth is the bounding
box of the pixels the window actually lit. Worst edge error, in buffer pixels:

| window | `contentRect` reported | `contentScale` | as-is | **× `scaleFactor`** | × `contentScale` |
|---|---|---|---|---|---|
| 800×500 (as configured) | 0, 0, 800, 532 | 1.0 | 800.0 | **0.0** | 800.0 |
| 400×300 (shrunk) | 0, 0, 709.3, 532 | 1.7733 | 709.7 | **0.3** | 161.1 |
| 1100×700 (grown) | 0, 0, 800, 509.1 | 0.7273 | 800.0 | **0.8** | 1018.2 |

`contentRect × scaleFactor` is the only candidate that is right at every window size.

Two further facts fell out of the same run:

- **`y` runs from the TOP.** The grown case is the discriminating one: the content occupied the
  top 1019 rows of 1064 and the background band was at the **bottom**, while the attachment
  reported `y = 0`. Under a bottom-left convention the same picture would have reported
  `y = 22.9`.
- **The band is real and it is large.** Shrinking the window to half left 181 of 1600 columns as
  background — about 11% of the frame.

## What it costs

Cropping restores the **framing**. It cannot restore **resolution**. In the grown case
`contentScale` was 0.727: the window was larger than its buffer and ScreenCaptureKit
downsampled it to fit, and those pixels were never written. `ContentCropTrack.softestScale` is
the only place a reader can find that out.

## Where it lives

- `CropRect` moved from `Render` to `Geometry`. A second producer appeared that is not a person,
  and `Capture` and `Project` both need the type while neither may name `Render`.
- `CropRect.ofContent(inPoints:scaleFactor:bufferWidth:bufferHeight:)` — the measured
  conversion, in one place.
- `CropRect.within(_:)` — composing a person's crop with the capture's. A person draws on the
  picture they can see, so their fractions are fractions of the window, not of the buffer:
  `authored.within(content)`, never the reverse.
- `ContentCropSample` — one observation record, written **on change**, not per frame.
- `ContentCropTrack` — the read side; a step function, never an ease.
- `StageCompositor.contentCrop(at:)` and the composition in `startRequest`.

## Two things deliberately not done

- **The zoom ceiling is still computed from the authored crop alone.** Feeding it a number that
  moves would re-bake the whole camera on every frame of a window drag. What is given up is a
  ceiling that is slightly too generous for the seconds a window was smaller than its buffer.
- **Two editor overlays are in the wrong coordinate space, and both were left alone.** Neither
  is caused by anything here; both predate this work and both have their own test surface.

  | overlay | the editor stores | the renderer reads |
  |---|---|---|
  | `RedactionRegion` (`PreviewOverlay`) | fraction of the OUTPUT frame (`videoRect`) | fraction of the SOURCE image (`RedactionArt.applied`) |
  | `CropRect` handles (`CanvasBar.CropOverlay`) | fraction of the OUTPUT frame (same `videoRect`) | fraction of the SOURCE image (`CoreImageFrameRenderer.cropped`) |

  The two spaces coincide only when the card fills the output exactly, which — with any stage
  padding — it never does (`StagePlannerTests` pins `card.x + card.width < 1920`). Text overlays
  are NOT affected: `TextArt.image` is output-space and the editor agrees with it.

  Repairing these means deciding which space each value lives in and converting at one seam, and
  it wants its own tests. It is not folded into a capture-side repair.
