import CoreGraphics
import CoreText
import Foundation

/// The render tier's CoreGraphics exit, and the only file in `Sources/Headless` allowed to name
/// `CGRect`, `CGPoint`, `CGSize` or `CGFloat`. The app tier has its own bridge, and a test forbids
/// the two from sharing a function signature.
nonisolated enum HeadlessGeometryBridge {
    /// The `CGRect` `CIImage.cropped(to:)` needs; scalars in, because the output canvas has an
    /// extent but no position.
    public nonisolated static func outputCanvas(width: Int, height: Int) -> CGRect {
        CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    }

    /// The `CGSize` `AVVideoComposition.Configuration.renderSize` needs, from the plain `Int`s
    /// `CompositionBuilder` holds.
    public nonisolated static func renderSize(width: Int, height: Int) -> CGSize {
        CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    /// The rounded plate a caption is drawn on. A path rather than a rect, because a rect
    /// crossing this boundary would be a `CGRect` at the call site, which is the thing the
    /// boundary exists to prevent.
    ///
    /// **One line per declaration, deliberately.** `theTwoGeometryBridgesShareNoFunctionSignature`
    /// parses declarations with a line scan and requires every one of them to be visible to it;
    /// a parameter list wrapped onto a second line is a hole in the disjointness check rather
    /// than a failure of it, and the check says so itself.
    public nonisolated static func roundedPlate(x: Double, y: Double, width: Double, height: Double, cornerRadius: Double) -> CGPath {
        // `unsafe` for `transform:`, which is an `UnsafePointer<CGAffineTransform>?`. `nil` is
        // the only value passed and no pointer is formed or read.
        unsafe CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerWidth: min(cornerRadius, width / 2), cornerHeight: min(cornerRadius, height / 2), transform: nil)
    }

    /// One pixel's worth of rect, for a test sampling a rendered image.
    public nonisolated static func pixel(x: Int, y: Int) -> CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)
    }

    /// The positioned `CGRect` `CIImage.cropped(to:)` needs — `outputCanvas` deliberately has no
    /// position, and a redaction is nothing but a position.
    public nonisolated static func rect(x: Double, y: Double, width: Double, height: Double) -> CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// The zero `CGSize` `CGContext.setShadow` needs for an offsetless shadow.
    public nonisolated static func noOffset() -> CGSize { CGSize(width: 0, height: 0) }

    /// `CTLineGetTypographicBounds`' three out-parameters as plain `Double`s: the call needs
    /// `inout CGFloat`, which nothing outside this file may name.
    public nonisolated static func typographicBounds(of line: CTLine) -> (width: Double, ascent: Double, descent: Double) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = unsafe CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        return (Double(width), Double(ascent), Double(descent))
    }

    /// The `CGPoint` every `CGMutablePath` call in `CursorArt` takes, from plain `Double`s.
    public nonisolated static func point(x: Double, y: Double) -> CGPoint {
        CGPoint(x: x, y: y)
    }
}
