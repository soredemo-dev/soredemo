/// A rectangle in raw, native **pixels** — plain `Double`s, no origin
/// convention baked in.
///
/// This is the type that crosses module boundaries in place of `CGRect`, which
/// this package may not name (design doc § Geometry: the Y-axis flip; the
/// `ArchitectureCheck` plugin rejects `CGRect`/`CGPoint`/`CGSize`/`CGFloat`
/// outright). The app holds exactly one file, `Soredemo/Capture/CGGeometryBridge.swift`
/// (Task 18), converting `CGRect ↔ PixelRect`.
///
/// **Pixels, never points.** `CGDisplayBounds`, `CGEventGetLocation`, and AX
/// frames report **points** — see `PointRect`, this type's sibling — which
/// equal pixels only when `DisplayGeometry.scale == 1`. `PixelRect` and
/// `PointRect` are distinct types precisely so that handing one where the
/// other is expected is a compile error, not a silent unit bug; convert with
/// `DisplayGeometry.pixels(from:)` / `.points(from:)`.
///
/// **`PixelRect` does not know which corner is the origin.** Whether `(x, y)`
/// means top-left or bottom-left is a fact about whoever produced the value —
/// `CGDisplayBounds` and `CGEventGetLocation` are top-left, Core Image and
/// `CGContext` are bottom-left — not something this type records or enforces.
/// `NormalizationContext` is the one place that fixes a convention (top-left,
/// display-local) for the values that pass through it; elsewhere, `PixelRect`
/// is just a bag of four numbers.
public struct PixelRect: Hashable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    /// Traps on a non-finite field, or a negative dimension. Zero width/height
    /// is allowed — the same not-yet-dragged-selection case `NormalizedSize`
    /// allows. Like every precondition in this module, this cannot be
    /// exercised with `#expect` — a precondition failure kills the process —
    /// so it is not covered by `ConversionTests.swift`.
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
    /// Names its own unit — see `PointRect.description` for why this exists
    /// and what it replaces.
    public var description: String {
        "PixelRect(x: \(x), y: \(y), width: \(width), height: \(height) px)"
    }
}
