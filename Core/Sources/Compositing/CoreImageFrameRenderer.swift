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

    public func render(_ plan: RenderPlan, source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        let background = backgroundImage(plan)
        let card = cardImage(plan, source: source)
        var composed = background
        if let shadow = shadowImage(plan) {
            composed = shadow.composited(over: composed)
        }
        composed = card.composited(over: composed)
        // Whether to draw a pointer is `StageCompositor`'s decision, not this file's.
        if let pointer = plan.pointer {
            composed = cursorImage(for: pointer, outputHeight: plan.outputHeight).composited(over: composed)
        }
        // Rule 5 confines `CGRect`/`CGFloat` to the bridge file, so no literal `CGRect` here.
        let cropped = composed
            .cropped(to: HeadlessGeometryBridge.outputCanvas(width: plan.outputWidth, height: plan.outputHeight))
        context.render(cropped, to: destination,
                       bounds: cropped.extent,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    private func backgroundImage(_ plan: RenderPlan) -> CIImage {
        switch plan.style.background {
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
        let image = CIImage(cvPixelBuffer: source)
        // The camera scales and shifts the CONTENT; `rounded` then masks it to the card,
        // which never moves. `RenderPlan.contentX/Y` owns the mapping so the pointer and
        // the image cannot disagree about where a normalised point lands.
        let scaleX = plan.card.width * plan.contentZoom / image.extent.width
        let scaleY = plan.card.height * plan.contentZoom / image.extent.height
        let originX = plan.contentX(ofNormalised: 0)
        let originY = plan.contentY(ofNormalised: 0)
        let placed = image
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: originX, y: originY))
        return rounded(placed, plan: plan)
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

    /// The pointer art for one placement, translated to its output-pixel position. Returns an empty
    /// image if the bitmap could not be created, so a hiccup loses the pointer, not the frame.
    /// `cursorCanvasLock` is never held across the caller's GPU render.
    private func cursorImage(for placement: NormalizedPointerPlacement, outputHeight: Int) -> CIImage {
        let scale = Self.pointerScale(forOutputHeight: outputHeight)
        let halfExtent = max(CursorArt.rippleEndRadius, scale * CursorArt.pointerMaxExtent)
            + Self.cursorCanvasPadding
        let size = Int((halfExtent * 2).rounded(.up))
        // The tip, the origin both paths are built around, sits at the canvas centre.
        let tip = Double(size) / 2

        let image = cursorCanvasLock.withLock { () -> CGImage? in
            guard let bitmap = cursorCanvas(size: size) else { return nil }
            bitmap.saveGState()
            bitmap.translateBy(x: tip, y: tip)

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

            // `ripplePhase == nil` means "not clicking", so no ring is drawn.
            if let phase = placement.ripplePhase {
                bitmap.addPath(CursorArt.ripplePath(phase: phase))
                bitmap.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1 - min(max(phase, 0), 1)))
                bitmap.setLineWidth(2)
                bitmap.strokePath()
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
