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
/// **Two have appeared, in Task 10, and this is that paragraph saying so
/// rather than the claim quietly going stale.** Both are in
/// `Soredemo/Capture/AXObserver.swift` and neither converts an *event*
/// location:
///
///   * `AXObserver.normalizedFrame(globalTopLeftX:globalTopLeftY:width:height:in:)`
///     — the same four steps over an AX element's frame, which is a rectangle
///     and therefore anchors the Y flip on its **bottom** edge, a difference
///     `NormalizationContext.normalize`'s two overloads already carry and this
///     function cannot avoid having;
///   * `AXObserver.globalPoint(of:revision:in:)` — the **inverse** of
///     `normalizedPosition` below, needed because
///     `AXUIElementCopyElementAtPosition` takes a global point and a
///     `ButtonEvent` no longer has one.
///
/// So the accurate claim today is narrower and still worth something: a global
/// event location becomes a `NormalizedPoint` only here, and every conversion
/// in either direction is composed of the same three package primitives
/// (`DisplayArrangement.route`, `DisplayGeometry.pixels`/`points`,
/// `NormalizationContext`) rather than open-coded. What checks the pair is not
/// prose but `§ 8.1` of `scripts/cross-boundary-digest-probe.swift`, which
/// runs a point through this function and back through the inverse and
/// requires the original global coordinate, against a `scale: 2` fixture where
/// a dropped step changes the answer.
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

    /// One thing worth recording. A discriminated union rather than five
    /// callbacks, so a caller cannot wire up four of them and silently drop
    /// the fifth — which for `.secureInput` would restore exactly the
    /// silence that case exists to break, and for `.tapDisabled` would turn a
    /// blind window back into an unexplained gap in the pointer track.
    public enum Observation: Sendable, Equatable {
        case pointer(PointerSample)
        case button(ButtonEvent)
        case key(KeySample)
        /// Emitted when the interval **closes**, not when it opens: it is a
        /// range, and a range with no end is not yet a fact. `stop()` closes
        /// an open one with `.observationStopped` so a recording that ends
        /// mid-password still reports the interval rather than losing it.
        case secureInput(SecureInputInterval)
        /// A window during which the tap was switched off and this observer
        /// saw nothing — emitted at the moment it is re-enabled, which is the
        /// first moment its end is known.
        ///
        /// **A case in the union rather than a counter, for the reason the
        /// union exists.** A caller can wire up four of these and drop the
        /// fifth, but it cannot *fail to notice* the fifth the way it could
        /// fail to read a diagnostics field nobody prints. Unobserved time is
        /// the one thing a downstream producer must not infer from an absence
        /// of samples, which is exactly what a gap in the pointer track looks
        /// like (`ARCHITECTURE.md` D6a).
        case tapDisabled(TapDisabledInterval)
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
        /// Times the system disabled the tap and this observer re-armed it —
        /// **one per `TapDisabledInterval` emitted**, and the count is here
        /// only to pair with the sum below.
        ///
        /// A `.listenOnly` tap is still disabled if the callback is too slow.
        /// Left un-rearmed, everything afterwards is silence that looks
        /// exactly like a person who stopped moving.
        ///
        /// **It is disabled WITHOUT `kCGEventTapDisabledByTimeout` being
        /// delivered, and the budget is between 10 ms and 50 ms.** Measured:
        /// a deliberate stall in the callback, swept 10/50/100/200/400/800/
        /// 1600 ms, three seconds a rung, mouse moving throughout —
        ///
        /// | stall | notifications | `CGEvent.tapIsEnabled` |
        /// | --- | --- | --- |
        /// | 10 ms | 0 | enabled |
        /// | 50 ms and every rung above | 0 | **NOT enabled** |
        ///
        /// with a `.defaultTap` positive control in the same run receiving the
        /// notification at 400 ms, so the channel is real and it is this tap
        /// *kind* that never sees it. That is why `pollTapEnabled()` exists
        /// and why it, not the callback, is what populates these numbers. It
        /// is also why AX work does not belong on the callback thread: Spike
        /// A's hit-test is 21.25 ms at p90, inside the 10–50 ms band.
        ///
        /// **This used to be the whole record and that was the defect**
        /// (`ARCHITECTURE.md` D6a): a count says the loss happened N times and
        /// cannot say for how long, so 400 ms of lost pointer track and 4 ms
        /// of it read identically. The measurement is now
        /// `Observation.tapDisabled`, an interval per occurrence; this counter
        /// and `tapBlindNanos` are the run-level summary of those intervals,
        /// not a substitute for them.
        public internal(set) var tapDisabledIntervals = 0
        /// The **sum of the enclosing bounds** of every blind window, in
        /// nanoseconds — a quantity in the unit that was lost, which is what
        /// D6a's other four rows all have and this one did not.
        ///
        /// An over-estimate by construction: each interval contains the true
        /// window rather than being it (see `TapDisabledInterval`). Summed
        /// anyway, because the alternative summary is a count, and the safe
        /// direction for "how much of this recording is unobserved" is up.
        public internal(set) var tapBlindNanos: Int64 = 0
        /// Blind windows whose lower edge is `.observationStart` rather than a
        /// real event or a poll — the ones whose width is not a measurement of
        /// anything. Kept apart so `tapBlindNanos` can be read without one
        /// unbounded window silently dominating it.
        public internal(set) var tapDisabledIntervalsWithNoObservedLowerBound = 0
        /// Blind windows found by the **poll**, as opposed to by a
        /// notification. For this app's `.listenOnly` tap every one is
        /// expected to be found this way; see `TapDisableDetection`.
        public internal(set) var tapDisabledIntervalsFoundByPolling = 0

        /// **How many times anything actually looked**, and over how long.
        ///
        /// **Without this pair, `tapDisabledIntervals == 0` is not a
        /// measurement.** It has two readings — there were no blind windows,
        /// or nothing was ever checking — and they are the same zero. That is
        /// this project's oldest failure shape, and the version of this file
        /// that shipped an hour ago had it in a worse form than the count it
        /// replaced: an empty interval list looks more thoroughly checked than
        /// a zero count, while being fed by a channel that was measured never
        /// to deliver for this tap kind.
        ///
        /// Read them together, which `tapAccounting` prints:
        ///
        /// ```
        /// tap disabled windows : 0
        /// tap enabled polls    : 1247 over 124.7 s
        /// ```
        ///
        /// The first line alone says nothing. The second is what makes it a
        /// statement about the tap rather than about the observer.
        public internal(set) var tapEnabledPolls = 0
        /// First poll to last poll, in nanoseconds — the span the count above
        /// covers. A count with no span cannot distinguish 1247 polls over two
        /// minutes from 1247 polls in the first second before the timer died.
        public internal(set) var tapPollingSpanNanos: Int64 = 0
        /// Polls that could not read the tap at all (there was none to read).
        /// Counted rather than folded into `tapEnabledPolls`, because a poll
        /// that did not look is not evidence of looking.
        public internal(set) var tapPollsWithNoTap = 0

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

        /// The two numbers that only mean something together. Never print the
        /// first without the second.
        public var tapAccounting: String {
            let seconds = Double(tapPollingSpanNanos) / 1e9
            let blindMs = Double(tapBlindNanos) / 1e6
            var windows = "tap disabled windows : \(tapDisabledIntervals)"
                + " (\(tapDisabledIntervalsFoundByPolling) found by polling), "
                + String(format: "%.1f", blindMs) + " ms of enclosing blind window"
            if tapDisabledIntervalsWithNoObservedLowerBound > 0 {
                windows += "  (\(tapDisabledIntervalsWithNoObservedLowerBound) with no lower bound"
                    + " at all — those contribute no width to the total above)"
            }
            var polls = "tap enabled polls    : \(tapEnabledPolls) over "
                + String(format: "%.1f", seconds) + " s"
            if tapPollsWithNoTap > 0 { polls += "  (+\(tapPollsWithNoTap) with no tap to read)" }
            if tapEnabledPolls == 0 {
                polls += "  ← NOTHING WAS LOOKING; the line above is not a measurement"
            }
            return windows + "\n" + polls
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
    /// The poll's queue. **Never the main queue**, and created here rather
    /// than reached for at use so there is exactly one place to check that.
    private let pollQueue = DispatchQueue(label: "video.soredemo.input-observer.tap-poll",
                                          qos: .utility)
    private let arrangement: DisplayArrangement
    private let epoch: BootEpoch
    private let secureInputIsEnabled: @Sendable () -> Bool
    private let tapIsEnabledOverride: (@Sendable () -> Bool)?

    private nonisolated(unsafe) var _diagnostics = Diagnostics()
    private nonisolated(unsafe) var handler: (@Sendable (Observation) -> Void)?
    private nonisolated(unsafe) var tap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    /// The start of the open secure-input interval, if one is open.
    private nonisolated(unsafe) var secureInputBegan: HostInstant?
    /// The instant of the last event this observer saw — **any** event,
    /// including one suppressed by secure input, because what this records is
    /// that the tap was still delivering, not that anything was emitted.
    ///
    /// This is the lower edge of a blind window: the tap cannot have been
    /// disabled before the last event it delivered.
    private nonisolated(unsafe) var lastObservedInstant: HostInstant?
    /// When `start()` armed the tap — the only defensible lower bound for a
    /// blind window that opens before any event has arrived.
    private nonisolated(unsafe) var observationBegan: HostInstant?
    /// The most recent poll that read the tap as **enabled**.
    ///
    /// This is the lower bound that keeps working during a blind window.
    /// `lastObservedInstant` cannot: a disabled tap delivers no events, so it
    /// freezes at the disable and every extra second of silence widens the
    /// interval by a second of pure ignorance.
    private nonisolated(unsafe) var lastEnabledPollInstant: HostInstant?
    private nonisolated(unsafe) var firstPollInstant: HostInstant?
    /// The timer that does the polling, and the queue it runs on — **not** the
    /// main run loop. See `startPolling()`.
    private nonisolated(unsafe) var pollTimer: (any DispatchSourceTimer)?

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
    /// **`tapIsEnabledOverride` exists because the poll cannot otherwise be
    /// checked at all**, and it is `nil` — meaning "read the real tap" — in
    /// every shipping path.
    ///
    /// Reading the real one needs a `CFMachPort` from `CGEvent.tapCreate`,
    /// which needs Input Monitoring, which TCC grants to a signed bundle and
    /// not to `scripts/cross-boundary-digest-probe.swift`. Without the
    /// override the entire detection path — the thing this whole mechanism
    /// exists to be — would be reachable only by a human step, which is how a
    /// dead channel went unnoticed for two rounds of this task. Same argument,
    /// same shape, as `secureInputIsEnabled` above.
    ///
    /// It is an optional override rather than a defaulted closure because the
    /// real read needs `self`'s tap, which does not exist when the default
    /// argument is evaluated. `AppSourceAllowListTests` pins that
    /// `CGEvent.tapIsEnabled` is still named exactly once, in this file — the
    /// failure mode for an override is that the real read is deleted and
    /// everything stays green.
    public init(arrangement: DisplayArrangement, epoch: BootEpoch,
                secureInputIsEnabled: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() },
                tapIsEnabledOverride: (@Sendable () -> Bool)? = nil) {
        self.arrangement = arrangement
        self.epoch = epoch
        self.secureInputIsEnabled = secureInputIsEnabled
        self.tapIsEnabledOverride = tapIsEnabledOverride
    }

    deinit {
        // No lock: by the time `deinit` runs there is no other reference
        // through which a concurrent access could occur. Same reasoning as
        // `CaptureSession.deinit`. The timer holds `self` weakly, so it cannot
        // be what kept this object alive, but it must still be cancelled or it
        // keeps firing against a freed port.
        pollTimer?.cancel()
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
    /// disabled by the system (see `Observation.tapDisabled` and
    /// `Diagnostics.tapBlindNanos`).
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
            // Recorded before the tap is enabled, so it is a true lower bound
            // on any blind window: nothing can have been missed before the tap
            // existed.
            self.observationBegan = HostInstant(epoch: epoch, hostTime: Minting.hostNow())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        // After the tap exists, so the first poll has something to read.
        startPolling()
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
        // Before the port is cleared, so a poll cannot be mid-read when it is
        // invalidated. `cancel()` does not wait for an in-flight handler, but
        // that handler holds `lock` for the whole of its CoreGraphics work and
        // the clearing below takes the same lock.
        stopPolling()
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
            // `callbackInstant` is NOT the end of the blind window — the tap
            // is still off at this point. `reArmTap` takes the end reading
            // itself, after `CGEvent.tapEnable` has returned.
            reArmTap(disabledBy: type == .tapDisabledByTimeout ? .timeout : .userInput)
            return
        }

        guard let instant = instant(of: event, callbackInstant: callbackInstant) else { return }
        // Before the secure-input branch, deliberately: a suppressed event is
        // still proof the tap was delivering, and it is the tap's liveness
        // this records. Placing it after the branch would make a password
        // field look like a blind window.
        lock.withLock { lastObservedInstant = instant }

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

    /// Re-enables the tap and emits the blind window it closes.
    ///
    /// **The order is: re-arm first, measure second, emit third.** Re-arming
    /// is the only thing here that shortens the loss, so it happens before any
    /// bookkeeping; the end instant is read immediately after
    /// `CGEvent.tapEnable` returns, because that call *is* the end of the
    /// window; and the handler — caller code of unknown cost — runs last, so
    /// nothing it does is inside the interval it is being told about.
    ///
    /// A blind window with no lower bound at all is impossible: `start()`
    /// records `observationBegan` before enabling the tap, so the fallback is
    /// a real instant rather than a zero-width interval, which would read as
    /// "no time was lost" — the exact "measurement with a safe default" this
    /// project keeps being bitten by.
    // MARK: - The poll, and why there is one

    /// How often the tap's own enabled flag is read, in nanoseconds.
    ///
    /// **100 ms, and the consequence rather than the number is what matters.**
    /// This is not a D4 threshold — nothing rejects on it — it is a direct
    /// exchange of a negligible amount of CPU for the tightness of a blind
    /// window's lower edge. Two properties follow from it:
    ///
    ///   * a blind window is **detected** within one interval of starting, so
    ///     the tap is re-enabled ~100 ms after being switched off rather than
    ///     staying off for the rest of the recording;
    ///   * the window's lower edge is within ~100 ms of the truth **even when
    ///     no events are arriving**, which is exactly the situation a disabled
    ///     tap creates. `lastObservedInstant` cannot do this: it freezes at
    ///     the disable, so with only that bound a 30-second silence produces a
    ///     30-second "blind window" of which 29.9 seconds is ignorance.
    ///
    /// Tightening it is cheap and the only argument against is CPU; loosening
    /// it widens every recorded window by the same amount.
    private nonisolated static let pollIntervalNanos: Int64 = 100_000_000

    /// Starts the poll, on a **dedicated queue that is not the callback's**.
    ///
    /// **The thread matters more than the poll does.** What is being detected
    /// is the callback thread being stuck — the tap is disabled *because* the
    /// callback took too long — so a poll scheduled on the same run loop is
    /// blocked at exactly the moment it is needed, and is never blocked while
    /// anyone is testing it, because nothing is stuck then. That failure is
    /// invisible in every green run. `§ 7.9` of the probe holds the main
    /// thread for several poll intervals and asserts the count advanced
    /// anyway, which is the only form of this check that can fail.
    ///
    /// A `DispatchSourceTimer` on a private serial queue rather than a
    /// `Thread` with a sleep loop: the queue is not the main one by
    /// construction, and cancellation is a property of the source instead of a
    /// flag another thread has to notice.
    nonisolated func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + .nanoseconds(Int(Self.pollIntervalNanos)),
                       repeating: .nanoseconds(Int(Self.pollIntervalNanos)))
        timer.setEventHandler { [weak self] in self?.pollTapEnabled() }
        lock.withLock {
            pollTimer?.cancel()
            pollTimer = timer
        }
        timer.resume()
    }

    nonisolated func stopPolling() {
        let existing = lock.withLock { () -> (any DispatchSourceTimer)? in
            let value = pollTimer
            pollTimer = nil
            return value
        }
        existing?.cancel()
    }

    /// One poll. **The only place `CGEvent.tapIsEnabled` is read**, and the
    /// seam `§ 7.9` drives directly.
    ///
    /// Reads the flag, and if the tap has been switched off, switches it back
    /// on and closes the blind window it just found.
    ///
    /// **Everything CoreGraphics touches happens under the lock**, which is
    /// unusual in this file and is deliberate: `stop()` clears `tap` under the
    /// same lock and only invalidates the port afterwards, so holding it here
    /// is what makes "the port is still alive while this reads it" true rather
    /// than probable. Both calls are flag reads on a Mach port and do not
    /// block; the handler, which is caller code of unknown cost, is called
    /// outside.
    nonisolated func pollTapEnabled() {
        let now = HostInstant(epoch: epoch, hostTime: Minting.hostNow())

        let window: TapDisabledInterval? = lock.withLock {
            if firstPollInstant == nil { firstPollInstant = now }
            defer {
                if let first = firstPollInstant {
                    _diagnostics.tapPollingSpanNanos = now.hostTime.rawValue - first.hostTime.rawValue
                }
            }

            let enabled: Bool
            if let tapIsEnabledOverride {
                enabled = tapIsEnabledOverride()
            } else if let tap {
                enabled = CGEvent.tapIsEnabled(tap: tap)
            } else {
                // Nothing to read. NOT counted as a poll: a poll that did not
                // look is not evidence of looking, and this counter's whole
                // job is to say whether anything was.
                _diagnostics.tapPollsWithNoTap += 1
                return nil
            }

            _diagnostics.tapEnabledPolls += 1
            guard !enabled else {
                lastEnabledPollInstant = now
                return nil
            }

            // The tap is off. Re-enable it first — that is the only action
            // here that shortens the loss.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let reEnabled = Minting.hostNow()

            let (began, source) = lowerBoundLocked()
            guard let began else {
                // **No instant in this process's history bounds the window
                // from below**, so there is no interval to emit — a zero-width
                // one anchored at "now" would read as "no time was lost",
                // which is the safe-default failure this whole mechanism
                // exists to avoid. Counted in both totals instead, and
                // `tapAccounting` prints the second beside the first so the
                // outage is not invisible.
                //
                // Unreachable through `start()`, which records
                // `observationBegan` before the tap is enabled; reachable when
                // `pollTapEnabled()` is driven directly, which is what the
                // probe does.
                _diagnostics.tapDisabledIntervals += 1
                _diagnostics.tapDisabledIntervalsFoundByPolling += 1
                _diagnostics.tapDisabledIntervalsWithNoObservedLowerBound += 1
                return nil
            }
            let width = max(0, reEnabled.rawValue - began.hostTime.rawValue)
            _diagnostics.tapDisabledIntervals += 1
            _diagnostics.tapDisabledIntervalsFoundByPolling += 1
            _diagnostics.tapBlindNanos += width
            if source == .observationStart {
                _diagnostics.tapDisabledIntervalsWithNoObservedLowerBound += 1
            }
            lastEnabledPollInstant = HostInstant(epoch: epoch, hostTime: reEnabled)
            lastObservedInstant = HostInstant(epoch: epoch, hostTime: reEnabled)
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
    /// which of the three it came from. **Call under the lock.**
    ///
    /// `max` of the two live bounds rather than a fixed preference: which one
    /// is tighter depends on whether input was dense (the event wins) or the
    /// tap had been quiet (the poll wins), and picking one statically would
    /// throw away the better bound in half of all runs.
    private nonisolated func lowerBoundLocked() -> (HostInstant?, TapBlindWindowLowerBound) {
        let event = lastObservedInstant
        let poll = lastEnabledPollInstant
        switch (event, poll) {
        case let (event?, poll?):
            return event.hostTime.rawValue >= poll.hostTime.rawValue
                ? (event, .lastObservedEvent) : (poll, .lastEnabledPoll)
        case let (event?, nil):  return (event, .lastObservedEvent)
        case let (nil, poll?):   return (poll, .lastEnabledPoll)
        case (nil, nil):         return (observationBegan, .observationStart)
        }
    }

    /// **The tap's presence gates only the re-arming, not the recording.**
    /// An earlier version returned immediately when `tap == nil`, which made
    /// the entire blind-window path unreachable from `§ 7.9` of the probe —
    /// that check drives `handle(type:event:)` directly and never creates a
    /// tap, because creating one needs Input Monitoring. A gap that is
    /// recorded only in code no check can reach is the shape this whole
    /// register exists to avoid. It is also the more honest order: a disable
    /// event arriving *is* the evidence that a window happened, whether or not
    /// this observer still holds the port to re-enable.
    private nonisolated func reArmTap(disabledBy reason: TapDisableReason) {
        if let existing = lock.withLock({ tap }) {
            CGEvent.tapEnable(tap: existing, enable: true)
        }
        let reEnabled = Minting.hostNow()

        let (began, source) = lock.withLock { lowerBoundLocked() }
        guard let began else {
            // No event has ever been observed AND no tap was ever armed —
            // there is no instant in this process's history that bounds the
            // window from below, so there is no interval to report. Counted,
            // never emitted as a zero-width one: a zero-width interval reads
            // as "no time was lost", which is the safe-default failure this
            // whole register exists to avoid. Reachable only when `handle` is
            // driven directly, which is what the probe does.
            lock.withLock { _diagnostics.tapDisabledIntervals += 1 }
            return
        }
        // Clamped at zero for the reason `emitSecureInterval` documents:
        // `HostRange` traps on a negative duration, and an out-of-order pair
        // must not kill a recording in progress. Unlike that one, both
        // endpoints here are this process's own readings of one monotonic
        // clock, so the clamp is not expected to fire.
        let width = max(0, reEnabled.rawValue - began.hostTime.rawValue)
        let interval = HostRange(epoch: epoch, start: began.hostTime, duration: Nanoseconds(width))
        lock.withLock {
            _diagnostics.tapDisabledIntervals += 1
            _diagnostics.tapBlindNanos += width
            if source == .observationStart {
                _diagnostics.tapDisabledIntervalsWithNoObservedLowerBound += 1
            }
            // The window is closed; the next one starts from here, not from
            // the stale event that preceded this one.
            lastObservedInstant = HostInstant(epoch: epoch, hostTime: reEnabled)
        }
        emit(.tapDisabled(TapDisabledInterval(interval: interval, disabledBy: reason,
                                              lowerBoundFrom: source,
                                              detectedBy: .notification)))
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
