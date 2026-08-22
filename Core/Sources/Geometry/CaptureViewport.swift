import Foundation

/// **The rectangle actually being recorded**, and the basis every observed point is
/// normalised against.
///
/// This type exists because a real window recording was wrong in a way a display recording
/// never is. `InputObserver` normalised pointer positions against a `DisplayArrangement`,
/// which is the right rectangle only when the capture IS a display; capturing a window put
/// every sample in the display's coordinate space while the video was in the window's, and
/// the drawn cursor was systematically offset. Two rectangles treated as one — `1a98402`'s
/// family in the geometry domain rather than the clock domain.
///
/// The fix is dependency inversion rather than a special case: the observer depends on THIS,
/// and both capture kinds construct one — a display from its placement in the arrangement, a
/// window from its source rect. Neither is a branch in the observer.
///
/// **Not a `DisplayGeometry`, and not a rectangle alone.** It carries both: the geometry
/// supplies the scale and the `GeometryRevision` a normalised point is only meaningful
/// against, and the rectangle supplies where in global space this recording begins and how
/// much of it there is.
public struct CaptureViewport: Sendable, Hashable {
    /// The display this viewport sits on — the source of `scale` and of the revision
    /// stamped on everything normalised here.
    public let geometry: DisplayGeometry
    /// Global, top-left-origin POINTS, matching `DisplayArrangement`'s space and the
    /// coordinates `CGEvent` reports.
    public let globalOriginX: Double
    public let globalOriginY: Double
    public let widthInPoints: Double
    public let heightInPoints: Double

    public init(geometry: DisplayGeometry, globalOriginX: Double, globalOriginY: Double,
                widthInPoints: Double, heightInPoints: Double) {
        self.geometry = geometry
        self.globalOriginX = globalOriginX
        self.globalOriginY = globalOriginY
        self.widthInPoints = widthInPoints
        self.heightInPoints = heightInPoints
    }

    /// The revision a point normalised here belongs to. Carried so a caller never reaches
    /// past this type for it and pairs a point with the wrong coordinate system.
    public var revision: GeometryRevision { geometry.revision }

    /// A global, top-left-origin point in POINTS, normalised to 0…1 with a bottom-left
    /// origin — or `nil` when the point is outside the recording.
    ///
    /// **`nil`, never clamped.** A pointer that was not in shot has no position in the
    /// recording, and a clamped value would put a real-looking coordinate in the log for
    /// something that never happened.
    ///
    /// The flip and the division are `NormalizationContext`'s, not restated here: it owns
    /// the pixel→normalised rule and this type owns global→local. One rule, one owner.
    public func normalise(globalTopLeftX: Double, globalTopLeftY: Double) -> NormalizedPoint? {
        guard widthInPoints > 0, heightInPoints > 0 else { return nil }
        let localX = globalTopLeftX - globalOriginX
        let localY = globalTopLeftY - globalOriginY
        guard localX >= 0, localX < widthInPoints,
              localY >= 0, localY < heightInPoints else { return nil }

        // `NormalizationContext` divides by the geometry's PIXEL extent, so the local
        // point is converted to this viewport's own pixels first — a window's pixel
        // extent is its point extent times the display's scale, not the display's.
        let context = NormalizationContext(
            geometry: DisplayGeometry(displayUUID: geometry.displayUUID,
                                      pixelWidth: max(1, Int((widthInPoints * geometry.scale).rounded())),
                                      pixelHeight: max(1, Int((heightInPoints * geometry.scale).rounded())),
                                      scale: geometry.scale))
        return context.normalize(topLeftX: localX * geometry.scale,
                                 topLeftY: localY * geometry.scale)
    }
}

extension DisplayArrangement {
    /// The viewport for capturing a whole display — the case where the arrangement WAS the
    /// right rectangle, expressed through the same type so the observer has no branch.
    public func viewport(forDisplayContaining globalTopLeftX: Double,
                         globalTopLeftY: Double) -> CaptureViewport? {
        for placement in placements {
            let widthInPoints = Double(placement.geometry.pixelWidth) / placement.geometry.scale
            let heightInPoints = Double(placement.geometry.pixelHeight) / placement.geometry.scale
            guard globalTopLeftX >= placement.globalOriginX,
                  globalTopLeftX < placement.globalOriginX + widthInPoints,
                  globalTopLeftY >= placement.globalOriginY,
                  globalTopLeftY < placement.globalOriginY + heightInPoints else { continue }
            return CaptureViewport(geometry: placement.geometry,
                                   globalOriginX: placement.globalOriginX,
                                   globalOriginY: placement.globalOriginY,
                                   widthInPoints: widthInPoints,
                                   heightInPoints: heightInPoints)
        }
        return nil
    }
}
