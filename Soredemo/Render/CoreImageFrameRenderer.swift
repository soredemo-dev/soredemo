import CoreImage
import CoreVideo
import Foundation
import Metal
import Render

/// Today's implementation: Core Image on a Metal-backed context.
///
/// Chosen first because the card, shadow and corner radius are three built-in filters and one
/// composite. It is **not** chosen permanently — the alternative is a hand-written Metal pass, and
/// the decision belongs to a measured 4K frame time. Both sit behind `FrameRendering`, which is why
/// that measurement can still change the answer when it arrives.
nonisolated final class CoreImageFrameRenderer: FrameRendering {
    private let context: CIContext

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw FrameRenderingError.noRenderDevice
        }
        // `.workingColorSpace` pinned, not defaulted: uncontrolled colour handling is the failure
        // that cost this project an evening, and a default is a value nobody chose.
        context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
    }

    func render(_ plan: RenderPlan, source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        let background = backgroundImage(plan)
        let card = cardImage(plan, source: source)
        // `CGGeometryBridge.outputCanvas`, not a literal `CGRect(...)` here: rule 5
        // (`AppSourceAllowListTests.coreGraphicsGeometryTypesAppearOnlyInTheBridge`) confines
        // `CGRect`/`CGFloat` to that one file, and `CIImage.cropped(to:)` is the exit point where
        // this app's own `Int`s become CoreGraphics' unit for Core Image. See the bridge's own doc
        // comment on `outputCanvas` for why this was a correction to the task brief.
        let composed = card.composited(over: background)
            .cropped(to: CGGeometryBridge.outputCanvas(width: plan.outputWidth, height: plan.outputHeight))
        context.render(composed, to: destination,
                       bounds: composed.extent,
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

    /// Rounded corners as a mask, not as a crop: a crop gives square corners and a mask gives the
    /// radius the plan asked for.
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
}
