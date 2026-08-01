/// A point in normalised display coordinates: **0…1, bottom-left origin**,
/// matching Core Image so the render path (`render-core`) never flips
/// (design doc § Geometry: the Y-axis flip). Increasing `y` moves *up* the
/// display — the opposite of `CGDisplayBounds`, `CGEventGetLocation`, and AX
/// `kAXPositionAttribute`, which are all top-left.
///
/// The flip between those top-left pixel sources and this bottom-left
/// normalised space happens in exactly **one** place — `NormalizationContext`
/// (Task 9) — and nowhere in this type. A "convenience" conversion added
/// here is exactly how that single-flip guarantee dies, so none exists: this
/// is a pure value type over already-normalised numbers.
public struct NormalizedPoint: Hashable, Codable, Sendable {
    public let x: Double
    public let y: Double

    /// Traps on a non-finite coordinate. Like every precondition in this
    /// file, this cannot be exercised with `#expect` — a precondition
    /// failure kills the process — so it is not covered by
    /// `NormalizedTests.swift`. Recorded here rather than left to be
    /// silently implied by nearby tests that never touch it.
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

    /// Traps on a non-finite or negative dimension. Zero is allowed — a
    /// not-yet-dragged selection is a legitimate zero-area frame. Untested
    /// in-process for the same reason as `NormalizedPoint.init`.
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
/// `GeometryRevision` of the display it was normalised against (D-P2, D3).
///
/// **The revision is load-bearing, not decorative.** Displays get
/// reconfigured mid-recording; two frames normalised against different
/// configurations describe different physical rectangles even when their
/// numbers coincide, and comparing them as though they shared a coordinate
/// space is a wrong answer computed in silence — a zoom landing on the wrong
/// control with no error anywhere. `contains` and `intersects` both
/// precondition on `revision == other.revision` before doing any arithmetic,
/// so that comparison is a loud precondition failure instead.
///
/// This is a pure value type: `origin` and `size` are already-normalised
/// numbers, and this type performs no coordinate conversion of its own.
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

    /// Whether `other` lies entirely within `self`.
    ///
    /// Traps if the two frames were normalised against different displays —
    /// see the type's documentation. This is a precondition, not a thrown
    /// error: reaching a cross-revision comparison is a programmer error —
    /// mis-plumbed state surviving a display reconfiguration — not untrusted
    /// input, so there is nothing for a caller to recover from.
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
