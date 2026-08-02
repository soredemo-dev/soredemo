import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Geometry
import Project
import Timeline

/// `ROADMAP.md`'s `input-observation` row: a **listen-only** `CGEvent` tap for
/// pointer motion, clicks and an allow-listed set of keyboard shortcuts.
///
/// **This type is the first real caller of both halves of the conversion
/// boundary.** `NormalizationContext` and `Soredemo/Capture/CGGeometryBridge.swift`
/// had zero callers in the app target until this file existed — the first was
/// a pure function nobody called, the second was exercised only by a hand-run
/// script. The row carries a claim moved off `geometry-types` ("all conversion
/// in one place"), and the claim is only true while `normalizedPosition(…)`
/// below is the *only* place a global event location becomes a
/// `NormalizedPoint`. If a second one appears, the row is false and should say
/// so instead.
///
/// **The conversion is four steps and the order is load-bearing:**
///
/// ```
/// CGEvent.location            global, top-left, POINTS
///   -> CGGeometryBridge.location(from:)     CGPoint  ->  bare scalars
///   -> DisplayArrangement.route             global   ->  within-screen POINTS
///   -> DisplayGeometry.pixels(from:)        points   ->  within-screen PIXELS
///   -> NormalizationContext.normalize       pixels   ->  NormalizedPoint
/// ```
///
/// Steps 2 and 3 are the ones that get skipped, and neither skip fails to
/// compile: `route` takes bare `Double`s (Task 10.5 left that gap knowingly),
/// so points and pixels are not distinguishable by type at that boundary.
/// Feeding `route`'s point output straight into `normalize` is off by exactly
/// the display's `scale`, and feeding an unrouted global point in is off by
/// the display's global origin — both produce a well-formed `NormalizedPoint`
/// with no error anywhere. The check that catches the first is `§ 7` of
/// `scripts/cross-boundary-digest-probe.swift`, whose fixture display is at
/// `scale: 2`; at `scale: 1` the pixel step is the identity and the check
/// passes either way, which is the third time this project has written an
/// expectation table whose fixture made the assertion vacuous.
///
/// **`CGEventTimestamp` is nanoseconds and is NOT converted.** Three
/// independent statements of the same fact, because guessing it wrong places
/// every click at 1/24 of its true offset with no error and no crash:
///   * the SDK header — `CGEventTypes.h`, at the `typedef`:
///     "Event timestamp; roughly, nanoseconds since startup";
///   * F2-1's measurement — the ratio of `CGEventTimestamp` to
///     `mach_absolute_time()` was 41.6667 = 125/3 across three samples, which
///     is this machine's `mach_timebase_info` (`numer 125, denom 3`, still
///     what it reads today), i.e. the event stamp is already in the units
///     `mach_absolute_time()` has to be multiplied into;
///   * `Diagnostics.implausibleEventTimestampCount` below, which is the
///     standing instrument rather than a one-off measurement: under the wrong
///     unit **every** event lands there, because a tick-valued stamp read as
///     nanoseconds sits ~24× further from `Minting.hostNow()` than the whole
///     uptime.
/// So the stamp goes straight into `Nanoseconds`, on the same base as
/// `Minting.hostNow()` — which is what `hostNow()`'s own doc comment already
/// asserted, with no caller to hold it to it until now.
///
/// **`nonisolated` on everything the tap can reach.** Under this target's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` an unannotated declaration is
/// `@MainActor`, and a `CGEventTapCallBack` is a bare C function pointer: it
/// cannot be a closure that captures anything, and it cannot be MainActor-
/// isolated. `CaptureSession` documents the same decision for
/// `SCStreamOutput`, with the compiler errors it hit; the shape here is
/// identical, and the free function `inputObserverTapCallback` at the bottom
/// of this file is why the callback is a named `nonisolated func` rather than
/// the closure literal `spikes/2026-08-02-pairing-latency/main.swift` uses
/// (that spike is a top-level script compiled without `-default-isolation
/// MainActor`, so its closure converts; this file's would not).
///
/// **Listen-only.** `options: .listenOnly` — the tap never modifies, delays
/// or drops an event. The callback returns the event it was handed, always.
public final class InputObserver: @unchecked Sendable {

    // MARK: - What the observer produces

    /// One thing worth recording. A discriminated union rather than four
    /// callbacks, so a caller cannot wire up three of them and silently drop
    /// the fourth — which for `.secureInput` would restore exactly the
    /// silence that case exists to break.
    public enum Observation: Sendable, Equatable {
        case pointer(PointerSample)
        case button(ButtonEvent)
        case key(KeySample)
        /// Emitted when the interval **closes**, not when it opens: it is a
        /// range, and a range with no end is not yet a fact. `stop()` closes
        /// an open one with `.observationStopped` so a recording that ends
        /// mid-password still reports the interval rather than losing it.
        case secureInput(SecureInputInterval)
    }

    // MARK: - Diagnostics

    /// What this observer saw, as counts. Held in memory, read by the caller
    /// after the fact; nothing here is written to the package.
    ///
    /// **The keyboard counters are counts, never content.** `keyDownsSeen`
    /// and `keyDownsRefused` are integers: they say how many keys were
    /// pressed, never which. They are here because the alternative — an
    /// unexplained absence of `KeySample`s — is indistinguishable from a tap
    /// that never received a keystroke, and `keyDownsSeen == keySamples +
    /// keyDownsRefused` is the conservation law that makes "the filter
    /// removed them" a statement rather than a hope. A filter's output taken
    /// without its input cannot show what the filter removed, which is the
    /// same structural point `CaptureSession.Diagnostics` had to be
    /// rearranged for.
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
        /// Locations `DisplayArrangement.route` placed on no known display.
        ///
        /// Non-zero means the arrangement this observer was constructed with
        /// is stale — a display was plugged, unplugged or rearranged since —
        /// and the samples are **dropped, not clamped**. A clamped sample is
        /// a pointer position on a display it was never on, which reads as
        /// real motion; the absence is at least visible here.
        ///
        /// **Pointer motion only.** A click that could not be routed lands in
        /// `unroutableButtonLocations` instead, because the two are
        /// reconciled by different people looking for different things.
        public internal(set) var unroutablePointerLocations = 0
        /// The same, for a **click** — a click that produced no
        /// `ButtonEvent`.
        ///
        /// Split out on review. Folded into the counter above, which it was,
        /// someone reconciling "two button events for three clicks" would be
        /// looking for the missing click under a pointer-shaped name, which
        /// is where it would not be found.
        public internal(set) var unroutableButtonLocations = 0
        /// Events whose `CGEventTimestamp` would not fit `Int64` nanoseconds.
        /// Structurally impossible before the year 2262; counted anyway,
        /// because the alternative to counting is truncating.
        public internal(set) var unconvertibleTimestamps = 0
        /// Events whose timestamp was **in the future**, or more than
        /// `plausibleSkewNanos` (50 ms) in the past, relative to
        /// `Minting.hostNow()` at callback entry.
        ///
        /// **This is the standing check on the unit.** A `CGEventTimestamp`
        /// misread as `mach_absolute_time` ticks would put every single event
        /// here, by a margin of hours. A handful is a slow callback; a run
        /// where this equals the event count is the unit being wrong, and it
        /// is visible without anyone re-deriving the ratio.
        ///
        /// The window is one-sided: the window server stamps the event before
        /// this callback runs, so any future stamp is a different clock, not
        /// latency. Spike A measured `tapLatencyNegative` false in all 118 of
        /// its samples — that direction has never legitimately occurred. See
        /// `plausibleSkewNanos` for where 50 ms comes from.
        public internal(set) var implausibleEventTimestampCount = 0
        /// Times the system disabled the tap and this observer re-armed it.
        ///
        /// A `.listenOnly` tap is still disabled if the callback is too slow
        /// (`kCGEventTapDisabledByTimeout`). Left un-rearmed, everything
        /// afterwards is silence that looks exactly like a person who stopped
        /// moving.
        public internal(set) var tapReArmedCount = 0

        /// No legitimate violation: every `keyDown` this observer saw either
        /// produced one `KeySample` or was refused by the filter.
        ///
        /// Events dropped by secure input never reach the keyboard path at
        /// all — the suppression check runs first — so they are not a third
        /// term here; `eventsSuppressedBySecureInput` counts them across all
        /// event types together.
        public var everyKeyDownIsAccountedFor: Bool {
            keyDownsSeen == keySamples + keyDownsRefused
        }

        public var keyAccounting: String {
            "keyDown \(keyDownsSeen) = recorded \(keySamples) + refused \(keyDownsRefused)"
                + "  → \(everyKeyDownIsAccountedFor ? "balances" : "DOES NOT BALANCE")"
        }
    }

    public nonisolated var diagnostics: Diagnostics { lock.withLock { _diagnostics } }

    // MARK: - Stored state
    //
    // `nonisolated(unsafe)` on every stored property, for the reason
    // `CaptureSession` sets out at length: unannotated, each one is implicitly
    // `@MainActor` under this target's default isolation, and the tap callback
    // is `nonisolated` and synchronous and cannot touch a MainActor property.
    // Nothing here is protected by actor isolation; everything is protected by
    // `lock`, and `withLock`'s closure is what makes concurrent access safe.

    private let lock = NSLock()
    private let arrangement: DisplayArrangement
    private let epoch: BootEpoch
    private let secureInputIsEnabled: @Sendable () -> Bool

    private nonisolated(unsafe) var _diagnostics = Diagnostics()
    private nonisolated(unsafe) var handler: (@Sendable (Observation) -> Void)?
    private nonisolated(unsafe) var tap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    /// The start of the open secure-input interval, if one is open.
    private nonisolated(unsafe) var secureInputBegan: HostInstant?

    // MARK: - Init

    /// `arrangement` and `epoch` are supplied by the caller and never read
    /// from ambient state here — the same shape `CaptureSession.init` and
    /// `CaptureSource.geometry(scale:displayUUID:)` already use, and for the
    /// same reason: it makes the whole conversion a pure function of its
    /// inputs, testable against fixture displays that are not attached to this
    /// machine. `currentArrangement()` below is the ambient reader, kept
    /// separate so nothing that converts also discovers.
    ///
    /// A stale arrangement is not corrected mid-run. Re-reading it on a
    /// display-reconfiguration callback belongs with the one
    /// `CaptureSession` already registers (D2-10) rather than a second,
    /// independently-racing observer here; until that is wired up, a
    /// rearrangement mid-recording shows as `unroutablePointerLocations`
    /// rather than as wrong coordinates.
    /// **`secureInputIsEnabled` defaults to the real reader and exists so the
    /// interval can be exercised without a password field.** Not a mock
    /// standing in for a reader that could have been called directly: whether
    /// `IsSecureEventInputEnabled()` is true is a property of *another
    /// application's* window having focus, so a check that waits for it to
    /// become true is a check that never runs on this machine — and "secure
    /// input produces an interval, not silence" is a privacy claim, which is
    /// the category this project has repeatedly passed vacuously. Injecting
    /// the predicate makes the interval logic (open, close, the two end
    /// reasons, the suppression) checkable in `§ 7.4` of the probe; that the
    /// real predicate is wired up and reads true at the right moment is the
    /// human step's job, and it is the only part of this that needs one.
    public init(arrangement: DisplayArrangement, epoch: BootEpoch,
                secureInputIsEnabled: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }) {
        self.arrangement = arrangement
        self.epoch = epoch
        self.secureInputIsEnabled = secureInputIsEnabled
    }

    deinit {
        // No lock: by the time `deinit` runs there is no other reference
        // through which a concurrent access could occur. Same reasoning as
        // `CaptureSession.deinit`.
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    // MARK: - Lifecycle

    /// The event types this tap asks for.
    ///
    /// **Wider than the plan's mask, in two places, and both follow from the
    /// row's own "keep the whole pointer track".** The plan listed
    /// `mouseMoved`, the left and right button transitions and
    /// `leftMouseDragged`. That omits `rightMouseDragged` and
    /// `otherMouseDragged`, so the pointer track would have a hole for the
    /// duration of every right-drag — an absence indistinguishable from a
    /// stationary pointer, which is the thing this row keeps re-deriving. It
    /// also omits the `other` button entirely, while `PointerButton.other`
    /// exists in the record type (Task 3) and would otherwise be unreachable:
    /// a middle-click would be recorded as nothing at all.
    ///
    /// `.keyDown` only — not `.keyUp`, not `.flagsChanged`. A shortcut is
    /// recorded at the moment it fires; key-up and modifier transitions would
    /// add timing detail about typing rhythm for no gain in what the log can
    /// say.
    /// **Internal, not `private`, and that is the review finding it exists to
    /// close.** While this was `private`, deleting `.mouseMoved` from the list
    /// left all 338 tests and all 83 probe checks green while the shipped app
    /// recorded clicks and shortcuts and **no pointer track at all** — because
    /// the probe drives `handle(type:event:)` directly and so never consults
    /// the mask. The mask is the one piece of this file that only the tap
    /// reads, which is exactly why it needed a check of its own rather than
    /// being trusted because everything downstream of it is tested. `§ 7.5`
    /// pins it against `category(of:)` in both directions.
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
    /// of the `switch` that used to hold it.
    ///
    /// **Lifted so it can be enumerated.** A `switch` is not a value: nothing
    /// could ask "which types does this handle?", so nothing could check that
    /// the answer matches `eventTypes`. The two lists drifting apart is silent
    /// in both directions — a type asked for but not handled is a wasted
    /// callback, and a type handled but not asked for is a feature that never
    /// fires — and one of those two is the `.mouseMoved` deletion above.
    ///
    /// Returning `nil` covers `tapDisabledByTimeout`/`tapDisabledByUserInput`
    /// (handled earlier, before any location is read, since they carry none)
    /// and anything the OS widens delivery to later.
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
    /// Not `nonisolated`: this touches the **main** run loop, so it is
    /// MainActor-isolated by this target's default and that is correct rather
    /// than incidental. `CFRunLoopGetMain()` is used explicitly, never
    /// `CFRunLoopGetCurrent()` — a tap added to a transient thread's run loop
    /// stops delivering when that thread's loop stops running, which presents
    /// as a recording where the pointer track simply ends part-way through.
    ///
    /// `onObservation` is called on the main thread as a consequence, and is
    /// therefore not a place to do work: `CGEvent` taps that take too long are
    /// disabled by the system (see `Diagnostics.tapReArmedCount`).
    public func start(onObservation: @escaping @Sendable (Observation) -> Void) throws {
        guard lock.withLock({ tap == nil }) else { throw CaptureError.alreadyObserving }

        // `passUnretained`, matching `CaptureSession`'s reconfiguration
        // token: the tap is torn down in `stop()`/`deinit`, both of which run
        // while `self` is still alive, so the callback can never outlive it.
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap,
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
            self.tap = created
            self.runLoopSource = source
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
    }

    /// Tears the tap down and closes an open secure-input interval with
    /// `.observationStopped`.
    ///
    /// Closing it here is the whole reason `SecureInputIntervalEnd` has two
    /// cases. A recording that ends while a password field still has focus
    /// would otherwise drop the interval on the floor — and the dropped
    /// interval is precisely the one where the log has no samples to show for
    /// the time, which is the state a reader most needs told.
    public func stop() {
        let (existingTap, existingSource, pending) = lock.withLock {
            () -> (CFMachPort?, CFRunLoopSource?, HostInstant?) in
            let values = (tap, runLoopSource, secureInputBegan)
            tap = nil
            runLoopSource = nil
            secureInputBegan = nil
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
        lock.withLock { handler = nil }
    }

    /// Installs the sink `emit` delivers to, **without creating a tap**.
    ///
    /// `start(onObservation:)` calls this and then creates the tap. `§ 7` of
    /// `scripts/cross-boundary-digest-probe.swift` calls it alone and then
    /// drives `handle(type:event:)` with synthetic `CGEvent`s, because
    /// creating a tap needs Input Monitoring and what those checks are about
    /// is the callback *body* — the conversion, the filter and the secure-
    /// input interval, none of which the tap participates in.
    ///
    /// Deliberately not `public`: this is the seam that makes the shell thin,
    /// not a second way for a caller to start observing. A caller that
    /// installs a sink and never creates a tap gets silence, which is the one
    /// outcome this whole file is written to avoid.
    nonisolated func setObservationSink(_ sink: @escaping @Sendable (Observation) -> Void) {
        lock.withLock { handler = sink }
    }

    // MARK: - The conversion, in one place

    /// Steps 2, 3 and 4 of the conversion — the whole of it that does not
    /// need a `CGPoint`, and therefore the whole of it that can be tested.
    ///
    /// Step 1 (`CGGeometryBridge.location(from:)`) is at the call site
    /// because that is where the CoreGraphics value exists and the bridge is
    /// the only file allowed to name its type; it is a single call and it
    /// converts nothing itself beyond `CGFloat` → `Double`.
    ///
    /// Returns `nil` when the location is on no display in `arrangement`.
    /// Not a clamp and not a nearest-display guess: both would produce a
    /// coordinate that reads as a real pointer position on a display the
    /// pointer was never on.
    ///
    /// **The `pixels(from:)` step in the middle is the one that looks
    /// redundant and is not.** `route` returns display-local *points*;
    /// `normalize` requires display-local *pixels* and says so in its own
    /// documentation. On a `scale: 1` display the two are equal and this line
    /// can be deleted with every test still green — which is why the fixture
    /// that guards it is at `scale: 2`. The zero-size `PointRect` is the
    /// spelling `DisplayArrangement`'s documentation itself uses for a single
    /// routed point, since `DisplayGeometry` converts rects and a point has
    /// no width to convert.
    public nonisolated static func normalizedPosition(
        globalTopLeftX: Double, globalTopLeftY: Double, in arrangement: DisplayArrangement
    ) -> (position: NormalizedPoint, revision: GeometryRevision)? {
        // Step 2 — global points → display-local points.
        guard let hit = arrangement.route(globalTopLeftX: globalTopLeftX,
                                          globalTopLeftY: globalTopLeftY) else { return nil }
        // Step 3 — display-local points → display-local native pixels.
        let pixels = hit.geometry.pixels(
            from: PointRect(x: hit.localX, y: hit.localY, width: 0, height: 0))
        // Step 4 — display-local pixels → normalised, bottom-left, 0…1.
        let position = NormalizationContext(geometry: hit.geometry)
            .normalize(topLeftX: pixels.x, topLeftY: pixels.y)
        return (position, hit.geometry.revision)
    }

    // MARK: - The keyboard filter

    /// One entry in the allow-list.
    ///
    /// `modifiers` is matched **exactly**, not by subset: ⇧⌘Z is a different
    /// entry from ⌘Z, not the same one with an extra flag. A subset match
    /// would fold every accidental modifier combination onto the nearest
    /// approved shortcut and record something the person did not press.
    public struct ApprovedShortcut: Sendable, Equatable {
        public let identifier: String
        public let keyCode: Int64
        public let modifiers: CGEventFlags
    }

    /// **A closed allow-list, and the entire privacy mechanism of this file.**
    ///
    /// The package must never receive an unfiltered keystroke — there is then
    /// nothing to redact later, and no version of the file on disk that ever
    /// held one. So this is not a *deny*-list of sensitive keys: a key that
    /// is not named here produces nothing at all, and adding a key is a
    /// deliberate act with a diff.
    ///
    /// `identifier` is a **name for the shortcut**, never a rendering of the
    /// keystroke. That distinction is what makes `KeySample.shortcut` safe to
    /// store: "cmd+c" is derived from this table, not from the event, and the
    /// event's character content is never read — no `CGEventKeyboardGet
    /// UnicodeString`, no `NSEvent.characters`, anywhere under `Soredemo/`,
    /// which `AppSourceTests.noAppSourceReadsKeystrokeText` enforces over the
    /// whole app rather than trusting this file.
    ///
    /// The key codes are Carbon's `kVK_ANSI_*` constants rather than integer
    /// literals — they are layout-independent *positions*, which is what a
    /// `CGEvent` carries, and writing 8 for "C" by hand is how the wrong key
    /// ends up allow-listed.
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
    /// **Masked, never compared raw, and this is measured rather than
    /// tidy.** A real `CGEvent` always carries `maskNonCoalesced` (0x100) in
    /// its flags, and may carry `maskAlphaShift`, `maskSecondaryFn` or
    /// `maskNumericPad` besides. An exact-equality test against
    /// `[.maskCommand]` on the raw flags therefore matches **nothing, ever**
    /// — a filter that silently records no shortcut at all, which is
    /// indistinguishable from a filter that works until someone presses ⌘C
    /// and looks for it.
    ///
    /// The consequence, stated because it is a real one: fn+⌘C is recorded as
    /// "cmd+c". Ignoring `fn` and caps-lock is the deliberate trade — they do
    /// not distinguish two approved shortcuts from one another anywhere in
    /// the table above.
    public nonisolated static let consideredModifiers: CGEventFlags =
        [.maskCommand, .maskShift, .maskControl, .maskAlternate]

    /// The identifier for an approved shortcut, or `nil` — which means
    /// **nothing is recorded**, not "recorded without a name".
    ///
    /// Two independent gates, in this order:
    ///   1. at least one of Command or Control must be held. Ordinary typing,
    ///      ⇧-typing and ⌥-typing — every way a password or a message is
    ///      entered — is refused here, before the table is even consulted;
    ///   2. the (key code, exact modifier set) pair must appear in
    ///      `approvedShortcuts`.
    ///
    /// Gate 1 is redundant with gate 2 today, since every entry in the table
    /// carries `.maskCommand`. It is kept because the two fail differently:
    /// gate 2 is a data question that a future entry could get wrong, gate 1
    /// is a structural statement about which events can reach the table at
    /// all. `§ 7.3` of the probe reddens on removing either.
    public nonisolated static func approvedShortcut(forKeyCode keyCode: Int64,
                                                    flags: CGEventFlags) -> String? {
        let modifiers = flags.intersection(consideredModifiers)
        guard modifiers.contains(.maskCommand) || modifiers.contains(.maskControl) else { return nil }
        return approvedShortcuts.first { $0.keyCode == keyCode && $0.modifiers == modifiers }?.identifier
    }

    // MARK: - The tap callback's body

    /// Called synchronously from `inputObserverTapCallback`, on the main
    /// thread (that is where the run-loop source is installed) — but
    /// `nonisolated` regardless, because a C function pointer has no
    /// isolation to inherit and the compiler cannot be told otherwise.
    nonisolated func handle(type: CGEventType, event: CGEvent) {
        let callbackInstant = Minting.hostNow()

        // Out-of-band types first: these are not input, they are the system
        // saying the tap has been switched off. Handled before anything reads
        // a location, because they carry none.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reArmTap()
            return
        }

        guard let instant = instant(of: event, callbackInstant: callbackInstant) else { return }

        // Secure input, before anything is read off the event. `IsSecure
        // EventInputEnabled()` is true while a password field has focus;
        // while it is, this emits NOTHING — not a redacted sample, not a
        // placeholder — and accumulates the interval instead.
        if secureInputIsEnabled() {
            lock.withLock {
                _diagnostics.eventsSuppressedBySecureInput += 1
                if secureInputBegan == nil { secureInputBegan = instant }
            }
            return
        }
        if let began = lock.withLock({ () -> HostInstant? in
            defer { secureInputBegan = nil }
            return secureInputBegan
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
    /// check that stands in for re-deriving F2-1.
    private nonisolated func instant(of event: CGEvent, callbackInstant: Nanoseconds) -> HostInstant? {
        guard let stampNanos = Int64(exactly: event.timestamp) else {
            lock.withLock { _diagnostics.unconvertibleTimestamps += 1 }
            return nil
        }
        // Non-negative, not symmetric. The event is stamped by the window
        // server BEFORE this callback runs, so a stamp in the future is not a
        // slow callback — it is a different clock. The previous version of
        // this line accepted anything within a second in either direction,
        // which silently admitted the whole future half of that window.
        let skew = callbackInstant.rawValue - stampNanos
        if skew < 0 || skew > Self.plausibleSkewNanos {
            lock.withLock { _diagnostics.implausibleEventTimestampCount += 1 }
        }
        return HostInstant(epoch: epoch, hostTime: Nanoseconds(stampNanos))
    }

    /// 50 ms, in nanoseconds — the upper bound on `hostNow() - event.timestamp`
    /// before an event is counted implausible.
    ///
    /// **Derived from Spike A, and the citation matters because the first
    /// version of this comment credited the wrong measurement.** F2-1
    /// established the *timebase ratio*; it says nothing about how long the
    /// tap path takes. The tap-latency distribution is Spike A's, in
    /// `docs/design/2026-08-02-phase-2-record-design.md` § "Tap latency is not
    /// the hazard": 118 samples on real targets, including clicks during menu,
    /// Dock and window animations —
    ///
    /// | p50 | p90 | p95 | max |
    /// | --- | --- | --- | --- |
    /// | 0.41 ms | 1.64 ms | 2.57 ms | **5.46 ms** |
    ///
    /// 50 ms is ~9× that worst case, so a healthy run does not trip it, and it
    /// is ~200× tighter than the failure it exists to catch: a stamp misread
    /// as `mach_absolute_time` ticks sits *hours* from `hostNow()`, since it
    /// would be 3/125 of the true value on this machine's timebase. The old
    /// value, 1 s, was ~180× the observed max and therefore discriminated
    /// nothing except the unit error — it could not have distinguished a
    /// genuinely pathological callback from a normal one.
    ///
    /// **Still a D4 placeholder, and labelled as one** — but derived rather
    /// than picked. The design doc's own caveat on that table stands: "one
    /// machine, one session, an uncontrolled app mix … this is the first
    /// distribution, not the answer." What changes if it is refitted is the
    /// sensitivity of a diagnostic, never a recorded value: nothing is
    /// dropped for being implausible, it is only counted.
    private nonisolated static let plausibleSkewNanos: Int64 = 50_000_000

    private nonisolated func reArmTap() {
        let existing = lock.withLock { tap }
        guard let existing else { return }
        CGEvent.tapEnable(tap: existing, enable: true)
        lock.withLock { _diagnostics.tapReArmedCount += 1 }
    }

    /// Step 1 of the conversion — and the only place in this file that a
    /// CoreGraphics value is handed across.
    ///
    /// `isButton` picks which counter a failure lands in. **Two counters, not
    /// one**, because a click and a pointer sample are reconciled by different
    /// people looking for different things: a reader who counts two button
    /// events for three clicks needs to find the missing click, and it was
    /// previously hiding under a pointer-shaped name.
    private nonisolated func position(of event: CGEvent, isButton: Bool = false)
        -> (position: NormalizedPoint, revision: GeometryRevision)? {
        let location = CGGeometryBridge.location(from: event.location)
        guard let converted = Self.normalizedPosition(globalTopLeftX: location.x,
                                                      globalTopLeftY: location.y,
                                                      in: arrangement) else {
            lock.withLock {
                if isButton { _diagnostics.unroutableButtonLocations += 1 }
                else { _diagnostics.unroutablePointerLocations += 1 }
            }
            return nil
        }
        return converted
    }

    private nonisolated func handlePointerMotion(_ event: CGEvent, at instant: HostInstant) {
        guard let converted = position(of: event) else { return }
        lock.withLock { _diagnostics.pointerSamples += 1 }
        // Never thinned (D2-7): ~24 bytes a sample at 120 Hz is about 1 MB
        // for five minutes, against several GB of video, and a thinned track
        // cannot be re-tuned when `camera-motion`'s spring is calibrated.
        emit(.pointer(PointerSample(instant: instant,
                                    position: converted.position,
                                    revision: converted.revision)))
    }

    private nonisolated func handleButton(_ event: CGEvent, button: PointerButton,
                                          phase: ButtonPhase, at instant: HostInstant) {
        guard let converted = position(of: event, isButton: true) else { return }
        lock.withLock { _diagnostics.buttonEvents += 1 }
        emit(.button(ButtonEvent(instant: instant, position: converted.position,
                                 revision: converted.revision, button: button, phase: phase)))
    }

    /// **The one place a keystroke could leak, and it reads two integers.**
    ///
    /// `keyboardEventKeycode` is a hardware key position and
    /// `event.flags` is a modifier bitmask; neither is text, and this
    /// function never asks the event for its characters. What leaves here is
    /// `approvedShortcut`'s return value, which comes from the table in this
    /// file — so the identifier written to the log is a literal that exists
    /// in the source, and cannot be anything a person typed.
    private nonisolated func handleKeyDown(_ event: CGEvent, at instant: HostInstant) {
        lock.withLock { _diagnostics.keyDownsSeen += 1 }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let shortcut = Self.approvedShortcut(forKeyCode: keyCode, flags: event.flags) else {
            lock.withLock { _diagnostics.keyDownsRefused += 1 }
            return
        }
        lock.withLock { _diagnostics.keySamples += 1 }
        emit(.key(KeySample(instant: instant, shortcut: shortcut)))
    }

    private nonisolated func emitSecureInterval(from began: HostInstant, to ended: HostInstant,
                                                endedBy: SecureInputIntervalEnd) {
        // Clamped at zero rather than trusting the ordering: event timestamps
        // are the OS's, not this process's, and `HostRange` traps on a
        // negative duration. A trap here would kill the app over an
        // out-of-order pair of stamps, which is a far worse outcome than a
        // zero-width interval that still says "secure input was on".
        let duration = max(0, ended.hostTime.rawValue - began.hostTime.rawValue)
        let range = HostRange(epoch: epoch, start: began.hostTime, duration: Nanoseconds(duration))
        lock.withLock { _diagnostics.secureInputIntervals += 1 }
        emit(.secureInput(SecureInputInterval(interval: range, endedBy: endedBy)))
    }

    private nonisolated func emit(_ observation: Observation) {
        // The handler is read under the lock and called outside it: it is
        // caller code of unknown cost, and calling it while holding the lock
        // would let it deadlock this observer against its own `diagnostics`
        // accessor.
        let handler = lock.withLock { self.handler }
        handler?(observation)
    }

    // MARK: - The ambient reader

    /// The displays as they are attached **right now**, as a
    /// `DisplayArrangement` — the input `init` will not read for itself.
    ///
    /// Kept separate from everything above so that the conversion never
    /// depends on this machine's hardware, and so a fixture arrangement is
    /// the ordinary case in tests rather than a mock standing in for a real
    /// reader.
    ///
    /// **`scale` comes from the display mode, not `NSScreen`.**
    /// `CGDisplayMode.pixelWidth / .width` is native pixels over points for
    /// the mode actually in use, which is the definition `DisplayGeometry
    /// .scale` carries; going through `NSScreen.backingScaleFactor` would
    /// need a second lookup to match an `NSScreen` back to a
    /// `CGDirectDisplayID` and would pull AppKit into a file that otherwise
    /// needs none of it.
    ///
    /// A display that cannot be fully described is **dropped, not defaulted**
    /// — no mode, no persistent UUID, or a zero-width mode. A placeholder
    /// display in the arrangement would route points onto a display that does
    /// not exist; a missing one routes them nowhere, which
    /// `Diagnostics.unroutablePointerLocations` counts and reports.
    public nonisolated static func currentArrangement() -> DisplayArrangement {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return DisplayArrangement(placements: [])
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &ids, &displayCount) == .success else {
            return DisplayArrangement(placements: [])
        }

        var placements: [DisplayArrangement.Placement] = []
        for id in ids.prefix(Int(displayCount)) {
            // **Mirrors are skipped; the display being mirrored is kept.**
            //
            // `CGGetActiveDisplayList` returns every member of a *software*
            // mirror set, and members of a mirror set share a
            // `CGDisplayBounds` — so a laptop mirrored to a projector, which
            // is an ordinary configuration for a demo recorder, yields two
            // placements over one global rectangle with two different
            // `displayUUID`s and therefore two different `GeometryRevision`s.
            // `DisplayArrangement.route` returns the first match, so which
            // revision a `PointerSample` carries would be decided by the
            // order `CGGetActiveDisplayList` happened to return, silently.
            //
            // That is not a cosmetic wrong answer. `NormalizationContext
            // .denormalize` **preconditions** on revision equality, so a
            // sample stamped with the projector's revision reaching a
            // derivation built against the laptop's is a trap, not a number
            // that is slightly off.
            //
            // Skipping the mirror rather than folding the set to its primary
            // by hand: `CGDisplayMirrorsDisplay` already names the primary,
            // and that primary is in the active list too, so dropping the
            // mirrors leaves exactly one placement per distinct rectangle
            // with no reconstruction step to get wrong. It is also the one
            // that matches what is being captured — `CaptureSource` is built
            // from an `SCDisplay`/`CGMainDisplayID`, which is the mirrored-
            // from display, not its mirror.
            //
            // Hardware mirroring is invisible here (the window server
            // presents one display), so this branch is about the software
            // case only. **Not verified against real mirrored hardware** —
            // this machine has one display; see the task report's
            // could-not-verify table.
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
/// `CGEventTapCallBack` is a bare C function pointer: it captures nothing, so
/// it cannot be a method, and under this target's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` a closure literal written at
/// the call site is inferred `@MainActor` and will not convert to one. (The
/// same closure compiles fine in `spikes/2026-08-02-pairing-latency/main.swift`,
/// which is a top-level script built without that flag — the difference is the
/// build setting, not the API.) `nonisolated` is therefore explicit here for
/// the reason `CaptureSession` and `Minting` both document: unannotated, this
/// function is `@MainActor` and cannot be used as a C function pointer at all.
///
/// **Returns the event it was handed, unchanged, on every path** — including
/// the paths where the observer records nothing. `.listenOnly` already means
/// the return value is ignored, and returning `nil` from a listen-only tap
/// would still be a statement this file has no business making about someone
/// else's event stream.
private nonisolated func inputObserverTapCallback(proxy: CGEventTapProxy,
                                                  type: CGEventType,
                                                  event: CGEvent,
                                                  userInfo: UnsafeMutableRawPointer?)
    -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<InputObserver>.fromOpaque(userInfo).takeUnretainedValue()
            .handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
