import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Geometry
import Project
import Timeline

/// A **listen-only** `CGEvent` tap for pointer motion, clicks and an
/// allow-listed set of keyboard shortcuts.
///
/// **The conversion is four steps and the order is load-bearing:**
/// `CGGeometryBridge.location(from:)` → `DisplayArrangement.route` (global
/// points → display-local points) → `DisplayGeometry.pixels(from:)` (points →
/// pixels) → `NormalizationContext.normalize`. Skipping the route or the pixel
/// step still compiles — `route` takes bare `Double`s — and still yields a
/// well-formed `NormalizedPoint`, wrong by the display's origin or its `scale`.
///
/// **`CGEventTimestamp` is nanoseconds and is NOT converted**: it is already on
/// the same base as `Minting.hostNow()`, so the stamp goes straight into
/// `Nanoseconds`.
///
/// **`nonisolated` on everything the tap can reach.** A `CGEventTapCallBack` is
/// a bare C function pointer and cannot be MainActor-isolated, while this
/// target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` would otherwise make
/// every unannotated declaration so.
///
/// **Listen-only.** `options: .listenOnly` — the tap never modifies, delays
/// or drops an event. The callback returns the event it was handed, always.
final class InputObserver: @unchecked Sendable {

    // MARK: - What the observer produces

    /// One thing worth recording. A discriminated union rather than five
    /// callbacks, so a caller cannot wire up some cases and silently drop the
    /// rest.
    public enum Observation: Sendable, Equatable {
        case pointer(PointerSample)
        case button(ButtonEvent)
        case key(KeySample)
        /// Emitted when the interval **closes**, not when it opens. `stop()`
        /// closes an open one with `.observationStopped`.
        case secureInput(SecureInputInterval)
        /// A window during which the tap was switched off and this observer
        /// saw nothing — emitted at the moment it is re-enabled, which is the
        /// first moment its end is known.
        case tapDisabled(TapDisabledInterval)
    }

    // MARK: - Diagnostics

    /// What this observer saw, as counts; held in memory, never written to the
    /// package. **The keyboard counters are counts, never content**, and
    /// satisfy `keyDownsSeen == keySamples + keyDownsRefused`.
    public struct Diagnostics: Sendable, Equatable {
        public internal(set) var pointerSamples = 0
        public internal(set) var buttonEvents = 0
        public internal(set) var keySamples = 0
        public internal(set) var keyDownsSeen = 0
        public internal(set) var keyDownsRefused = 0
        /// Events observed while `IsSecureEventInputEnabled()` was true, and
        /// therefore not emitted in any form.
        public internal(set) var eventsSuppressedBySecureInput = 0
        public internal(set) var secureInputIntervals = 0
        /// **How many times `IsSecureEventInputEnabled()` was actually
        /// asked**, counted at the ask rather than the answer. Read with
        /// `secureInputCheckSpanNanos`, which `secureInputAccounting` prints:
        /// alone, `secureInputIntervals == 0` cannot distinguish "nobody typed
        /// a password" from "nothing ever asked".
        public internal(set) var secureInputChecks = 0
        /// First check to last, in nanoseconds — the span the count above
        /// covers.
        public internal(set) var secureInputCheckSpanNanos: Int64 = 0
        /// Pointer-motion locations `DisplayArrangement.route` placed on no
        /// known display; the samples are **dropped, not clamped**. Non-zero
        /// means the arrangement this observer was constructed with is stale.
        public internal(set) var unroutablePointerLocations = 0
        /// The same, for a **click** — a click that produced no `ButtonEvent`.
        /// Split from the counter above so a missing click is not looked for
        /// under a pointer-shaped name.
        public internal(set) var unroutableButtonLocations = 0
        /// Events whose `CGEventTimestamp` would not fit `Int64` nanoseconds.
        /// Counted rather than truncated.
        public internal(set) var unconvertibleTimestamps = 0
        /// Events stamped **in the future**, or more than `plausibleSkewNanos`
        /// (50 ms) in the past, relative to `Minting.hostNow()` at callback
        /// entry — the standing check that the stamp's unit is nanoseconds. The
        /// window is one-sided because the window server stamps the event
        /// before this callback runs.
        public internal(set) var implausibleEventTimestampCount = 0
        /// Times the system disabled the tap and this observer re-armed it —
        /// **one per `TapDisabledInterval` emitted**. A `.listenOnly` tap is
        /// disabled WITHOUT `kCGEventTapDisabledByTimeout` ever being
        /// delivered, which is why `pollTapEnabled()` exists.
        public internal(set) var tapDisabledIntervals = 0
        /// The **sum of the enclosing bounds** of every blind window, in
        /// nanoseconds. An over-estimate by construction: each interval
        /// contains the true window rather than being it.
        public internal(set) var tapBlindNanos: Int64 = 0
        /// Blind windows whose lower edge is `.observationStart` rather than a
        /// real event or a poll. Kept apart so one unbounded window cannot
        /// silently dominate `tapBlindNanos`.
        public internal(set) var tapDisabledIntervalsWithNoObservedLowerBound = 0
        /// Blind windows found by the **poll**, as opposed to by a
        /// notification. For this app's `.listenOnly` tap every one is
        /// expected to be found this way.
        public internal(set) var tapDisabledIntervalsFoundByPolling = 0

        /// **How many times anything actually looked**, and over how long.
        /// Without this pair `tapDisabledIntervals == 0` cannot distinguish
        /// "no blind windows" from "nothing was checking"; `tapAccounting`
        /// prints the two together.
        public internal(set) var tapEnabledPolls = 0
        /// First poll to last poll, in nanoseconds — the span the count above
        /// covers.
        public internal(set) var tapPollingSpanNanos: Int64 = 0
        /// Polls that could not read the tap at all (there was none to read).
        /// Kept out of `tapEnabledPolls`: a poll that did not look is not
        /// evidence of looking.
        public internal(set) var tapPollsWithNoTap = 0

        /// No legitimate violation: every `keyDown` this observer saw either
        /// produced one `KeySample` or was refused by the filter. Events
        /// dropped by secure input never reach the keyboard path, so they are
        /// not a third term here.
        public var everyKeyDownIsAccountedFor: Bool {
            keyDownsSeen == keySamples + keyDownsRefused
        }

        public var keyAccounting: String {
            "keyDown \(keyDownsSeen) = recorded \(keySamples) + refused \(keyDownsRefused)"
                + "  → \(everyKeyDownIsAccountedFor ? "balances" : "DOES NOT BALANCE")"
        }

        /// D6a's secure-input row, as the pair that makes its zero readable.
        /// Never print the interval count without the check count.
        public var secureInputAccounting: String {
            let seconds = Double(secureInputCheckSpanNanos) / 1e9
            var line = "secure input intervals: \(secureInputIntervals)"
                + " (\(eventsSuppressedBySecureInput) event(s) suppressed)\n"
                + "secure input checks   : \(secureInputChecks) over "
                + seconds.formatted(.number.precision(.fractionLength(1))) + " s"
            if secureInputChecks == 0 {
                line += "  ← NOTHING WAS LOOKING; the line above is not a measurement"
            }
            return line
        }

        /// The two numbers that only mean something together. Never print the
        /// first without the second.
        public var tapAccounting: String {
            let seconds = Double(tapPollingSpanNanos) / 1e9
            let blindMs = Double(tapBlindNanos) / 1e6
            var windows = "tap disabled windows : \(tapDisabledIntervals)"
                + " (\(tapDisabledIntervalsFoundByPolling) found by polling), "
                + blindMs.formatted(.number.precision(.fractionLength(1))) + " ms of enclosing blind window"
            if tapDisabledIntervalsWithNoObservedLowerBound > 0 {
                windows += "  (\(tapDisabledIntervalsWithNoObservedLowerBound) with no lower bound"
                    + " at all — those contribute no width to the total above)"
            }
            var polls = "tap enabled polls    : \(tapEnabledPolls) over "
                + seconds.formatted(.number.precision(.fractionLength(1))) + " s"
            if tapPollsWithNoTap > 0 { polls += "  (+\(tapPollsWithNoTap) with no tap to read)" }
            if tapEnabledPolls == 0 {
                polls += "  ← NOTHING WAS LOOKING; the line above is not a measurement"
            }
            return windows + "\n" + polls
        }

        /// Zeroed. `public` so the app tier can construct one to diff against.
        public init() {}
    }

    public nonisolated var diagnostics: Diagnostics { lock.withLock { unsafe _diagnostics } }

    // MARK: - Stored state
    //
    // `nonisolated(unsafe)` on every stored property: unannotated, each one is
    // implicitly `@MainActor` under this target's default isolation, and the tap
    // callback is `nonisolated` and cannot touch a MainActor property. Nothing
    // here is protected by actor isolation; everything is protected by `lock`.

    private let lock = NSLock()
    /// The poll's queue. **Never the main queue.**
    private let pollQueue = DispatchQueue(label: "video.soredemo.input-observer.tap-poll",
                                          qos: .utility)
    /// **What is being recorded** — a display, or a window's rect inside one. Was a
    /// `DisplayArrangement` until the window-capture repair (2026-08-20); the observer no
    /// longer knows what a display is, which is the coupling that made the bug expressible.
    private let viewport: CaptureViewport
    private let epoch: BootEpoch
    private let secureInputIsEnabled: @Sendable () -> Bool
    /// Reads the CURRENT system cursor's classified shape, or `nil` when no reader was
    /// injected. A closure because the only API that can answer is AppKit's `NSCursor`,
    /// which `HeadlessCheck` bans from this target — the app tier injects the read, the
    /// same seam `secureInputIsEnabled` and `AXObserver.accessibilityIsGranted` use.
    ///
    /// **Never called from the tap callback, and that is a repair.** It was, once per
    /// pointer sample, and a real recording showed the cursor flickering during fast
    /// movement: the production reader asks AppKit for `NSCursor.currentSystem` and compares
    /// image bytes, which at 120 Hz is enough work for macOS to disable the tap with
    /// `kCGEventTapDisabledByTimeout`. A disabled tap becomes a `tapDisabled` blind
    /// interval, a blind interval draws no pointer, and that is the flicker. The callback
    /// reads `cachedPointerShape` instead; `refreshPointerShape()` is what runs the reader,
    /// on the poll timer that already exists for the tap's own health.
    /// `../opensource/a Swift recorder` (Apache 2.0) samples the pointer on a timer for the same
    /// reason.
    private let pointerShapeReader: @Sendable () -> PointerShape?
    /// Reads where inside the cursor's image the pointer actually is — see
    /// `PointerSample.hotspot` for why a drawn cursor is misplaced without it. Same seam,
    /// same cadence, same reason as the shape: AppKit is not reachable from this target and
    /// the read is too expensive for the tap callback.
    private let pointerHotspotReader: @Sendable () -> NormalizedPoint?
    /// The most recent values the readers returned. Guarded by `lock` like every other
    /// mutable member here.
    private nonisolated(unsafe) var cachedPointerShape: PointerShape?
    private nonisolated(unsafe) var cachedPointerHotspot: NormalizedPoint?
    private let tapIsEnabledOverride: (@Sendable () -> Bool)?

    // MARK: - state guarded by `lock`
    //
    // **Every access to the `nonisolated(unsafe)` properties below is marked `unsafe` at
    // its own expression, and one argument covers all of them**: each is read and written
    // only inside a `lock.withLock` block, or in a context that runs before the instance
    // is shared. `nonisolated(unsafe)` is what lets a `Sendable` type hold mutable state
    // under a lock; the compiler cannot see the lock, so the marks state what it cannot
    // check. Repeating that sentence at each of the 83 sites would say nothing extra —
    // the discipline is a property of the type, not of any one line.
    //
    // Surfaced by Phase 3A-3: `.strictMemorySafety()` applies to package targets, and this
    // file was in the app target until then, so none of these had ever been measured.
    private nonisolated(unsafe) var _diagnostics = Diagnostics()
    private nonisolated(unsafe) var handler: (@Sendable (Observation) -> Void)?
    private nonisolated(unsafe) var tap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    /// The start of the open secure-input interval, if one is open.
    private nonisolated(unsafe) var secureInputBegan: HostInstant?
    /// The first event at which `secureInputIsEnabled()` was consulted — the
    /// left edge of `Diagnostics.secureInputCheckSpanNanos`. Held rather than
    /// derived, since the interval may open and close any number of times.
    private nonisolated(unsafe) var firstSecureInputCheckInstant: HostInstant?
    /// The instant of the last event this observer saw — **any** event,
    /// including one suppressed by secure input. This is the lower edge of a
    /// blind window: the tap cannot have been disabled before the last event
    /// it delivered.
    private nonisolated(unsafe) var lastObservedInstant: HostInstant?
    /// When `start()` armed the tap — the only defensible lower bound for a
    /// blind window that opens before any event has arrived.
    private nonisolated(unsafe) var observationBegan: HostInstant?
    /// The most recent poll that read the tap as **enabled** — the lower bound
    /// that keeps working during a blind window, when `lastObservedInstant` is
    /// frozen at the disable.
    private nonisolated(unsafe) var lastEnabledPollInstant: HostInstant?
    private nonisolated(unsafe) var firstPollInstant: HostInstant?
    /// Polling span from every earlier `start()`/`stop()` cycle. The current
    /// session's span is added to this rather than replacing it.
    private nonisolated(unsafe) var accumulatedPollingSpanNanos: Int64 = 0
    /// The timer that does the polling. Runs on `pollQueue` — **not** the main
    /// run loop.
    private nonisolated(unsafe) var pollTimer: (any DispatchSourceTimer)?

    // MARK: - Init

    /// `arrangement` and `epoch` are supplied by the caller and never read from
    /// ambient state here, which makes the whole conversion a pure function of
    /// its inputs; `currentArrangement()` below is the ambient reader. A stale
    /// arrangement is not corrected mid-run: a rearrangement mid-recording
    /// shows as `unroutablePointerLocations`, not as wrong coordinates.
    ///
    /// `secureInputIsEnabled` defaults to the real reader and is injectable so
    /// the interval logic can be exercised without a password field.
    /// `tapIsEnabledOverride` is `nil` — read the real tap — in every shipping
    /// path; it is an optional rather than a defaulted closure because the real
    /// read needs `self`'s tap, which does not exist when a default argument is
    /// evaluated.
    public init(viewport: CaptureViewport, epoch: BootEpoch,
                secureInputIsEnabled: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() },
                tapIsEnabledOverride: (@Sendable () -> Bool)? = nil,
                pointerShapeReader: @escaping @Sendable () -> PointerShape? = { nil },
                pointerHotspotReader: @escaping @Sendable () -> NormalizedPoint? = { nil }) {
        self.viewport = viewport
        self.epoch = epoch
        self.secureInputIsEnabled = secureInputIsEnabled
        self.tapIsEnabledOverride = tapIsEnabledOverride
        self.pointerShapeReader = pointerShapeReader
        self.pointerHotspotReader = pointerHotspotReader
    }

    deinit {
        // No lock: by the time `deinit` runs there is no other reference
        // through which a concurrent access could occur. The timer must still
        // be cancelled or it keeps firing against a freed port.
        unsafe pollTimer?.cancel()
        if let tap = unsafe tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource = unsafe runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    // MARK: - Lifecycle

    /// The event types this tap asks for.
    ///
    /// **Wider than the minimal mask**: all three drag types, so the pointer
    /// track has no hole for the duration of a right- or other-button drag,
    /// plus the `other` button, which `PointerButton.other` would otherwise
    /// leave unreachable. `.keyDown` only — not `.keyUp`, not `.flagsChanged`.
    ///
    /// **Internal, not `private`**: only the tap reads the mask, so it needs a
    /// check of its own against `category(of:)`.
    nonisolated static let eventTypes: [CGEventType] = [
        .mouseMoved,
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        .keyDown,
    ]

    nonisolated static var eventMask: CGEventMask {
        eventTypes.reduce(into: CGEventMask(0)) { $0 |= CGEventMask(1) << CGEventMask($1.rawValue) }
    }

    /// What `handle` does with an event type — the dispatch table, lifted out
    /// of a `switch` so it can be enumerated and checked against `eventTypes`.
    /// `nil` covers `tapDisabledByTimeout`/`tapDisabledByUserInput` (handled
    /// earlier) and anything the OS widens delivery to later.
    enum EventCategory: Equatable, Sendable {
        case pointerMotion
        case button(PointerButton, ButtonPhase)
        case key
    }

    nonisolated static func category(of type: CGEventType) -> EventCategory? {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return .pointerMotion
        case .leftMouseDown:  return .button(.left, .down)
        case .leftMouseUp:    return .button(.left, .up)
        case .rightMouseDown: return .button(.right, .down)
        case .rightMouseUp:   return .button(.right, .up)
        case .otherMouseDown: return .button(.other, .down)
        case .otherMouseUp:   return .button(.other, .up)
        case .keyDown:        return .key
        default:              return nil
        }
    }

    /// Creates the tap and starts delivering to `onObservation`.
    ///
    /// MainActor-isolated because it installs the run-loop source on
    /// `CFRunLoopGetMain()`, never `CFRunLoopGetCurrent()` — a tap added to a
    /// transient thread's run loop stops delivering when that loop stops.
    /// `onObservation` is therefore called on the main thread and is not a
    /// place to do work: a slow tap callback is disabled by the system.
    public func start(onObservation: @escaping @Sendable (Observation) -> Void) throws {
        guard lock.withLock({ unsafe tap == nil }) else { throw CaptureError.alreadyObserving }

        // `passUnretained`: the tap is torn down in `stop()`/`deinit`, both of
        // which run while `self` is still alive, so the callback cannot
        // outlive it.
        let context = unsafe Unmanaged.passUnretained(self).toOpaque()

        guard let created = unsafe CGEvent.tapCreate(tap: .cgSessionEventTap,
                                              place: .headInsertEventTap,
                                              options: .listenOnly,
                                              eventsOfInterest: Self.eventMask,
                                              callback: inputObserverTapCallback,
                                              userInfo: context)
        else {
            // NOT "no events happened". See `CaptureError`.
            throw CaptureError.inputMonitoringUnavailable
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            CFMachPortInvalidate(created)
            throw CaptureError.eventTapRunLoopSourceUnavailable
        }

        setObservationSink(onObservation)
        lock.withLock {
            unsafe self.tap = created
            unsafe self.runLoopSource = source
            // Recorded before the tap is enabled, so it is a true lower bound
            // on any blind window.
            unsafe self.observationBegan = HostInstant(epoch: epoch, hostTime: Minting.hostNow())
            // **Every instant that bounds a blind window is cleared here, and
            // `start()` after `stop()` is legal**: without this a first poll
            // would reach back across the idle gap between the two sessions.
            // The polling span is carried across as an accumulated base rather
            // than reset, so `tapEnabledPolls` and the span it is quoted over
            // cover about the same period.
            unsafe self.lastObservedInstant = nil
            unsafe self.lastEnabledPollInstant = nil
            unsafe self.firstPollInstant = nil
            unsafe self.accumulatedPollingSpanNanos = unsafe _diagnostics.tapPollingSpanNanos
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        // After the tap exists, so the first poll has something to read.
        startPolling()
    }

    public func stop() {
        // Before the port is cleared, so a poll cannot be mid-read when it is
        // invalidated: the poll handler holds `lock` for the whole of its
        // CoreGraphics work and the clearing below takes the same lock.
        stopPolling()
        let (existingTap, existingSource, pending) = lock.withLock {
            () -> (CFMachPort?, CFRunLoopSource?, HostInstant?) in
            let values = unsafe (tap, runLoopSource, secureInputBegan)
            unsafe tap = nil
            unsafe runLoopSource = nil
            unsafe secureInputBegan = nil
            return values
        }
        if let existingTap {
            CGEvent.tapEnable(tap: existingTap, enable: false)
            CFMachPortInvalidate(existingTap)
        }
        if let existingSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), existingSource, .commonModes)
        }
        if let pending {
            emitSecureInterval(from: pending,
                               to: HostInstant(epoch: epoch, hostTime: Minting.hostNow()),
                               endedBy: .observationStopped)
        }
        lock.withLock { unsafe handler = nil }
    }

    /// Installs the sink `emit` delivers to, **without creating a tap**.
    ///
    /// `start(onObservation:)` calls this and then creates the tap; a checker
    /// can call it alone and drive `handle(type:event:)` with synthetic
    /// `CGEvent`s, since creating a tap needs Input Monitoring. Deliberately
    /// not `public`: a caller that installs a sink and never creates a tap
    /// gets silence.
    nonisolated func setObservationSink(_ sink: @escaping @Sendable (Observation) -> Void) {
        lock.withLock { unsafe handler = sink }
    }

    // MARK: - The conversion, in one place

    /// Steps 2, 3 and 4 of the conversion; step 1
    /// (`CGGeometryBridge.location(from:)`) stays at the call site, where the
    /// CoreGraphics value exists.
    ///
    /// **Takes a `CaptureViewport`, not a `DisplayArrangement`, and that is the
    /// repair.** The arrangement is the right rectangle only when the capture IS
    /// a display; a window recording normalised every sample against the display
    /// while the video was in the window's space, so the drawn cursor was
    /// systematically offset — two rectangles treated as one, `1a98402`'s family
    /// in the geometry domain. The viewport is whatever is actually being
    /// recorded, both capture kinds construct one, and neither is a branch here.
    ///
    /// The conversion itself is `CaptureViewport.normalise`, not restated: it
    /// owns global→local and delegates local→normalised to
    /// `NormalizationContext`. One rule, one owner — this function is the seam,
    /// not a second implementation of the arithmetic.
    ///
    /// Returns `nil` when the location is outside the recording — not a clamp
    /// and not a nearest-display guess: a pointer that was not in shot has no
    /// position in the recording.
    public nonisolated static func normalizedPosition(
        globalTopLeftX: Double, globalTopLeftY: Double, in viewport: CaptureViewport
    ) -> (position: NormalizedPoint, revision: GeometryRevision)? {
        guard let position = viewport.normalise(globalTopLeftX: globalTopLeftX,
                                                globalTopLeftY: globalTopLeftY)
        else { return nil }
        return (position, viewport.revision)
    }

    /// Runs the injected shape reader and caches what it returns, so the tap callback never
    /// has to. Called from the poll timer — the cadence is the timer's, not the pointer's,
    /// which is the whole point: a cursor shape changes when the pointer crosses a control
    /// boundary, not on every one of 120 samples a second.
    ///
    /// `nonisolated` and public to the module so the poll can reach it; the read itself hops
    /// wherever the injected closure needs to go.
    nonisolated func refreshPointerShape() {
        let shape = pointerShapeReader()
        let hotspot = pointerHotspotReader()
        lock.withLock {
            unsafe cachedPointerShape = shape
            unsafe cachedPointerHotspot = hotspot
        }
    }

    // MARK: - The keyboard filter

    /// One entry in the allow-list. `modifiers` is matched **exactly**, not by
    /// subset: ⇧⌘Z is a different entry from ⌘Z, not the same one with an
    /// extra flag.
    public struct ApprovedShortcut: Sendable, Equatable {
        public let identifier: String
        public let keyCode: Int64
        public let modifiers: CGEventFlags
    }

    /// **A closed allow-list, and the entire privacy mechanism of this file.**
    /// Not a deny-list: a key not named here produces nothing at all.
    ///
    /// `identifier` is a **name for the shortcut**, never a rendering of the
    /// keystroke — it is derived from this table, not from the event, and the
    /// event's character content is never read. Key codes are Carbon's
    /// `kVK_ANSI_*` constants because a `CGEvent` carries layout-independent
    /// *positions*, not characters.
    public nonisolated static let approvedShortcuts: [ApprovedShortcut] = [
        // Editing — the ones a demo actually shows happening.
        ApprovedShortcut(identifier: "cmd+c", keyCode: Int64(kVK_ANSI_C), modifiers: [.maskCommand]),
        ApprovedShortcut(identifier: "cmd+v", keyCode: Int64(kVK_ANSI_V), modifiers: [.maskCommand]),
        ApprovedShortcut(identifier: "cmd+x", keyCode: Int64(kVK_ANSI_X), modifiers: [.maskCommand]),
        ApprovedShortcut(identifier: "cmd+a", keyCode: Int64(kVK_ANSI_A), modifiers: [.maskCommand]),
        ApprovedShortcut(identifier: "cmd+z", keyCode: Int64(kVK_ANSI_Z), modifiers: [.maskCommand]),
        ApprovedShortcut(identifier: "cmd+shift+z", keyCode: Int64(kVK_ANSI_Z),
                         modifiers: [.maskCommand, .maskShift]),
        ApprovedShortcut(identifier: "cmd+s", keyCode: Int64(kVK_ANSI_S), modifiers: [.maskCommand]),
        // Navigation and window management.
        ApprovedShortcut(identifier: "cmd+f", keyCode: Int64(kVK_ANSI_F), modifiers: [.maskCommand]),
        ApprovedShortcut(identifier: "cmd+n", keyCode: Int64(kVK_ANSI_N), modifiers: [.maskCommand]),
        ApprovedShortcut(identifier: "cmd+t", keyCode: Int64(kVK_ANSI_T), modifiers: [.maskCommand]),
        ApprovedShortcut(identifier: "cmd+w", keyCode: Int64(kVK_ANSI_W), modifiers: [.maskCommand]),
        ApprovedShortcut(identifier: "cmd+r", keyCode: Int64(kVK_ANSI_R), modifiers: [.maskCommand]),
        ApprovedShortcut(identifier: "cmd+shift+t", keyCode: Int64(kVK_ANSI_T),
                         modifiers: [.maskCommand, .maskShift]),
    ]

    /// The four modifiers this filter is willing to look at.
    ///
    /// **Flags must be masked with this, never compared raw**: a real
    /// `CGEvent` always carries `maskNonCoalesced` and may carry
    /// `maskAlphaShift`, `maskSecondaryFn` or `maskNumericPad`, so exact
    /// equality against raw flags matches nothing, ever. The trade is that
    /// fn+⌘C is recorded as "cmd+c".
    public nonisolated static let consideredModifiers: CGEventFlags =
        [.maskCommand, .maskShift, .maskControl, .maskAlternate]

    /// The identifier for an approved shortcut, or `nil` — which means
    /// **nothing is recorded**, not "recorded without a name".
    ///
    /// Two independent gates, in this order: at least one of Command or
    /// Control must be held, then the (key code, exact modifier set) pair must
    /// appear in `approvedShortcuts`. Gate 1 is redundant with gate 2 today and
    /// kept because the two fail differently.
    public nonisolated static func approvedShortcut(forKeyCode keyCode: Int64,
                                                    flags: CGEventFlags) -> String? {
        let modifiers = flags.intersection(consideredModifiers)
        guard modifiers.contains(.maskCommand) || modifiers.contains(.maskControl) else { return nil }
        return approvedShortcuts.first { $0.keyCode == keyCode && $0.modifiers == modifiers }?.identifier
    }

    // MARK: - The tap callback's body

    /// Called synchronously from `inputObserverTapCallback` on the main thread,
    /// but `nonisolated` regardless: a C function pointer has no isolation to
    /// inherit.
    nonisolated func handle(type: CGEventType, event: CGEvent) {
        let callbackInstant = Minting.hostNow()

        // Out-of-band types first: these are the system saying the tap has been
        // switched off, and they carry no location.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // `callbackInstant` is NOT the end of the blind window — the tap is
            // still off here; `reArmTap` takes the end reading itself.
            reArmTap(disabledBy: type == .tapDisabledByTimeout ? .timeout : .userInput)
            return
        }

        guard let instant = instant(of: event, callbackInstant: callbackInstant) else { return }
        // Before the secure-input branch, deliberately: a suppressed event is
        // still proof the tap was delivering. After it, a password field would
        // look like a blind window.
        lock.withLock { unsafe lastObservedInstant = instant }

        // Secure input, before anything is read off the event: while a password
        // field has focus this emits NOTHING — not a redacted sample, not a
        // placeholder — and accumulates the interval instead. The ask itself is
        // counted, before the answer is looked at.
        let secureInputIsOn = secureInputIsEnabled()
        lock.withLock {
            unsafe _diagnostics.secureInputChecks += 1
            if unsafe firstSecureInputCheckInstant == nil { unsafe firstSecureInputCheckInstant = instant }
            if let first = unsafe firstSecureInputCheckInstant, first.epoch == instant.epoch {
                unsafe _diagnostics.secureInputCheckSpanNanos =
                    max(0, instant.hostTime.rawValue - first.hostTime.rawValue)
            }
        }
        if secureInputIsOn {
            lock.withLock {
                unsafe _diagnostics.eventsSuppressedBySecureInput += 1
                if unsafe secureInputBegan == nil { unsafe secureInputBegan = instant }
            }
            return
        }
        if let began = lock.withLock({ () -> HostInstant? in
            defer { unsafe secureInputBegan = nil }
            return unsafe secureInputBegan
        }) {
            emitSecureInterval(from: began, to: instant, endedBy: .secureInputDisabled)
        }

        switch Self.category(of: type) {
        case .key:
            handleKeyDown(event, at: instant)
        case .pointerMotion:
            handlePointerMotion(event, at: instant)
        case .button(let button, let phase):
            handleButton(event, button: button, phase: phase, at: instant)
        case nil:
            // The mask asks for nothing else. A type arriving here is the OS
            // widening what it delivers, not an event to guess about.
            break
        }
    }

    /// The event's own timestamp as a `HostInstant`, plus the plausibility
    /// check on its unit.
    private nonisolated func instant(of event: CGEvent, callbackInstant: Nanoseconds) -> HostInstant? {
        guard let stampNanos = Int64(exactly: event.timestamp) else {
            lock.withLock { unsafe _diagnostics.unconvertibleTimestamps += 1 }
            return nil
        }
        // Non-negative, not symmetric. The event is stamped by the window
        // server BEFORE this callback runs, so a stamp in the future is not a
        // slow callback — it is a different clock.
        let skew = callbackInstant.rawValue - stampNanos
        if skew < 0 || skew > Self.plausibleSkewNanos {
            lock.withLock { unsafe _diagnostics.implausibleEventTimestampCount += 1 }
        }
        return HostInstant(epoch: epoch, hostTime: Nanoseconds(stampNanos))
    }

    /// 50 ms, in nanoseconds — the upper bound on `hostNow() - event.timestamp`
    /// before an event is counted implausible. A D4 placeholder; nothing is
    /// dropped for being implausible, it is only counted.
    private nonisolated static let plausibleSkewNanos: Int64 = 50_000_000

    // MARK: - The poll, and why there is one

    /// How often the tap's own enabled flag is read, in nanoseconds.
    ///
    /// 100 ms buys two things: a blind window is detected within one interval
    /// of starting, and its lower edge is within ~100 ms of the truth even when
    /// no events are arriving. Loosening it widens every recorded window by the
    /// same amount.
    ///
    /// `internal`, not `private`: a verification asserts a blind window's left
    /// edge is bounded by this rate, and must read the constant rather than
    /// restate it.
    internal nonisolated static let pollIntervalNanos: Int64 = 100_000_000

    /// Starts the poll on a **dedicated queue that is not the callback's**:
    /// what is being detected is the callback thread being stuck, so a poll
    /// scheduled on the same run loop would be blocked exactly when needed.
    nonisolated func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + .nanoseconds(Int(Self.pollIntervalNanos)),
                       repeating: .nanoseconds(Int(Self.pollIntervalNanos)))
        timer.setEventHandler { [weak self] in
            self?.pollTapEnabled()
            // The cursor shape rides this poll rather than the pointer stream. Both belong
            // here for the same reason: this queue is deliberately NOT the callback's, so
            // work done here cannot be what stalls the callback. 100 ms is far finer than a
            // person crossing a control boundary and far coarser than 120 Hz.
            self?.refreshPointerShape()
        }
        lock.withLock {
            unsafe pollTimer?.cancel()
            unsafe pollTimer = timer
        }
        timer.resume()
    }

    nonisolated func stopPolling() {
        let existing = lock.withLock { () -> (any DispatchSourceTimer)? in
            let value = unsafe pollTimer
            unsafe pollTimer = nil
            return value
        }
        existing?.cancel()
    }

    /// One poll. **The only place `CGEvent.tapIsEnabled` is read.** Reads the
    /// flag, and if the tap has been switched off, switches it back on and
    /// closes the blind window it just found.
    ///
    /// **Everything CoreGraphics touches happens under the lock**: `stop()`
    /// clears `tap` under the same lock and only invalidates the port
    /// afterwards, so holding it here keeps the port alive across the read.
    /// The handler, being caller code of unknown cost, is called outside.
    nonisolated func pollTapEnabled() {
        let now = HostInstant(epoch: epoch, hostTime: Minting.hostNow())

        let window: TapDisabledInterval? = lock.withLock {
            if unsafe firstPollInstant == nil { unsafe firstPollInstant = now }
            defer {
                if let first = unsafe firstPollInstant {
                    unsafe _diagnostics.tapPollingSpanNanos = unsafe accumulatedPollingSpanNanos
                        + (now.hostTime.rawValue - first.hostTime.rawValue)
                }
            }

            let enabled: Bool
            if let tapIsEnabledOverride {
                enabled = tapIsEnabledOverride()
            } else if let tap = unsafe tap {
                enabled = CGEvent.tapIsEnabled(tap: tap)
            } else {
                // Nothing to read. NOT counted as a poll: a poll that did not
                // look is not evidence of looking.
                unsafe _diagnostics.tapPollsWithNoTap += 1
                return nil
            }

            unsafe _diagnostics.tapEnabledPolls += 1
            guard !enabled else {
                unsafe lastEnabledPollInstant = now
                return nil
            }

            // The tap is off. Re-enable it first — the only action here that
            // shortens the loss. One call, no backoff: against a persistent
            // cause this becomes a 10 Hz re-arm loop, but backoff would
            // silently lengthen every window it touched.
            if let tap = unsafe tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let reEnabled = Minting.hostNow()

            let (began, source) = lowerBoundLocked()
            guard let began else {
                // **No instant in this process's history bounds the window
                // from below**, so there is no interval to emit — a zero-width
                // one would read as "no time was lost". Counted in all three
                // totals instead. Unreachable through `start()`, which records
                // `observationBegan` before the tap is enabled.
                unsafe _diagnostics.tapDisabledIntervals += 1
                unsafe _diagnostics.tapDisabledIntervalsFoundByPolling += 1
                unsafe _diagnostics.tapDisabledIntervalsWithNoObservedLowerBound += 1
                return nil
            }
            let width = max(0, reEnabled.rawValue - began.hostTime.rawValue)
            unsafe _diagnostics.tapDisabledIntervals += 1
            unsafe _diagnostics.tapDisabledIntervalsFoundByPolling += 1
            unsafe _diagnostics.tapBlindNanos += width
            if source == .observationStart {
                unsafe _diagnostics.tapDisabledIntervalsWithNoObservedLowerBound += 1
            }
            unsafe lastEnabledPollInstant = HostInstant(epoch: epoch, hostTime: reEnabled)
            unsafe lastObservedInstant = HostInstant(epoch: epoch, hostTime: reEnabled)
            return TapDisabledInterval(
                interval: HostRange(epoch: epoch, start: began.hostTime,
                                    duration: Nanoseconds(width)),
                // **Not `.timeout`.** The poll saw that the tap was off and
                // nothing told it why; naming a reason here would be an
                // accusation this code did not measure.
                disabledBy: nil,
                lowerBoundFrom: source,
                detectedBy: .enabledPoll)
        }

        if let window { emit(.tapDisabled(window)) }
    }

    /// The tightest defensible lower bound for a blind window closing now, and
    /// which of the three it came from. **Call under the lock.** `max` of the
    /// two live bounds, since which is tighter depends on whether input was
    /// dense (the event wins) or the tap had been quiet (the poll wins).
    private nonisolated func lowerBoundLocked() -> (HostInstant?, TapBlindWindowLowerBound) {
        let event = unsafe lastObservedInstant
        let poll = unsafe lastEnabledPollInstant
        switch (event, poll) {
        case let (event?, poll?):
            return event.hostTime.rawValue >= poll.hostTime.rawValue
                ? (event, .lastObservedEvent) : (poll, .lastEnabledPoll)
        case let (event?, nil):  return (event, .lastObservedEvent)
        case let (nil, poll?):   return (poll, .lastEnabledPoll)
        case (nil, nil):         return unsafe (observationBegan, .observationStart)
        }
    }

    /// Re-arms the tap and emits the blind window it just closed. **The tap's
    /// presence gates only the re-arming, not the recording**: a disable event
    /// arriving is the evidence that a window happened, whether or not this
    /// observer still holds the port to re-enable.
    private nonisolated func reArmTap(disabledBy reason: TapDisableReason) {
        // One `tapEnable`, exactly as in `pollTapEnabled()`. Both re-arm sites
        // are one call with no backoff; keep them the same, or a tap disabled
        // twice in one recording recovers differently depending on which
        // channel happened to notice.
        if let existing = lock.withLock({ unsafe tap }) {
            CGEvent.tapEnable(tap: existing, enable: true)
        }
        let reEnabled = Minting.hostNow()

        let (began, source) = lock.withLock { lowerBoundLocked() }
        guard let began else {
            // No instant in this process's history bounds the window from
            // below, so there is no interval to report. Counted, never emitted
            // as a zero-width one, which would read as "no time was lost".
            lock.withLock { unsafe _diagnostics.tapDisabledIntervals += 1 }
            return
        }
        // Clamped at zero because `HostRange` traps on a negative duration.
        // Both endpoints here are this process's own readings of one monotonic
        // clock, so the clamp is not expected to fire.
        let width = max(0, reEnabled.rawValue - began.hostTime.rawValue)
        let interval = HostRange(epoch: epoch, start: began.hostTime, duration: Nanoseconds(width))
        lock.withLock {
            unsafe _diagnostics.tapDisabledIntervals += 1
            unsafe _diagnostics.tapBlindNanos += width
            if source == .observationStart {
                unsafe _diagnostics.tapDisabledIntervalsWithNoObservedLowerBound += 1
            }
            // The window is closed; the next one starts from here, not from
            // the stale event that preceded this one.
            unsafe lastObservedInstant = HostInstant(epoch: epoch, hostTime: reEnabled)
        }
        emit(.tapDisabled(TapDisabledInterval(interval: interval, disabledBy: reason,
                                              lowerBoundFrom: source,
                                              detectedBy: .notification)))
    }

    /// Step 1 of the conversion — and the only place in this file that a
    /// CoreGraphics value is handed across. `isButton` picks which of the two
    /// unroutable-location counters a failure lands in.
    private nonisolated func position(of event: CGEvent, isButton: Bool = false)
        -> (position: NormalizedPoint, revision: GeometryRevision)? {
        let location = CGGeometryBridge.location(from: event.location)
        guard let converted = Self.normalizedPosition(globalTopLeftX: location.x,
                                                      globalTopLeftY: location.y,
                                                      in: viewport) else {
            lock.withLock {
                if isButton { unsafe _diagnostics.unroutableButtonLocations += 1 }
                else { unsafe _diagnostics.unroutablePointerLocations += 1 }
            }
            return nil
        }
        return converted
    }

    private nonisolated func handlePointerMotion(_ event: CGEvent, at instant: HostInstant) {
        guard let converted = position(of: event) else { return }
        lock.withLock { unsafe _diagnostics.pointerSamples += 1 }
        // Never thinned (D2-7): ~24 bytes a sample at 120 Hz is about 1 MB for
        // five minutes, and a thinned track cannot be re-tuned later.
        emit(.pointer(PointerSample(instant: instant,
                                    position: converted.position,
                                    revision: converted.revision,
                                    shape: lock.withLock { unsafe cachedPointerShape },
                                    hotspot: lock.withLock { unsafe cachedPointerHotspot })))
    }

    private nonisolated func handleButton(_ event: CGEvent, button: PointerButton,
                                          phase: ButtonPhase, at instant: HostInstant) {
        guard let converted = position(of: event, isButton: true) else { return }
        lock.withLock { unsafe _diagnostics.buttonEvents += 1 }
        emit(.button(ButtonEvent(instant: instant, position: converted.position,
                                 revision: converted.revision, button: button, phase: phase)))
    }

    /// **The one place a keystroke could leak, and it reads two integers.**
    /// `keyboardEventKeycode` and `event.flags` are not text, and this function
    /// never asks the event for its characters; what leaves is a literal from
    /// `approvedShortcuts`, not anything a person typed.
    private nonisolated func handleKeyDown(_ event: CGEvent, at instant: HostInstant) {
        lock.withLock { unsafe _diagnostics.keyDownsSeen += 1 }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let shortcut = Self.approvedShortcut(forKeyCode: keyCode, flags: event.flags) else {
            lock.withLock { unsafe _diagnostics.keyDownsRefused += 1 }
            return
        }
        lock.withLock { unsafe _diagnostics.keySamples += 1 }
        emit(.key(KeySample(instant: instant, shortcut: shortcut)))
    }

    private nonisolated func emitSecureInterval(from began: HostInstant, to ended: HostInstant,
                                                endedBy: SecureInputIntervalEnd) {
        // Clamped at zero rather than trusting the ordering: event timestamps
        // are the OS's, not this process's, and `HostRange` traps on a negative
        // duration.
        let duration = max(0, ended.hostTime.rawValue - began.hostTime.rawValue)
        let range = HostRange(epoch: epoch, start: began.hostTime, duration: Nanoseconds(duration))
        lock.withLock { unsafe _diagnostics.secureInputIntervals += 1 }
        emit(.secureInput(SecureInputInterval(interval: range, endedBy: endedBy)))
    }

    private nonisolated func emit(_ observation: Observation) {
        // The handler is read under the lock and called outside it: calling
        // caller code while holding the lock would let it deadlock this
        // observer against its own `diagnostics` accessor.
        let handler = lock.withLock { unsafe self.handler }
        handler?(observation)
    }

    // MARK: - The ambient reader

    /// The displays as they are attached **right now** — the input `init` will
    /// not read for itself, kept separate so the conversion never depends on
    /// this machine's hardware.
    ///
    /// **`scale` comes from the display mode, not `NSScreen`**:
    /// `CGDisplayMode.pixelWidth / .width` is the definition
    /// `DisplayGeometry.scale` carries. A display that cannot be fully
    /// described — no mode, no persistent UUID, or a zero-width mode — is
    /// **dropped, not defaulted**, and its points then route nowhere.
    public nonisolated static func currentArrangement() -> DisplayArrangement {
        var displayCount: UInt32 = 0
        guard unsafe CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return DisplayArrangement(placements: [])
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard unsafe CGGetActiveDisplayList(displayCount, &ids, &displayCount) == .success else {
            return DisplayArrangement(placements: [])
        }

        var placements: [DisplayArrangement.Placement] = []
        for id in ids.prefix(Int(displayCount)) {
            // **Mirrors are skipped; the display being mirrored is kept.**
            // `CGGetActiveDisplayList` returns every member of a *software*
            // mirror set and those members share a `CGDisplayBounds`, so two
            // placements would cover one rectangle with different
            // `GeometryRevision`s and `route` would pick whichever came first
            // — and `NormalizationContext.denormalize` **preconditions** on
            // revision equality. `CGDisplayMirrorsDisplay` names the primary,
            // which is in the active list too, so dropping mirrors leaves one
            // placement per rectangle. Hardware mirroring is invisible here.
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { continue }
            guard let mode = CGDisplayCopyDisplayMode(id) else { continue }
            let pointWidth = mode.width
            let pointHeight = mode.height
            guard pointWidth > 0, pointHeight > 0, mode.pixelWidth > 0, mode.pixelHeight > 0 else { continue }
            guard let uuid = Minting.displayIdentity(of: id) else { continue }
            let bounds = CGGeometryBridge.pointRect(from: CGDisplayBounds(id))
            placements.append(DisplayArrangement.Placement(
                geometry: DisplayGeometry(displayUUID: uuid,
                                          pixelWidth: mode.pixelWidth,
                                          pixelHeight: mode.pixelHeight,
                                          scale: Double(mode.pixelWidth) / Double(pointWidth)),
                globalOriginX: bounds.x,
                globalOriginY: bounds.y))
        }
        return DisplayArrangement(placements: placements)
    }
}

/// The tap's C callback.
///
/// **A named free function, not a closure literal, and not a method.**
/// `CGEventTapCallBack` is a bare C function pointer: it captures nothing, and
/// under this target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` an
/// unannotated function — or a closure literal at the call site — is
/// `@MainActor` and will not convert to one. Hence the explicit `nonisolated`.
///
/// **Returns the event it was handed, unchanged, on every path**, including the
/// paths where the observer records nothing.
private nonisolated func inputObserverTapCallback(proxy: CGEventTapProxy,
                                                  type: CGEventType,
                                                  event: CGEvent,
                                                  userInfo: UnsafeMutableRawPointer?)
    -> Unmanaged<CGEvent>? {
    if let userInfo = unsafe userInfo {
        unsafe Unmanaged<InputObserver>.fromOpaque(userInfo).takeUnretainedValue()
            .handle(type: type, event: event)
    }
    return unsafe Unmanaged.passUnretained(event)
}
