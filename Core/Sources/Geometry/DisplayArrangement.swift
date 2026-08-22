import Foundation

/// Where each display sits in the global coordinate space `CGEventGetLocation` and
/// `CGDisplayBounds` report in. Extrinsic and never digested: global origins shift with the
/// arrangement, so folding one into `DisplayGeometry` would let display B change A's revision.
///
/// Every value here is in POINTS. `NormalizationContext.normalize` requires display-local
/// PIXELS, so a routed point must pass through `DisplayGeometry.pixels(from:)` first;
/// skipping that gives a plausible, wrong answer. Nothing here performs the Y-flip.
public struct DisplayArrangement: Sendable {
    /// One display's `DisplayGeometry` paired with where its top-left corner sits in the global
    /// space. `globalOriginX`/`globalOriginY` are POINTS, passed through from `CGDisplayBounds`
    /// unconverted, and may be negative for a display left of or above the main one.
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

    /// Routes a global point (POINTS) to the display it lands on, re-expressed in that display's
    /// local top-left POINTS, or `nil` if it lies on no known display. The result still needs
    /// `DisplayGeometry.pixels(from:)` before `NormalizationContext.normalize`.
    ///
    /// Bounds are half-open in points — `[origin, origin + sizeInPoints)` on each axis — so two
    /// adjacent displays never both claim a shared edge. The first placement containing the point
    /// wins; overlapping placements are not validated here.
    public func route(globalTopLeftX: Double, globalTopLeftY: Double)
        -> (geometry: DisplayGeometry, localX: Double, localY: Double)? {
        for placement in placements {
            // Display size in POINTS: the arguments are points, while
            // `pixelWidth`/`pixelHeight` are native pixels.
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
