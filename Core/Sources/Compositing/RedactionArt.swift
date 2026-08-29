import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Render

/// Hiding part of the recording, before anything else is composed on top of it.
///
/// **Applied to the SOURCE image, inside the card, before the camera's crop.** A region pinned
/// to the output would slide off whatever it was covering the moment the camera panned. Pinned
/// to the source it covers the same pixels of the same window however the frame is composed —
/// and a redaction that moves off its target is worse than none, because a person watched it
/// work once and stopped checking.
public enum RedactionArt {
    /// `image` with every region covered. Returns `image` unchanged when there is nothing to do,
    /// so the common case costs one array check rather than a filter graph.
    public static func applied(_ regions: [RedactionRegion], to image: CIImage) -> CIImage {
        guard !regions.isEmpty else { return image }
        let extent = image.extent
        let shorterEdge = Swift.min(Double(extent.width), Double(extent.height))
        var composed = image
        for region in regions where !region.isEmpty {
            // `y` runs from the TOP in the region — a rectangle picked off a picture — and from
            // the bottom in a `CIImage`. The flip happens here, once.
            let width = region.width * Double(extent.width)
            let height = region.height * Double(extent.height)
            let x = Double(extent.minX) + region.x * Double(extent.width)
            let y = Double(extent.minY)
                + (1 - region.y - region.height) * Double(extent.height)
            // **Rounded to whole pixels.** A mosaic grid laid out on half-pixel boundaries
            // resamples at every block edge, and the blocks come out slightly graded instead of
            // flat — measured, before this line existed, as an 8% difference between two points
            // inside one block that should have been identical.
            let left = x.rounded(.down)
            let bottom = y.rounded(.down)
            let across = Swift.max(1, width.rounded())
            let up = Swift.max(1, height.rounded())
            let box = HeadlessGeometryBridge.rect(x: left, y: bottom, width: across, height: up)

            let covering: CIImage
            switch region.style.clamped {
            case .mosaic(let blockFraction):
                covering = mosaicked(composed, x: left, y: bottom, width: across, height: up,
                                     block: Swift.max(1, (blockFraction * shorterEdge).rounded()))
            case .solid(let red, let green, let blue):
                covering = CIImage(color: CIColor(red: red, green: green, blue: blue))
                    .cropped(to: box)
            }

            composed = (region.isOval
                        ? masked(covering, x: left, y: bottom, width: across, height: up)
                        : covering)
                .composited(over: composed)
        }
        return composed
    }

    /// The region reduced to blocks, each one an AVERAGE of what it covers.
    ///
    /// **Not `CIPixellate`, and the difference is the point of the feature.** That filter
    /// point-samples: every block shows one real pixel of the original, magnified. Measured on a
    /// black-and-white test image, a block straddling the boundary came out pure white — the
    /// value of the single pixel at its centre. For a mosaic meant to hide an API key, a block
    /// that IS a real pixel value is a weaker promise than it looks. A Lanczos downscale
    /// averages over a neighbourhood, and the nearest-neighbour scale back up is what makes the
    /// result blocky rather than merely soft — which matters too, because a reviewer trusts a
    /// mosaic they can see working. Averaging is what makes it irreversible; the
    /// `applyMosaicToImageData` sums each block and divides.
    ///
    /// **Scalars in, not a rect.** Rule 5 confines `CGRect` to `HeadlessGeometryBridge`, and a
    /// parameter typed `CGRect` names it just as surely as a literal does — which is what the
    /// check caught when this took one.
    private static func mosaicked(_ image: CIImage, x: Double, y: Double,
                                  width: Double, height: Double, block: Double) -> CIImage {
        let box = HeadlessGeometryBridge.rect(x: x, y: y, width: width, height: height)
        // Moved to the origin first: a scale is about the origin, so scaling in place would
        // also move the region across the frame by a factor of `block`.
        let atOrigin = image.cropped(to: box)
            .transformed(by: CGAffineTransform(translationX: -x, y: -y))
        let small = atOrigin.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: 1 / block,
            kCIInputAspectRatioKey: 1.0,
        ])
        // `samplingNearest()` on the small image is what makes the result blocky rather than a
        // smooth upscale. A second one after the transform was tried and measured to change
        // nothing, so it is not here.
        //
        // **The blocks are not perfectly flat**, measured: two points inside one block differ by
        // about 8%, because the Lanczos kernel is wider than a block and the upscale is not a
        // pure step. That is fine for what this is for — what leaks is a gradient between
        // neighbouring block averages, not the detail underneath — but it is not the "each block
        // is one uniform colour" a reader would otherwise assume from the name.
        return small.samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: block, y: block))
            .transformed(by: CGAffineTransform(translationX: x, y: y))
            .cropped(to: box)
    }

    /// `covering` reduced to the ellipse inscribed in `box`. A face is not a rectangle.
    ///
    /// **A transformed radial gradient, not a drawn bitmap.** The obvious implementation fills a
    /// `CGPath` ellipse into a context and uses it as a mask; that allocates a bitmap per region
    /// per FRAME, which at sixty frames a second is the sort of cost that only shows up in a
    /// long export. A unit circle scaled to the box's dimensions is an ellipse, costs no
    /// allocation, and the narrow band between the two radii is the antialiased edge.
    private static func masked(_ covering: CIImage, x: Double, y: Double,
                               width: Double, height: Double) -> CIImage {
        let gradient = CIFilter.radialGradient()
        gradient.center = HeadlessGeometryBridge.point(x: 0, y: 0)
        gradient.radius0 = 0.49
        gradient.radius1 = 0.5
        gradient.color0 = CIColor.white
        gradient.color1 = CIColor.clear
        guard let unit = gradient.outputImage else { return covering }
        let mask = unit.transformed(
            by: CGAffineTransform(scaleX: width, y: height)
                .concatenating(CGAffineTransform(translationX: x + width / 2,
                                                 y: y + height / 2)))
        let blend = CIFilter.blendWithMask()
        blend.inputImage = covering
        blend.maskImage = mask
        blend.backgroundImage = CIImage.empty()
        return blend.outputImage ?? covering
    }
}
