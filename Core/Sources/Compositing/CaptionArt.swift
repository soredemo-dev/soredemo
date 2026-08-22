import CoreImage
import Foundation
import Render

/// A caption, as a piece of text.
///
/// **An adapter over `TextArt`, not a second renderer.** A caption IS text: centred, at the
/// bottom, on a black plate. Two renderers laying text out the same way diverge — the plate
/// padding gets tuned in one and not the other, and nobody notices until a screenshot puts them
/// side by side. `CaptionStyle.asTextStyle` is the conversion and it lives beside the style.
///
/// This file stays because the caption path has one thing titles do not: `fits`, which is the
/// seam that keeps `CaptionBuilder`'s line breaking measuring the same font the renderer draws.
public enum CaptionArt {
    /// How wide this text draws, in output pixels, including the plate's padding. What a caller
    /// compares against `CaptionStyle.maximumWidth(forOutputWidth:)`.
    public static func width(of text: String, style: CaptionStyle, outputHeight: Int) -> Double {
        TextArt.width(of: text, pointSize: style.pointSize(forOutputHeight: outputHeight),
                      bold: false)
    }

    /// A `fits` closure for `CaptionBuilder`, bound to one output size and style — the seam that
    /// keeps breaking and drawing agreeing.
    public static func fits(style: CaptionStyle, outputWidth: Int, outputHeight: Int)
    -> @Sendable (String) -> Bool {
        let limit = style.maximumWidth(forOutputWidth: outputWidth)
        return { text in width(of: text, style: style, outputHeight: outputHeight) <= limit }
    }

    /// The caption as an image the size of the whole frame, positioned by the style.
    public static func image(_ overlay: CaptionOverlay,
                             outputWidth: Int, outputHeight: Int) -> CIImage? {
        TextArt.image(TextOverlay(text: overlay.text, style: overlay.style.asTextStyle),
                      outputWidth: outputWidth, outputHeight: outputHeight)
    }
}
