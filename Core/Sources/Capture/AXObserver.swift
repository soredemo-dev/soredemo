import ApplicationServices
import Foundation
import Geometry
import Project
import Timeline

/// `ROADMAP.md`'s `ax-observation` row: for each click, the accessibility
/// element under the pointer — role, frame, and a bounded walk of its
/// ancestors — recorded and not judged (D2-1). Nothing here chooses an
/// element; the whole chain goes to disk (D2-3) and derivation chooses later.
///
/// The name deliberately shadows `ApplicationServices.AXObserver`, the
/// notification-observer API this file does not use; a file needing both must
/// qualify the framework's.
///
/// Click coordinates are never re-derived: `globalPoint(of:revision:in:)` runs
/// `InputObserver`'s normalisation in reverse rather than reading
/// `CGEventGetLocation` a second time.
///
/// The AX work runs off the tap callback thread because of the asymmetry when
/// a target application hangs: inside the callback the tap is disabled and the
/// whole pointer track goes empty; behind the bounded queue only the affected
/// clicks' chains are lost, and `clicksDroppedByBacklog` counts them.
/// `AXUIElementSetMessagingTimeout` is not the answer — it still spends its
/// bounded delay on the callback thread and has no queue to absorb a burst.
///
/// A `.listenOnly` tap is disabled *without* `kCGEventTapDisabledByTimeout`
/// being delivered to its callback; that is why `InputObserver` polls.
///
/// `nonisolated` on everything: under `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor` an unannotated declaration is `@MainActor`, and this type is
/// reached from a bare C tap callback that traps at runtime on a MainActor
/// hop.
final class AXObserver: @unchecked Sendable {

    // MARK: - The bounds

    /// Ancestor-walk depth cap, fixed at 30 rather than a placeholder (D2-5).
    public nonisolated static let depthCap = 30

    /// 35 ms in nanoseconds: the walk's wall-clock budget, whose clock starts
    /// after the hit element has been described. A D4 placeholder. It does not
    /// bound the hit-test — `AXUIElementCopyElementAtPosition` takes no timeout
    /// parameter, so its cost is recorded in `AXChainRecord.hitTestInterval`
    /// instead. Truncation drops the outermost ancestors, never the hit element.
    public nonisolated static let walkBudgetNanos: Int64 = 35_000_000

    // MARK: - Diagnostics

    /// What this observer did, as counts held in memory and read by the caller
    /// after the fact; nothing here is written to the package. Three
    /// conservation laws below partition the clicks, the truncation reasons and
    /// the containment verdicts. `clickOutsideTheHitFrame` equal to
    /// `chainsRecorded` means the reverse coordinate conversion is wrong.
    public struct Diagnostics: Sendable, Equatable {
        public internal(set) var clicksObserved = 0
        public internal(set) var chainsRecorded = 0
        /// Clicks whose `revision` names no display in this observer's
        /// arrangement, so there was no global point to hit-test at. Non-zero
        /// means a stale arrangement; the click produces no record rather than
        /// a record hit-tested at a guessed point.
        public internal(set) var clicksWithNoGlobalPoint = 0
        /// Clicks stamped in a different boot session from this observer's
        /// own epoch. Counted, never corrected: the record uses the click's
        /// epoch, so the interval and the instant stay on one clock.
        public internal(set) var clicksFromAnotherEpoch = 0
        /// Clicks refused because `maximumQueuedClicks` were already waiting.
        /// A term in the conservation law: they happened and produced no record.
        public internal(set) var clicksDroppedByBacklog = 0
        /// The deepest the AX queue ever got. Approaching `maximumQueuedClicks`
        /// says the walk is not keeping up, before any click is dropped.
        public internal(set) var deepestBacklog = 0

        public internal(set) var truncatedReachedRoot = 0
        public internal(set) var truncatedDepthCapReached = 0
        public internal(set) var truncatedBudgetExceeded = 0
        /// Ancestor walks that ran all the way to `depthCap`, counted at the
        /// walk rather than from the record's final `truncation`, which a later
        /// budget overrun can overwrite. Deliberately outside every
        /// conservation law: it counts a phase, not a partition of the records.
        public internal(set) var ancestorWalksStoppedAtTheDepthCap = 0
        public internal(set) var hitTestsReturnedNothing = 0
        /// Of `hitTestsReturnedNothing`, those observed while Accessibility was
        /// not granted. Read only on that path, so the grant costs one TCC query
        /// per empty hit-test rather than one per click.
        public internal(set) var hitTestsReturnedNothingWithoutAccessibility = 0
        /// Clicks on this app's own windows, which are not asked about at all. Its own bucket
        /// rather than folded into `hitTestsReturnedNothing`: the two lead the camera to
        /// opposite decisions, so a count that merged them could not say which one happened.
        public internal(set) var clicksOverOwnWindow = 0

        public internal(set) var clickInsideTheHitFrame = 0
        public internal(set) var clickOutsideTheHitFrame = 0
        public internal(set) var clickFrameNotComparable = 0
        public internal(set) var recordsWithNoFrame = 0
        public internal(set) var recordsWithNoHitElement = 0

        public internal(set) var elementsDescribed = 0
        /// Elements whose `kAXPositionAttribute` or `kAXSizeAttribute` did not
        /// answer. Their `frame` is `nil`, never a zero rectangle, which would
        /// be a legal-looking element at the main display's top-left corner.
        public internal(set) var elementFramesUnavailable = 0
        /// Elements that answered with a non-finite coordinate or a negative
        /// dimension — the application misreporting itself, and values
        /// `PointRect.init` would trap on.
        public internal(set) var elementFramesUnusable = 0
        /// Elements whose frame origin lies on no display in this observer's
        /// arrangement — offscreen, or on a display that has since gone away.
        public internal(set) var elementFramesUnroutable = 0

        /// The children attribute was never asked for; the ancestor walk had
        /// already spent the budget. The record's `children` is `nil`.
        public internal(set) var childrenNotRead = 0
        /// The children attribute was asked for and did not answer. Also `nil`
        /// in the record, but a different fact, so counted separately.
        public internal(set) var childrenAttributeUnavailable = 0
        /// The children list was read but not every child could be described
        /// before the budget ran out; the record's `truncation` is
        /// `.budgetExceeded` even when the ancestor walk reached the root.
        public internal(set) var childrenReadsCutShortByBudget = 0

        public internal(set) var axCalls = 0
        /// Two consecutive `Minting.hostNow()` readings that went backwards.
        /// Impossible on a monotonic clock; counted rather than clamped in
        /// silence, and only ever checkable at zero since no fixture can make
        /// `mach_absolute_time` run backwards.
        public internal(set) var nonMonotonicClockReadings = 0

        // MARK: - The three laws
        //
        // Within one `chain(at:source:)` call each law is structurally true.
        // What they catch is the accumulation across a run: `merge` copies two
        // dozen fields by hand, and a missing line there is invisible at the
        // call site and produces plausible totals.

        /// Every click this observer was handed either produced a record or is
        /// counted as unconvertible, across the whole run.
        public var everyClickIsAccountedFor: Bool {
            clicksObserved == chainsRecorded + clicksWithNoGlobalPoint + clicksDroppedByBacklog
        }

        /// Every record carries exactly one of the five truncation reasons.
        /// `ancestorWalksStoppedAtTheDepthCap` is deliberately not a term here.
        public var everyRecordHasATruncationReason: Bool {
            chainsRecorded == truncatedReachedRoot + truncatedDepthCapReached
                + truncatedBudgetExceeded + hitTestsReturnedNothing + clicksOverOwnWindow
        }

        /// Every record falls into exactly one containment case.
        public var everyRecordHasAContainmentVerdict: Bool {
            chainsRecorded == clickInsideTheHitFrame + clickOutsideTheHitFrame
                + clickFrameNotComparable + recordsWithNoFrame + recordsWithNoHitElement
        }

        public var accounting: String {
            """
            clicks \(clicksObserved) = recorded \(chainsRecorded) + no global point \(clicksWithNoGlobalPoint)\
             + dropped by backlog \(clicksDroppedByBacklog)\
              → \(everyClickIsAccountedFor ? "balances" : "DOES NOT BALANCE")
            recorded \(chainsRecorded) = root \(truncatedReachedRoot) + depth \(truncatedDepthCapReached)\
             + budget \(truncatedBudgetExceeded) + no hit \(hitTestsReturnedNothing)\
              → \(everyRecordHasATruncationReason ? "balances" : "DOES NOT BALANCE")
            recorded \(chainsRecorded) = inside \(clickInsideTheHitFrame) + outside \(clickOutsideTheHitFrame)\
             + not comparable \(clickFrameNotComparable) + no frame \(recordsWithNoFrame)\
             + no element \(recordsWithNoHitElement)\
              → \(everyRecordHasAContainmentVerdict ? "balances" : "DOES NOT BALANCE")
            """
        }

        /// Zeroed. `public` so the app tier can construct one to diff against.
        public init() {}
    }

    public nonisolated var diagnostics: Diagnostics { lock.withLock { unsafe _diagnostics } }

    // MARK: - Stored state

    private let lock = NSLock()
    /// **The rectangle actually being recorded, not the display.**
    ///
    /// This was a `DisplayArrangement` and that was the defect: `InputObserver` moved to a
    /// `CaptureViewport` when a window recording was found to be normalising every pointer
    /// sample against the wrong rectangle, and this observer was not moved with it. The two
    /// then disagreed in every mode except whole-display capture, where the viewport IS the
    /// display and the numbers coincide.
    ///
    /// What that cost, in a window or region recording: a click normalised against the WINDOW
    /// was denormalised against the DISPLAY, so accessibility was asked what sits at the middle
    /// of the screen for a click at the middle of the window. `AXChainRecord.clickContainment`
    /// then compared two rectangles from two coordinate systems, `FramingGate` refused every
    /// chain, and the symptom a person saw was that window and region recordings never zoom.
    ///
    /// A `var` for `InputObserver`'s reason: a followed window moves and resizes mid-recording,
    /// and a viewport frozen at `start()` would put every later hit-test at a stale place.
    private nonisolated(unsafe) var viewport: CaptureViewport
    private let viewportLock = NSLock()
    private let epoch: BootEpoch
    private let accessibilityIsGranted: @Sendable () -> Bool
    /// The queue every AX call runs on — never the caller's, never the main one.
    private let queue = DispatchQueue(label: "video.soredemo.ax-observation", qos: .userInitiated)

    /// This app's own windows, published from the main actor and read here. Guarded by
    /// `ownWindowsLock` rather than `lock`: it is written from a different side of the app and
    /// sharing a lock with the observation state would make a window move wait behind a click.
    private nonisolated let ownWindowsLock = NSLock()
    private nonisolated(unsafe) var _ownWindows: OwnWindowExclusion = .nothing
    nonisolated var ownWindows: OwnWindowExclusion {
        ownWindowsLock.withLock { unsafe _ownWindows }
    }

    /// Tells the observer which windows are this app's. See `OwnWindowExclusion` for why it is
    /// told rather than asking: asking means reading every window on the machine, titles
    /// included, which this app must never do.
    public nonisolated func setOwnWindows(_ exclusion: OwnWindowExclusion) {
        ownWindowsLock.withLock { unsafe _ownWindows = exclusion }
    }
    // MARK: - state guarded by `lock`
    //
    // **Every access to the `nonisolated(unsafe)` properties below is marked `unsafe` at
    // its own expression, and one argument covers all of them**: each is read and written
    // only inside a `lock.withLock` block, or in a context that runs before the instance
    // is shared. `nonisolated(unsafe)` is what lets a `Sendable` type hold mutable state
    // under a lock; the compiler cannot see the lock, so the marks state what it cannot
    // check. Repeating that sentence at each of the 36 sites would say nothing extra —
    // the discipline is a property of the type, not of any one line.
    //
    // Surfaced by Phase 3A-3: `.strictMemorySafety()` applies to package targets, and this
    // file was in the app target until then, so none of these had ever been measured.
    private nonisolated(unsafe) var queuedClicks = 0
    private nonisolated(unsafe) var _diagnostics = Diagnostics()

    /// Pass the **same** `arrangement` the `InputObserver` producing the clicks
    /// was constructed with: a click's `revision` is looked up in it, so a
    /// mismatched pair yields `clicksWithNoGlobalPoint` on every click.
    ///
    /// `accessibilityIsGranted` is injected because the real predicate,
    /// `AXIsProcessTrusted()`, answers about *this executable's* TCC grant and
    /// so cannot answer about the right subject outside the app bundle.
    public init(viewport: CaptureViewport, epoch: BootEpoch,
                accessibilityIsGranted: @escaping @Sendable () -> Bool = {
                    CapturePermissions.status(of: .accessibility) == .granted
                }) {
        unsafe self.viewport = viewport
        self.epoch = epoch
        self.accessibilityIsGranted = accessibilityIsGranted
    }

    // MARK: - The conversion, in reverse

    /// Points the observer at a new recorded rectangle — a window that moved or was resized
    /// mid-recording. `CaptureSession` calls this and `InputObserver.updateViewport` from the
    /// same place, with the same value, because a hit-test aimed at one rectangle while the
    /// click that prompted it was normalised against another is the defect this whole type
    /// moved to a viewport to fix.
    public nonisolated func updateViewport(_ updated: CaptureViewport) {
        viewportLock.withLock { unsafe viewport = updated }
    }

    /// The rectangle currently being hit-tested against. For tests and for the window
    /// tracker's own check that its update landed.
    public nonisolated var currentViewport: CaptureViewport {
        viewportLock.withLock { unsafe viewport }
    }

    /// The global, top-left, **points** coordinate a `NormalizedPoint` came
    /// from — the input `AXUIElementCopyElementAtPosition` needs.
    ///
    /// The exact inverse of `InputObserver.normalizedPosition`, step for step,
    /// and it must stay that way: skipping the pixels→points step is off by the
    /// display's `scale`, skipping the origin step by its global origin, and
    /// neither fails to compile. The display is found by `revision`, since
    /// re-routing would need the global point this function produces.
    ///
    /// `nil` when `revision` names no display in `arrangement`; never a
    /// nearest-display guess, which would return a real element from a display
    /// the click was never on. The zero-size `NormalizedFrame` is how a point
    /// is spelled for `denormalize`, which has no point overload.
    public nonisolated static func globalPoint(of position: NormalizedPoint,
                                               revision: GeometryRevision,
                                               in viewport: CaptureViewport)
        -> (x: Double, y: Double)? {
        // **The revision still has to match**, and it is the one check that survives the move
        // from an arrangement to a viewport. A click carries the revision it was normalised
        // against; if the window has since been followed onto another display the viewport's
        // revision has moved on, and denormalising an old point against a new rectangle would
        // hit-test a place the click was never at. `nil` is the honest answer, counted as
        // `clicksWithNoGlobalPoint`.
        guard viewport.revision == revision else { return nil }
        return viewport.globalPoint(of: position)
    }

    /// An AX element's frame — global, top-left, **points**, as
    /// `kAXPositionAttribute` and `kAXSizeAttribute` report it — as a
    /// `NormalizedFrame` carrying the revision of the display its origin routed
    /// to. `NormalizationContext.normalize`'s rect overload anchors the Y flip
    /// on the rect's bottom edge; the point formula on a rect is off by the
    /// rect's own height.
    ///
    /// Routed by its origin, so a frame straddling two displays normalises
    /// against the display its top-left corner is on and may exceed width 1;
    /// that is recorded, not clamped. `nil` when the origin lies on no display,
    /// or on a non-finite coordinate or negative dimension, both of which
    /// `PointRect.init` would trap on.
    public nonisolated static func normalizedFrame(globalTopLeftX: Double, globalTopLeftY: Double,
                                                   width: Double, height: Double,
                                                   in viewport: CaptureViewport) -> NormalizedFrame? {
        viewport.normalise(globalTopLeftX: globalTopLeftX, globalTopLeftY: globalTopLeftY,
                           width: width, height: height)
    }

    // MARK: - The walk

    /// The AX observation for one click, against the real accessibility API.
    /// Needs the Accessibility grant; without it every hit-test answers with
    /// nothing.
    ///
    /// **Do not call this from `InputObserver`'s tap callback** — use
    /// `enqueue(_:onRecord:)`. `phase` is not filtered here: a caller wanting
    /// only `.down` filters before calling (D2-1). A caller that has to name
    /// the source it used should call `chain(at:source:)` instead, since this
    /// overload hard-codes `LiveAXElementSource`.
    public nonisolated func chain(at click: ButtonEvent) -> AXChainRecord? {
        chain(at: click, source: LiveAXElementSource(exclusion: ownWindows))
    }

    /// The production entry point: hands `click` to this observer's own serial
    /// queue and returns immediately, leaving two lock acquisitions and a
    /// `DispatchQueue.async` on the caller's thread.
    ///
    /// Serial rather than concurrent, so a hung target cannot be answered with
    /// more simultaneous IPCs into it, and so records stay in click order. The
    /// backlog is capped at `maximumQueuedClicks`; clicks past it are dropped
    /// and counted in `Diagnostics.clicksDroppedByBacklog`.
    ///
    /// `onRecord` is called **on the AX queue**, not the caller's.
    public nonisolated func enqueue(_ click: ButtonEvent,
                                    onRecord: @escaping @Sendable (AXChainRecord) -> Void) {
        enqueue(click, source: LiveAXElementSource(exclusion: ownWindows), onRecord: onRecord)
    }

    /// The same, over an injected source, so a caller whose output has to name
    /// the source that produced its numbers can print the value's own type.
    public nonisolated func enqueue<Source: AXElementSource>(
        _ click: ButtonEvent, source: Source,
        onRecord: @escaping @Sendable (AXChainRecord) -> Void
    ) {
        let accepted = lock.withLock { () -> Bool in
            guard unsafe queuedClicks < Self.maximumQueuedClicks else {
                // Counted here rather than in `chain`, which this click never
                // reaches — into `clicksObserved` too, or the conservation law
                // would absorb the drop.
                unsafe _diagnostics.clicksObserved += 1
                unsafe _diagnostics.clicksDroppedByBacklog += 1
                return false
            }
            unsafe queuedClicks += 1
            if unsafe queuedClicks > _diagnostics.deepestBacklog { unsafe _diagnostics.deepestBacklog = unsafe queuedClicks }
            return true
        }
        guard accepted else { return }
        queue.async { [self] in
            lock.withLock { unsafe queuedClicks -= 1 }
            if let record = chain(at: click, source: source) { onRecord(record) }
        }
    }

    /// How many clicks may be waiting for the AX queue before further ones are
    /// dropped. Whatever this becomes it must stay bounded: the failure it
    /// exists for is one hung application and a person still clicking.
    public nonisolated static let maximumQueuedClicks = 8

    /// Blocks until every enqueued click has been observed.
    ///
    /// Part of a recording's normal flow, not just the probe's:
    /// `CaptureSession.finalizeCurrentSegment` calls it before closing a
    /// segment's `ObservationWriter` (D2-12), and it can block for up to
    /// `walkBudgetNanos` × `maximumQueuedClicks` at every segment boundary.
    public nonisolated func waitForQueuedClicks() {
        queue.sync {}
    }

    /// The walk itself, over an injected `AXElementSource`. The seam exists so
    /// the bounds, truncation reasons and call arithmetic can be checked
    /// without an Accessibility grant and without a UI; it does not check that
    /// `LiveAXElementSource` asks the right questions of the real API.
    public nonisolated func chain<Source: AXElementSource>(at click: ButtonEvent,
                                                           source: Source) -> AXChainRecord? {
        var tally = Diagnostics()
        tally.clicksObserved = 1
        if click.instant.epoch != epoch { tally.clicksFromAnotherEpoch = 1 }
        // The record's own epoch is the CLICK's, not this observer's: the
        // instant and the interval have to be on one clock.
        let epoch = click.instant.epoch

        guard let point = Self.globalPoint(of: click.position, revision: click.revision,
                                           in: currentViewport) else {
            tally.clicksWithNoGlobalPoint = 1
            merge(tally)
            return nil
        }

        // The hit-test, and NOTHING else, inside the recorded interval: the API
        // carries no timestamp, so this interval's width is the whole
        // uncertainty about when the answer was true (D2-2a).
        //
        // **Our own windows are decided HERE, before any source is asked.** It used to be only
        // `LiveAXElementSource.hitTest` that knew, answering `nil` — which reads exactly like
        // "nothing there", and "nothing there" is what the camera's pointer fallback zooms to.
        // A click on the recording bar's Stop was therefore a zoom on the last 0.4 s of every
        // recording stopped from it (`ZoomBlock.preRoll`). Deciding it here names the reason in
        // the record; the live source keeps its own check, because asking about our own window
        // in-process is the crash `OwnWindowExclusion` was written for.
        let overOwnWindow = ownWindows.contains(globalTopLeftX: point.x, globalTopLeftY: point.y)
        let hitTestBefore = Minting.hostNow()
        let hitElement = overOwnWindow
            ? nil : source.hitTest(globalTopLeftX: point.x, globalTopLeftY: point.y)
        let hitTestAfter = Minting.hostNow()
        tally.axCalls += 1
        let hitTestInterval = range(from: hitTestBefore, to: hitTestAfter, epoch: epoch, into: &tally)

        func finish(hit: AXElementRecord?, ancestors: [AXElementRecord],
                    children: [AXElementRecord]?, truncation: ChainTruncation) -> AXChainRecord {
            let record = AXChainRecord(instant: click.instant,
                                       clickPosition: click.position,
                                       clickRevision: click.revision,
                                       hitTestGlobalX: point.x,
                                       hitTestGlobalY: point.y,
                                       hitTestInterval: hitTestInterval,
                                       hit: hit,
                                       ancestors: ancestors,
                                       children: children,
                                       truncation: truncation,
                                       axCalls: tally.axCalls,
                                       depthCap: Self.depthCap,
                                       walkBudgetNanos: Self.walkBudgetNanos)
            tally.chainsRecorded = 1
            switch truncation {
            case .reachedRoot:            tally.truncatedReachedRoot = 1
            case .depthCapReached:        tally.truncatedDepthCapReached = 1
            case .budgetExceeded:         tally.truncatedBudgetExceeded = 1
            case .hitTestReturnedNothing: tally.hitTestsReturnedNothing = 1
            case .overOwnWindow:          tally.clicksOverOwnWindow = 1
            }
            // Computed from the record about to be returned, so what is counted
            // here and what a reader recomputes from disk cannot disagree.
            switch record.clickContainment {
            case .containsTheClick:       tally.clickInsideTheHitFrame = 1
            case .doesNotContainTheClick: tally.clickOutsideTheHitFrame = 1
            case .notComparable:          tally.clickFrameNotComparable = 1
            case .noFrameRecorded:        tally.recordsWithNoFrame = 1
            case .noHitElement:           tally.recordsWithNoHitElement = 1
            }
            merge(tally)
            return record
        }

        if overOwnWindow {
            return finish(hit: nil, ancestors: [], children: nil, truncation: .overOwnWindow)
        }

        guard let hitElement else {
            // Asked only on this path: "AX answered with nothing" and "this
            // app may not ask" are otherwise the same empty record.
            if !accessibilityIsGranted() {
                tally.hitTestsReturnedNothingWithoutAccessibility = 1
            }
            return finish(hit: nil, ancestors: [], children: nil, truncation: .hitTestReturnedNothing)
        }

        let hit = describe(hitElement, source: source, epoch: epoch, into: &tally)

        // The budget clock starts HERE, after the hit element has been
        // described. So the hit-test and the hit element's four attribute reads
        // sit outside the budget entirely; neither can be bounded, and both are
        // recorded instead, as `hitTestInterval` and `hit.readInterval`.
        let walkStart = Minting.hostNow()
        func budgetSpent() -> Bool {
            Minting.hostNow().rawValue - walkStart.rawValue > Self.walkBudgetNanos
        }

        // ---- up: the bounded ancestor walk (D2-2), innermost first.
        var ancestors: [AXElementRecord] = []
        var truncation = ChainTruncation.reachedRoot
        var current = hitElement
        for depth in 0..<Self.depthCap {
            if budgetSpent() { truncation = .budgetExceeded; break }
            tally.axCalls += 1
            guard let parent = source.parent(of: current) else { break }
            ancestors.append(describe(parent, source: source, epoch: epoch, into: &tally))
            current = parent
            // Set only after a level was actually appended: a walk whose last
            // parent lookup came back empty reached the root, it did not hit
            // the cap.
            if depth == Self.depthCap - 1 {
                truncation = .depthCapReached
                // Counted here as well as in `finish`, deliberately: the
                // children phase below may overwrite `truncation` with
                // `.budgetExceeded`, hiding that the cap bound at all.
                tally.ancestorWalksStoppedAtTheDepthCap = 1
            }
        }

        // ---- down: one level (D2-3), under what is left of the same budget.
        // After the walk, not before, so a click whose budget runs out loses
        // its outermost ancestors rather than its children.
        var children: [AXElementRecord]?
        if budgetSpent() {
            tally.childrenNotRead = 1
            truncation = .budgetExceeded
        } else {
            tally.axCalls += 1
            if let kids = source.children(of: hitElement) {
                var described: [AXElementRecord] = []
                for kid in kids {
                    if budgetSpent() {
                        // The list was read but not all of it described.
                        // `.budgetExceeded` even when the walk above reached
                        // the root: truncation is about the whole observation.
                        tally.childrenReadsCutShortByBudget = 1
                        truncation = .budgetExceeded
                        break
                    }
                    described.append(describe(kid, source: source, epoch: epoch, into: &tally))
                }
                children = described
            } else {
                tally.childrenAttributeUnavailable = 1
            }
        }

        return finish(hit: hit, ancestors: ancestors, children: children, truncation: truncation)
    }

    /// Four AX calls in one bracketed interval: role, position, size, title. A
    /// frame costs two of them because `kAXFrameAttribute` is not exposed to
    /// Swift. The interval's width is the uncertainty about this element only,
    /// not about the chain, whose levels are read at different moments.
    /// Roles whose `kAXTitleAttribute` is the content they hold rather than a label on them: a
    /// window's title is whatever document is open in it, a web area's is the page's. **The
    /// log may carry AX titles because a title is the interface's own label**
    /// (`noAppSourceReadsUserContent`); these two are the exception that the rule's own reason
    /// excludes, and the same text `WindowTarget` and the ban on `kCGWindowName` keep out by
    /// other routes. Closed by construction: a role added here is a visible edit.
    /// `docs/design/2026-10-25-a-window-title-is-content.md`.
    nonisolated static let rolesWhoseTitleIsContent: Set<String> = ["AXWindow", "AXWebArea"]

    private nonisolated func describe<Source: AXElementSource>(
        _ element: Source.Element, source: Source, epoch: BootEpoch, into tally: inout Diagnostics
    ) -> AXElementRecord {
        let before = Minting.hostNow()
        let role = source.role(of: element)
        let position = source.position(of: element)
        let size = source.size(of: element)
        // **Not asked for at all** where the title is the content the element holds — a window's
        // is its document's name, a web area's its page's. See `rolesWhoseTitleIsContent`.
        let readsTitle = !Self.rolesWhoseTitleIsContent.contains(role ?? "")
        let title = readsTitle ? source.title(of: element) : nil
        let after = Minting.hostNow()
        tally.axCalls += readsTitle ? 4 : 3
        tally.elementsDescribed += 1

        var frame: NormalizedFrame?
        if let position, let size {
            frame = Self.normalizedFrame(globalTopLeftX: position.x, globalTopLeftY: position.y,
                                         width: size.width, height: size.height,
                                         in: currentViewport)
            if frame == nil {
                // Two different findings: the element misreported itself, or its origin is
                // outside the rectangle being recorded — an element on another part of the
                // screen than the window in shot, which is normal and not a fault.
                let usable = position.x.isFinite && position.y.isFinite
                    && size.width.isFinite && size.height.isFinite
                    && size.width >= 0 && size.height >= 0
                if usable { tally.elementFramesUnroutable += 1 }
                else { tally.elementFramesUnusable += 1 }
            }
        } else {
            tally.elementFramesUnavailable += 1
        }

        return AXElementRecord(role: role, title: title, frame: frame,
                               readInterval: range(from: before, to: after, epoch: epoch, into: &tally))
    }

    /// A `HostRange` from two `Minting.hostNow()` readings. A negative width is
    /// impossible on one monotonic clock but is counted and clamped anyway,
    /// because `HostRange` traps on a negative duration.
    private nonisolated func range(from before: Nanoseconds, to after: Nanoseconds,
                                   epoch: BootEpoch, into tally: inout Diagnostics) -> HostRange {
        let width = after.rawValue - before.rawValue
        if width < 0 { tally.nonMonotonicClockReadings += 1 }
        return HostRange(epoch: epoch, start: before, duration: Nanoseconds(max(0, width)))
    }

    /// Adds one observation's counters into the shared totals, once, at the
    /// end. The lock must never be held across an AX call: a synchronous IPC
    /// into a hung application would block every reader of `diagnostics`.
    private nonisolated func merge(_ tally: Diagnostics) {
        lock.withLock {
            unsafe _diagnostics.clicksObserved += tally.clicksObserved
            unsafe _diagnostics.chainsRecorded += tally.chainsRecorded
            unsafe _diagnostics.clicksWithNoGlobalPoint += tally.clicksWithNoGlobalPoint
            unsafe _diagnostics.clicksFromAnotherEpoch += tally.clicksFromAnotherEpoch
            unsafe _diagnostics.clicksDroppedByBacklog += tally.clicksDroppedByBacklog
            unsafe _diagnostics.truncatedReachedRoot += tally.truncatedReachedRoot
            unsafe _diagnostics.truncatedDepthCapReached += tally.truncatedDepthCapReached
            unsafe _diagnostics.truncatedBudgetExceeded += tally.truncatedBudgetExceeded
            unsafe _diagnostics.ancestorWalksStoppedAtTheDepthCap += tally.ancestorWalksStoppedAtTheDepthCap
            unsafe _diagnostics.hitTestsReturnedNothing += tally.hitTestsReturnedNothing
            unsafe _diagnostics.hitTestsReturnedNothingWithoutAccessibility
                += tally.hitTestsReturnedNothingWithoutAccessibility
            unsafe _diagnostics.clicksOverOwnWindow += tally.clicksOverOwnWindow
            unsafe _diagnostics.clickInsideTheHitFrame += tally.clickInsideTheHitFrame
            unsafe _diagnostics.clickOutsideTheHitFrame += tally.clickOutsideTheHitFrame
            unsafe _diagnostics.clickFrameNotComparable += tally.clickFrameNotComparable
            unsafe _diagnostics.recordsWithNoFrame += tally.recordsWithNoFrame
            unsafe _diagnostics.recordsWithNoHitElement += tally.recordsWithNoHitElement
            unsafe _diagnostics.elementsDescribed += tally.elementsDescribed
            unsafe _diagnostics.elementFramesUnavailable += tally.elementFramesUnavailable
            unsafe _diagnostics.elementFramesUnusable += tally.elementFramesUnusable
            unsafe _diagnostics.elementFramesUnroutable += tally.elementFramesUnroutable
            unsafe _diagnostics.childrenNotRead += tally.childrenNotRead
            unsafe _diagnostics.childrenAttributeUnavailable += tally.childrenAttributeUnavailable
            unsafe _diagnostics.childrenReadsCutShortByBudget += tally.childrenReadsCutShortByBudget
            unsafe _diagnostics.axCalls += tally.axCalls
            unsafe _diagnostics.nonMonotonicClockReadings += tally.nonMonotonicClockReadings
        }
    }
}

// MARK: - The seam

/// The accessibility primitives the walk is built from — **one IPC round trip
/// per function**, which is what makes `AXChainRecord.axCalls` real. There is
/// deliberately no `frame(of:)`: a frame is `position` *and* `size`, two round
/// trips, and hiding that would understate the budget it is spent against.
///
/// `Element` is not constrained to `Sendable` because `AXUIElement` is not, and
/// need not be: every element is consumed inside the single synchronous
/// `AXObserver.chain(at:source:)` call that produced it, and none escapes.
nonisolated protocol AXElementSource: Sendable {
    associatedtype Element

    /// The **deepest** element at a global, top-left, points coordinate.
    /// `nil` when nothing is there, when the target application does not
    /// answer, or when this process is not trusted for Accessibility.
    func hitTest(globalTopLeftX: Double, globalTopLeftY: Double) -> Element?
    func role(of element: Element) -> String?
    func title(of element: Element) -> String?
    /// Global, top-left, **points** — the same space `CGEventGetLocation`
    /// reports in, so a click coordinate is comparable against this.
    func position(of element: Element) -> (x: Double, y: Double)?
    func size(of element: Element) -> (width: Double, height: Double)?
    func parent(of element: Element) -> Element?
    /// The element's direct children, or `nil` if the attribute did not answer.
    /// An empty array means the element has none; the two are different facts.
    func children(of element: Element) -> [Element]?
}

/// The real thing: `AXUIElement`, over the real accessibility API. Every
/// CoreGraphics value stays inside `CGGeometryBridge` (architecture rule 5), so
/// this struct never names `CGPoint` or `CGSize`.
struct LiveAXElementSource: AXElementSource {
    public typealias Element = AXUIElement

    /// This app's own windows, which are never asked about. See `OwnWindowExclusion`.
    let exclusion: OwnWindowExclusion

    public init(exclusion: OwnWindowExclusion = .nothing) {
        self.exclusion = exclusion
    }

    /// The system-wide element is created per call rather than stored: it is a
    /// local object, not an IPC, and storing it would make this struct hold a
    /// non-`Sendable` CoreFoundation reference for the observer's lifetime.
    public nonisolated func hitTest(globalTopLeftX: Double, globalTopLeftY: Double) -> AXUIElement? {
        // **This app's own windows are not asked about, and the reason is a crash rather than
        // taste.** The call below is served IN THIS PROCESS when the point is over one of our
        // windows, on this background queue, where AppKit's accessibility server reads window
        // geometry — `NSWindow geometry should only be modified on the main thread!`. See
        // `OwnWindowExclusion`. Cheap enough here: this runs once per click, not per sample.
        guard !exclusion.contains(globalTopLeftX: globalTopLeftX,
                                  globalTopLeftY: globalTopLeftY) else { return nil }
        var element: AXUIElement?
        // `Float`, because that is the API's parameter type. Its 24-bit
        // significand is exact to 16,777,216, so a screen coordinate loses
        // nothing in the narrowing.
        let error = unsafe AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                                     Float(globalTopLeftX),
                                                     Float(globalTopLeftY),
                                                     &element)
        return error == .success ? element : nil
    }

    public nonisolated func role(of element: AXUIElement) -> String? {
        copyAttribute(.role, of: element) as? String
    }

    /// A title is UI text and is recorded on purpose — the label on a control,
    /// never keystroke content, which
    /// `AppSourceTests.noAppSourceReadsKeystrokeText` enforces app-wide.
    public nonisolated func title(of element: AXUIElement) -> String? {
        copyAttribute(.title, of: element) as? String
    }

    public nonisolated func position(of element: AXUIElement) -> (x: Double, y: Double)? {
        CGGeometryBridge.point(fromAXValue: copyAttribute(.position, of: element))
    }

    public nonisolated func size(of element: AXUIElement) -> (width: Double, height: Double)? {
        CGGeometryBridge.size(fromAXValue: copyAttribute(.size, of: element))
    }

    public nonisolated func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(.parent, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Type-ID guarded member by member, like `parent(of:)`: the value must be
    /// a CFArray and **every** member an `AXUIElement`, or the result is `nil`.
    /// A conditional `as? [AXUIElement]` could succeed partially and drop
    /// members with nothing counting the loss.
    public nonisolated func children(of element: AXUIElement) -> [AXUIElement]? {
        guard let value = copyAttribute(.children, of: element),
              CFGetTypeID(value) == CFArrayGetTypeID(),
              let members = value as? [CFTypeRef] else { return nil }
        guard members.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
        return members.map { $0 as! AXUIElement }
    }

    /// One `AXUIElementCopyAttributeValue`, one synchronous IPC into the target
    /// process. Any `AXError` other than `.success` becomes `nil`; the
    /// distinctions among them are not preserved, because the one a reader
    /// needs is counted once in
    /// `AXObserver.Diagnostics.hitTestsReturnedNothingWithoutAccessibility`.
    private nonisolated func copyAttribute(_ attribute: ReadableAXAttribute,
                                           of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = unsafe AXUIElementCopyAttributeValue(element, attribute.name as CFString, &value)
        return error == .success ? value : nil
    }
}

/// **The complete list of AX attributes this app is able to read**, as a closed
/// type rather than a `String` parameter, because
/// `AXUIElementCopyAttributeValue` is stringly-typed and the content scan
/// (`AppSourceTests.noAppSourceReadsUserContent`) cannot see inside a string
/// literal. A permitted set is closed by construction where a ban list is not;
/// adding an attribute is a visible edit here. There is deliberately no case
/// for the text *inside* a control.
enum ReadableAXAttribute {
    /// `kAXRoleAttribute` — what kind of element this is.
    case role
    /// `kAXTitleAttribute` — the label **on** a control, never the text inside
    /// one. Recorded on purpose; see `AXObserver.title(of:)`.
    case title
    /// `kAXPositionAttribute` — where it is.
    case position
    /// `kAXSizeAttribute` — how big it is.
    case size
    /// `kAXParentAttribute` — one level up, for the ancestor walk.
    case parent
    /// `kAXChildrenAttribute` — one level down (D2-3), never a tree search.
    case children

    /// The CoreFoundation constant — **the only place in this app where an AX
    /// attribute name is written**. `nonisolated` is required: the AX walk runs
    /// off the main actor, and under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
    /// an unannotated property here is unreachable from it.
    nonisolated var name: String {
        switch self {
        case .role: kAXRoleAttribute
        case .title: kAXTitleAttribute
        case .position: kAXPositionAttribute
        case .size: kAXSizeAttribute
        case .parent: kAXParentAttribute
        case .children: kAXChildrenAttribute
        }
    }
}
