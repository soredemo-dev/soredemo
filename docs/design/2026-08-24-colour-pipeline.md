# The colour pipeline, and what the reference recorders actually do

Written after reading a native editor's `HDRVideoExporter.swift`, a Swift recorder's
`OutputColorSpace`/`CaptureConfiguration`, and a Rust recorder's capture crates line by line, and
after measuring this Mac and the files Soredemo writes.

## What is measured

| Thing | Value | How |
| --- | --- | --- |
| This display | wide-gamut RGB, custom 4064-byte ICC profile | `CGDisplayCopyColorSpace(CGMainDisplayID())` — `isWideGamutRGB == true`, and it equals neither the named sRGB, Display P3, nor 709 spaces |
| A Soredemo export | `ColorPrimaries = ITU_R_709_2`, `TransferFunction = ITU_R_709_2`, `Depth = 24`, `codec = avc1` | format description extensions of `~/Desktop/Full Screen.mp4` |
| Our capture | `pixelFormat = kCVPixelFormatType_32BGRA`, **`colorSpaceName = CGColorSpace.sRGB`, set explicitly** and marked "D2-15 — pinned, placeholder gamut choice" | `CaptureSession.swift:794–795` |
| Our master | H.264, tagged `ITU_R_709_2` primaries / transfer / matrix, **explicitly** | `CaptureSession.swift:692–701` |
| Our compositor | `32BGRA` in both `sourcePixelBufferAttributes` and `requiredPixelBufferAttributesForRenderContext` | `StageCompositor.swift:173–176` |
| Our writer adaptor | `32BGRA` | `MP4Exporter.swift:215` |

**So a wide-gamut display is being recorded and written as Rec.709 at 8 bits — and that is
a decision, not an oversight.** An earlier draft of this note said "nothing in the chain is
asked to preserve them", which was wrong and wrong in the direction that matters: the
capture is asked, explicitly, to convert to sRGB, and every tag downstream agrees with it.
The chain is INTERNALLY CONSISTENT. Nothing is mislabelled, which is the failure
a native editor warns about and the one that actually looks broken.

What is lost is the display's gamut, converted away at the capture on purpose. Colours
outside sRGB — saturated app icons, brand colours, a photograph on screen — are clipped
there, correctly and knowingly.

**And the master is the bottleneck, not the export.** It is 8-bit H.264 tagged 709, so
widening the export's colour space alone would do nothing: the gamut is gone two steps
earlier. Any change here is a change to the capture first.

## What the reference projects do

**None of the three captures in 10 bits.** That is the single most useful thing this
reading established, because it is the opposite of what one would assume from the fact
that two of them ship an HDR or wide-gamut control.

**a Swift recorder** captures `kCVPixelFormatType_32BGRA` (`CaptureConfiguration.swift:20`) and
previews in `bgra8Unorm`. Its `OutputColorSpace` picker offers auto / sRGB / Display P3 /
BT.709 / BT.2020, and each case maps to a `CGColorSpace` for the `CIContext` and to
`AVVideoColorPrimaries*` for the writer. Its `avTransferFunction` returns
`ITU_R_709_2` **for every case including BT.2020** — so its "BT.2020" is SDR in wider
primaries, not HDR, and the code says so by construction rather than in a comment.

**a native editor** has a dedicated `HDRVideoExporter` for HEVC Main10 BT.2020 HLG/PQ, and its
source is an SDR 709 composition. The comment that matters:

> Convert 709 → HLG per frame in CoreImage; relabeling the composition as HLG would tag
> the output HDR without converting pixels, blowing out SDR midtones.

It reads each frame as 709, renders it through a `CIContext` whose working space is 709
into a `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` buffer with the output space set
to `itur_2100_HLG`, and tags the file to match. And:

> Render into the space matching the tagged transfer, or pixels won't agree with metadata.

**a Rust recorder** renders through wgpu and writes through ffmpeg; its capture path is likewise 8-bit
BGRA.

## What this means for Soredemo

There are two separate jobs here and they are usually confused with each other.

**1. Keeping the display's gamut.** Not a defect — a pinned choice, and the conservative one
is the right default for what this app makes. Files from a screen recorder are watched in
browsers, in Slack, in a Twitter timeline, and sRGB/709 is what every one of those renders
correctly without negotiating a tag. Screen content is overwhelmingly authored in sRGB
anyway. Changing it means setting the capture's colour space, the master's tags, the
`CIContext`'s working space, and the export's tags — all four, or the chain stops agreeing
with itself.

**The 8-bit caveat is real and has to be said**: P3 in 8 bits has coarser steps than sRGB in
8 bits, because the same 256 values cover a larger volume. Gradients that are clean today
can band. Apple's own convention for P3 video is 10-bit for this reason. So this change
wants `kCVPixelFormatType_ARGB2101010LEPacked` at the capture and a 10-bit render context
with it, or it trades clipping for banding.

**2. HDR output.** Nobody's HDR is a captured HDR — a native editor's is a conversion at
export. We could do the same thing, from the same starting point, with the same technique,
and it would be equally honest as long as the pixels are converted rather than the file
re-tagged. It buys interoperability with a pipeline that demands HDR; it does not buy a
better picture, because there is no more information in the source.

## The recommendation

**Keep sRGB as the default.** It is internally consistent, it has no banding problem at 8
bits, and it is what the places these files end up in render correctly. There is no bug to
fix here.

**Add Display P3 as ONE coherent path when it is wanted — capture, master, render and
export together, at 10 bits, over HEVC.** Not as a picker. P3 at 8 bits trades clipping for
banding, because the same 256 steps cover a larger volume; P3 in an 8-bit H.264 master is
the worst of both, since the gamut is squeezed and the steps are coarse. The path that
makes sense is the whole thing or none of it.

**Do not copy a Swift recorder's design.** A five-way colour-space picker over an 8-bit sRGB
pipeline means four of the five options change a label and not a pixel — and its
`avTransferFunction` returning 709 for BT.2020 is that showing through.

**HDR last, if at all.** From an SDR source it buys interoperability with a pipeline that
demands HDR, and not a better picture. Doing it before the P3 path means doing it twice,
because converting from a 709 source is a different conversion from converting from a P3
one.
