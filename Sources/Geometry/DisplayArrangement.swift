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
/// global point land on, and where on that display's own local pixels?**
/// `route` is that answer. What it returns is display-local top-left pixels —
/// exactly what `NormalizationContext.normalize` requires — so the pipeline
/// is always global point → `route` → display-local point → `normalize`.
/// Nothing here calls `normalize`, and nothing here performs the Y-flip:
/// `NormalizationContext` is the one place that happens (design doc §
/// Geometry: the Y-axis flip).
public struct DisplayArrangement: Sendable {
    /// One display's `DisplayGeometry` paired with where its top-left pixel
    /// sits in the global coordinate space.
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

    /// Routes a point in the global coordinate space to the display it lands
    /// on, re-expressed in that display's own local top-left pixels — or
    /// `nil` if the point lies on no known display.
    ///
    /// Each display's bounds are **half-open**: `[globalOriginX,
    /// globalOriginX + pixelWidth)` on X, same shape on Y. A point exactly on
    /// a display's left or top edge belongs to it; a point exactly on its
    /// right or bottom edge does not. Two adjacent displays' bounds touch at
    /// that shared edge, and a closed interval on both sides would let them
    /// both claim the same pixel column or row — which display's local
    /// coordinates a click near a shared edge means would then depend on
    /// placement order in `placements`, silently, rather than being a
    /// property of the arrangement itself.
    ///
    /// The first placement whose bounds contain the point wins. Overlapping
    /// placements are not validated here — the app is responsible for
    /// building a non-overlapping arrangement from `CGDisplayBounds`, which
    /// does not overlap displays in a real configuration.
    public func route(globalTopLeftX: Double, globalTopLeftY: Double)
        -> (geometry: DisplayGeometry, localX: Double, localY: Double)? {
        for placement in placements {
            let minX = placement.globalOriginX
            let minY = placement.globalOriginY
            let maxX = minX + Double(placement.geometry.pixelWidth)
            let maxY = minY + Double(placement.geometry.pixelHeight)
            guard globalTopLeftX >= minX, globalTopLeftX < maxX,
                  globalTopLeftY >= minY, globalTopLeftY < maxY else { continue }
            return (placement.geometry, globalTopLeftX - minX, globalTopLeftY - minY)
        }
        return nil
    }
}
