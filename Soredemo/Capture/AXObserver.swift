import ApplicationServices
import Foundation
import Geometry
import Project
import Timeline
// `Minting` — in `Headless` since Phase 3A-3.
import Headless

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
public final class AXObserver: @unchecked Sendable {

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

        /// Every record carries exactly one of the four truncation reasons.
        /// `ancestorWalksStoppedAtTheDepthCap` is deliberately not a term here.
        public var everyRecordHasATruncationReason: Bool {
            chainsRecorded == truncatedReachedRoot + truncatedDepthCapReached
                + truncatedBudgetExceeded + hitTestsReturnedNothing
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
    }

    public nonisolated var diagnostics: Diagnostics { lock.withLock { _diagnostics } }

    // MARK: - Stored state

    private let lock = NSLock()
    private let arrangement: DisplayArrangement
    private let epoch: BootEpoch
    private let accessibilityIsGranted: @Sendable () -> Bool
    /// The queue every AX call runs on — never the caller's, never the main one.
    private let queue = DispatchQueue(label: "video.soredemo.ax-observation", qos: .userInitiated)
    private nonisolated(unsafe) var queuedClicks = 0
    private nonisolated(unsafe) var _diagnostics = Diagnostics()

    /// Pass the **same** `arrangement` the `InputObserver` producing the clicks
    /// was constructed with: a click's `revision` is looked up in it, so a
    /// mismatched pair yields `clicksWithNoGlobalPoint` on every click.
    ///
    /// `accessibilityIsGranted` is injected because the real predicate,
    /// `AXIsProcessTrusted()`, answers about *this executable's* TCC grant and
    /// so cannot answer about the right subject outside the app bundle.
    public init(arrangement: DisplayArrangement, epoch: BootEpoch,
                accessibilityIsGranted: @escaping @Sendable () -> Bool = {
                    CapturePermissions.status(of: .accessibility) == .granted
                }) {
        self.arrangement = arrangement
        self.epoch = epoch
        self.accessibilityIsGranted = accessibilityIsGranted
    }

    // MARK: - The conversion, in reverse

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
                                               in arrangement: DisplayArrangement)
        -> (x: Double, y: Double)? {
        guard let placement = arrangement.placements
            .first(where: { $0.geometry.revision == revision }) else { return nil }
        let geometry = placement.geometry
        // Step 4 in reverse — normalised, bottom-left → display-local pixels.
        let pixels = NormalizationContext(geometry: geometry).denormalize(
            NormalizedFrame(origin: position,
                            size: NormalizedSize(width: 0, height: 0),
                            revision: revision))
        // Step 3 in reverse — display-local pixels → display-local points.
        let points = geometry.points(from: pixels)
        // Step 2 in reverse — display-local points → global points.
        return (placement.globalOriginX + points.x, placement.globalOriginY + points.y)
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
                                                   in arrangement: DisplayArrangement) -> NormalizedFrame? {
        guard globalTopLeftX.isFinite, globalTopLeftY.isFinite,
              width.isFinite, height.isFinite, width >= 0, height >= 0 else { return nil }
        // Step 2 — global points → display-local points.
        guard let hit = arrangement.route(globalTopLeftX: globalTopLeftX,
                                          globalTopLeftY: globalTopLeftY) else { return nil }
        // Step 3 — display-local points → display-local native pixels.
        let pixels = hit.geometry.pixels(
            from: PointRect(x: hit.localX, y: hit.localY, width: width, height: height))
        // Step 4 — display-local pixels → normalised, bottom-left, 0…1.
        return NormalizationContext(geometry: hit.geometry)
            .normalize(topLeftX: pixels.x, topLeftY: pixels.y,
                       width: pixels.width, height: pixels.height)
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
        chain(at: click, source: LiveAXElementSource())
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
        enqueue(click, source: LiveAXElementSource(), onRecord: onRecord)
    }

    /// The same, over an injected source, so a caller whose output has to name
    /// the source that produced its numbers can print the value's own type.
    public nonisolated func enqueue<Source: AXElementSource>(
        _ click: ButtonEvent, source: Source,
        onRecord: @escaping @Sendable (AXChainRecord) -> Void
    ) {
        let accepted = lock.withLock { () -> Bool in
            guard queuedClicks < Self.maximumQueuedClicks else {
                // Counted here rather than in `chain`, which this click never
                // reaches — into `clicksObserved` too, or the conservation law
                // would absorb the drop.
                _diagnostics.clicksObserved += 1
                _diagnostics.clicksDroppedByBacklog += 1
                return false
            }
            queuedClicks += 1
            if queuedClicks > _diagnostics.deepestBacklog { _diagnostics.deepestBacklog = queuedClicks }
            return true
        }
        guard accepted else { return }
        queue.async { [self] in
            lock.withLock { queuedClicks -= 1 }
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
                                           in: arrangement) else {
            tally.clicksWithNoGlobalPoint = 1
            merge(tally)
            return nil
        }

        // The hit-test, and NOTHING else, inside the recorded interval: the API
        // carries no timestamp, so this interval's width is the whole
        // uncertainty about when the answer was true (D2-2a).
        let hitTestBefore = Minting.hostNow()
        let hitElement = source.hitTest(globalTopLeftX: point.x, globalTopLeftY: point.y)
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
    private nonisolated func describe<Source: AXElementSource>(
        _ element: Source.Element, source: Source, epoch: BootEpoch, into tally: inout Diagnostics
    ) -> AXElementRecord {
        let before = Minting.hostNow()
        let role = source.role(of: element)
        let position = source.position(of: element)
        let size = source.size(of: element)
        let title = source.title(of: element)
        let after = Minting.hostNow()
        tally.axCalls += 4
        tally.elementsDescribed += 1

        var frame: NormalizedFrame?
        if let position, let size {
            frame = Self.normalizedFrame(globalTopLeftX: position.x, globalTopLeftY: position.y,
                                         width: size.width, height: size.height,
                                         in: arrangement)
            if frame == nil {
                // Two different findings: the element misreported itself, or it
                // is somewhere this arrangement does not cover.
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
            _diagnostics.clicksObserved += tally.clicksObserved
            _diagnostics.chainsRecorded += tally.chainsRecorded
            _diagnostics.clicksWithNoGlobalPoint += tally.clicksWithNoGlobalPoint
            _diagnostics.clicksFromAnotherEpoch += tally.clicksFromAnotherEpoch
            _diagnostics.clicksDroppedByBacklog += tally.clicksDroppedByBacklog
            _diagnostics.truncatedReachedRoot += tally.truncatedReachedRoot
            _diagnostics.truncatedDepthCapReached += tally.truncatedDepthCapReached
            _diagnostics.truncatedBudgetExceeded += tally.truncatedBudgetExceeded
            _diagnostics.ancestorWalksStoppedAtTheDepthCap += tally.ancestorWalksStoppedAtTheDepthCap
            _diagnostics.hitTestsReturnedNothing += tally.hitTestsReturnedNothing
            _diagnostics.hitTestsReturnedNothingWithoutAccessibility
                += tally.hitTestsReturnedNothingWithoutAccessibility
            _diagnostics.clickInsideTheHitFrame += tally.clickInsideTheHitFrame
            _diagnostics.clickOutsideTheHitFrame += tally.clickOutsideTheHitFrame
            _diagnostics.clickFrameNotComparable += tally.clickFrameNotComparable
            _diagnostics.recordsWithNoFrame += tally.recordsWithNoFrame
            _diagnostics.recordsWithNoHitElement += tally.recordsWithNoHitElement
            _diagnostics.elementsDescribed += tally.elementsDescribed
            _diagnostics.elementFramesUnavailable += tally.elementFramesUnavailable
            _diagnostics.elementFramesUnusable += tally.elementFramesUnusable
            _diagnostics.elementFramesUnroutable += tally.elementFramesUnroutable
            _diagnostics.childrenNotRead += tally.childrenNotRead
            _diagnostics.childrenAttributeUnavailable += tally.childrenAttributeUnavailable
            _diagnostics.childrenReadsCutShortByBudget += tally.childrenReadsCutShortByBudget
            _diagnostics.axCalls += tally.axCalls
            _diagnostics.nonMonotonicClockReadings += tally.nonMonotonicClockReadings
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
public nonisolated protocol AXElementSource: Sendable {
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
public struct LiveAXElementSource: AXElementSource {
    public typealias Element = AXUIElement

    public init() {}

    /// The system-wide element is created per call rather than stored: it is a
    /// local object, not an IPC, and storing it would make this struct hold a
    /// non-`Sendable` CoreFoundation reference for the observer's lifetime.
    public nonisolated func hitTest(globalTopLeftX: Double, globalTopLeftY: Double) -> AXUIElement? {
        var element: AXUIElement?
        // `Float`, because that is the API's parameter type. Its 24-bit
        // significand is exact to 16,777,216, so a screen coordinate loses
        // nothing in the narrowing.
        let error = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
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
        let error = AXUIElementCopyAttributeValue(element, attribute.name as CFString, &value)
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
