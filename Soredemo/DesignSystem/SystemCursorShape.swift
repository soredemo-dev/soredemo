import AppKit
import Capture
import Graph
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

    /// **Every cursor classified as `.other` until 2026-08-30, and the wall that stopped it was
    /// not there.**
    ///
    /// The comment this replaces said: "those class images are 0×0 and their
    /// `tiffRepresentation` is `nil` … no comparison could ever succeed". That measurement was
    /// real and it was taken in the wrong place — a bare command-line binary that never touches
    /// `NSApplication`. **AppKit populates the class cursors' images when the application object
    /// is created**, and until it exists `NSCursor.arrow.image` really is 0×0.
    /// It is a documented requirement,
    /// says so on its fifth line, in a comment above `let _ = NSApplication.shared` — which is
    /// where this was found, after the same 0×0 was measured a second time and disbelieved.
    ///
    /// Re-measured inside an application, all seventeen class cursors have real images and
    /// distinct digests:
    ///
    ///     arrow           28x40   583248 bytes   57a1d610…
    ///     iBeam           23x22   263952         3de4a52b…
    ///     pointingHand    32x32    20892         65d626a5…
    ///     crosshair       24x24    11932         c5bc204d…
    ///     resizeLeftRight 30x24    14812         b94c84b1…
    ///     resizeUpDown    24x28    13852         b3b52be9…
    ///
    /// **Size alone cannot do it and the digest can.** `pointingHand`, `openHand` and
    /// `closedHand` are all 32x32 with 20,892 bytes of TIFF; `operationNotAllowed`, `dragCopy`,
    /// `contextualMenu` and `disappearingItem` are all 28x40 with 22,812. Only the digests tell
    /// those families apart.
    ///
    /// ### The table is built at runtime, which is the whole point
    ///
    /// The usual answer hashes the live cursor against a table of
    /// literal digests — and has had to write **two** of them, one for macOS 26 and one for
    /// everything before, because the artwork changed. A literal table is a fact about an OS
    /// version pinned inside an application, and it goes stale silently: an unrecognised cursor
    /// draws as an arrow and nothing reports it.
    ///
    /// This asks the running system instead. Every class cursor is hashed once, and the live
    /// cursor is looked up in what came back. A macOS that redraws its cursors changes both sides
    /// of the comparison at once, so there is nothing to update and nothing to go stale. **The
    /// measured digests above match published tables for this OS version exactly**, which is as close to a second
    /// opinion as this can get.
    ///
    /// **The hotspot is unchanged and was always real.** It is where inside the cursor's image
    /// the pointer actually is, and art drawn with its own origin at the recorded position is
    /// correct only when that origin IS the hotspot.
    ///
    /// `currentSystem` with a `current` fallback: the first is `nil` when no
    /// system cursor is set, and the app's own beats reporting nothing.
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
    ///
    /// **Built once and held**, because hashing ten images is a few milliseconds and the reader
    /// runs ten times a second.
    ///
    /// The four resize cursors that point one way — `resizeLeft`, `resizeRight`, `resizeUp`,
    /// `resizeDown` — are reported as the two-headed shape on their own axis. That is a
    /// deliberate approximation and the smaller of two errors: this app draws two resize shapes
    /// and not four, and a viewer who saw a horizontal resize affordance is shown a horizontal
    /// resize affordance rather than the arrow `.other` would give them. `openHand`,
    /// `closedHand`, `contextualMenu` and the rest have no art here and stay honestly `.other`.
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
