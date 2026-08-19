import AppKit
import Project

/// Classifies the CURRENT system cursor into `PointerShape` — the app-tier half of the
/// seam `InputObserver.pointerShapeReader` names. AppKit only exists in this tier
/// (`HeadlessCheck` bans it from `Capture`), which is why capture takes a closure.
///
/// **Classification is by image bytes, and the honest limits are stated here.**
/// `NSCursor.currentSystem` returns a fresh instance per call, so identity comparison is
/// useless; what is stable is the cursor's image. The table maps the TIFF bytes of the
/// standard cursors' images to their shapes, and anything else — an app's custom cursor,
/// a resize variant this table does not carry — classifies as `.other`, which is a real
/// answer ("recorded, and not a shape the schema names"), never a guess.
///
/// Two caches keep the per-sample cost flat at 120 Hz: the last image OBJECT seen (the
/// common case — the cursor did not change between samples, and AppKit reuses the image
/// instance) short-circuits everything; a byte-keyed cache holds every classification
/// ever computed, bounded by the handful of distinct cursors a session actually shows.
///
/// `@MainActor` because `NSCursor` is; the tap callback runs on the main run loop
/// (`InputObserver`'s own callback documentation), so `assumeIsolated` in the closure
/// below is an assertion about where taps deliver, not a hope.
@MainActor
enum SystemCursorShape {
    private static let knownCursors: [(shape: PointerShape, cursor: NSCursor)] = [
        (.arrow, .arrow),
        (.iBeam, .iBeam),
        (.pointingHand, .pointingHand),
        (.crosshair, .crosshair),
        (.resizeLeftRight, .resizeLeftRight),
        (.resizeUpDown, .resizeUpDown),
    ]

    private static var byImageBytes: [Data: PointerShape] = [:]
    private static var lastImage: NSImage?
    private static var lastShape: PointerShape?

    static func current() -> PointerShape? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        let image = cursor.image
        if image === lastImage { return lastShape }

        let shape = classify(image)
        lastImage = image
        lastShape = shape
        return shape
    }

    private static func classify(_ image: NSImage) -> PointerShape {
        guard let bytes = image.tiffRepresentation else { return .other }
        if let cached = byImageBytes[bytes] { return cached }
        let shape = knownCursors.first {
            $0.cursor.image.tiffRepresentation == bytes
        }?.shape ?? .other
        byImageBytes[bytes] = shape
        return shape
    }

    /// The closure `CaptureSession` takes: hops onto the main actor by assertion, since
    /// the tap that calls it delivers there. If that assertion is ever wrong the trap
    /// names this line rather than corrupting AppKit state silently.
    nonisolated static func reader() -> @Sendable () -> PointerShape? {
        { MainActor.assumeIsolated { current() } }
    }
}
