import CoreImage
import CoreVideo
import Foundation
import Vision

/// **Cuts the room out from behind a camera, leaving the person over the screen recording.**
///
/// A webcam bubble shows the wall, the bookshelf and whoever walks past, and every one of those
/// is a reason not to record at all.
///
/// ### What macOS already gives, and why that is not this
///
/// `CameraEffects` already surfaces the system's own Portrait mode, which BLURS the background.
/// That is free, it runs in the camera pipeline, and this deliberately does not duplicate it —
/// a second blur written by hand would be worse and slower than the one Apple ships. What Portrait
/// mode cannot do is REMOVE the background, and removing it is a different picture: the person
/// stands on the screen recording itself rather than in a soft-focus version of their room. So
/// the two are offered as what they are, and the one already provided is not reimplemented.
///
/// ### Vision, measured rather than assumed — three numbers that decided the design
///
/// `VNGeneratePersonSegmentationRequest`, on this machine, on 2026-08-29:
///
///     quality    time per frame   mask size     for a card of…
///     fast          7.85 ms        256 x 192    under-sampled at any realistic card width
///     balanced     21.32 ms        512 x 384    up to ~512 px, at or above 1:1
///     accurate     55.90 ms       2016 x 1512   anything wider
///
/// Three facts fell out of that table, and each one changed the code:
///
///  1. **The mask's size does not depend on the input's.** A 1280x720 frame and a 640x360 frame
///     produce the same 512x384 mask and take the same time. So the obvious optimisation —
///     downscale the camera before segmenting — saves nothing at all and was dropped.
///  2. **The mask does not preserve the input's ASPECT.** 1920x1080 gives 512x384, and so does a
///     square 1000x1000; only portrait input flips it (720x1280 gives 384x512). The mask maps to
///     the whole input image, so the only correct placement is to stretch it over the full extent
///     with X and Y scaled INDEPENDENTLY. Matching the aspect — the natural thing to write —
///     would squash the silhouette off the person by a fifth of the frame.
///  3. **The first request of each quality costs one to two seconds**, loading the model, and
///     every request after it costs the table's number. That is a stall in the first frame of a
///     preview, which is why `warmUp()` exists and is called when the switch is turned on rather
///     than when the first frame is drawn.
///
/// `fast` is not offered. Its 256x192 mask is smaller than the card it would be drawn into for
/// any camera bigger than a fifth of a 1280-wide frame, and a blocky edge around somebody's hair
/// is the exact failure this feature is judged on. The 13 ms it saves are not worth it.
///
/// ### How the mask is read, which is not what the documentation says
///
/// `CIBlendWithMask` is documented as blending on the mask's ALPHA. Measured against a
/// `OneComponent8` buffer — the format Vision is asked for — that is not what happens:
/// CoreImage reads such a buffer as grey with alpha 255 throughout, and the blend keys off the
/// LUMINANCE. Probed with a half-255/half-0 mask over a red image: the 255 half came back opaque
/// red and the 0 half came back fully transparent, which is right, and which would have been
/// uniformly opaque if alpha were what was read.
///
/// So the mask is handed to the filter directly. `CIMaskToAlpha` was measured in the same probe
/// and produced **pixel-identical** output, which makes it a pass that costs time and explains
/// nothing; it is not in the pipeline. Written down because "convert the mask to alpha first" is
/// what every example does, and the next person to read this will wonder why it is missing.
///
/// ### What happens when there is nobody in the picture, and why nothing is done about it
///
/// Measured on frames with no person in them — black, grey, and a gradient: Vision returns a full
/// mask every time, never nothing, and that mask's PEAK value is 2 to 5 out of 255. Under 2%
/// opacity. So a person who leans out of shot does not need detecting; the mask already answers
/// "nobody" and the camera goes very nearly transparent on its own.
///
/// **A confidence floor was considered and rejected.** Refusing below some peak — and drawing the
/// camera unaltered instead — would mean that the moment somebody steps out of frame, the room
/// they turned this feature on to hide appears in the corner of their recording. That is the one
/// outcome the feature exists to prevent, arriving at the one moment they are not there to catch
/// it. An empty card is the honest picture of an empty room, and it is what ships.
///
/// One measurement that is not acted on but is worth knowing: given deliberate NOISE rather than
/// a plausible frame, the model does hallucinate — 35% coverage with a peak of 196. A camera
/// delivering corrupted frames will therefore produce a strange cut-out rather than an empty one.
/// Nothing here can tell that apart from a real person, and a camera producing noise has a bigger
/// problem than its background.
///
/// ### Two refinements considered and rejected, both by measurement
///
///  1. **A sigmoid on the raw mask**, to harden a mushy boundary. Plotted against a 0-to-255
///     ramp, a contrast-4 sigmoid gives `0 -> 30` and `255 -> 225`: it never saturates, so it
///     COMPRESSES the mask rather than sharpening it, leaving background 12% opaque and the
///     person 12% transparent. The idea is sound for a soft low-resolution mask; this one does
///     not need it. Measured: a frame with nobody in it peaks at 2 to 5 out of 255, which is a
///     decisive answer rather than a probability field. Hardening a decisive mask would only
///     alias the handful of genuinely anti-aliased pixels along the silhouette — the exact
///     pixels the feather above exists to keep smooth.
///  2. **A temporal average across frames**, which kills the edge shimmer an
///     independently-computed mask has. Right for a live camera, where frames arrive in order
///     and each has a previous one, and wrong here — and not by a little. This renders a timeline
///     that is scrubbed, seeked and exported out of order, so a running average would make a
///     frame's appearance depend on how somebody arrived at it: the same frame different in the
///     preview and in the export, and different again on a second export.
///     `theExportPreservesTheSourcesPixelValues` and its neighbours exist because that is not
///     acceptable.
///
///     **What refusing it costs, stated rather than hidden:** the silhouette can shimmer slightly
///     between frames. The deterministic fix, if that ever proves visible, is a fixed window
///     around the frame's own position — N-1, N and N+1, which depends only on where the frame is
///     and not on how it was reached. That is three segmentations per output frame, 63 ms, and it
///     is not paid until somebody can show the shimmer is worth it.
public enum PersonMask {
    /// How finely the person is cut out. The two levels the measurement above left standing.
    public enum Quality: String, Sendable, Equatable, Hashable, CaseIterable {
        /// 512x384, 21 ms. Enough for any camera card up to about 512 output pixels wide.
        case balanced
        /// 2016x1512, 56 ms. Earned only by a camera big enough that `balanced` would be
        /// upscaled — a full-frame talking head, not a corner bubble.
        case accurate

        /// The width of the mask this level produces, measured rather than documented; Vision
        /// publishes no such number. Used to decide when `accurate` is worth its 2.7x.
        public var maskWidth: Int {
            switch self {
            case .balanced: 512
            case .accurate: 2016
            }
        }

        var visionLevel: VNGeneratePersonSegmentationRequest.QualityLevel {
            switch self {
            case .balanced: .balanced
            case .accurate: .accurate
            }
        }
    }

    /// The level to segment at for a camera drawn `width` output pixels across.
    ///
    /// **The rule is "do not upscale the mask", and that is the whole rule.** Below the mask's own
    /// width the cheaper level is already at or above 1:1 and the expensive one buys nothing a
    /// viewer can see; above it, every extra output pixel is invented and the silhouette starts
    /// to show its staircase exactly where hair meets background.
    ///
    /// A non-finite or non-positive width answers `balanced` rather than trapping: a card with no
    /// width draws nothing, so the level chosen for it cannot be visible, and the cheaper answer
    /// is the safer one to be wrong with.
    public static func quality(forCardWidthInPixels width: Double) -> Quality {
        guard width.isFinite, width > Double(Quality.balanced.maskWidth) else { return .balanced }
        return .accurate
    }

    /// Why a frame was left with its background on. **Never `nil`** — a camera that quietly keeps
    /// its room is indistinguishable from a switch that was never turned on, and the two have
    /// completely different fixes.
    public enum Refusal: String, Sendable, Equatable, Hashable {
        /// The camera's buffer has no pixels to segment. Reachable: a camera that has been
        /// opened but has not produced a frame yet hands back an empty one.
        case theFrameHasNoPixels
        /// Vision refused to run the request at all — no model for this machine, or a format it
        /// will not take.
        case visionRefusedTheRequest
        /// Vision ran and produced no mask at all.
        ///
        /// **This is not what an empty room looks like**, and the distinction was measured
        /// rather than assumed. Given a frame with nobody in it — black, grey, or a gradient —
        /// Vision still returns a full 512x384 mask; its peak value is 2 to 5 out of 255, which
        /// is under 2% opacity, so the camera comes out very nearly transparent all by itself.
        /// So a person leaning out of shot does NOT arrive here. This case is Vision failing.
        case visionReturnedNoMask
    }

    /// A cut-out, or the reason there is not one.
    public enum Outcome: Sendable {
        case cutOut(CIImage)
        case refused(Refusal)
    }

    /// The camera's frame with everything that is not a person made transparent.
    ///
    /// `image` and `buffer` are the same frame, passed twice on purpose: Vision needs the pixel
    /// buffer and CoreImage needs the image, and deriving either from the other inside here would
    /// mean a copy per frame at 60 frames a second.
    ///
    /// **The caller draws the camera unchanged on a refusal.** A camera with its room behind it
    /// is a far better outcome than a hole where somebody's face was, and the refusal says which
    /// of the three things happened.
    public static func cutOut(_ image: CIImage, from buffer: CVPixelBuffer,
                              quality: Quality) -> Outcome {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return .refused(.theFrameHasNoPixels) }

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality.visionLevel
        // One component per pixel, which is all a mask is. Also the format the channel-reading
        // measurement in this file's header was taken against.
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
        } catch {
            return .refused(.visionRefusedTheRequest)
        }
        guard let maskBuffer = (request.results?.first)?.pixelBuffer else {
            return .refused(.visionReturnedNoMask)
        }

        let mask = CIImage(cvPixelBuffer: maskBuffer)
        let maskExtent = mask.extent
        guard maskExtent.width > 0, maskExtent.height > 0 else {
            return .refused(.visionReturnedNoMask)
        }
        // **X and Y independently** — see fact 2 in the header. The mask covers the whole input
        // image whatever shape either of them is.
        let scaleX = extent.width / maskExtent.width
        let scaleY = extent.height / maskExtent.height
        var placed = mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        placed = placed.transformed(by: CGAffineTransform(translationX: extent.minX - placed.extent.minX,
                                                          y: extent.minY - placed.extent.minY))

        // **Feathered by rather less than one mask pixel.** The mask is a hard binary edge at its
        // own resolution; stretched over a bigger frame that edge becomes a visible staircase
        // through hair, which is where a cut-out is judged. Blurring by a fraction of a mask
        // pixel breaks the staircase without eating the silhouette — a blur measured in OUTPUT
        // pixels would erode a large frame's edges and do nothing at all to a small one.
        //
        // Clamped before the blur and cropped after it, because a Gaussian reads outside its
        // input and grows its extent: without the clamp the frame's own border fades to
        // transparent, which cuts a soft line down the side of anybody standing near the edge.
        let cameraPixelsPerMaskPixel = extent.width / maskExtent.width
        let sigma = max(cameraPixelsPerMaskPixel * 0.6, 0.5)
        let feathered = placed.clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: extent)

        // Transparent of the frame's own size, not `CIImage.empty()`. An empty image has ZERO
        // extent, and a blend into nothing evaporates silently — the defect that left the camera
        // overlay's border invisible in every build until 2026-08-26.
        let transparent = CIImage(color: .clear).cropped(to: extent)
        return .cutOut(image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: feathered,
            kCIInputBackgroundImageKey: transparent,
        ]))
    }

    /// Loads the segmentation models, so the first real frame does not pay for it.
    ///
    /// **Measured at 1.0 s to 1.9 s for the first request of each quality level**, and roughly 7
    /// ms for the second — the cost is the model, once per level per process. Called when
    /// somebody turns the switch on, which is seconds before they press Record or scrub to a
    /// frame with a camera in it, rather than lazily on the frame that needs it.
    ///
    /// Both levels are warmed because which one a frame uses depends on how wide the camera card
    /// is, and dragging that slider must not reintroduce the stall this exists to remove.
    ///
    /// Runs the request against a 64x64 buffer: the measurement showed the input's size does not
    /// change the time, so there is no reason to warm with a big one.
    public static func warmUp() {
        var buffer: CVPixelBuffer?
        // `unsafe` for the inout pointer `CVPixelBufferCreate` writes through — the mark
        // `.strictMemorySafety()` asks for. The buffer is local and never escapes this call.
        unsafe CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { return }
        for quality in Quality.allCases {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = quality.visionLevel
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            // Failures are ignored on purpose: this is a cache warm, and a machine that cannot
            // run the request will say so through `Refusal` on the frame that actually needs it,
            // where the caller can do something about it.
            try? VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
        }
    }
}
