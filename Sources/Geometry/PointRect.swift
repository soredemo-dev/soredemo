/// A rectangle in **points** — plain `Double`s, no origin convention baked
/// in. `PointRect` and `PixelRect` carry the same four fields; they are two
/// distinct types, not one type with a naming convention, so that mixing
/// them is a compile error instead of a silent unit bug (design doc §
/// Geometry: the Y-axis flip, "Unit mismatch at capture entry").
///
/// **Points are what `CGDisplayBounds`, `CGEventGetLocation`, and AX
/// `kAXPositionAttribute` report.** They equal native pixels only when
/// `scale == 1`; on a Retina display, `points == pixels / scale`. Nothing
/// in this package touches CoreGraphics, but every Phase 2 capture entry
/// hits this fork — `DisplayGeometry.pixels(from:)` and
/// `DisplayGeometry.points(from:)` are the only sanctioned crossing.
///
/// **`PointRect` does not know which corner is the origin**, for the same
/// reason `PixelRect` doesn't: that is a fact about whoever produced the
/// value, not something this type records or enforces. See `PixelRect`'s
/// documentation.
///
/// This type is deliberately a near-duplicate of `PixelRect` rather than a
/// generic `Rect<Unit>` — see the task report for Task 10.5. Both are plain
/// data structs with no methods, so the duplication costs almost nothing,
/// and `cannot convert value of type 'PointRect' to expected argument type
/// 'PixelRect'` is a far clearer diagnostic at a real call site than a
/// generic constraint failure would be.
public struct PointRect: Hashable, Codable, Sendable {
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
    /// Names its own unit. Added for `Soredemo/App/SoredemoApp.swift`'s
    /// `--present-picker` diagnostic, which printed a `.display`'s size as
    /// `"1512x982 pt"` and a `.window`'s `bufferSize` as `"3024x1964 px"` by
    /// hand-writing the unit into each format string separately — the exact
    /// silent-mixing risk `PointRect`/`PixelRect` exist to make a compile
    /// error (design doc § Geometry: the Y-axis flip), reintroduced one
    /// layer up, in a print statement neither type's own machinery could
    /// catch. The fix is not "phrase that one print statement more
    /// carefully" — it is that the unit comes from the **type**, so every
    /// future print of a `PointRect` carries it for free.
    public var description: String {
        "PointRect(x: \(x), y: \(y), width: \(width), height: \(height) pt)"
    }
}
