import AppKit
import Capture
import Compositing
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
        var table: [ContentDigest: PointerShape] = [:]
        for (cursor, shape) in classCursors {
            guard let data = cursor.image.tiffRepresentation else { continue }
            // **First writer wins.** Two class properties can be the same image — if a future
            // macOS drew `resizeLeft` exactly as `resizeLeftRight`, the more specific entry
            // listed first is the one that should answer.
            let digest = Minting.digest(of: data)
            if table[digest] == nil { table[digest] = shape }
        }
        return table
    }()

    /// Every class cursor this app names a shape for, most specific first.
    ///
    /// **One list, read by two things.** The digest table classifies what is on
    /// screen; the artwork table supplies what to draw. Two lists would be two
    /// lists that drift, and the drift would be silent: a shape classified with
    /// no artwork falls back to the drawn path, which looks like a rendering
    /// choice rather than like a missing entry.
    @MainActor
    static let classCursors: [(NSCursor, PointerShape)] = [
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

// MARK: - the artwork itself, not only its name

extension SystemCursorShape {
    /// Hands the system's own cursor artwork to the compositor.
    ///
    /// **Called before a preview or an export composes anything**, and cheap
    /// enough to call again: six images, already in memory, wrapped rather than
    /// rendered. The compositor cannot fetch them itself — `HeadlessCheck` bans
    /// AppKit from that tier, which is the same boundary that makes the shape
    /// READER a closure this file supplies.
    ///
    /// Idempotent, and re-run rather than cached across a macOS update: the point
    /// of asking the system is that a macOS which redraws its cursors is followed.
    @MainActor
    static func handArtworkToTheCompositor() {
        // The application object has to exist before any class cursor has an
        // image — the measurement that took a whole phase to find. See the
        // design doc.
        _ = NSApplication.shared
        var artwork: [PointerShape: CursorArtwork] = [:]
        for (cursor, shape) in Self.classCursors where artwork[shape] == nil {
            // First listed wins, matching `knownCursors`' own rule: `resizeLeft`
            // and `resizeLeftRight` map to one shape, and the two-headed one is
            // the artwork that shape should be drawn with.
            guard let made = Self.artwork(from: cursor) else { continue }
            artwork[shape] = made
        }
        SystemCursorArtwork.byShape = artwork
    }

    /// One cursor's artwork, or `nil` when it has no usable image.
    ///
    /// `cgImage(forProposedRect:)` at the cursor's own POINT size returns the
    /// backing bitmap at whatever density macOS holds it — 10× for the arrow on
    /// macOS 26, 2× for the hand — so the density is read back from the result
    /// rather than assumed. Assuming 2× would draw the arrow five times too big.
    @MainActor
    private static func artwork(from cursor: NSCursor) -> CursorArtwork? {
        let pointSize = cursor.image.size
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }
        var proposed = NSRect(origin: .zero, size: pointSize)
        guard let image = cursor.image.cgImage(forProposedRect: &proposed,
                                               context: nil, hints: nil) else { return nil }
        return CursorArtwork(image: image,
                             pointWidth: Double(pointSize.width),
                             pointHeight: Double(pointSize.height),
                             hotspotX: Double(cursor.hotSpot.x),
                             hotspotY: Double(cursor.hotSpot.y))
    }
}
