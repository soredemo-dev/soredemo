import CoreImage
import CoreVideo
import Foundation
import Vision

/// Cuts the room out from behind a camera, leaving the person over the screen recording.
///
/// `cutOut(_:from:quality:)` returns the frame with everything that is not a person made
/// transparent, or a named `Refusal`. **The caller draws the camera unchanged on a refusal** — a
/// camera with its room behind it is a far better outcome than a hole where somebody's face was.
///
/// Pick the level with `quality(forCardWidthInPixels:)`, which will not upscale its own mask if
/// it can avoid it. Call `warmUp()` when the feature is switched on: the first request of each
/// level loads a model and costs one to two seconds.
///
/// **Background BLUR is not here and is not missing.** macOS ships Portrait mode and
/// `CameraEffects` puts it one click away; a hand-written blur would be slower and worse.
///
/// See `docs/design/camera-background-removal.md` for the measurements this rests on — the mask
/// does not preserve the input's aspect, `CIBlendWithMask` does not read the channel its
/// documentation names, and an empty room needs no confidence floor.
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
