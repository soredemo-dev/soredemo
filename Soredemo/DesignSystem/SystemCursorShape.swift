import AppKit
import Capture
import Graph
import Geometry
import Project

/// Reads the live system cursor for `InputObserver`'s injected shape and hotspot
/// seams. AppKit exists only in this tier (`HeadlessCheck` bans it from `Capture`),
/// which is why capture takes closures rather than calling `NSCursor` itself.
///
/// **The readers never block and never assert.** They are called from
/// `InputObserver`'s poll queue, never the main thread — an earlier version
/// asserted otherwise and trapped on a real run — so they return the last value
/// sampled and schedule the next on the main actor. The cost is one poll interval
/// of staleness; `docs/design/classifying-the-live-cursor.md` records why that is
/// the better failure and why `DispatchQueue.main.sync` is worse.
// `nonisolated` on the type, not just on its members: this target builds with
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an unannotated enum is
// MainActor-isolated and its `static let cache` becomes unreachable from the
// `@Sendable` closures.
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

    /// The shape of the live system cursor, classified by hashing its image
    /// against a table built from the class cursors at runtime.
    ///
    /// Every cursor was `.other` until 2026-08-30, because the measurement that
    /// said the class images are 0×0 had been taken in a binary that never creates
    /// `NSApplication` — AppKit populates them when the application object does.
    /// Size alone cannot separate the families and the digest can; the table is
    /// built at runtime so it cannot go stale against an OS that redraws its
    /// cursors. Measurements in `docs/design/classifying-the-live-cursor.md`.
    ///
    /// `currentSystem` with a `current` fallback: the first is `nil` when no system
    /// cursor is set, and the app's own beats reporting nothing.
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
        return (classify(cursor), NormalizedPoint(x: hotspot.x / size.width,
                                                  y: hotspot.y / size.height))
    }

    /// Which shape this cursor is, by matching its image against the running system's own.
    @MainActor
    static func classify(_ cursor: NSCursor) -> PointerShape {
        guard let data = cursor.image.tiffRepresentation else { return .other }
        // **Through `Minting`, not `SHA256` directly.** Digests enter this app through one
        // boundary so that derivation stays a deterministic function of its input, and the
        // app-source scan enforces it — it caught this file reaching for CryptoKit the moment
        // the classifier was written.
        return knownCursors[Minting.digest(of: data)] ?? .other
    }

    /// Every class cursor this app has art for, by the digest of its image.
    /// Built once and held: hashing ten images is a few milliseconds and the
    /// reader runs ten times a second.
    ///
    /// The four one-way resize cursors are reported as the two-headed shape on
    /// their own axis — a deliberate approximation, and the smaller of two errors.
    /// Cursors with no art here stay honestly `.other`.
    @MainActor
    static let knownCursors: [ContentDigest: PointerShape] = {
        // Touching the shared application is what populates `arrow` and `iBeam` — see the header.
        // It is already alive in this app; this is here so the table is still right if anything
        // ever builds it before the application object exists.
        _ = NSApplication.shared
        let sources: [(NSCursor, PointerShape)] = [
            (.arrow, .arrow),
            (.iBeam, .iBeam),
            (.pointingHand, .pointingHand),
            (.crosshair, .crosshair),
            (.resizeLeftRight, .resizeLeftRight),
            (.resizeUpDown, .resizeUpDown),
            (.resizeLeft, .resizeLeftRight),
            (.resizeRight, .resizeLeftRight),
            (.resizeUp, .resizeUpDown),
            (.resizeDown, .resizeUpDown),
        ]
        var table: [ContentDigest: PointerShape] = [:]
        for (cursor, shape) in sources {
            guard let data = cursor.image.tiffRepresentation else { continue }
            // **First writer wins.** Two class properties can be the same image — if a future
            // macOS drew `resizeLeft` exactly as `resizeLeftRight`, the more specific entry
            // listed first is the one that should answer.
            let digest = Minting.digest(of: data)
            if table[digest] == nil { table[digest] = shape }
        }
        return table
    }()

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
