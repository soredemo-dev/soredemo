/// A point in normalised display coordinates: 0…1, bottom-left origin, matching Core
/// Image so the render path never flips. Increasing `y` moves up the display, unlike
/// `CGDisplayBounds`, `CGEventGetLocation`, and AX `kAXPositionAttribute`. The flip
/// happens only in `NormalizationContext`; this type performs no conversion.
public struct NormalizedPoint: Hashable, Codable, Sendable {
    public let x: Double
    public let y: Double

    /// Traps on a non-finite coordinate.
    public init(x: Double, y: Double) {
        precondition(x.isFinite, "NormalizedPoint.x must be finite, got \(x)")
        precondition(y.isFinite, "NormalizedPoint.y must be finite, got \(y)")
        self.x = x
        self.y = y
    }
}

/// A size in normalised display coordinates. Orientation-free — a size has no
/// origin — so unlike `NormalizedPoint` there is nothing to flip here.
public struct NormalizedSize: Hashable, Codable, Sendable {
    public let width: Double
    public let height: Double

    /// Traps on a non-finite or negative dimension. Zero is allowed: a not-yet-dragged
    /// selection is a legitimate zero-area frame.
    public init(width: Double, height: Double) {
        precondition(width.isFinite && width >= 0,
                     "NormalizedSize.width must be finite and non-negative, got \(width)")
        precondition(height.isFinite && height >= 0,
                     "NormalizedSize.height must be finite and non-negative, got \(height)")
        self.width = width
        self.height = height
    }
}

/// An axis-aligned rectangle in normalised display coordinates, tied to the
/// `GeometryRevision` of the display it was normalised against. Two frames under
/// different configurations describe different physical rectangles even when their
/// numbers coincide, so `contains` and `intersects` precondition on matching
/// revisions before any arithmetic. Performs no coordinate conversion.
public struct NormalizedFrame: Hashable, Codable, Sendable {
    public let origin: NormalizedPoint
    public let size: NormalizedSize
    public let revision: GeometryRevision

    public init(origin: NormalizedPoint, size: NormalizedSize, revision: GeometryRevision) {
        self.origin = origin
        self.size = size
        self.revision = revision
    }

    public var minX: Double { origin.x }
    public var maxX: Double { origin.x + size.width }
    public var minY: Double { origin.y }
    public var maxY: Double { origin.y + size.height }

    /// Whether `other` lies entirely within `self`. Traps if the two frames carry
    /// different revisions: a cross-revision comparison is a programmer error, not
    /// untrusted input, so there is nothing for a caller to recover from.
    public func contains(_ other: NormalizedFrame) -> Bool {
        precondition(revision == other.revision, """
            geometry revision mismatch: \(revision) vs \(other.revision). Frames normalized \
            against different display configurations are not comparable.
            """)
        return other.minX >= minX && other.maxX <= maxX
            && other.minY >= minY && other.maxY <= maxY
    }

    /// Whether `self` and `other` overlap. Frames that only share a boundary
    /// edge do not intersect. Same revision guard as `contains`.
    public func intersects(_ other: NormalizedFrame) -> Bool {
        precondition(revision == other.revision, """
            geometry revision mismatch: \(revision) vs \(other.revision). Frames normalized \
            against different display configurations are not comparable.
            """)
        return minX < other.maxX && maxX > other.minX
            && minY < other.maxY && maxY > other.minY
    }
}
