import Foundation

/// The one place in this codebase where the Y axis flips. Converts raw pixels for a
/// single display into normalised, revision-tagged coordinates, and back.
///
/// Every input to `normalize` must be display-local top-left pixels: a global point
/// must first pass through `DisplayArrangement.route` (which yields display-local
/// points) and then `DisplayGeometry.pixels(from:)`. Skipping either step yields a
/// plausible-looking result with no error raised. The flip anchors on the rect's
/// bottom edge: `y` is `1 - ((topLeftY + height) / pixelHeight)`.
public struct NormalizationContext: Sendable {
    /// The display this context normalises against. Its `revision` is stamped onto
    /// every frame produced and checked on every frame passed to `denormalize`.
    public let geometry: DisplayGeometry

    public init(geometry: DisplayGeometry) {
        self.geometry = geometry
    }

    private var pixelWidth: Double { Double(geometry.pixelWidth) }
    private var pixelHeight: Double { Double(geometry.pixelHeight) }

    /// Normalises a display-local, top-left-origin pixel point: the frame formula with
    /// `height == 0`, since a point has no height to anchor against.
    public func normalize(topLeftX: Double, topLeftY: Double) -> NormalizedPoint {
        NormalizedPoint(x: topLeftX / pixelWidth,
                         y: 1 - (topLeftY / pixelHeight))
    }

    /// Normalises a display-local, top-left-origin pixel rectangle. The flip anchors
    /// on the bottom edge: `y` is `1 - ((topLeftY + height) / pixelHeight)`. The
    /// result carries `geometry.revision`.
    public func normalize(topLeftX: Double, topLeftY: Double,
                           width: Double, height: Double) -> NormalizedFrame {
        let origin = NormalizedPoint(x: topLeftX / pixelWidth,
                                      y: 1 - ((topLeftY + height) / pixelHeight))
        let size = NormalizedSize(width: width / pixelWidth, height: height / pixelHeight)
        return NormalizedFrame(origin: origin, size: size, revision: geometry.revision)
    }

    /// Inverts `normalize(topLeftX:topLeftY:width:height:)`, returning display-local,
    /// top-left-origin pixels. Traps if `frame.revision != geometry.revision`, which
    /// would scale normalised numbers by the wrong display's pixel dimensions.
    public func denormalize(_ frame: NormalizedFrame) -> PixelRect {
        precondition(frame.revision == geometry.revision, """
            geometry revision mismatch: \(frame.revision) vs \(geometry.revision). A frame \
            normalized against a different display configuration cannot be denormalized here.
            """)
        let width = frame.size.width * pixelWidth
        let height = frame.size.height * pixelHeight
        let x = frame.origin.x * pixelWidth
        // Inverse of the forward formula: origin.y == 1 - ((topLeftY + height) / pixelHeight),
        // so topLeftY == pixelHeight * (1 - (origin.y + size.height)).
        let y = pixelHeight * (1 - (frame.origin.y + frame.size.height))
        return PixelRect(x: x, y: y, width: width, height: height)
    }
}
