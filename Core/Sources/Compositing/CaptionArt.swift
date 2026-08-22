import CoreGraphics
import CoreImage
import CoreText
import Foundation
import Render

/// Drawing a caption, and measuring one.
///
/// **Measuring and drawing are the same code path on purpose.** `CaptionBuilder` breaks a line
/// when a caller's `fits` says it does not fit; if that measurement came from anywhere other
/// than the thing that later draws the line, the breaks would be computed against one font and
/// rendered in another — and the failure looks like captions that overflow only sometimes, at
/// only some export sizes. `width(of:style:outputHeight:)` is what a caller's `fits` must use.
public enum CaptionArt {
    /// Padding around the text inside its plate, as a fraction of the type size. Horizontal is
    /// larger than vertical because a plate that hugs the text sideways reads as clipped.
    static let horizontalPaddingRatio = 0.7
    static let verticalPaddingRatio = 0.32

    /// The system UI font at the style's size for this output — one place, so the measurement
    /// and the drawing cannot pick different faces.
    ///
    /// `CTFontCreateUIFontForLanguage(.system, …)` rather than a font named as a string: a name
    /// that is not installed silently falls back to Helvetica, which is a different width, and
    /// the caption then overflows on exactly the machines that lack the font.
    static func font(_ style: CaptionStyle, outputHeight: Int) -> CTFont {
        // `Double` straight in: Swift converts to `CGFloat` implicitly (SE-0307), so the type
        // is never named here — rule 5 bans the NAME, and an implicit conversion writes none.
        let size = style.pointSize(forOutputHeight: outputHeight)
        return CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private static func line(_ text: String, style: CaptionStyle, outputHeight: Int) -> CTLine {
        // `kCTFontAttributeName`, not `.font`: that key is AppKit's, and `HeadlessCheck` bans
        // AppKit in this target. Core Text reads its own key regardless of who set it.
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String):
                font(style, outputHeight: outputHeight),
        ])
        return CTLineCreateWithAttributedString(attributed as CFAttributedString)
    }

    /// How wide this text draws, in output pixels, including the plate's padding. What a caller
    /// compares against `CaptionStyle.maximumWidth(forOutputWidth:)`.
    public static func width(of text: String, style: CaptionStyle, outputHeight: Int) -> Double {
        guard !text.isEmpty else { return 0 }
        let bounds = HeadlessGeometryBridge.typographicBounds(
            of: line(text, style: style, outputHeight: outputHeight))
        let padding = style.pointSize(forOutputHeight: outputHeight) * horizontalPaddingRatio * 2
        return bounds.width + padding
    }

    /// A `fits` closure for `CaptionBuilder`, bound to one output size and style. The seam that
    /// keeps breaking and drawing agreeing — see the header.
    public static func fits(style: CaptionStyle, outputWidth: Int, outputHeight: Int)
    -> @Sendable (String) -> Bool {
        let limit = style.maximumWidth(forOutputWidth: outputWidth)
        return { text in width(of: text, style: style, outputHeight: outputHeight) <= limit }
    }

    /// The caption as an image the size of the whole frame, positioned by the style, or `nil`
    /// when there is nothing to draw or the bitmap could not be made.
    ///
    /// Frame-sized rather than text-sized-and-translated: a `CIImage` composited at an offset
    /// needs its own transform, and the caption's position is a property of the frame anyway.
    /// The cost is one full-size bitmap per distinct caption, which the caller caches.
    public static func image(_ overlay: CaptionOverlay,
                             outputWidth: Int, outputHeight: Int) -> CIImage? {
        let text = overlay.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, outputWidth > 0, outputHeight > 0 else { return nil }

        let style = overlay.style
        let size = style.pointSize(forOutputHeight: outputHeight)
        let drawn = line(text, style: style, outputHeight: outputHeight)
        let bounds = HeadlessGeometryBridge.typographicBounds(of: drawn)

        let horizontalPadding = size * horizontalPaddingRatio
        let verticalPadding = size * verticalPaddingRatio
        let plateWidth = bounds.width + horizontalPadding * 2
        let plateHeight = bounds.ascent + bounds.descent + verticalPadding * 2
        // CoreGraphics' origin is bottom-left and so is the frame's, so the inset is measured
        // from y = 0 directly — no flip, which is where an upside-down caption comes from.
        let plateX = (Double(outputWidth) - plateWidth) / 2
        let plateY = Double(outputHeight) * style.bottomInsetFraction

        // `data: nil`: CGContext owns its backing store and no raw pointer is read here.
        guard let bitmap = unsafe CGContext(
            data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        if style.backgroundOpacity > 0 {
            bitmap.addPath(HeadlessGeometryBridge.roundedPlate(
                x: plateX, y: plateY, width: plateWidth, height: plateHeight,
                cornerRadius: Double(outputHeight) * style.backgroundCornerFraction))
            bitmap.setFillColor(CGColor(red: 0, green: 0, blue: 0,
                                        alpha: style.backgroundOpacity))
            bitmap.fillPath()
        }

        bitmap.setFillColor(CGColor(red: style.red, green: style.green, blue: style.blue,
                                    alpha: 1))
        // The baseline sits `descent + padding` above the plate's bottom edge, which is what
        // puts a descender inside the plate rather than through its lower edge.
        bitmap.textPosition = HeadlessGeometryBridge.point(
            x: plateX + horizontalPadding, y: plateY + verticalPadding + bounds.descent)
        CTLineDraw(drawn, bitmap)

        guard let image = bitmap.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }
}
