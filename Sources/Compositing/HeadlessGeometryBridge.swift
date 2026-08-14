import CoreGraphics
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

    /// The `CGPoint` every `CGMutablePath` call in `CursorArt` takes, from plain `Double`s.
    public nonisolated static func point(x: Double, y: Double) -> CGPoint {
        CGPoint(x: x, y: y)
    }
}
