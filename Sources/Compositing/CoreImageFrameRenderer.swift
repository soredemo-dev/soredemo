import CoreImage
import CoreVideo
import Foundation
// `CursorArt` and `HeadlessGeometryBridge` are same-module names and need no import.
import Metal
import Render

/// A `FrameRendering` implementation on Core Image over a Metal-backed context.
///
/// `StageStyle.shadowRadius`/`.shadowOpacity` are modelled and persisted but never read here: this
/// renderer draws no shadow.
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
        var composed = card.composited(over: background)
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
        }
    }

    private func cardImage(_ plan: RenderPlan, source: CVPixelBuffer) -> CIImage {
        let image = CIImage(cvPixelBuffer: source)
        let scaleX = plan.card.width / image.extent.width
        let scaleY = plan.card.height / image.extent.height
        let placed = image
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: plan.card.x, y: plan.card.y))
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
            bitmap.addPath(CursorArt.pointerPath(scale: scale))
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
        return CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(translationX: placement.x - tip, y: placement.y - tip))
    }
}
