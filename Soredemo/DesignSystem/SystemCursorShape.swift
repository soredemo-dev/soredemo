import AppKit
import Geometry
import Project

/// Reads the live system cursor for `InputObserver`'s injected shape and hotspot seams.
/// AppKit exists only in this tier (`HeadlessCheck` bans it from `Capture`), which is why
/// capture takes closures rather than calling `NSCursor` itself.
///
/// **The readers are called from `InputObserver`'s poll queue, never the main thread, and
/// that is a requirement.** The poll timer exists to notice the tap callback's thread being
/// stuck, so it deliberately does not share a thread with it. An earlier version of this
/// file wrapped the read in `MainActor.assumeIsolated` — an assertion that the caller IS on
/// the main actor — and a real run trapped with `EXC_BREAKPOINT` on the poll thread. The
/// doc comment there even claimed "the poll timer hops here" while nothing hopped.
/// `theShapeReaderIsCalledOffTheMainThread` now pins the contract from the package side.
///
/// So the readers **never block and never assert**: they return the last value sampled and
/// schedule the next sample on the main actor. `DispatchQueue.main.sync` would be the
/// obvious alternative and is worse — the main thread can be inside AppKit waiting on
/// something the poll is meant to detect, and a sync hop would deadlock precisely then.
///
/// The cost of the design is one poll interval of staleness (100 ms). A cursor shape
/// changes when the pointer crosses a control boundary, so a sample 100 ms behind is the
/// same answer nearly always, and being briefly behind is a better failure than trapping.
// `nonisolated` on the type, not just on its members: this app target builds with
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an unannotated enum is MainActor-isolated
// and its `static let cache` becomes unreachable from the `@Sendable` closures — which is
// the same default that made `assumeIsolated` look reasonable in the version that trapped.
nonisolated enum SystemCursorShape {
    /// The last sample, written on the main actor and read from anywhere.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (shape: PointerShape, hotspot: NormalizedPoint)?
        private var refreshInFlight = false

        func read() -> (shape: PointerShape, hotspot: NormalizedPoint)? {
            lock.withLock { value }
        }

        /// Schedules one refresh on the main actor, at most one at a time: the poll fires
        /// every 100 ms and a backlog of hops would be work the main thread does not need.
        func scheduleRefresh() {
            let shouldStart = lock.withLock {
                if refreshInFlight { return false }
                refreshInFlight = true
                return true
            }
            guard shouldStart else { return }
            Task { @MainActor [weak self] in
                let sampled = SystemCursorShape.sampleOnMainActor()
                guard let self else { return }
                self.lock.withLock {
                    self.value = sampled
                    self.refreshInFlight = false
                }
            }
        }
    }

    private nonisolated static let cache = Cache()

    /// **Classification is `.other`, deliberately, and the measurement is why.** An earlier
    /// version compared the live cursor's TIFF bytes against `NSCursor.arrow.image`,
    /// `.iBeam.image` and so on. Measured on this machine: those class images are 0×0 and
    /// their `tiffRepresentation` is `nil`, while `NSCursor.currentSystem` returns a real
    /// 32×32 image with ~20 KB of TIFF. No comparison could ever succeed, so every cursor
    /// classified as `.other` anyway — silently. `../opensource/a Rust recorder` (AGPLv3, read for
    /// approach not code) hashes the live image against a table of KNOWN digests; those are
    /// OS-version-specific and cannot be derived from the class cursors here, so this
    /// returns `.other` openly until such a table exists.
    ///
    /// **The hotspot is the part that affects position, and it is real.** It is where inside
    /// the cursor's image the pointer actually is — measured here: `(0.406, 0.250)` for the
    /// pointing hand, `(0.458, 0.458)` for the crosshair — and art drawn with its own origin
    /// at the recorded position is correct only when that origin IS the hotspot. Carrying
    /// the true value lets the renderer place art correctly for shapes it cannot name, which
    /// is currently all of them.
    ///
    /// `currentSystem` with a `current` fallback, the pair a Rust recorder uses: the first is `nil` when
    /// no system cursor is set, and the app's own beats reporting nothing.
    @MainActor
    private static func sampleOnMainActor() -> (shape: PointerShape, hotspot: NormalizedPoint)? {
        guard let cursor = NSCursor.currentSystem ?? NSCursor.current as NSCursor? else {
            return nil
        }
        let size = cursor.image.size
        guard size.width > 0, size.height > 0 else {
            // No image means no hotspot to normalise against; the centre is the honest
            // stand-in rather than a fabricated origin.
            return (.other, NormalizedPoint(x: 0.5, y: 0.5))
        }
        let hotspot = cursor.hotSpot
        return (.other, NormalizedPoint(x: hotspot.x / size.width,
                                        y: hotspot.y / size.height))
    }

    /// The shape reader `CaptureSession` injects. Non-blocking: returns the last sample and
    /// asks for the next.
    nonisolated static func reader() -> @Sendable () -> PointerShape? {
        {
            let value = cache.read()?.shape
            cache.scheduleRefresh()
            return value
        }
    }

    /// The hotspot reader, separate because a caller may want one without the other. Both
    /// read the same cache, so one refresh serves both.
    nonisolated static func hotspotReader() -> @Sendable () -> NormalizedPoint? {
        {
            let value = cache.read()?.hotspot
            cache.scheduleRefresh()
            return value
        }
    }
}
