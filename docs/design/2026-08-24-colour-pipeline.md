# The colour pipeline, and what the reference recorders actually do

Written after reading a native editor's `HDRVideoExporter.swift`, a Swift recorder's
`OutputColorSpace`/`CaptureConfiguration`, and a Rust recorder's capture crates line by line, and
after measuring this Mac and the files Soredemo writes.

## What is measured

| Thing | Value | How |
| --- | --- | --- |
| This display | wide-gamut RGB, custom 4064-byte ICC profile | `CGDisplayCopyColorSpace(CGMainDisplayID())` — `isWideGamutRGB == true`, and it equals neither the named sRGB, Display P3, nor 709 spaces |
| A Soredemo export | `ColorPrimaries = ITU_R_709_2`, `TransferFunction = ITU_R_709_2`, `Depth = 24`, `codec = avc1` | format description extensions of `~/Desktop/Full Screen.mp4` |
| Our capture | `configuration.pixelFormat = kCVPixelFormatType_32BGRA`, `colorSpaceName` never set | `CaptureSession.swift:794` |
| Our compositor | `32BGRA` in both `sourcePixelBufferAttributes` and `requiredPixelBufferAttributesForRenderContext` | `StageCompositor.swift:173–176` |
| Our writer adaptor | `32BGRA` | `MP4Exporter.swift:215` |

**So a wide-gamut display is being recorded and written as Rec.709 at 8 bits.** Colours
outside 709 — saturated app icons, brand colours, photographs — are clipped or shifted
somewhere in that chain, and nothing in the chain is asked to preserve them.

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

**1. Not throwing away the gamut we already have.** This is the real defect, it is at the
CAPTURE, and it is cheap. `SCStreamConfiguration.colorSpaceName` is never set, so
ScreenCaptureKit converts the display's P3 to its default before we ever see a pixel. The
information is gone before the compositor or the exporter could preserve it. Fixing it
means setting the capture's colour space, giving the `CIContext` a matching working space,
and tagging the export `AVVideoColorPrimaries_P3_D65` with a 709 transfer — which is
exactly what a Swift recorder's `displayP3` case does, and what QuickTime and every Apple tool
write for wide-gamut SDR video.

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

**Not started.** Job 1 is worth doing and is a change to the whole path — capture format,
both compositor attribute dictionaries, the renderer's working space, the writer's adaptor
and its colour tags — with a rendering-parity test at each end. Job 2 is worth doing after
it, and only after, because converting from a 709 source is a smaller thing than converting
from a P3 one and doing them in the other order means doing the second one twice.
