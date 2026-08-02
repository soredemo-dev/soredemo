import Foundation

/// Where each display sits in the global coordinate space `CGEventGetLocation`
/// and `CGDisplayBounds` report in — **extrinsic**, and deliberately **never
/// digested** (D-P2, "Global arrangement must stay out").
///
/// `CGDisplayBounds` origins shift when the arrangement changes, and
/// promoting a different display to main re-bases the whole global space. If
/// a display's global origin were folded into `DisplayGeometry` — the type
/// whose `revision` is a content digest — then rearranging display B would
/// silently change display A's revision too, invalidating footage that
/// nothing about display A actually altered. So placement lives here,
/// completely separate from geometry, and nothing in this file is ever
/// hashed into a `GeometryRevision`.
///
/// Used at capture entry only, to answer one question: **which display did a
/// global point land on, and where on that display's own local coordinates?**
/// `route` is that answer.
///
/// **`route`'s arguments and return value are points, not pixels** — that is
/// what `CGDisplayBounds` and `CGEventGetLocation` actually report, and it is
/// also what `Placement.globalOriginX`/`globalOriginY` are. `route` compares
/// them against each display's size **in points**, derived from
/// `pixelWidth`/`pixelHeight` and `scale` (`DisplayGeometry.points(from:)`'s
/// own division, inlined here since these are bare dimensions, not a rect).
/// Comparing points against raw pixel dimensions directly was the Task 10.5
/// defect: a 3840×2160 display at `scale: 2` is 1920 points wide, and a point
/// at x=2500 was accepted because it was compared against 3840, not 1920.
///
/// `NormalizationContext.normalize` requires display-local **pixels**, not
/// points, and it deliberately does not do this conversion itself — it is the
/// one place that flips Y, and should not also acquire a second, independent
/// unit conversion. So the full pipeline has one more explicit step than it
/// looks like it needs:
///
/// ```swift
/// // global point (points) → route → local point (points)
/// guard let hit = arrangement.route(globalTopLeftX: x, globalTopLeftY: y) else { return }
/// // local point (points) → convert via scale → local point (pixels)
/// let pixels = hit.geometry.pixels(from: PointRect(x: hit.localX, y: hit.localY, width: 0, height: 0))
/// // local point (pixels) → normalize
/// let normalized = NormalizationContext(geometry: hit.geometry).normalize(topLeftX: pixels.x, topLeftY: pixels.y)
/// ```
///
/// Wiring `hit.localX`/`hit.localY` straight into `normalize` skips that
/// middle step and produces a plausible, wrong answer — the same failure
/// mode `NormalizationContext`'s own documentation warns about for a global
/// (unrouted) point.
///
/// Nothing here calls `normalize`, and nothing here performs the Y-flip:
/// `NormalizationContext` is the one place that happens (design doc §
/// Geometry: the Y-axis flip).
///
/// **Scalars, not `PointRect`.** `route`'s arguments and return value stay
/// bare `Double`s rather than becoming `PointRect`/`PixelRect` — see the
/// Task 10.5 report for why: in short, a single routed point has no width or
/// height, and wrapping it in a zero-size rect at every call site to buy a
/// compile-time guarantee reintroduces the representational mismatch this
/// module works to avoid elsewhere (a point is not a degenerate rect, even
/// though `NormalizationContext.normalize`'s point overload treats it as
/// one internally). That means the mistake `PointRect` prevents for rects —
/// handing pixels where points are expected — is still expressible at
/// `route`'s scalar boundary; nothing but this comment and the type of the
/// values documented above stops it. The defect actually observed, however,
/// was not a caller passing the wrong unit — it was `route`'s own internal
/// comparison mixing them — and that is fixed unconditionally below,
/// independent of `route`'s parameter types.
public struct DisplayArrangement: Sendable {
    /// One display's `DisplayGeometry` paired with where its top-left corner
    /// sits in the global coordinate space.
    ///
    /// **`globalOriginX`/`globalOriginY` are points, not pixels** — this is
    /// exactly what `CGDisplayBounds` reports, and it is the caller's
    /// responsibility to pass that value through unconverted, not to
    /// pre-multiply by `scale`. `route` does the unit-aware comparison; see
    /// its documentation.
    ///
    /// `globalOriginX`/`globalOriginY` are ordinary `Double`s, not `UInt` or
    /// anything else that forbids negative values: a secondary display placed
    /// to the *left* of or *above* the main display has a negative origin on
    /// macOS, and that is a normal arrangement, not an edge case to reject.
    public struct Placement: Sendable {
        public let geometry: DisplayGeometry
        public let globalOriginX: Double
        public let globalOriginY: Double

        public init(geometry: DisplayGeometry, globalOriginX: Double, globalOriginY: Double) {
            self.geometry = geometry
            self.globalOriginX = globalOriginX
            self.globalOriginY = globalOriginY
        }
    }

    public let placements: [Placement]

    public init(placements: [Placement]) {
        self.placements = placements
    }

    /// Routes a point in the global coordinate space (**points**) to the
    /// display it lands on, re-expressed in that display's own local
    /// top-left **points** — or `nil` if the point lies on no known display.
    /// See this type's documentation for the full points → pixels pipeline;
    /// the result here still needs `DisplayGeometry.pixels(from:)` before it
    /// can be passed to `NormalizationContext.normalize`.
    ///
    /// Each display's bounds are **half-open**: `[globalOriginX,
    /// globalOriginX + widthInPoints)` on X, same shape on Y — **in points**,
    /// not `pixelWidth`/`pixelHeight` directly. This is the Task 10.5 fix:
    /// comparing a point value against a pixel dimension silently accepts
    /// points that lie past a Retina display's actual (smaller, in points)
    /// width. A point exactly on a display's left or top edge belongs to it;
    /// a point exactly on its right or bottom edge does not. Two adjacent
    /// displays' bounds touch at that shared edge, and a closed interval on
    /// both sides would let them both claim the same column or row — which
    /// display's local coordinates a click near a shared edge means would
    /// then depend on placement order in `placements`, silently, rather than
    /// being a property of the arrangement itself.
    ///
    /// The first placement whose bounds contain the point wins. Overlapping
    /// placements are not validated here — the app is responsible for
    /// building a non-overlapping arrangement from `CGDisplayBounds`, which
    /// does not overlap displays in a real configuration.
    public func route(globalTopLeftX: Double, globalTopLeftY: Double)
        -> (geometry: DisplayGeometry, localX: Double, localY: Double)? {
        for placement in placements {
            // Display size in POINTS, not `pixelWidth`/`pixelHeight` — those
            // are native pixels, and `globalTopLeftX`/`globalTopLeftY` (and
            // `globalOriginX`/`globalOriginY`) are points. This division is
            // what `DisplayGeometry.points(from:)` does for a rect; inlined
            // here because these are bare dimensions, not a `PixelRect`.
            let widthInPoints = Double(placement.geometry.pixelWidth) / placement.geometry.scale
            let heightInPoints = Double(placement.geometry.pixelHeight) / placement.geometry.scale
            let minX = placement.globalOriginX
            let minY = placement.globalOriginY
            let maxX = minX + widthInPoints
            let maxY = minY + heightInPoints
            guard globalTopLeftX >= minX, globalTopLeftX < maxX,
                  globalTopLeftY >= minY, globalTopLeftY < maxY else { continue }
            return (placement.geometry, globalTopLeftX - minX, globalTopLeftY - minY)
        }
        return nil
    }
}
