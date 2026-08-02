import ApplicationServices
import Foundation
import Geometry
import Project
import Timeline

/// `ROADMAP.md`'s `ax-observation` row: for each click, the accessibility
/// element under the pointer, with its role, its frame, and a **bounded** walk
/// of its ancestors — recorded, and **not judged** (D2-1).
///
/// **Nothing here chooses an element.** The row's preference for well-bounded
/// descendants is a gate, and `ARCHITECTURE.md` D4 requires a gate's
/// thresholds to be fitted to measured distributions that do not exist yet.
/// Choosing at capture time would write a producer's judgement into the
/// evidence layer and make `producerVersion` meaningless for that decision,
/// because the alternatives would be gone. So the whole chain goes to disk,
/// both directions (D2-3), and the derivation stage chooses later.
///
/// **The name shadows `ApplicationServices.AXObserver`, deliberately.** That
/// type is the notification-observer API (`AXObserverCreate`), which this file
/// does not use and this project has no plan to: a notification observer is a
/// subscription to another process's UI changes, where this row wants a
/// point-in-time hit-test per click. Nothing in this app names Apple's
/// `AXObserver`, so the shadowing costs nothing today; a file that needs both
/// must qualify the framework's as `ApplicationServices.AXObserver`.
///
/// ## Where the two clocks and the two coordinate spaces meet
///
/// This type sits directly downstream of `InputObserver`'s `ButtonEvent`s, and
/// **it does not re-derive their coordinates.** Task 9's human verification
/// measured that path against real hardware — 395 pointer samples with
/// `min/max` of `0.0000/1.0000` on both axes, one click producing exactly two
/// button events at the same normalised position — so a `ButtonEvent`'s
/// `position` and `revision` are trustworthy inputs. `AXUIElementCopyElement
/// AtPosition` needs a global point back, and `globalPoint(of:revision:in:)`
/// below gets it by running that same four-step conversion **in reverse**,
/// through `NormalizationContext` and `DisplayArrangement`, rather than
/// reading `CGEventGetLocation` a second time. A second path to the same
/// number is a second path to disagree about it.
///
/// ## What the bounds are, and which one is a placeholder
///
/// **Depth 30 is fixed, not a placeholder** (D2-5). F2-2 measured a clean
/// knee: a cap of 25 covered every one of 118 samples, and the walks that hit
/// a cap of 20 completed in 4–13 ms, because deep means web content — cheap
/// per level, simply tall.
///
/// **The 35 ms budget is the one genuine placeholder in this file**, awaiting
/// D4 calibration against recorded demos. It has no knee at all: 20 ms
/// truncates 15% of clicks, 35 ms 9%, 50 ms 7%, and the tail never reaches
/// zero. It is also the number that will move most on a slower or busier
/// machine. See `walkBudgetNanos` for why raising it is not the improvement it
/// looks like.
///
/// ## Why the AX work is not on the tap callback thread
///
/// **This section is the one justification; `enqueue(_:onRecord:)` and
/// `chain(at:source:)` point here rather than restating it.** It is written at
/// length because the reasoning that used to be here was wrong, was acted on,
/// and would be re-derived by the next person to measure the thing it got
/// wrong.
///
/// ### The reason it is off-thread: the asymmetry of what is lost
///
/// Not "an AX call has no upper bound". That argument needs the reader to
/// believe a hung application is likely, and its force therefore moves every
/// time someone re-measures how likely that is. The argument that does not
/// move is what happens **when one does hang**:
///
/// | | what is lost |
/// | --- | --- |
/// | AX **inside** the callback | the tap is disabled → the **whole pointer track** goes empty, for a span nothing bounds |
/// | AX **off** the callback | the bounded queue fills → the **AX chain for the affected clicks only**, and `clicksDroppedByBacklog` counts them |
///
/// The pointer track is the skeleton of the evidence; an AX chain is per-click
/// enrichment sitting on top of it, and it is an input to a derivation that
/// `framing-gates` can refuse. **Losing something a gate can refuse beats
/// losing the skeleton**, however unlikely the trigger — and the second loss
/// is not merely smaller, it is a different kind of thing. That is why the
/// design does not change when the threshold below changes.
///
/// ### Measured: a 125 ms cost per click does **not** disable the tap
///
/// Spike C step 6, part A: a 125 ms stall — Spike A's *worst* observed
/// hit-test — imposed on `.leftMouseDown` **only**, 30 s, 1928 callbacks. The
/// tap was still enabled at the end and was **never once seen disabled**.
///
/// ### Falsified, and recorded as falsified rather than replaced
///
/// This file used to say, twice, that a callback exceeding a **10–50 ms**
/// budget gets the tap switched off, and that Spike A's p90 hit-test of
/// 21.25 ms therefore killed the pointer track on more than one click in ten.
/// **That is not true, and the number it rested on was measuring something
/// else.**
///
/// Step 5 stalled on **every `mouseMoved`**, which arrives at 60–120 Hz. A
/// 20 ms stall against a 120 Hz stream cannot keep up by construction: the
/// backlog grows without bound and the system disables a *persistently
/// overloaded* tap. The conclusion drawn from that was written about a
/// **single slow callback**, which is a different thing. Real AX work happens
/// on clicks, one to three seconds apart — 125 ms every two seconds is a **6%
/// duty cycle**, two orders of magnitude below what step 5 imposed.
///
/// It is the same mistake as a fixture whose distribution does not match its
/// subject, which this project has now made three times, here at a new scope:
/// the *rate* was the part of the fixture that did not match.
///
/// So: if you are reading this because you have just measured that a slow
/// callback is survivable — that is correct, it is above, and it is not a
/// reason to move this work back into the callback. The reason is the
/// asymmetry, not the threshold.
///
/// **What from step 5 still stands**, because only its threshold was an
/// artefact: a `.listenOnly` tap is disabled **without**
/// `kCGEventTapDisabledByTimeout` being delivered to its callback — 0
/// notifications at every rung, while `CGEvent.tapIsEnabled(tap:)` read false,
/// with a `.defaultTap` control receiving the notification in the same run.
/// That is why `InputObserver` polls, and it is untouched by any of the above.
///
/// ### Rejected: `AXUIElementSetMessagingTimeout`
///
/// It bounds an AX call, which would make "keep it in the callback" viable
/// again, and it looks like the clever answer. It trades "a call with no upper
/// bound" for "a bounded call that **fails by timing out**" — and a timeout
/// failure is data loss of exactly the kind `clicksDroppedByBacklog` already
/// is. The same loss, in a worse place: it still spends its bounded delay on
/// the callback thread, and it has no queue to absorb a burst, so a run of
/// slow clicks pays the timeout every time instead of once.
///
/// ## `nonisolated` on everything
///
/// Under this target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` an
/// unannotated declaration is `@MainActor`, and this type is reached from
/// `InputObserver`'s tap callback — a bare C function pointer that cannot be
/// MainActor-isolated and traps at runtime, not compile time, if something it
/// reaches is. `CaptureSession`, `Minting` and `InputObserver` all document
/// the same decision with the compiler errors they hit; the shape here is
/// identical.
public final class AXObserver: @unchecked Sendable {

    // MARK: - The bounds

    /// **Fixed at 30, not a placeholder** (D2-5). 25 covered every sample in
    /// F2-2 and a level costs one `kAXParentAttribute` read, so the margin is
    /// nearly free. Expect it to bind rarely, and when it does, to bind on web
    /// content.
    public nonisolated static let depthCap = 30

    /// 35 ms, in nanoseconds — the wall-clock budget for the walk.
    ///
    /// **The clock starts after the hit element has been described**, not when
    /// the hit-test returns, matching how F2-2 timed the distribution these
    /// numbers are fitted to. So a worst case is not 35 ms: it is the
    /// hit-test (F2-2 max 125.47 ms) **plus** four unbounded attribute reads
    /// on the hit element **plus** this budget plus one final level, and the
    /// first two of those are what `AXChainRecord.hitTestInterval` and
    /// `hit.readInterval` are recorded for. An earlier version of this comment
    /// said "from the moment the hit-test returns", which understated the
    /// worst case by the entire hit-element describe — on F2-2's tail that is
    /// not a rounding term.
    ///
    /// **A D4 placeholder, labelled as one, and the only one in this file.**
    /// F2-2's truncation table has no knee: 20 ms → 15% truncated, 35 ms → 9%,
    /// 50 ms → 7%, and it never reaches zero. Raising it is a direct exchange
    /// of coverage for latency with no natural stopping point.
    ///
    /// **Before raising it, read F2-3, because 9% truncated is not 9% of
    /// clicks lost.** The hit-test returns the *deepest* element at the point
    /// and this walk goes **up**, so truncation drops the **outermost**
    /// ancestors — the ones least likely to be what the camera should frame.
    /// Measured, not argued: all 107 complete walks in Spike A topped out at
    /// `AXApplication`, while the 11 truncated ones stopped at `AXGroup` (×7),
    /// `AXWebArea` (×2) and `AXWindow` (×2). So the truncated 9% are clicks
    /// missing some outer containers, not clicks with no element recorded.
    ///
    /// **The budget does not bound the hit-test itself**, and nothing this
    /// process can write does: `AXUIElementCopyElementAtPosition` is a
    /// synchronous IPC into an application that is busy handling the click,
    /// with no timeout parameter. F2-2 measured it at p50 1.05 ms and max
    /// 125.47 ms. What this file can do about that is record it —
    /// `AXChainRecord.hitTestInterval` is that call and nothing else — so the
    /// cost is visible per click rather than averaged into a walk time.
    public nonisolated static let walkBudgetNanos: Int64 = 35_000_000

    // MARK: - Diagnostics

    /// What this observer did, as counts, held in memory and read by the
    /// caller after the fact. Nothing here is written to the package.
    ///
    /// **Three conservation laws, because a count on its own cannot show what
    /// was dropped.** `InputObserver.Diagnostics` had to be rearranged for the
    /// same reason: a filter's output taken without its input says nothing
    /// about what the filter removed. Here the three are:
    ///
    /// 1. every click either produced a record, or is counted as one that
    ///    could not be converted back to a global point, or as one dropped
    ///    because the AX queue was already full;
    /// 2. every record carries exactly one truncation reason, and the four
    ///    counters sum to the number of records;
    /// 3. every record falls into exactly one containment case — and
    ///    `clickOutsideTheHitFrame` is the standing instrument on the
    ///    coordinate path, below.
    ///
    /// **What those three laws can and cannot catch is set out where they are
    /// declared**, and it is narrower than "these numbers are right": within
    /// one call they are structurally true, so what they check is `merge`'s
    /// hand-copied lines and the accumulation across a run. The counters that
    /// are genuine instruments are the ones partitioning a real decision — the
    /// unusable/unroutable frame split, the two ways to end up with no
    /// children list, and the containment verdicts — and each of those is
    /// driven to non-zero in both directions by `§ 8` of the probe, rather
    /// than checked at zero, which passes trivially.
    ///
    /// **`clickOutsideTheHitFrame` is this file's `implausibleEventTimestamp
    /// Count`.** If the reverse conversion were wrong — off by a display's
    /// scale, or by its global origin — every hit-test would be performed at
    /// the wrong point and the element it returned would not contain the
    /// click, on every click, in every run. A handful is AX staleness during
    /// animation, which F2-2 measured at 12% of clicks exceeding one 60 fps
    /// frame. A run where this equals `chainsRecorded` is the coordinate path
    /// being wrong, and it is visible without re-deriving anything.
    public struct Diagnostics: Sendable, Equatable {
        public internal(set) var clicksObserved = 0
        public internal(set) var chainsRecorded = 0
        /// Clicks whose `revision` names no display in this observer's
        /// arrangement, so there was no global point to hit-test at.
        ///
        /// Non-zero means the arrangement is stale — a display was plugged,
        /// unplugged or rearranged since this observer was constructed — and
        /// the click produced **no record**, rather than a record hit-tested
        /// at a guessed point. The same stance, and the same reason, as
        /// `InputObserver.Diagnostics.unroutableButtonLocations`: a guessed
        /// point returns a real element, and a real element for the wrong
        /// place is worse than an absence that is counted.
        public internal(set) var clicksWithNoGlobalPoint = 0
        /// Clicks stamped in a different boot session from this observer's
        /// own epoch. Counted, never corrected: the record uses the click's
        /// epoch, so the interval and the instant stay on one clock.
        public internal(set) var clicksFromAnotherEpoch = 0
        /// Clicks refused because `maximumQueuedClicks` were already waiting —
        /// one hung application, and a person still clicking.
        ///
        /// **A term in the conservation law, not a footnote.** These clicks
        /// happened and produced no record, which is the one outcome that must
        /// never be inferred from an absence: without this term the law would
        /// balance by simply not counting them, and a recording made against a
        /// beachballed app would show a shorter click list with nothing
        /// saying why.
        public internal(set) var clicksDroppedByBacklog = 0
        /// The deepest the AX queue ever got. Zero-to-one is the healthy
        /// shape; anything approaching `maximumQueuedClicks` says the walk is
        /// not keeping up with the clicking, before any click is actually
        /// dropped.
        public internal(set) var deepestBacklog = 0

        public internal(set) var truncatedReachedRoot = 0
        public internal(set) var truncatedDepthCapReached = 0
        public internal(set) var truncatedBudgetExceeded = 0
        /// Ancestor walks that ran all the way to `depthCap` — counted **at
        /// the walk**, not from the record's final `truncation`.
        ///
        /// The two differ, and the difference is the reason this exists. A
        /// chain that hits the cap and then overruns the budget while reading
        /// children ends with `truncation == .budgetExceeded`, so
        /// `truncatedDepthCapReached` never sees it. Since the cap binding is
        /// the signal that hierarchies are getting deeper than 30 — the one
        /// thing that would justify revisiting a bound D2-5 fixed — reading it
        /// off a field another phase can overwrite would understate it
        /// silently, and most often on exactly the deep web content where it
        /// matters.
        ///
        /// Deliberately outside every conservation law below: it is a
        /// statement about a phase, not a partition of the records.
        public internal(set) var ancestorWalksStoppedAtTheDepthCap = 0
        public internal(set) var hitTestsReturnedNothing = 0
        /// Of `hitTestsReturnedNothing`, those observed while Accessibility
        /// was not granted to this process.
        ///
        /// **Read only on that path, and that is deliberate.** "AX answered
        /// with nothing" and "this app is not allowed to ask" are the same
        /// empty record otherwise, and the second is not a property of the
        /// click — it is `CapturePermission.accessibility` being absent, whose
        /// stated degradation is already `.noElementIdentity`. Reading it on
        /// every click would cost a TCC query per click for a value that
        /// changes at most once a session.
        public internal(set) var hitTestsReturnedNothingWithoutAccessibility = 0

        public internal(set) var clickInsideTheHitFrame = 0
        public internal(set) var clickOutsideTheHitFrame = 0
        public internal(set) var clickFrameNotComparable = 0
        public internal(set) var recordsWithNoFrame = 0
        public internal(set) var recordsWithNoHitElement = 0

        public internal(set) var elementsDescribed = 0
        /// Elements whose `kAXPositionAttribute` or `kAXSizeAttribute` did not
        /// answer. Their `frame` is `nil`, never a zero rectangle — which
        /// would be an element at the top-left corner of the main display, a
        /// legal-looking answer that is wrong.
        public internal(set) var elementFramesUnavailable = 0
        /// Elements that answered with a non-finite coordinate or a negative
        /// dimension. Kept apart from the absence above because this one is
        /// the target application misreporting itself, not declining to
        /// answer — and because `PointRect.init` would trap on either.
        public internal(set) var elementFramesUnusable = 0
        /// Elements whose frame origin lies on no display in this observer's
        /// arrangement — offscreen, or on a display that has since gone away.
        public internal(set) var elementFramesUnroutable = 0

        /// The children attribute was never asked for, because the budget was
        /// already spent on the ancestor walk. The record's `children` is
        /// `nil`, which is what "I did not ask" looks like on disk.
        public internal(set) var childrenNotRead = 0
        /// The children attribute was asked for and did not answer. Also
        /// `nil` in the record — but a different fact, and counted separately
        /// so the two are not reconciled as one.
        public internal(set) var childrenAttributeUnavailable = 0
        /// The children list was read but not every child could be described
        /// before the budget ran out. The record's `truncation` is
        /// `.budgetExceeded` in that case even when the ancestor walk itself
        /// reached the root.
        public internal(set) var childrenReadsCutShortByBudget = 0

        public internal(set) var axCalls = 0
        /// Two consecutive `Minting.hostNow()` readings that went backwards.
        /// Structurally impossible on a monotonic clock; counted rather than
        /// clamped in silence, because the clamp is what would make it
        /// invisible.
        ///
        /// **The one counter here that is only ever checked at zero, and that
        /// is the honest maximum rather than an omission.** Every other
        /// counter partitions a decision this code makes, so a synthetic
        /// source can drive it in both directions. This one reports a property
        /// of `mach_absolute_time`, which no fixture can make run backwards —
        /// driving it would mean injecting a clock, and a clock seam exists
        /// nowhere else in this app because `Minting` is deliberately the one
        /// unmocked boundary. So it is asserted at zero, which proves only
        /// that the clamp did not fire; if it ever does, the counter is what
        /// says so rather than a silently zero-width interval.
        public internal(set) var nonMonotonicClockReadings = 0

        // MARK: - The three laws, and exactly what they can catch
        //
        // **They are not general instruments, and the first version of these
        // comments over-claimed.** Within one `chain(at:source:)` call each
        // law is structurally true: the tally sets `clicksObserved = 1` and
        // exactly one outcome, and `finish` switches exhaustively over
        // `ChainTruncation` and `ClickContainment`, so a single call cannot
        // produce a record with no verdict however the walk is edited. Saying
        // "a run cannot be quietly missing verdicts" was therefore a claim
        // about the compiler's exhaustiveness check wearing a runtime check's
        // clothes.
        //
        // What they do catch is the accumulation, and that is a real bug class
        // rather than a theoretical one: `merge` copies two dozen fields by
        // hand, one line each, and a missing or misdirected line is invisible
        // at the call site, compiles, and produces plausible totals. A law
        // breaks the moment `merge` drops any of the terms in it. That is the
        // guarantee, and it is worth having — the same shape as
        // `InputObserver.Diagnostics.everyKeyDownIsAccountedFor`, which also
        // exists to catch a bookkeeping slip rather than a logic error.
        //
        // They are also live checks on the accumulated numbers a person reads:
        // a run that prints `accounting` and does not balance means the totals
        // beside it should not be quoted, whatever produced the imbalance.

        /// Every click this observer was handed either produced a record or is
        /// counted as unconvertible — across the whole run, which is where
        /// `merge` can lose one.
        public var everyClickIsAccountedFor: Bool {
            clicksObserved == chainsRecorded + clicksWithNoGlobalPoint + clicksDroppedByBacklog
        }

        /// Every record carries exactly one of the four truncation reasons.
        /// `ancestorWalksStoppedAtTheDepthCap` is deliberately NOT a term
        /// here — it counts a phase, not a record.
        public var everyRecordHasATruncationReason: Bool {
            chainsRecorded == truncatedReachedRoot + truncatedDepthCapReached
                + truncatedBudgetExceeded + hitTestsReturnedNothing
        }

        /// No legitimate violation: every record falls into exactly one
        /// containment case.
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
    /// The queue every AX call runs on — **never the caller's, and never the
    /// main one**. See `enqueue(_:onRecord:)`.
    private let queue = DispatchQueue(label: "video.soredemo.ax-observation", qos: .userInitiated)
    private nonisolated(unsafe) var queuedClicks = 0
    private nonisolated(unsafe) var _diagnostics = Diagnostics()

    /// `arrangement` and `epoch` are supplied by the caller and never read
    /// from ambient state here — the same shape `InputObserver.init` and
    /// `CaptureSession.init` use, and for the same reason: it makes the whole
    /// conversion a pure function of its inputs, testable against fixture
    /// displays that are not attached to this machine.
    ///
    /// Pass the **same** arrangement the `InputObserver` producing the clicks
    /// was constructed with. A different one is not a subtle wrongness: a
    /// click's `revision` is looked up in this arrangement, so a mismatched
    /// pair produces `clicksWithNoGlobalPoint` on every click rather than a
    /// wrong coordinate — which is the intended failure direction.
    ///
    /// **`accessibilityIsGranted` defaults to the real reader and is injected
    /// for the same reason `InputObserver.secureInputIsEnabled` is.** It is
    /// not a mock standing in for a reader that could have been called
    /// directly: `CapturePermissions.status(of: .accessibility)` is
    /// `AXIsProcessTrusted()`, whose answer is a property of *this executable's
    /// TCC grant*, and `scripts/cross-boundary-digest-probe.swift` is a bare
    /// `swiftc` output whose reads TCC attributes to whatever shell launched
    /// it (this project measured that, and it is why that file performs no
    /// permission-scoped check at all). So in the one environment where the
    /// attribution counter can be exercised, the real predicate cannot answer
    /// about the right subject. Injecting it makes
    /// `hitTestsReturnedNothingWithoutAccessibility` checkable in both
    /// directions there; that the real predicate is wired up and answers about
    /// this app is the human step's job.
    ///
    /// The default is the only place this policy lives — `CapturePermissions`
    /// is the one model of what each permission's absence means, and its
    /// `Degradation` for Accessibility is already `.noElementIdentity`, which
    /// is exactly the state this counter reports.
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
    /// **The exact inverse of `InputObserver.normalizedPosition`, step for
    /// step, and it must stay that way:**
    ///
    /// ```
    /// NormalizedPoint          0…1, bottom-left
    ///   -> NormalizationContext.denormalize   normalised -> within-screen PIXELS
    ///   -> DisplayGeometry.points(from:)      pixels     ->  within-screen POINTS
    ///   -> + Placement.globalOrigin           local      ->  global POINTS
    /// ```
    ///
    /// Skipping the middle step is off by exactly the display's `scale` and
    /// skipping the last is off by its global origin, and neither fails to
    /// compile nor produces an out-of-range number — the same two mistakes the
    /// forward direction documents, in the same order, with the same silence.
    /// What catches them is that the round trip through both directions is
    /// checked against a `scale: 2` fixture display in `§ 8.1` of
    /// `scripts/cross-boundary-digest-probe.swift`; at `scale: 1` the pixel
    /// step is the identity and the check would pass either way.
    ///
    /// The display is found by `revision`, not by re-routing the point:
    /// re-routing needs a global point, which is what this function is for.
    ///
    /// `nil` when `revision` names no display in `arrangement` — a stale
    /// arrangement, or a click from a display that has gone away. Not a
    /// nearest-display guess: that would hit-test a real point on a display
    /// the click was never on, and get back a real element.
    ///
    /// **`NormalizedFrame` with a zero size is the spelling for a point
    /// here**, unlike `DisplayArrangement.route`, whose documentation rejects
    /// it — because `denormalize` takes a frame and there is no point
    /// overload, and because the frame formula at `height == 0` **is** the
    /// point formula (`NormalizationContext.normalize` says so of its own two
    /// overloads). The zero size is not carrying a rectangle's meaning; it is
    /// the identity element of the anchor adjustment.
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

    /// An AX element's frame — global, top-left, **points**, which is what
    /// `kAXPositionAttribute` and `kAXSizeAttribute` report — as a
    /// `NormalizedFrame` carrying the revision of the display its origin
    /// routed to.
    ///
    /// **This is the second place in this app where a global coordinate
    /// becomes a normalised one**, and `InputObserver`'s own header names it,
    /// because that header's claim ("the only place") had to stop being true
    /// or stop being said. It is the same four steps in the same order, over a
    /// rectangle rather than a point: the difference is that
    /// `NormalizationContext.normalize`'s rect overload anchors the Y flip on
    /// the rect's **bottom** edge, and using the point formula on a rect is
    /// off by exactly the rect's own height — small enough to look like
    /// rounding, large enough to land a zoom on the wrong control.
    ///
    /// The frame is routed **by its origin**. A window straddling two displays
    /// therefore normalises against the display its top-left corner is on, and
    /// its normalised width can exceed 1. That is a real, recorded fact about
    /// the element rather than an error: `framing-gates` already has a
    /// *partly offscreen* rejection code, and clamping here would erase its
    /// input.
    ///
    /// `nil` when the origin lies on no display in `arrangement`, or when the
    /// element reported a non-finite coordinate or a negative dimension —
    /// `PointRect.init` traps on both, and the trap belongs nowhere near a
    /// walk that is reading another process's UI.
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
    ///
    /// **Needs the Accessibility grant.** Without it
    /// `AXUIElementCopyElementAtPosition` answers with nothing, every time,
    /// and the records say `.hitTestReturnedNothing` —
    /// `Diagnostics.hitTestsReturnedNothingWithoutAccessibility` is what tells
    /// that apart from a click on empty desktop.
    ///
    /// **Do not call this from `InputObserver`'s tap callback.** Use
    /// `enqueue(_:onRecord:)`, and see this type's header — "Why the AX work
    /// is not on the tap callback thread" — for the argument, which is about
    /// what is lost when a target application hangs and **not** about a
    /// per-callback time budget. An earlier version of this comment said the
    /// latter, citing a 10–50 ms figure that was an artefact of stalling every
    /// `mouseMoved`; measured since, a 125 ms stall on clicks alone leaves the
    /// tap enabled across 1928 callbacks.
    ///
    /// The cost of deferring is real: the hit-test happens later than the
    /// click, which adds to exactly the staleness D2-2a exists to record. It
    /// is the lesser cost, and it is not lost — it is
    /// `AXChainRecord.clickToHitTestStartNanos`, a recorded quantity of the
    /// same kind as `hitTestInterval`, so a derivation can reject on it
    /// instead of inheriting it.
    ///
    /// **`phase` is not filtered here.** A caller that wants only `.down` —
    /// which is the one that pairs with "the click" in
    /// `ROADMAP.md`'s sense — filters before calling. This file records what
    /// it is handed (D2-1).
    ///
    /// **A caller whose output has to name the source it used should call
    /// `chain(at:source:)` and pass one**, rather than this convenience. The
    /// distinction is not pedantic: this overload hard-codes
    /// `LiveAXElementSource`, so anything printed about "which source produced
    /// these numbers" beside it can only be a literal, and a literal is the
    /// same unearned claim whether the code beneath it is right or not. The
    /// synthetic source answers with the same AX role vocabulary — `AXButton`,
    /// `AXGroup`, `AXApplication` — so a live run and a fixture run are
    /// otherwise indistinguishable in a log.
    /// `spikes/2026-08-02-pairing-latency/main.swift` passes its source for
    /// exactly that reason.
    public nonisolated func chain(at click: ButtonEvent) -> AXChainRecord? {
        chain(at: click, source: LiveAXElementSource())
    }

    /// The **production entry point**: hands `click` to this observer's own
    /// serial queue and returns immediately.
    ///
    /// This exists because of the asymmetry set out in this type's header: AX
    /// work inside `InputObserver`'s tap callback risks the **whole pointer
    /// track** when a target application hangs, where AX work behind this
    /// queue risks **the AX chains of the affected clicks**, counted. What
    /// stays on the callback thread is this function: two lock acquisitions
    /// and a `DispatchQueue.async`.
    ///
    /// It is **not** here because a slow callback disables the tap — measured,
    /// it does not: 125 ms on clicks only, 30 s, 1928 callbacks, tap still
    /// enabled. The header records why that figure was believed and why it was
    /// wrong.
    ///
    /// **Serial, not concurrent.** A hung application blocks an AX call for
    /// seconds; a concurrent queue would answer that by opening more
    /// simultaneous IPCs into the same hung application, which is the standard
    /// way to turn one stuck responder into a thread explosion. Serial also
    /// keeps records in click order, which is what a reader joining them
    /// against the pointer track expects.
    ///
    /// **Bounded, and the drop is counted.** With a serial queue a hung target
    /// means clicks arrive faster than they are consumed, so the backlog is
    /// capped at `maximumQueuedClicks` and everything past it is dropped and
    /// counted in `Diagnostics.clicksDroppedByBacklog` — never silently
    /// enqueued to be answered a minute later, which would produce records
    /// whose `clickToHitTestStartNanos` is larger than anything a derivation
    /// could use, at the cost of unbounded memory. A dropped click is still a
    /// click that happened: it stays in `clicksObserved`, and the conservation
    /// law has a third term for it.
    ///
    /// `onRecord` is called **on the AX queue**, not the caller's.
    public nonisolated func enqueue(_ click: ButtonEvent,
                                    onRecord: @escaping @Sendable (AXChainRecord) -> Void) {
        enqueue(click, source: LiveAXElementSource(), onRecord: onRecord)
    }

    /// The same, over an injected source — so a caller whose output has to
    /// **name** the source that produced its numbers can pass one and print
    /// `String(describing: type(of:))` of that value rather than a literal.
    /// `spikes/2026-08-02-pairing-latency/main.swift` does exactly that; the
    /// synthetic source answers with the same AX role vocabulary as the live
    /// one, so a log cannot otherwise tell a real run from a fixture run.
    public nonisolated func enqueue<Source: AXElementSource>(
        _ click: ButtonEvent, source: Source,
        onRecord: @escaping @Sendable (AXChainRecord) -> Void
    ) {
        let accepted = lock.withLock { () -> Bool in
            guard queuedClicks < Self.maximumQueuedClicks else {
                // Counted here rather than in `chain`, which this click never
                // reaches — and counted into `clicksObserved` too, or the
                // conservation law would quietly absorb the drop.
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
    /// dropped.
    ///
    /// Eight, which at F2-2's p90 whole-walk of 32 ms is about a quarter of a
    /// second of backlog. Not a D4 threshold — nothing rejects on it — but it
    /// is a placeholder in the weaker sense that no distribution of *click
    /// arrival* rates has been measured yet. What it must not be is unbounded:
    /// the failure it exists for is one hung application, where the queue
    /// grows for as long as the person keeps clicking.
    public nonisolated static let maximumQueuedClicks = 8

    /// Blocks until every enqueued click has been observed. **For the probe
    /// and the spike**, which need the asynchronous path to have finished
    /// before they can assert anything about it; not part of a recording's
    /// normal flow, where nothing waits for AX.
    public nonisolated func waitForQueuedClicks() {
        queue.sync {}
    }

    /// The walk itself, over an injected `AXElementSource`.
    ///
    /// **The seam exists so the bounds can be checked without a grant and
    /// without a UI.** Depth 30, the 35 ms budget, the four truncation
    /// reasons, the call arithmetic and the children distinction are all
    /// properties of *this function*, and every one of them is unreachable
    /// from a test that needs Accessibility, a running application and a click
    /// during an animation to produce a sample. It is the same trade
    /// `InputObserver`'s injected `secureInputIsEnabled` makes, for the same
    /// reason: the injected version is not a mock standing in for a reader
    /// that could have been called directly — the real one cannot be called at
    /// all in the environment the checks run in.
    ///
    /// What the seam does **not** check is that `LiveAXElementSource` asks the
    /// right questions of the real API. That needs a person, a grant and three
    /// classes of target application; see `spikes/2026-08-02-pairing-latency/`.
    public nonisolated func chain<Source: AXElementSource>(at click: ButtonEvent,
                                                           source: Source) -> AXChainRecord? {
        var tally = Diagnostics()
        tally.clicksObserved = 1
        if click.instant.epoch != epoch { tally.clicksFromAnotherEpoch = 1 }
        // The record's own epoch is the CLICK's, not this observer's: the
        // instant and the interval have to be on one clock for
        // `AXChainRecord.clickToHitTestAnswerNanos` to mean anything, and the
        // click's is the one that is already on disk beside it.
        let epoch = click.instant.epoch

        guard let point = Self.globalPoint(of: click.position, revision: click.revision,
                                           in: arrangement) else {
            tally.clicksWithNoGlobalPoint = 1
            merge(tally)
            return nil
        }

        // The hit-test, and NOTHING else, inside the recorded interval: the
        // API carries no timestamp of its own, so the width of this interval
        // is the whole uncertainty about when the answer was true (D2-2a).
        // Anything else measured inside it would inflate that uncertainty
        // with time this process spent on itself.
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
            // The standing instrument on the coordinate path — see
            // `Diagnostics.clickOutsideTheHitFrame`. Computed from the record
            // that is about to be returned, so what is counted here and what a
            // reader recomputes from disk cannot disagree.
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

        // The budget clock starts HERE — after the hit element has been
        // described, not when the hit-test returned — matching how F2-2
        // measured the distribution these numbers are fitted to ("whole walk"
        // was timed from the start of the walk, not from the click).
        //
        // **So two things sit outside the budget entirely**, and anyone
        // budgeting a worst case has to add them by hand: the hit-test itself
        // (F2-2 max 125.47 ms) and the hit element's own four attribute reads.
        // Neither can be bounded by anything this process can impose —
        // `AXUIElementCopyAttributeValue` is a synchronous IPC with no timeout
        // parameter, so the smallest unit this code can decline to start is a
        // whole element. What it can do instead is record them:
        // `hitTestInterval` is the first, `hit.readInterval` is the second,
        // and both are per-record rather than averaged into a walk time.
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
                // Counted HERE as well as in `finish`, and the duplication is
                // the point. `truncation` is one field and the children phase
                // below may overwrite it with `.budgetExceeded`, so a chain
                // that hits the cap and then overruns increments
                // `truncatedBudgetExceeded` and NOT `truncatedDepthCapReached`
                // — which would make the final-verdict counter unable to show
                // the cap starting to bind on web content, the one thing it is
                // there for. This counter is the walk-phase fact and does not
                // participate in any conservation law.
                tally.ancestorWalksStoppedAtTheDepthCap = 1
            }
        }

        // ---- down: one level (D2-3), under what is left of the same budget.
        //
        // After the walk, not before, so that a click whose budget runs out
        // loses its OUTERMOST ancestors rather than its children — that
        // ordering is the whole of F2-3's "truncation degrades gracefully",
        // and reversing it would quietly reverse the conclusion.
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
                        // The list was read but not all of it was described.
                        // Recorded as `.budgetExceeded` even when the walk
                        // above reached the root: the truncation field is a
                        // statement about the whole observation, and a
                        // silently short list is the one outcome D2-2 exists
                        // to prevent.
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

    /// Four AX calls, in one bracketed interval: role, position, size, title.
    ///
    /// **A frame costs two of the four.** `kAXFrameAttribute` is not exposed
    /// to Swift, so position and size are separate IPC round trips into the
    /// target process — which is why `AXElementSource` is written at the
    /// attribute level rather than offering a `frame(of:)`: the extra round
    /// trip goes straight into the budget above, and a protocol that hid it
    /// would make `axCalls` a number this file made up.
    ///
    /// The interval spans all four reads, so its width is the uncertainty
    /// about **this element** — not about the chain, whose levels are read at
    /// different moments and at p95 are three 60 fps frames apart (F2-2).
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
                // Two ways to arrive here and they are different findings: the
                // element misreported itself (which would trap `PointRect`),
                // or it is somewhere this arrangement does not cover.
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

    /// A `HostRange` from two `Minting.hostNow()` readings.
    ///
    /// Both endpoints come from one monotonic clock on one thread, so `after`
    /// cannot precede `before` — unlike `InputObserver.emitSecureInterval`,
    /// whose endpoints include the window server's own stamp. It is checked
    /// anyway, and counted rather than clamped in silence, because `HostRange`
    /// traps on a negative duration and killing a recording over a clock
    /// reading is a worse outcome than a zero-width interval plus a counter
    /// that says the impossible happened.
    private nonisolated func range(from before: Nanoseconds, to after: Nanoseconds,
                                   epoch: BootEpoch, into tally: inout Diagnostics) -> HostRange {
        let width = after.rawValue - before.rawValue
        if width < 0 { tally.nonMonotonicClockReadings += 1 }
        return HostRange(epoch: epoch, start: before, duration: Nanoseconds(max(0, width)))
    }

    /// Adds one observation's counters into the shared totals, once, at the
    /// end.
    ///
    /// **The lock is never held across an AX call.** A synchronous IPC into an
    /// application that is busy — the whole hazard this row is bounded for —
    /// would otherwise block every reader of `diagnostics` for as long as the
    /// hung application felt like taking.
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
/// per function**, which is what makes `AXChainRecord.axCalls` a count of
/// something real rather than an estimate.
///
/// There is deliberately no `frame(of:)`: `kAXFrameAttribute` is not exposed
/// to Swift, so a frame is `position` *and* `size`, two round trips, and a
/// convenience that returned both would hide the doubled cost inside the one
/// budget it is spent against.
///
/// `Element` is not constrained to `Sendable`: `AXUIElement` is a CoreFoundation
/// type and is not marked as such, and it does not need to be — every element
/// this protocol produces is consumed inside the single synchronous
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
    /// reports in, which is why the click's coordinate can be handed to
    /// `hitTest` and compared against this afterwards.
    func position(of element: Element) -> (x: Double, y: Double)?
    func size(of element: Element) -> (width: Double, height: Double)?
    func parent(of element: Element) -> Element?
    /// The element's direct children, or `nil` if the attribute did not
    /// answer. An empty array means the element has none — the two are
    /// different facts and `AXChainRecord.children` keeps them apart.
    func children(of element: Element) -> [Element]?
}

/// The real thing: `AXUIElement`, over the real accessibility API.
///
/// **Every CoreGraphics value stays inside `CGGeometryBridge`.** An element's
/// position and size arrive as `AXValue`s that open into a `CGPoint` and a
/// `CGSize`, and this struct never names either — `CGGeometryBridge.point
/// (fromAXValue:)` and `.size(fromAXValue:)` are where that crossing happens,
/// per architecture rule 5.
public struct LiveAXElementSource: AXElementSource {
    public typealias Element = AXUIElement

    public init() {}

    /// The system-wide element is created per call rather than stored.
    ///
    /// It is a local object, not an IPC — creating it costs nothing measurable
    /// — and storing it would make this struct hold a non-`Sendable`
    /// CoreFoundation reference for the lifetime of the observer, which is a
    /// concurrency claim this file would then have to make and could not
    /// support.
    public nonisolated func hitTest(globalTopLeftX: Double, globalTopLeftY: Double) -> AXUIElement? {
        var element: AXUIElement?
        // `Float`, because that is the API's parameter type. Its 24-bit
        // significand represents every integer to 16,777,216 exactly, so a
        // screen coordinate — four or five digits, on a desktop that is a few
        // thousand points across — loses nothing that matters here. Named
        // rather than assumed, because a silent narrowing at the one point
        // where this file hands a coordinate to someone else is exactly the
        // kind of thing that would show up later as "the hit-test returns the
        // wrong element" with a ready alternative explanation.
        let error = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                                     Float(globalTopLeftX),
                                                     Float(globalTopLeftY),
                                                     &element)
        return error == .success ? element : nil
    }

    public nonisolated func role(of element: AXUIElement) -> String? {
        copyAttribute(kAXRoleAttribute, of: element) as? String
    }

    /// **A title is UI text, and it is recorded on purpose.** It is what makes
    /// "the Save button" identifiable in derivation, and it is already visible
    /// in the video this observation accompanies. It is not keystroke content:
    /// nothing in this app reads what a person typed, which
    /// `AppSourceTests.noAppSourceReadsKeystrokeText` enforces over the whole
    /// app target rather than trusting any one file.
    public nonisolated func title(of element: AXUIElement) -> String? {
        copyAttribute(kAXTitleAttribute, of: element) as? String
    }

    public nonisolated func position(of element: AXUIElement) -> (x: Double, y: Double)? {
        CGGeometryBridge.point(fromAXValue: copyAttribute(kAXPositionAttribute, of: element))
    }

    public nonisolated func size(of element: AXUIElement) -> (width: Double, height: Double)? {
        CGGeometryBridge.size(fromAXValue: copyAttribute(kAXSizeAttribute, of: element))
    }

    public nonisolated func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(kAXParentAttribute, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// **Type-ID guarded, member by member, like `parent(of:)` above.**
    ///
    /// `as? [AXUIElement]` alone is the same shape as the `as? NSValue` cast
    /// that silently failed on every frame of every recording one file over —
    /// a conditional bridge over a CoreFoundation type, whose failure is
    /// indistinguishable from the attribute having nothing to say. Here it is
    /// worse in one way: a *partial* success would drop members without
    /// anything counting the loss.
    ///
    /// So: the value must be a CFArray, and **every** member must be an
    /// `AXUIElement`. Anything else returns `nil` — "the attribute did not
    /// answer in a form this code understands", which the caller counts as
    /// `childrenAttributeUnavailable` — rather than a filtered list that
    /// silently claims to be complete. All-or-nothing is the loud direction,
    /// and it is the one `parent(of:)` already takes.
    public nonisolated func children(of element: AXUIElement) -> [AXUIElement]? {
        guard let value = copyAttribute(kAXChildrenAttribute, of: element),
              CFGetTypeID(value) == CFArrayGetTypeID(),
              let members = value as? [CFTypeRef] else { return nil }
        guard members.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
        return members.map { $0 as! AXUIElement }
    }

    /// One `AXUIElementCopyAttributeValue`, which is one synchronous IPC into
    /// the target process — the call this whole row is bounded to survive.
    ///
    /// Any `AXError` other than `.success` becomes `nil`. The distinctions
    /// among them (`.attributeUnsupported`, `.noValue`, `.cannotComplete`,
    /// `.apiDisabled`) are not preserved: they would have to go into
    /// `AXElementRecord` per attribute to be useful, and what a reader
    /// actually needs — "this app was never allowed to ask" — is a property of
    /// the process, not of the attribute, and is counted once in
    /// `AXObserver.Diagnostics.hitTestsReturnedNothingWithoutAccessibility`.
    private nonisolated func copyAttribute(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return error == .success ? value : nil
    }
}
