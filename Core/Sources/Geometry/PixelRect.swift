/// A rectangle in raw, native pixels: plain `Double`s, no origin convention baked in.
/// Crosses module boundaries in place of `CGRect`, which this package may not name;
/// the app converts in one file, `Soredemo/Capture/CGGeometryBridge.swift`.
///
/// Pixels, never points. `PixelRect` and `PointRect` are distinct types so mixing
/// them is a compile error rather than a silent unit bug; convert with
/// `DisplayGeometry.pixels(from:)` / `.points(from:)`. Which corner `(x, y)` means is
/// a fact about the producer, not recorded or enforced here; `NormalizationContext`
/// is the one place that fixes a convention.
public struct PixelRect: Hashable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    /// Traps on a non-finite field or a negative dimension. Zero width/height is
    /// allowed.
    public init(x: Double, y: Double, width: Double, height: Double) {
        precondition(x.isFinite, "PixelRect.x must be finite, got \(x)")
        precondition(y.isFinite, "PixelRect.y must be finite, got \(y)")
        precondition(width.isFinite && width >= 0,
                     "PixelRect.width must be finite and non-negative, got \(width)")
        precondition(height.isFinite && height >= 0,
                     "PixelRect.height must be finite and non-negative, got \(height)")
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

extension PixelRect: CustomStringConvertible {
    /// Names its own unit, so any print of a `PixelRect` carries it.
    public var description: String {
        "PixelRect(x: \(x), y: \(y), width: \(width), height: \(height) px)"
    }
}
