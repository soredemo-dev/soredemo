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
        composed = card.composited(over: composed)
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
            return covering(image, width: Double(plan.outputWidth),
                            height: Double(plan.outputHeight))
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
        return output
    }

    /// The card's own silhouette — same rect, same corner radius — filled black at
    /// `shadowOpacity` and gaussian-blurred. `nil` when either knob is zero, so a
    /// shadowless style costs no filter pass at all (`aZeroOpacityShadowChangesNothing`).
    /// Sigma is `shadowRadius / 2`: the style's radius names the visual reach, and a
    /// gaussian at sigma s is visually spent by ~2s.
    private func shadowImage(_ plan: RenderPlan) -> CIImage? {
        let opacity = plan.style.shadowOpacity
        let radius = plan.style.shadowRadius
        guard opacity > 0, radius > 0 else { return nil }
        guard let silhouette = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(x: plan.card.x, y: plan.card.y,
                                    z: plan.card.width, w: plan.card.height),
            "inputRadius": plan.cornerRadius,
            "inputColor": CIColor(red: 0, green: 0, blue: 0, alpha: opacity),
        ])?.outputImage else { return nil }
        return silhouette.applyingGaussianBlur(sigma: radius / 2)
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

        var placed = image
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
        let ring = outer.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: inner.applyingFilter("CIColorInvert"),
            kCIInputBackgroundImageKey: CIImage.empty(),
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
            case .pointingHand, .crosshair, .resizeLeftRight, .resizeUpDown:
                // No art yet — falls back to the arrow, DISCLOSED in the parity design
                // doc rather than silently: the shape is still recorded, so drawing can
                // improve without touching capture.
                art = CursorArt.pointerPath(scale: scale)
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
        // moved a correct placement by half a cursor, every frame. `../opensource/a Swift recorder`
        // (Apache 2.0) draws its own cursor art too and derives each hotspot from its own
        // design coordinates — the arrow's tip at (1.5, 1.0) in a 17×25 space — never from
        // the system image, for exactly this reason.
        //
        // `hotspot` is still RECORDED. It is the right value for a renderer that draws the
        // system image, which is what a real cursor-shape table would enable; it is simply
        // not the right value for this one.
        return CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(translationX: placement.x - tip,
                                               y: placement.y - tip))
    }
}
