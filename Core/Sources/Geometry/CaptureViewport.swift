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

        return context.normalize(topLeftX: localX * geometry.scale,
                                 topLeftY: localY * geometry.scale)
    }

    /// A global, top-left-origin RECTANGLE in points, normalised the same way — or `nil` when
    /// its origin is outside the recording.
    ///
    /// **`NormalizationContext`'s rect overload, not its point one applied twice.** That
    /// overload anchors the Y flip on the rect's BOTTOM edge; the point formula on a rect is
    /// off by the rect's own height, which is `AXObserver.normalizedFrame`'s own note and the
    /// reason this is a second method rather than two calls at the call site.
    ///
    /// The rectangle may extend past the viewport — an AX element larger than the window being
    /// recorded is normal — so only the ORIGIN is required to be inside, and a width past 1 is
    /// recorded rather than clamped. `FramingGate.partlyOffscreen` is what decides whether that
    /// disqualifies it, and it can only decide if the number reaches it.
    public func normalise(globalTopLeftX: Double, globalTopLeftY: Double,
                          width: Double, height: Double) -> NormalizedFrame? {
        guard widthInPoints > 0, heightInPoints > 0,
              globalTopLeftX.isFinite, globalTopLeftY.isFinite,
              width.isFinite, height.isFinite, width >= 0, height >= 0 else { return nil }
        let localX = globalTopLeftX - globalOriginX
        let localY = globalTopLeftY - globalOriginY
        guard localX >= 0, localX < widthInPoints,
              localY >= 0, localY < heightInPoints else { return nil }
        // Scalars rather than a `PointRect` round trip: the rect type is a unit marker for
        // values that cross a boundary, and nothing crosses one here — this is the same
        // points→pixels multiply `normalise` does one line at a time.
        let raw = context.normalize(topLeftX: localX * geometry.scale,
                                    topLeftY: localY * geometry.scale,
                                    width: width * geometry.scale,
                                    height: height * geometry.scale)
        // **Restamped with THIS viewport's revision.** `NormalizationContext` stamps the
        // geometry it was built from, and the one below is synthetic — it exists to carry the
        // viewport's pixel extent, and `GeometryRevision` is derived from a geometry's
        // contents, so it hashes to something no click will ever carry. A frame stamped with it
        // makes `NormalizedFrame.contains` trap on a revision mismatch against the click it is
        // meant to be compared with, which is how this was found.
        return NormalizedFrame(origin: raw.origin, size: raw.size, revision: revision)
    }

    /// The global, top-left point in POINTS that `position` came from.
    ///
    /// **The exact inverse of `normalise(globalTopLeftX:globalTopLeftY:)`, step for step**, and
    /// it must stay that way. This is the claim `AXObserver`'s own version of it used to make
    /// about `InputObserver` and stopped being true the moment the pointer moved to a viewport
    /// and the hit-test did not: a window-mode click was denormalised against the whole
    /// display, so accessibility was asked what is at the middle of the SCREEN when the click
    /// was at the middle of the WINDOW.
    ///
    /// Not failable: every normalised point has a global point, including one outside 0…1.
    /// Whether it lands on anything is the hit-test's answer to give.
    public func globalPoint(of position: NormalizedPoint) -> (x: Double, y: Double) {
        // Step 4 in reverse — normalised, bottom-left → viewport-local pixels.
        //
        // Stamped with the SYNTHETIC geometry's revision, not the viewport's: `denormalize`
        // preconditions that the frame it is given was normalised against the geometry it
        // holds, and this frame is a vehicle for a point rather than a value anybody keeps.
        // Handing it the viewport's revision trapped.
        let carrier = pixelGeometry
        let pixels = NormalizationContext(geometry: carrier).denormalize(
            NormalizedFrame(origin: position, size: NormalizedSize(width: 0, height: 0),
                            revision: carrier.revision))
        // Step 3 in reverse — viewport-local pixels → viewport-local points.
        // Step 2 in reverse — viewport-local points → global points.
        return (globalOriginX + Double(pixels.x) / geometry.scale,
                globalOriginY + Double(pixels.y) / geometry.scale)
    }

    /// **The viewport's own pixel extent as a `DisplayGeometry`.**
    ///
    /// `NormalizationContext` divides by the geometry's PIXEL extent, so a point local to this
    /// viewport has to be measured against the viewport's pixels — a window's pixel extent is
    /// its point extent times the display's scale, not the display's. Computed once here rather
    /// than rebuilt in each conversion, so the three cannot disagree about what they divide by.
    private var pixelGeometry: DisplayGeometry {
        DisplayGeometry(
            displayUUID: geometry.displayUUID,
            pixelWidth: max(1, Int((widthInPoints * geometry.scale).rounded())),
            pixelHeight: max(1, Int((heightInPoints * geometry.scale).rounded())),
            scale: geometry.scale)
    }

    private var context: NormalizationContext { NormalizationContext(geometry: pixelGeometry) }
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
