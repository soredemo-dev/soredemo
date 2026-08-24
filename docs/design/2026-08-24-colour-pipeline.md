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

**The 8-bit caveat, stated carefully.** An earlier draft said "8-bit sRGB has no banding and
8-bit P3 does", which is too strong and would not survive the first counter-example: every
HEIC an iPhone takes is 8-bit Display P3 and none of them band. P3's gamut volume is about
25% larger than sRGB's, and under a gamma-encoded transfer that makes each step slightly
coarser — a marginal cost, not a threshold. Where it actually shows is large smooth
gradients: a macOS wallpaper, a gradient panel in a design tool. Ordinary UI does not care.

So the honest form is: **P3 at 8 bits has a marginal cost, and for screen-recording content
it buys almost nothing** — not "8-bit P3 breaks". The conclusion is the same and the reason
now holds up.

**2. HDR output.** Nobody's HDR is a captured HDR — a native editor's is a conversion at
export. We could do the same thing, from the same starting point, with the same technique,
and it would be equally honest as long as the pixels are converted rather than the file
re-tagged. It buys interoperability with a pipeline that demands HDR; it does not buy a
better picture, because there is no more information in the source.

## The bigger lever, which this note missed at first: chroma subsampling

The master is 8-bit H.264, which on Apple's hardware encoder means **4:2:0** — the colour
channels at a quarter of the luma's resolution.

**For screen content that does far more damage than sRGB versus P3, and unlike the gamut
question anybody can see it.** Red text on black, a one-pixel coloured border, a thin
diagonal line: all of them get the coloured fringing that everyone recognises from a screen
recording, and all of it comes from here. A clipped saturated colour, by contrast, is
something almost nobody notices without the original beside it.

So the priority order for picture quality is the opposite of what this note originally
implied. **Chroma, bit rate and codec come before gamut, not after.**

What is measured on this Mac (Apple M1 Pro):

| | Result |
| --- | --- |
| `VTCompressionSessionCreate` for H.264, HEVC, ProRes 422, ProRes 4444 | all succeed |
| Setting `HEVC_Main_AutoLevel`, `Main10_AutoLevel`, `Main42210_AutoLevel` | all accepted, `UsingHardwareAcceleratedVideoEncoder == true` |
| Encoding one frame at each | all succeed |
| Whether the 4:2:2 output is genuinely 4:2:2 | **No — established by measuring the picture rather than the metadata.** See below. |

### The measurement that settled it

Encode 8-pixel red bars on black through each path, decode, and read the last red column of
the first bar, which should be 255. A text edge is exactly this: a sharp vertical transition
between a saturated colour and a dark ground, wide enough that luma is easy, so only the
chroma resolution decides whether the edge survives.

| Path | last red column | worst edge error |
| --- | --- | --- |
| H.264 High | 145 | 110 |
| HEVC Main | 145 | 111 |
| HEVC Main 4:2:2 10-bit, from BGRA | 143 | 112 |
| HEVC Main 4:2:2 10-bit, **from a genuine 4:2:2 10-bit source** | 143 | 112 |
| ProRes 422 | 144 | 111 |
| **ProRes 4444, from BGRA** | **234** | **21** |
| **ProRes 4444, from a 4:4:4 source** | **254** | **1** |

**Everything except ProRes 4444 is 4:2:0 by the time the encoder sees it** — including ProRes
422, and including HEVC asked for `Main42210` and handed exactly the source that profile
wants. The profile is accepted, `UsingHardwareAcceleratedVideoEncoder` reports true, the
frame encodes without error, and the output is 4:2:0.

**On this M1 Pro.** An earlier draft of this section wrote "on this hardware; do not build
one", which is a claim about one laptop dressed as a claim about the product. Soredemo runs
on M1 through M5 and on Intel, and Apple's media engines have gained formats with every
generation — a table written today is wrong for somebody by next autumn, which is the same
mistake the frame-rate ladder made before it started asking the displays.

So the app asks the machine instead. `CodecSupport.keepsColourEdges(_:)` runs exactly the
test above — a few milliseconds per codec — and the export panel says what is true *here*.
A codec that cannot be probed says nothing rather than being reported as a failure: "we could
not ask" and "the answer is no" are different, and only one of them is safe to put in front of
somebody.

**The answers are not cached, and that is worth writing down because the cache is what taught
this.** The first version keyed a `UserDefaults` entry on the chip name and the OS build.
That meant reading the chip name, which is an ambient value: the app tier may not read one
(`noAppSourceReadsAnAmbientValueAtAll`), and the package's single audited ambient file may
not be widened for it either, because that file's whole-file permit rests on *every member of
it reading the same clock*. Both refusals were right, and chasing them turned up that the
cache was solving a problem nobody had — the whole probe is about seven tenths of a second,
it runs off the main actor, and it happens once when an editor window opens. The cache would
have bought that second back and paid for it with an invalidation key that has to stay correct
forever.

The residual 21 on ProRes 4444 from BGRA is not chroma — it is what a fully saturated red
costs in 8-bit YCbCr. Measured separately: neutral 255, 16 and 0 round-trip **exactly**
through every codec here, tagged or untagged, so nothing is being crushed to video range.
Feeding 4444 a `4444AYpCbCr8` buffer instead of BGRA takes the error to 1.

**Shipped as a result (2026-08-24):** ProRes 4444 is in the codec picker, and the panel's
claim about any codec is measured on the machine in front of the person reading it.

**And one escape route is already shipping.** ProRes 422 is in the export's codec picker as
of 2026-08-24, and ProRes 422 is 4:2:2 by definition. Somebody who needs clean coloured
text out of this app has that today; what they do not have is a small file that also has it,
which is what an HEVC 4:2:2 path would be if the encoder really produces one.

## Open, and worth measuring before D2-15 is revisited

**Is the sRGB conversion a clip or a gamut map?** `SCStreamConfiguration.colorSpaceName` is
set to sRGB and ScreenCaptureKit converts before we see a pixel; whether out-of-gamut
colours are hard-clipped or perceptually mapped decides how much is actually lost.

**And "screen content is overwhelmingly sRGB" is weaker in 2026 than it sounds.** What people
record contains photographs, video playing, Figma, Final Cut — all P3-authored. If the
conversion is a hard clip, those saturated colours are genuinely cut off. That does not
change "leave it alone for now", but it does move D2-15 from *placeholder* to *a decision
with a known cost*, which is a different thing to write down.

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

**Chroma before gamut.** See the section above: 4:2:0 is what makes screen recordings look
like screen recordings, and it is fixable with a codec rather than a pipeline.

**HDR last, if at all.** From an SDR source it buys interoperability with a pipeline that
demands HDR, and not a better picture. Doing it before the P3 path means doing it twice,
because converting from a 709 source is a different conversion from converting from a P3
one.

## Two notes for whoever picks this up

**ScreenCaptureKit's pixel formats are documented and do not need probing.** `BGRA`,
`l10r` (`ARGB2101010LEPacked`), `420v` and `420f`. A 10-bit capture is available whenever a
P3 path is wanted; the probe written to establish this hung in `startCapture`, which is not
cancellable, and was deleted. Nobody needs to run it again.

**How the first draft of this note got it wrong.** It said `colorSpaceName` was never set.
It is set, one line below the `pixelFormat` line that was grepped for — and the conclusion
"there is no setting" was drawn from "the grep did not show one". That is inferring absence
from a single-line search, which is never safe, and it nearly produced a design note
announcing a defect where there was a deliberate choice. Read the block, not the line.
