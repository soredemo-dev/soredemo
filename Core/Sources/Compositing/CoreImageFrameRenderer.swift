import CoreImage
import CoreVideo
import Foundation
// `CursorArt` and `HeadlessGeometryBridge` are same-module names and need no import.
import Metal
import Render

/// A `FrameRendering` implementation on Core Image over a Metal-backed context.
///
/// `StageStyle.shadowRadius`/`.shadowOpacity` are drawn since the recorder-parity decision
/// (design doc 2026-08-19) — an ambient drop shadow, no offset, because the fields model
/// radius and opacity and nothing else; inventing a direction would be a value the style
/// cannot round-trip.
public nonisolated final class CoreImageFrameRenderer: FrameRendering {
    private let context: CIContext

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw FrameRenderingError.noRenderDevice
        }
        // Colour spaces pinned rather than defaulted, so colour handling is not implicit.
        context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
    }

    public func render(_ plan: RenderPlan, source: CVPixelBuffer, camera: CVPixelBuffer?,
                       into destination: CVPixelBuffer) throws {
        let background = backgroundImage(plan)
        let card = cardImage(plan, source: source)
        var composed = background
        if let shadow = shadowImage(plan) {
            composed = shadow.composited(over: composed)
        }
        // **The body goes under the card and over the shadow.** The recording draws into
        // `plan.card`, which IS the screen when there is a frame — so the body is the ring of
        // hardware around it, and anything drawn after the card would cover the picture.
        if let device = plan.deviceFrame {
            composed = deviceBody(device).composited(over: composed)
        }
        composed = card.composited(over: composed)
        // **After the card and before everything else.** The border belongs to the card's edge,
        // so it must sit over the picture — but under the pointer, the captions and the camera,
        // none of which are inside the card's frame in the sense the border describes.
        composed = cardBorder(plan).composited(over: composed)
        // Whether to draw a pointer is `StageCompositor`'s decision, not this file's.
        if let pointer = plan.pointer {
            composed = cursorImage(for: pointer, outputHeight: plan.outputHeight,
                                   style: plan.cursorStyle).composited(over: composed)
        }
        // **Above the cursor, and last.** A caption sits over the picture by definition; drawing
        // it under the pointer would let the pointer cross the text it is meant to be read with.
        if let caption = plan.caption,
           let image = CaptionArt.image(caption, outputWidth: plan.outputWidth,
                                        outputHeight: plan.outputHeight) {
            composed = image.composited(over: composed)
        }
        // **A pressed shortcut, above the caption.** Both are read alongside the picture;
        // the badge sits higher so the two never share a line when both are on.
        if let badge = plan.keystroke,
           let image = KeystrokeArt.image(badge, outputWidth: plan.outputWidth,
                                          outputHeight: plan.outputHeight) {
            composed = image.composited(over: composed)
        }
        // **The camera goes above the picture and under the overlays.** It is part of the
        // recording, so a title or a caption a person placed has to read over it — and a
        // redaction is applied to the source inside the card, so it is already below.
        if let overlay = plan.camera, let camera {
            composed = cameraImage(overlay, buffer: camera, plan: plan).composited(over: composed)
        }
        // **Annotations above the camera and below the titles.** Above the camera for the same
        // reason a title is: both are things a person deliberately placed, and an arrow hidden
        // behind a face is hidden exactly when someone is talking over the thing it points at.
        // Below the titles because a title is about the whole frame and an annotation is about
        // one part of it — when both are on, the one that names the scene should read first.
        for annotation in plan.annotations {
            guard let image = annotationImage(annotation, outputWidth: plan.outputWidth,
                                              outputHeight: plan.outputHeight) else { continue }
            composed = image.composited(over: composed)
        }
        // Titles above the caption: a caption is a transcript of what is being said and belongs
        // under anything a person deliberately placed.
        for text in plan.texts {
            guard let image = TextArt.image(text, outputWidth: plan.outputWidth,
                                            outputHeight: plan.outputHeight) else { continue }
            composed = image.composited(over: composed)
        }
        // Rule 5 confines `CGRect`/`CGFloat` to the bridge file, so no literal `CGRect` here.
        let cropped = composed
            .cropped(to: HeadlessGeometryBridge.outputCanvas(width: plan.outputWidth, height: plan.outputHeight))
        context.render(cropped, to: destination,
                       bounds: cropped.extent,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// Image backgrounds, decoded once and kept. A wallpaper is the same file on every frame,
    /// and decoding a 4K PNG sixty times a second to draw it unchanged is the kind of cost that
    /// only shows up in a long export. Guarded by its own lock, never held across a GPU render —
    /// the arrangement `cursorCanvases` already uses.
    private nonisolated(unsafe) var backgroundImages: [String: CIImage] = [:]
    private let backgroundImageLock = NSLock()

    /// Where image backgrounds are read from — the package the recording lives in. Set on the
    /// same terms as `StageCompositor`'s other statics: written before the composition reaches
    /// AVFoundation, so it is published before any callback can see it.
    ///
    /// `nil` draws the fallback rather than nothing: a background that silently disappears is
    /// worse than one that is obviously not the picture you chose.
    public nonisolated(unsafe) static var imageBaseURL: URL?

    private func backgroundImage(_ plan: RenderPlan) -> CIImage {
        switch plan.style.background {
        case .image(let filename):
            guard let image = imageBackground(filename) else { return Self.missingImageFallback }
            let filled = covering(image, width: Double(plan.outputWidth),
                                  height: Double(plan.outputHeight))
            guard plan.style.backgroundBlur > 0 else { return filled }
            // **Clamped before, cropped after.** A Gaussian reads outside its input and grows its
            // extent: without the clamp the picture fades to transparent at the frame's edges,
            // which on a dark stage draws a soft vignette nobody asked for and on a light one
            // shows whatever is underneath.
            //
            // The sigma is a fraction of the frame's WIDTH rather than a number of pixels,
            // because the same slider has to mean the same thing for a 720p export and a 4K one
            // — a fixed 40-pixel blur is heavy on one and invisible on the other. Four per cent
            // at the top of the range is 77 pixels at 1920, which turns a photograph into its own
            // colours without turning it into a flat fill.
            let sigma = plan.style.backgroundBlur * Double(plan.outputWidth)
                * Self.backgroundBlurFractionOfWidth
            return filled.clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: HeadlessGeometryBridge.rect(x: 0, y: 0,
                                                         width: Double(plan.outputWidth),
                                                         height: Double(plan.outputHeight)))
        case .transparent:
            // **`CIImage(color: .clear)`, which has infinite extent like every other case here.**
            // Not `CIImage.empty()`: that has ZERO extent, and compositing over it drops the
            // pass entirely — the defect that left the camera overlay's border invisible in every
            // build until 2026-08-26. Everything the frame is made of composites over this, so a
            // base with no extent is a frame with nothing in it.
            return CIImage(color: .clear)
        case let .solid(red, green, blue):
            return CIImage(color: CIColor(red: red, green: green, blue: blue))
        case let .linearGradient(startRed, startGreen, startBlue,
                                 endRed, endGreen, endBlue, angleDegrees):
            return gradientImage(plan, start: CIColor(red: startRed, green: startGreen, blue: startBlue),
                                 end: CIColor(red: endRed, green: endGreen, blue: endBlue),
                                 angleDegrees: angleDegrees)
        }
    }

    /// **`CISmoothLinearGradient`, not `CILinearGradient`.** The linear filter ramps the
    /// channels evenly, which on a full-frame fill shows Mach banding — the eye finds edges
    /// in a perfectly even ramp. The smooth variant applies a smoothstep easing, which costs
    /// nothing here and removes it.
    ///
    /// The two points are placed on the frame's diagonal at `angleDegrees`, measured
    /// counter-clockwise from +x as `StageBackground.linearGradient` documents. The span is
    /// half the frame's diagonal in each direction from the centre, so the gradient always
    /// covers the whole frame whatever the angle: projecting the frame's width and height
    /// onto the axis separately would leave a flat band at every angle but 0° and 90°.
    /// How much of the frame's width the strongest blur spans, as a Gaussian sigma.
    ///
    /// **Expressed against the width so the slider means the same thing at every export size.** A
    /// blur written in pixels is heavy at 720p and invisible at 4K, which makes a project look
    /// different depending on what it was exported as — the one thing a style must never do.
    ///
    /// 0.04 was chosen by looking: at 1920 it is a sigma of 77 pixels, which reduces a
    /// photograph to its own colours and light while stopping short of a flat fill. Doubling it
    /// loses the light; halving it leaves a face recognisable.
    static let backgroundBlurFractionOfWidth = 0.04

    /// **The fallback when an image will not load.** A mid grey rather than black or clear:
    /// black reads as a deliberate background and clear shows whatever was underneath, and both
    /// hide the fact that a chosen picture is missing.
    static let missingImageFallback = CIImage(color: CIColor(red: 0.22, green: 0.22, blue: 0.24))

    /// The image for `filename`, scaled to cover the frame, cached.
    ///
    /// **Scaled to COVER, not to fit.** A wallpaper letterboxed inside the frame leaves bars,
    /// which is not what a background is; the excess is cropped, which is what every desktop
    /// does with the same picture.
    private func imageBackground(_ filename: String) -> CIImage? {
        guard StageBackground.isSafeImageFilename(filename),
              let base = unsafe Self.imageBaseURL else { return nil }
        if let cached = backgroundImageLock.withLock({ unsafe backgroundImages[filename] }) {
            return cached
        }
        let url = base.appending(path: StageBackground.imageDirectory, directoryHint: .isDirectory)
            .appending(path: filename)
        guard let image = CIImage(contentsOf: url) else { return nil }
        backgroundImageLock.withLock { unsafe backgroundImages[filename] = image }
        return image
    }

    /// `image` scaled so it covers `width` × `height`, centred.
    private func covering(_ image: CIImage, width: Double, height: Double) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = max(width / Double(extent.width), height / Double(extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let offsetX = (width - Double(scaled.extent.width)) / 2 - Double(scaled.extent.minX)
        let offsetY = (height - Double(scaled.extent.height)) / 2 - Double(scaled.extent.minY)
        return scaled.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
    }

    /// `image` reduced to `crop`, with the result moved back to the origin.
    ///
    /// **Moved back, because everything downstream measures from zero.** `cardImage` scales by
    /// `card.width / image.extent.width` and translates by the plan's own origin; an image
    /// cropped in place would still carry its offset in `extent.minX` and would land that far
    /// off the card.
    static func cropped(_ image: CIImage, to crop: CropRect) -> CIImage {
        guard !crop.isWhole else { return image }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        // `y` runs from the top in a `CropRect` and from the bottom in a `CIImage`.
        let box = HeadlessGeometryBridge.rect(
            x: Double(extent.minX) + crop.x * Double(extent.width),
            y: Double(extent.minY) + (1 - crop.y - crop.height) * Double(extent.height),
            width: crop.width * Double(extent.width),
            height: crop.height * Double(extent.height))
        return image.cropped(to: box)
            .transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
    }

    private func gradientImage(_ plan: RenderPlan, start: CIColor, end: CIColor,
                               angleDegrees: Double) -> CIImage {
        let width = Double(plan.outputWidth)
        let height = Double(plan.outputHeight)
        let radians = angleDegrees * .pi / 180
        let reach = (width * width + height * height).squareRoot() / 2
        let centreX = width / 2
        let centreY = height / 2
        let dx = cos(radians) * reach
        let dy = sin(radians) * reach

        guard let filter = CIFilter(name: "CISmoothLinearGradient", parameters: [
            "inputPoint0": CIVector(x: centreX - dx, y: centreY - dy),
            "inputPoint1": CIVector(x: centreX + dx, y: centreY + dy),
            "inputColor0": start,
            "inputColor1": end,
        ]), let output = filter.outputImage else {
            // A filter this basic not resolving means CoreImage is not usable at all, but a
            // frame with the start colour is a better failure than a crash mid-export.
            return CIImage(color: start)
        }
        return Self.dithered(output, width: width, height: height)
    }

    /// **A grain of noise on a gradient, so an 8-bit export does not band.** A ramp across
    /// 1080 px between two colours a few dozen levels apart steps once every twenty or thirty
    /// pixels, and the eye finds every step; the smooth filter's easing removes the Mach bands
    /// at the ends and not the steps in the middle. Adding noise of ±`ditherLevels` / 255 —
    /// below what anyone sees as grain — breaks each step into a dither, which is how a Rust recorder's
    /// gradient layer (`noise_intensity`) and every film scan handle the same thing.
    /// `CIRandomGenerator` is procedural in position, so the same frame dithers the same way
    /// in the preview and in the export (`aDitheredGradientIsDeterministic`).
    static let ditherLevels: Double = 1.5

    static func dithered(_ image: CIImage, width: Double, height: Double) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let amplitude = Self.ditherLevels / 255
        let canvas = HeadlessGeometryBridge.rect(x: 0, y: 0, width: width, height: height)
        // **Alpha set to one FIRST, and that was a measured mistake twice over.** The
        // generator's alpha is random too, and Core Image holds colour premultiplied by it: a
        // matrix that set alpha to 1 on the premultiplied values rendered a ±1.5 level grain
        // as spikes of 255, and dividing the alpha out first (`unpremultiplyingAlpha`) made
        // the spikes worse, because a colour divided by a near-zero alpha is enormous before
        // the matrix scales it. `settingAlphaOne(in:)` is the operation that means what is
        // wanted — the noise's colour, at alpha 1 — measured flat at 127/128 around a 0.5
        // bias (probe, 2026-08-25). One channel's noise into all three, centred on zero.
        guard let grain = CIFilter(name: "CIColorMatrix", parameters: [
            kCIInputImageKey: noise.settingAlphaOne(in: canvas),
            "inputRVector": CIVector(x: amplitude, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: amplitude, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: amplitude, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: -amplitude / 2, y: -amplitude / 2, z: -amplitude / 2, w: 1),
        ])?.outputImage else { return image }
        guard let summed = CIFilter(name: "CIAdditionCompositing", parameters: [
            kCIInputImageKey: grain.cropped(to: canvas),
            kCIInputBackgroundImageKey: image.cropped(to: canvas),
        ])?.outputImage else { return image }
        return summed
    }

    /// **Two shadows from one silhouette, and the second falls DOWN.** The single blurred
    /// silhouette this used to draw is a halo: the same darkness on every side, which is what
    /// a rectangle glowing looks like and not what a window on a surface looks like. A real
    /// shadow has two parts — a wide, faint ambient one from light everywhere, and a tighter,
    /// darker key one displaced away from the light. Anything that reads as "a window sitting
    /// there" draws both, and a card whose shadow visibly hangs below it is the tell. Both here
    /// are
    /// derived from the style's two knobs, so nothing a person saved changes meaning:
    ///
    /// * ambient — the silhouette at `opacity × ambientShare`, sigma `radius / 2`, centred;
    /// * key — the silhouette at `opacity × keyShare`, sigma `radius × keySigmaFraction`,
    ///   moved down by `radius × keyDropFraction`.
    ///
    /// `nil` when either knob is zero, so a shadowless style costs no filter pass at all
    /// (`aZeroOpacityShadowChangesNothing`). The proportions are **uncalibrated**: chosen so a
    /// default style (radius 32, opacity 0.35) reads as a card on a desk rather than a card in
    /// fog, measured by eye on the "Dusk" preset and pinned by
    /// `theShadowFallsBelowTheCardMoreThanAboveIt`.
    static let ambientShare: Double = 0.6
    static let keyShare: Double = 0.75
    static let keySigmaFraction: Double = 0.3
    static let keyDropFraction: Double = 0.35

    private func shadowImage(_ plan: RenderPlan) -> CIImage? {
        let opacity = plan.style.shadowOpacity
        let radius = plan.style.shadowRadius
        guard opacity > 0, radius > 0 else { return nil }
        // **The shadow is cast by whatever the viewer sees, which is the body when there is
        // one.** A shadow the shape of the screen under a device draws a rectangle floating
        // inside the bezel, which reads as a compositing mistake rather than as a device.
        let silhouetteRect = plan.deviceFrame?.body ?? plan.card
        let silhouetteRadius = plan.deviceFrame?.bodyCornerRadius ?? plan.cornerRadius
        func silhouette(alpha: Double) -> CIImage? {
            CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(x: silhouetteRect.x, y: silhouetteRect.y,
                                        z: silhouetteRect.width, w: silhouetteRect.height),
                "inputRadius": silhouetteRadius,
                "inputColor": CIColor(red: 0, green: 0, blue: 0, alpha: alpha),
            ])?.outputImage
        }
        guard let ambient = silhouette(alpha: opacity * Self.ambientShare) else { return nil }
        let ambientBlurred = ambient.applyingGaussianBlur(sigma: radius / 2)
        guard let key = silhouette(alpha: opacity * Self.keyShare) else { return ambientBlurred }
        // Down is −y: the plan is bottom-left origin.
        let keyBlurred = key
            .transformed(by: CGAffineTransform(translationX: 0, y: -radius * Self.keyDropFraction))
            .applyingGaussianBlur(sigma: radius * Self.keySigmaFraction)
        return keyBlurred.composited(over: ambientBlurred)
    }

    private func cardImage(_ plan: RenderPlan, source: CVPixelBuffer) -> CIImage {
        // **Redactions first, in the source's own pixels.** Applied before the camera's scale
        // and shift, so a region covers the same window however the camera moved — see
        // `RedactionArt`. Applying them after would let a pan slide the cover off its target.
        // **Redacted first, then cropped.** A region is placed against the whole recording —
        // that is the space a person drew it in — so cropping first would move every cover.
        let redacted = RedactionArt.applied(plan.redactions, to: Self.screenImage(source))
        let image = Self.cropped(redacted, to: plan.crop)
        // The camera scales and shifts the CONTENT; `rounded` then masks it to the card,
        // which never moves. `RenderPlan.contentX/Y` owns the mapping so the pointer and
        // the image cannot disagree about where a normalised point lands.
        let scaleX = plan.card.width * plan.contentZoom / image.extent.width
        let scaleY = plan.card.height * plan.contentZoom / image.extent.height
        let originX = plan.contentX(ofNormalised: 0)
        let originY = plan.contentY(ofNormalised: 0)
        var placed = Self.resampled(image, scaleX: scaleX, scaleY: scaleY)
            .transformed(by: CGAffineTransform(translationX: originX, y: originY))
        if let blur = plan.motionBlur {
            placed = Self.smeared(placed, by: blur)
        }
        return rounded(placed, plan: plan)
    }

    /// **The screen's pixels are sRGB, whatever the master's tag says, and this is where that
    /// is declared.** `CaptureSession` asks ScreenCaptureKit for `colorSpaceName = sRGB` and
    /// writes the master tagged Rec.709 — the convention every screen recording on this
    /// platform follows, since 709 and sRGB share primaries and the tag is what players
    /// expect. They do NOT share a transfer curve. A decoded master frame arrives with 709
    /// attachments, and `CIImage(cvPixelBuffer:)` honours them: it converts the pixels
    /// through 709's curve into the context's sRGB working space, the context renders sRGB
    /// out, and the writer tags 709 again without converting back. **Measured: mid grey 128
    /// left the export as 141 and 200 as 208**, on every frame, with every tag agreeing with
    /// every other tag — the failure the colour-pipeline note (2026-08-24) said this chain
    /// did not have, because it checked the tags and not the pixels.
    ///
    /// Declaring the buffer sRGB on the way in makes the round trip the identity: the
    /// values the capture wrote are the values the export writes
    /// (`theExportPreservesTheSourcesPixelValues`). **The camera's frames are not treated
    /// this way** — `cameraImage` reads its buffer with its own tags, because a webcam's
    /// pixels really are the video the tag says they are.
    static let screenColourSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func screenImage(_ buffer: CVPixelBuffer) -> CIImage {
        CIImage(cvPixelBuffer: buffer, options: [.colorSpace: screenColourSpace])
    }

    /// **Lanczos, not the affine transform's bilinear sampler — and this is the single
    /// largest sharpness change available in the renderer.** A Retina recording drawn into
    /// a card is scaled DOWN by roughly 2×: at that ratio a bilinear sample reads four
    /// source pixels per output pixel and skips every other row and column outright, which
    /// on screen content — text, one-pixel rules, hard edges — is aliasing on top of the
    /// softness. A Lanczos kernel integrates every source pixel under its footprint, so a
    /// downscaled line is a thinner line rather than a broken or a blurred one, and an
    /// UPSCALE under the camera's zoom keeps its edges where bilinear rounds them.
    /// `RedactionArt` was already using this filter to make its blocks; the picture itself
    /// was not.
    ///
    /// The image is clamped to its extent before the kernel runs and cropped back after:
    /// Lanczos reads past the edge, and reading transparent there would darken the card's
    /// outermost pixel — a hairline the rounded mask would then feather into a visible
    /// border. At a scale of exactly 1 the filter is skipped, because the kernel is then the
    /// identity and the clamp-and-crop would be work for nothing.
    static func resampled(_ image: CIImage, scaleX: Double, scaleY: Double) -> CIImage {
        guard scaleX > 0, scaleY > 0, scaleX.isFinite, scaleY.isFinite,
              abs(scaleX - 1) > 1e-9 || abs(scaleY - 1) > 1e-9 else { return image }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let target = HeadlessGeometryBridge.rect(
            x: Double(extent.minX) * scaleX, y: Double(extent.minY) * scaleY,
            width: Double(extent.width) * scaleX, height: Double(extent.height) * scaleY)
        guard let filter = CIFilter(name: "CILanczosScaleTransform", parameters: [
            kCIInputImageKey: image.clampedToExtent(),
            kCIInputScaleKey: scaleY,
            kCIInputAspectRatioKey: scaleX / scaleY,
        ]), let output = filter.outputImage else {
            // The affine sampler is the fallback, never nothing: a frame drawn softer beats
            // a frame not drawn.
            return image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        return output.cropped(to: target)
    }

    /// The content smeared by this frame's camera motion — see `MotionBlur`. Pan and zoom
    /// smears compose when both are present; each is skipped when its length is zero, so a
    /// pure pan costs one filter. Clamped and cropped for the same reason `resampled` is:
    /// a blur reads past the edge, and a transparent edge would fade the card's border.
    static func smeared(_ image: CIImage, by blur: MotionBlur) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return image }
        // Rule 5: no `CGRect` here, so the crop rect is asked of the bridge.
        let bounds = HeadlessGeometryBridge.rect(
            x: Double(extent.minX), y: Double(extent.minY),
            width: Double(extent.width), height: Double(extent.height))
        var result = image.clampedToExtent()
        if blur.panRadius > 0,
           let filter = CIFilter(name: "CIMotionBlur", parameters: [
               kCIInputImageKey: result,
               kCIInputRadiusKey: blur.panRadius,
               kCIInputAngleKey: blur.panAngle,
           ]), let output = filter.outputImage {
            result = output
        }
        if blur.zoomAmount > 0,
           let filter = CIFilter(name: "CIZoomBlur", parameters: [
               kCIInputImageKey: result,
               kCIInputAmountKey: blur.zoomAmount,
               kCIInputCenterKey: CIVector(x: blur.centreX, y: blur.centreY),
           ]), let output = filter.outputImage {
            result = output
        }
        return result.cropped(to: bounds)
    }

    /// **A hairline light edge on the card, or nothing.**
    ///
    /// The ring is the difference between the card's shape and a slightly smaller one — the same
    /// construction the camera overlay's border already uses, and for the same reason:
    /// `CIRoundedRectangleGenerator` makes shapes rather than paths, so there is nothing for a
    /// stroke filter to stroke.
    ///
    /// **Its width is a fraction of the card, floored at one pixel.** A border fixed in pixels is
    /// invisible in a 4K export and heavy in a 720p one; a border fixed in fractions vanishes
    /// entirely on a small card. The floor is what stops the second.
    /// The device's body: a rounded rectangle filled with a vertical gradient.
    ///
    /// **A gradient, not a fill.** A device is lit from above in every product photograph
    /// anybody has seen; a flat rectangle behind a screen reads as a coloured border rather than
    /// as hardware. Two tones is the smallest thing that reads as a lit surface.
    ///
    /// The gradient is generated over the whole canvas and then masked to the body's shape,
    /// because `CILinearGradient` has infinite extent and `CIRoundedRectangleGenerator` is the
    /// only thing here that knows about corners.
    private func deviceBody(_ device: DeviceFrame.Placement) -> CIImage {
        let top = device.finish.top, bottom = device.finish.bottom
        guard let gradient = CIFilter(name: "CILinearGradient", parameters: [
                  // Bottom-left origin, so `point1` is the top.
                  "inputPoint0": CIVector(x: device.body.x, y: device.body.y),
                  "inputPoint1": CIVector(x: device.body.x,
                                          y: device.body.y + device.body.height),
                  "inputColor0": CIColor(red: bottom.r, green: bottom.g, blue: bottom.b),
                  "inputColor1": CIColor(red: top.r, green: top.g, blue: top.b),
              ])?.outputImage,
              let shape = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                  "inputExtent": CIVector(x: device.body.x, y: device.body.y,
                                          z: device.body.width, w: device.body.height),
                  "inputRadius": device.bodyCornerRadius,
                  "inputColor": CIColor.white,
              ])?.outputImage
        else { return CIImage.empty() }
        // **Masked, not cropped.** A crop would give the body square corners, which is the one
        // thing a device body must not have.
        return gradient.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: shape,
        ])
    }

    private func cardBorder(_ plan: RenderPlan) -> CIImage {
        guard plan.style.borderOpacity > 0 else { return CIImage.empty() }
        let width = max(plan.card.width * 0.0015, 1)
        guard let outer = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                  "inputExtent": CIVector(x: plan.card.x, y: plan.card.y,
                                          z: plan.card.width, w: plan.card.height),
                  "inputRadius": plan.cornerRadius,
                  "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: plan.style.borderOpacity),
              ])?.outputImage,
              let inner = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                  "inputExtent": CIVector(x: plan.card.x + width, y: plan.card.y + width,
                                          z: plan.card.width - width * 2,
                                          w: plan.card.height - width * 2),
                  "inputRadius": max(plan.cornerRadius - width, 0),
                  "inputColor": CIColor.white,
              ])?.outputImage
        else { return CIImage.empty() }
        // **`CISourceOutCompositing`, and a first draft used `CIBlendWithMask` over
        // `CIImage.empty()` and drew nothing at all** — measured, every probe across the edge
        // identical with the border on and off. An empty image has ZERO extent, so the blend had
        // nowhere to composite into and the whole pass evaporated silently. Source-out is the
        // ring stated directly: the outer shape wherever the inner one is not.
        return outer.applyingFilter("CISourceOutCompositing", parameters: [
            kCIInputBackgroundImageKey: inner,
        ])
    }

    /// Rounded corners as a mask; a crop would give square corners.
    private func rounded(_ image: CIImage, plan: RenderPlan) -> CIImage {
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(x: plan.card.x, y: plan.card.y,
                                    z: plan.card.width, w: plan.card.height),
            "inputRadius": plan.cornerRadius,
            "inputColor": CIColor.white,
        ])?.outputImage ?? image
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
    }

    // MARK: - the drawn pointer

    /// One annotation, drawn into a bitmap its own size and placed in the frame.
    ///
    /// **A bitmap per annotation, not per frame of output.** A 1920×1080 canvas to draw one
    /// arrow on is the allocation `RedactionArt.masked`'s header refuses; `AnnotationArt.canvas`
    /// is what says how small it can be, and it is the same function the paths are built
    /// against so the two cannot disagree about where the origin is.
    ///
    /// **Cached on everything except opacity.** `AnnotationOverlay` is `Hashable`, so the cache
    /// key is the overlay itself with its opacity normalised away: the drawing happens at full
    /// opacity and the fade is a colour matrix on the finished image, which costs nothing and
    /// means a steady annotation is drawn once and reused for every frame it is on. `scale` is
    /// deliberately left IN the key — it changes the geometry, not just the alpha — so the
    /// 0.35 s an animated annotation spends arriving is redrawn per frame and the rest is not.
    private func annotationImage(_ overlay: AnnotationOverlay,
                                 outputWidth: Int, outputHeight: Int) -> CIImage? {
        guard !overlay.isEmpty else { return nil }
        let key = AnnotationOverlay(shape: overlay.shape, startX: overlay.startX,
                                    startY: overlay.startY, endX: overlay.endX,
                                    endY: overlay.endY, style: overlay.style,
                                    opacity: 1, scale: overlay.scale)
        let drawn = annotationCacheLock.withLock { () -> CIImage? in
            if let hit = unsafe annotationCache[key] { return hit }
            guard let made = drawAnnotation(key, outputWidth: outputWidth,
                                            outputHeight: outputHeight) else { return nil }
            // A hard cap rather than an eviction policy. Every annotation on screen at once is
            // a handful; a cache that grew without bound would be a leak over a long export,
            // and one that evicted cleverly would be a policy nobody has measured. Dropping the
            // whole thing costs one redraw per annotation and cannot grow.
            if unsafe annotationCache.count >= 64 { unsafe annotationCache.removeAll() }
            unsafe annotationCache[key] = made
            return made
        }
        guard let drawn else { return nil }
        guard overlay.opacity < 1 else { return drawn }
        // The fade, applied to the finished image. `CIColorMatrix`'s alpha vector scales the
        // existing alpha rather than replacing it, so the antialiased edge fades with the rest
        // instead of becoming a hard edge at partial opacity.
        let fade = CIFilter.colorMatrix()
        fade.inputImage = drawn
        fade.aVector = CIVector(x: 0, y: 0, z: 0, w: overlay.opacity)
        return fade.outputImage ?? drawn
    }

    /// The actual drawing. Split from the cache above so the cache has one job and this has one.
    private func drawAnnotation(_ overlay: AnnotationOverlay,
                                outputWidth: Int, outputHeight: Int) -> CIImage? {
        let stroke = overlay.style.strokeWidth(forOutputWidth: outputWidth,
                                               outputHeight: outputHeight)
        let blur = overlay.style.shadowBlur(forOutputWidth: outputWidth,
                                            outputHeight: outputHeight)
        guard let canvas = AnnotationArt.canvas(for: overlay, strokeWidth: stroke,
                                                shadowBlur: blur) else { return nil }
        let width = Int(canvas.width.rounded(.up))
        let height = Int(canvas.height.rounded(.up))
        // **A ceiling, and it is not paranoia.** The canvas is derived from two points that a
        // decoder could put anywhere; a corrupt annotation asking for a 200_000-pixel bitmap
        // would be an allocation failure in the middle of an export rather than a missing arrow.
        // `AnnotationItem` clamps its points, so reaching this is a bug elsewhere — which is
        // exactly when a bound earns its place.
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { return nil }
        guard let artwork = AnnotationArt.artwork(for: overlay, strokeWidth: stroke,
                                                  originX: canvas.x, originY: canvas.y)
        else { return nil }

        // `data: nil`: CGContext owns its backing store and no raw pointer is read here.
        guard let bitmap = unsafe CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let colour = CGColor(red: overlay.style.red, green: overlay.style.green,
                             blue: overlay.style.blue, alpha: overlay.style.alpha)
        bitmap.setLineWidth(stroke)
        // Round joins and caps: a mitred join on a thick stroke at a sharp angle produces a
        // spike far outside the path, which would be clipped by the canvas computed for it.
        bitmap.setLineJoin(.round)
        bitmap.setLineCap(.round)

        // **The shadow first, and as a state rather than a second drawing pass.** Drawing the
        // artwork twice — once blurred, once not — is the obvious implementation and it doubles
        // the path work; `setShadow` makes Core Graphics do it in one.
        //
        // No offset. A drop shadow to one side helps a large filled shape and does nothing for a
        // two-pixel line, which needs contrast on every side — so this is a halo, which is what
        // keeps a red arrow legible over a red window.
        if overlay.style.shadowOpacity > 0 && blur > 0 {
            bitmap.setShadow(offset: HeadlessGeometryBridge.noOffset(), blur: blur,
                             color: CGColor(red: 0, green: 0, blue: 0,
                                            alpha: overlay.style.shadowOpacity))
        }

        if let interior = artwork.interior {
            bitmap.setFillColor(CGColor(red: overlay.style.red, green: overlay.style.green,
                                        blue: overlay.style.blue,
                                        alpha: overlay.style.alpha * overlay.style.fillOpacity))
            bitmap.addPath(interior)
            bitmap.fillPath()
        }
        bitmap.setStrokeColor(colour)
        bitmap.addPath(artwork.stroked)
        bitmap.strokePath()
        if let head = artwork.head {
            bitmap.setFillColor(colour)
            bitmap.addPath(head)
            bitmap.fillPath()
        }

        guard let image = bitmap.makeImage() else { return nil }
        return CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(translationX: canvas.x, y: canvas.y))
    }

    /// Guards `annotationCache` only; the cursor's canvases have their own lock because the two
    /// are taken in different places and a shared one would serialise a cursor draw behind an
    /// annotation draw for no reason.
    private let annotationCacheLock = NSLock()
    /// Every access runs inside `annotationCacheLock.withLock`, which the compiler cannot see —
    /// which is what the `unsafe` marks at each access say.
    private nonisolated(unsafe) var annotationCache: [AnnotationOverlay: CIImage] = [:]

    /// One `CGContext` bitmap per pixel size, reused across frames. The lock guards the dictionary
    /// and every draw into a bitmap it hands back, since same-size callers share one, so it is held
    /// across the whole fetch-clear-draw-makeImage sequence.
    private nonisolated let cursorCanvasLock = NSLock()
    private nonisolated(unsafe) var cursorCanvases: [Int: CGContext] = [:]

    /// Where the drawn art's own path origin sits inside its bounding box, as a fraction
    /// with a TOP-LEFT origin so it is directly comparable with `NSCursor.hotSpot`.
    /// `CursorArt.pointerPath` builds the arrow around its TIP, which is the box's top-left
    /// corner — so a recorded hotspot of (0, 0) means "already correct" and needs no offset.
    private static let artOriginFraction = (x: 0.0, y: 0.0)

    /// Headroom in output pixels beyond the pointer/ripple extent, so an antialiased stroke is
    /// never clipped at the bitmap edge.
    private static let cursorCanvasPadding: Double = 6

    /// `pointerPath`'s uniform scale from the output height: `1.0` at 1080p, proportional above,
    /// never below `1.0`.
    private static func pointerScale(forOutputHeight height: Int) -> Double {
        max(1, Double(height) / 1080)
    }

    /// The cleared `size`×`size` bitmap, built on first use. Must be called only from inside
    /// `cursorCanvasLock.withLock`.
    private func cursorCanvas(size: Int) -> CGContext? {
        if let existing = unsafe cursorCanvases[size] {
            existing.clear(HeadlessGeometryBridge.outputCanvas(width: size, height: size))
            return existing
        }
        // `data: nil`: CGContext owns its backing store and no raw pointer is read here.
        guard let created = unsafe CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        unsafe cursorCanvases[size] = created
        return created
    }

    /// The camera's frame, cropped to fill its own rectangle, masked to its shape and ringed.
    ///
    /// **Cropped to FILL, never letterboxed.** A 4:3 camera in a circle or a 16:9 slot has to
    /// lose some of its edges; showing bars instead would put two black stripes on the person's
    /// face, which is the one place on the stage a viewer is looking.
    private func cameraImage(_ overlay: CameraOverlay, buffer: CVPixelBuffer,
                             plan: RenderPlan) -> CIImage {
        let image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return CIImage.empty() }
        let style = overlay.style
        let box = style.rect(inOutputWidth: plan.outputWidth, outputHeight: plan.outputHeight,
                             sourceAspect: Double(extent.width) / Double(extent.height),
                             // The stage's zoom for this frame: a camera that held its full width
                             // while the picture zoomed in would be covering a larger share of a
                             // smaller area, which is exactly when it is most in the way.
                             contentZoom: plan.contentZoom)

        // **The room is cut away here, before anything else touches the frame.** Vision analysed
        // this exact buffer, so its mask is in this buffer's orientation and at this buffer's
        // size; mirroring or scaling first would mean transforming the mask to match, which is
        // one more chance to get a geometry wrong for no gain at all.
        //
        // The level is chosen from how wide the card will be drawn — `PersonMask` will not
        // upscale its own mask if it can avoid it — which is why `box` is computed above this
        // rather than below it.
        //
        // **A refusal draws the camera unchanged.** Somebody leaning out of frame is a refusal,
        // and blanking the card for as long as they are gone would be a far worse answer than
        // showing the room for a moment.
        var source = image
        var isCutOut = false
        if style.background == .removed {
            let quality = PersonMask.quality(forCardWidthInPixels: box.width)
            if case .cutOut(let cut) = PersonMask.cutOut(image, from: buffer, quality: quality) {
                source = cut
                isCutOut = true
            }
        }

        var placed = source
        if style.isMirrored {
            // Flipped about the frame's own centre before it is scaled, so the mirror does not
            // also move it — a scale and a flip do not commute about the origin.
            placed = placed.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                .concatenating(CGAffineTransform(translationX: extent.width, y: 0)))
        }
        let scale = max(box.width / Double(extent.width), box.height / Double(extent.height))
        placed = placed.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centred = placed.transformed(by: CGAffineTransform(
            translationX: box.x + (box.width - Double(placed.extent.width)) / 2
                - Double(placed.extent.minX),
            y: box.y + (box.height - Double(placed.extent.height)) / 2
                - Double(placed.extent.minY)))
        let cropped = centred.cropped(to: HeadlessGeometryBridge.rect(
            x: box.x, y: box.y, width: box.width, height: box.height))

        // **A cut-out person has no card, so it gets no shape, no ring and no shadow.** Rounding
        // the corners of a silhouette rounds nothing — the corners are already transparent — and
        // a ring drawn around where the card would have been would draw a circle in mid-air
        // beside somebody's shoulder. This is the one branch where `shape`, `borderOpacity` and
        // `shadowOpacity` are deliberately ignored rather than honoured; the values are kept in
        // the style so that switching the background back restores the card exactly.
        guard !isCutOut else { return cropped }

        let radius: Double = switch style.shape {
        case .circle: min(box.width, box.height) / 2
        case .rounded: box.width * style.cornerFraction
        case .square: 0
        }
        guard radius > 0 else { return ringed(cropped, box: box, radius: 0, style: style) }
        // The same rounded-rectangle generator the card's own mask uses, so a circular camera
        // and a rounded card are the same shape family rather than two approximations of one.
        guard let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(x: box.x, y: box.y, z: box.width, w: box.height),
            "inputRadius": radius,
            "inputColor": CIColor.white,
        ])?.outputImage else { return ringed(cropped, box: box, radius: radius, style: style) }
        let masked = cropped.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: mask,
            kCIInputBackgroundImageKey: CIImage.empty(),
        ])
        return ringed(masked, box: box, radius: radius, style: style)
    }

    /// The camera with its ring and its shadow. **A ring, because without one a camera over a
    /// light screenshot has no edge at all** — which is what makes an overlay look pasted on.
    private func ringed(_ image: CIImage,
                        box: (x: Double, y: Double, width: Double, height: Double),
                        radius: Double, style: CameraOverlayStyle) -> CIImage {
        var result = image
        if style.shadowOpacity > 0,
           let silhouette = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
               "inputExtent": CIVector(x: box.x, y: box.y, z: box.width, w: box.height),
               "inputRadius": radius,
               "inputColor": CIColor(red: 0, green: 0, blue: 0, alpha: style.shadowOpacity),
           ])?.outputImage {
            result = result.composited(
                over: silhouette.applyingGaussianBlur(sigma: box.width * 0.06))
        }
        guard style.borderOpacity > 0 else { return result }
        // The ring is the difference between the shape and a slightly smaller one — a stroke
        // filter would need a path, and this generator makes shapes rather than paths.
        let inset = max(box.width * 0.006, 1)
        guard let outer = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                  "inputExtent": CIVector(x: box.x, y: box.y, z: box.width, w: box.height),
                  "inputRadius": radius,
                  "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: style.borderOpacity),
              ])?.outputImage,
              let inner = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                  "inputExtent": CIVector(x: box.x + inset, y: box.y + inset,
                                          z: box.width - inset * 2, w: box.height - inset * 2),
                  "inputRadius": max(radius - inset, 0),
                  "inputColor": CIColor.white,
              ])?.outputImage
        else { return result }
        // **This drew nothing until 2026-08-26, and it was measured rather than noticed.** The
        // construction was `CIBlendWithMask` over `CIImage.empty()`, which has ZERO extent: the
        // blend had nowhere to composite into and the pass evaporated silently, so the camera's
        // border has never appeared in any build. Found while giving the CARD the same edge and
        // probing across it — every pixel identical with the border on and off. Source-out is
        // the ring stated directly: the outer shape wherever the inner one is not.
        let ring = outer.applyingFilter("CISourceOutCompositing", parameters: [
            kCIInputBackgroundImageKey: inner,
        ])
        return ring.composited(over: result)
    }

    /// The pointer art for one placement, translated to its output-pixel position. Returns an empty
    /// image if the bitmap could not be created, so a hiccup loses the pointer, not the frame.
    /// `cursorCanvasLock` is never held across the caller's GPU render.
    private func cursorImage(for placement: NormalizedPointerPlacement, outputHeight: Int,
                             style: CursorStyle) -> CIImage {
        // The chosen scale multiplies the density scale rather than replacing it: the second is
        // about the export's pixels and the first is about how big a person wants the cursor.
        let scale = Self.pointerScale(forOutputHeight: outputHeight) * style.scale
        let halfExtent = max(CursorArt.rippleEndRadius * style.clickSize,
                             scale * CursorArt.pointerMaxExtent)
            + Self.cursorCanvasPadding
        let size = Int((halfExtent * 2).rounded(.up))
        // The tip, the origin both paths are built around, sits at the canvas centre.
        let tip = Double(size) / 2

        // Faded out entirely: nothing to draw, and no bitmap work to do it with.
        guard placement.opacity > 0 else { return CIImage.empty() }
        let image = cursorCanvasLock.withLock { () -> CGImage? in
            guard let bitmap = cursorCanvas(size: size) else { return nil }
            bitmap.saveGState()
            bitmap.translateBy(x: tip, y: tip)
            // The lean, about the hotspot: the art is built around its origin, so a rotation
            // here pivots the tip and swings the body — the way a real cursor's body trails.
            // Negative because Core Graphics rotates counter-clockwise for a positive angle
            // and a lean to the RIGHT is clockwise.
            if placement.tiltDegrees != 0 {
                bitmap.rotate(by: -placement.tiltDegrees * .pi / 180)
            }
            bitmap.setAlpha(placement.opacity)

            bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            bitmap.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            bitmap.setLineWidth(1.5)
            // Every case named, no `default`: a new `PointerShape` is a compile error here,
            // so its art (or its explicit fallback) is a decision rather than an accident.
            // `nil` is "unrecorded" and `.other` is "recorded, unnamed" — both draw the
            // arrow by design (`PointerShape`'s own doc); the review UI tells them apart.
            let art: CGPath
            switch placement.shape {
            case .iBeam:
                art = CursorArt.iBeamPath(scale: scale)
            case .arrow, .other, nil:
                art = CursorArt.pointerPath(scale: scale)
            case .pointingHand:
                art = CursorArt.pointingHandPath(scale: scale)
            case .crosshair:
                art = CursorArt.crosshairPath(scale: scale)
            case .resizeLeftRight:
                art = CursorArt.resizeLeftRightPath(scale: scale)
            case .resizeUpDown:
                art = CursorArt.resizeUpDownPath(scale: scale)
            }
            bitmap.addPath(art)
            bitmap.drawPath(using: .fillStroke)

            // `ripplePhase == nil` means "not clicking", so nothing is drawn.
            if let phase = placement.ripplePhase, style.clickEffect != .none {
                let fade = (1 - min(max(phase, 0), 1)) * style.clickOpacity
                bitmap.addPath(CursorArt.ripplePath(phase: phase, size: style.clickSize))
                switch style.clickEffect {
                case .ripple:
                    bitmap.setStrokeColor(CGColor(red: style.red, green: style.green,
                                                  blue: style.blue, alpha: fade))
                    bitmap.setLineWidth(2 * style.clickSize)
                    bitmap.strokePath()
                case .pulse:
                    // **A filled disc, at a lower alpha than the ring.** A fill at the ring's
                    // opacity covers what was clicked, which is the thing a viewer is looking
                    // at; halved, it reads as a highlight rather than a lid.
                    bitmap.setFillColor(CGColor(red: style.red, green: style.green,
                                                blue: style.blue, alpha: fade * 0.5))
                    bitmap.fillPath()
                case .none:
                    break
                }
            }
            bitmap.restoreGState()
            return bitmap.makeImage()
        }
        guard let image else { return CIImage.empty() }
        // **No hotspot offset, and removing one was the repair.**
        //
        // `CursorArt`'s paths are built around their HOTSPOT at the origin — the arrow's tip,
        // the I-beam's centre; its own header says so. Drawing that origin at the recorded
        // position is therefore already correct, and nothing needs to move it.
        //
        // An earlier version shifted the art by `placement.hotspot`, which is the hotspot of
        // the SYSTEM cursor's IMAGE — a different picture with different padding. That
        // measurement was taken from one live cursor reading of (0.52, 0.50), its image's
        // centre, and generalised. Applied to art whose origin is already the hotspot it
        // moved a correct placement by half a cursor, every frame. Anything that draws art
        // (Apache 2.0) draws its own cursor art too and derives each hotspot from its own
        // design coordinates — the arrow's tip at (1.5, 1.0) in a 17×25 space — never from
        // the system image, for exactly this reason.
        //
        // `hotspot` is still RECORDED. It is the right value for a renderer that draws the
        // system image, which is what a real cursor-shape table would enable; it is simply
        // not the right value for this one.
        var drawn = CIImage(cgImage: image)
        // **Smeared unclamped, and cropped to nothing** — the opposite of the card's blur.
        // The card is clamped and cropped because its edge must stay solid; a cursor's smear
        // is meant to trail off into nothing at both ends, which is what reading transparent
        // past the bitmap's edge gives. The extent grows past the canvas and the composite
        // draws the overhang, so the trail is not clipped to the arrow's own box.
        if placement.smearRadius > 0,
           let filter = CIFilter(name: "CIMotionBlur", parameters: [
               kCIInputImageKey: drawn,
               kCIInputRadiusKey: placement.smearRadius,
               kCIInputAngleKey: placement.smearAngle,
           ]), let output = filter.outputImage {
            drawn = output
        }
        // **The press, applied to the finished image rather than to the art's own scale.**
        // The bitmap is cached by pixel size (`cursorCanvas(size:)`); folding a per-frame
        // multiplier into that size would mint a canvas per frame of every click and defeat
        // the cache entirely. A transform on the CIImage costs nothing and composites the same.
        //
        // **About the HOTSPOT, which is why the translate below changes with it.** The art is
        // built around its hotspot at the canvas's centre point `tip`, so after scaling by `p`
        // about the origin that hotspot sits at `tip × p` — and it is the hotspot, not the
        // bitmap's corner, that has to land on the recorded position. Scaling about the origin
        // and translating by the unscaled `tip` would walk the cursor toward the frame's corner
        // by a few points on every click.
        let press = placement.pressScale
        let scaled = press == 1 ? drawn
                                : drawn.transformed(by: CGAffineTransform(scaleX: press, y: press))
        return scaled
            .transformed(by: CGAffineTransform(translationX: placement.x - tip * press,
                                               y: placement.y - tip * press))
    }
}
