/// A rectangle in points: plain `Double`s, no origin convention baked in. A distinct
/// type from `PixelRect` rather than a generic `Rect<Unit>`, so mixing the two is a
/// compile error with a clear diagnostic instead of a silent unit bug.
///
/// Points are what `CGDisplayBounds`, `CGEventGetLocation`, and AX
/// `kAXPositionAttribute` report; `points == pixels / scale`, so they equal pixels
/// only when `scale == 1`. `DisplayGeometry.pixels(from:)` / `.points(from:)` are the
/// only sanctioned crossing. Which corner `(x, y)` means is a fact about the producer,
/// not recorded here.
public struct PointRect: Hashable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    /// Traps on a non-finite field or a negative dimension. Zero width/height is
    /// allowed.
    public init(x: Double, y: Double, width: Double, height: Double) {
        precondition(x.isFinite, "PointRect.x must be finite, got \(x)")
        precondition(y.isFinite, "PointRect.y must be finite, got \(y)")
        precondition(width.isFinite && width >= 0,
                     "PointRect.width must be finite and non-negative, got \(width)")
        precondition(height.isFinite && height >= 0,
                     "PointRect.height must be finite and non-negative, got \(height)")
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

extension PointRect: CustomStringConvertible {
    /// Names its own unit, so the unit comes from the type rather than from each
    /// format string that prints a `PointRect`.
    public var description: String {
        "PointRect(x: \(x), y: \(y), width: \(width), height: \(height) pt)"
    }
}
