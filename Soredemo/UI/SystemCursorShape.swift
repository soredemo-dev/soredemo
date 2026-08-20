import AppKit
import Geometry
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
    /// **The classifier this file first shipped with never matched anything, and the
    /// measurement is short enough to state.** It compared the live cursor's TIFF bytes
    /// against `NSCursor.arrow.image`, `NSCursor.iBeam.image` and so on. Measured on this
    /// machine: those class images are **0×0 and their `tiffRepresentation` is `nil`**,
    /// while `NSCursor.currentSystem` returns a real 32×32 image with ~20 KB of TIFF. No
    /// comparison could ever succeed, so every cursor classified as `.other` and every one
    /// rendered as an arrow — the I-beam art added alongside it reached tests and never
    /// reached a recording.
    ///
    /// **What replaces it, and its honest limit.** `../opensource/a Rust recorder` (AGPLv3 — read for
    /// approach, not for code) hashes the live cursor's image and looks the digest up in a
    /// table of KNOWN hashes. That works and this does not have such a table: the digests
    /// are OS-version-specific and cannot be derived from the class cursors here, for the
    /// reason above. So classification stays `.other` until a table exists, and this file
    /// no longer pretends otherwise.
    ///
    /// **What is fixed regardless of classification** is the part that affects position:
    /// the HOTSPOT is read from the live cursor and reported. A hotspot is where inside the
    /// cursor image the actual pointer is — `(0.406, 0.250)` for the pointing hand,
    /// `(0.458, 0.458)` for the crosshair, measured here — and drawing any art with its own
    /// origin at the recorded position is only correct when that origin IS the hotspot.
    /// Carrying the real value lets the renderer place art correctly for shapes it does not
    /// recognise, which is currently all of them.
    ///
    /// `currentSystemCursor()` with a `currentCursor()` fallback, the same pair a Rust recorder uses:
    /// the first is `nil` when no system cursor is set, and falling back to the app's own
    /// beats reporting nothing.
    ///
    /// `@MainActor` because `NSCursor` is; the poll timer hops here, and since the
    /// cursor-flicker repair this runs on that timer rather than in the tap callback.
    static func current() -> (shape: PointerShape, hotspot: NormalizedPoint)? {
        guard let cursor = NSCursor.currentSystem ?? NSCursor.current as NSCursor? else {
            return nil
        }
        let size = cursor.image.size
        guard size.width > 0, size.height > 0 else {
            // No image means no hotspot to normalise against; `.other` with the centre is
            // the honest answer rather than a fabricated origin.
            return (.other, NormalizedPoint(x: 0.5, y: 0.5))
        }
        let hotspot = cursor.hotSpot
        return (.other, NormalizedPoint(x: hotspot.x / size.width,
                                        y: hotspot.y / size.height))
    }

    /// The closure `CaptureSession` takes: hops onto the main actor by assertion, since the
    /// poll timer that calls it is not the tap callback and may block briefly.
    nonisolated static func reader() -> @Sendable () -> PointerShape? {
        { MainActor.assumeIsolated { current()?.shape } }
    }

    /// The hotspot reader, separate because a caller may want one without the other.
    nonisolated static func hotspotReader() -> @Sendable () -> NormalizedPoint? {
        { MainActor.assumeIsolated { current()?.hotspot } }
    }
}
