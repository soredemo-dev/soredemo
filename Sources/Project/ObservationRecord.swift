import Foundation
import Geometry
import Timeline

/// One line of an observation log.
///
/// **`epochs` is the whole reason this protocol exists.** `ObservationLog` is
/// keyed on a single `BootEpoch` (see `ObservationLogHeader.epoch`), and the
/// only way a writer can refuse a record from another boot session is to be
/// able to ask a record, without knowing its type, which epochs its instants
/// carry. Every record type answers with **every** epoch it holds, not just
/// the one on its primary instant: `AXChainRecord` alone carries the click's
/// epoch, the hit-test interval's, and one per element read interval, and a
/// record whose hit-test straddles a reboot is exactly the record whose
/// `clickToHitTestAnswerNanos` silently returns `nil` forever afterwards.
///
/// `kind` is a `get` requirement matching the stored property every record
/// already has — it is not a new field, and no record gains a wire key from
/// conforming.
public protocol ObservationRecord: Codable, Sendable {
    /// The `kind` discriminator this record writes, and the one
    /// `ObservationLog.kind(of:)` reads back without decoding the record.
    var kind: String { get }

    /// Every boot epoch any instant in this record is stamped with, in the
    /// order the fields are declared. **Never empty**: a record with no
    /// instant at all cannot be placed on the log's clock, and
    /// `ObservationLog.checkEpoch(of:against:)` reports that as a fault
    /// rather than vacuously accepting it.
    var epochs: [BootEpoch] { get }
}

/// A pointer position sample. The whole track is kept, never thinned — how
/// dense is dense enough is a property of `cursor-render`'s spring, which will
/// be tuned, and a thinned track cannot be re-tuned (D2-7).
public struct PointerSample: Hashable, Codable, Sendable {
    public let kind: String
    public let instant: HostInstant
    public let position: NormalizedPoint
    public let revision: GeometryRevision

    public init(instant: HostInstant, position: NormalizedPoint, revision: GeometryRevision) {
        self.kind = "pointer"
        self.instant = instant
        self.position = position
        self.revision = revision
    }
}

public enum PointerButton: String, Codable, Sendable { case left, right, other }
public enum ButtonPhase: String, Codable, Sendable { case down, up }

/// A mouse button transition. The verb half of "click the Save button" — the
/// object half is the AX chain recorded against the same instant (D2-1).
public struct ButtonEvent: Hashable, Codable, Sendable {
    public let kind: String
    public let instant: HostInstant
    public let position: NormalizedPoint
    public let revision: GeometryRevision
    public let button: PointerButton
    public let phase: ButtonPhase

    public init(instant: HostInstant, position: NormalizedPoint, revision: GeometryRevision,
                button: PointerButton, phase: ButtonPhase) {
        self.kind = "button"
        self.instant = instant
        self.position = position
        self.revision = revision
        self.button = button
        self.phase = phase
    }
}

/// A keystroke, already filtered to approved shortcuts by the observer — the
/// package never sees an unfiltered keystroke, so there is nothing here to
/// redact later.
public struct KeySample: Hashable, Codable, Sendable {
    public let kind: String
    public let instant: HostInstant
    public let shortcut: String

    public init(instant: HostInstant, shortcut: String) {
        self.kind = "key"
        self.instant = instant
        self.shortcut = shortcut
    }
}

/// Why a `SecureInputInterval` closed.
///
/// Two ways, not one, and they are not the same fact. `.secureInputDisabled`
/// means the observer saw secure input turn off and the interval is a
/// measurement. `.observationStopped` means the recording ended while it was
/// still on, so the end instant is when *observing* stopped, not when secure
/// input did — the interval is a lower bound and nothing knows how much
/// longer it ran. Collapsing the two would put a bound and a measurement in
/// the same field with nothing to tell them apart, which is the shape
/// `SegmentBoundary` already refuses one layer up.
public enum SecureInputIntervalEnd: String, Codable, Sendable {
    case secureInputDisabled
    case observationStopped
}

/// An interval during which `IsSecureEventInputEnabled()` was true and the
/// observer emitted **nothing at all** — not a redacted sample, not a
/// placeholder.
///
/// This record exists because emitting nothing is indistinguishable from
/// nothing having happened. A five-second gap in the pointer track is
/// produced by a person typing a password *and* by a person not touching the
/// mouse, and a derivation that cannot tell those apart will happily invent
/// motion across the first one.
///
/// **`interval` is a lower bound on the true one, always.** The observer
/// learns that secure input is on by asking while handling an event, so
/// `interval.start` is the first *observed* instant inside it, not the moment
/// the password field took focus; the same applies at the far end when the
/// end reason is `.observationStopped`. That is D2-2a's stance — an interval
/// whose width is the uncertainty — rather than a single instant that would
/// claim a precision nothing measured. A caller must not read this as
/// "secure input began at exactly `start`".
public struct SecureInputInterval: Hashable, Codable, Sendable {
    public let kind: String
    /// Half-open, epoch-stamped. `HostRange` already refuses a negative
    /// duration, so this type adds no ordering precondition of its own.
    public let interval: HostRange
    public let endedBy: SecureInputIntervalEnd

    public init(interval: HostRange, endedBy: SecureInputIntervalEnd) {
        self.kind = "secureInput"
        self.interval = interval
        self.endedBy = endedBy
    }
}

/// Why the system switched the tap off, **when that is knowable at all**.
/// Two causes with two different diagnoses, and collapsing them would hide
/// which.
///
/// `.timeout` is **this app's own fault**: the callback took too long, and
/// `ax-observation` is what makes that possible — a hit-test into a busy
/// application is a synchronous IPC on the callback thread, and F2-2 measured
/// one at 125.47 ms. A run with these in it is a run whose observation cost
/// has to come down.
///
/// `.userInput` is not ours: the system disables taps on some user actions
/// (the secure-input path among them). Nothing about the observer changes it,
/// and reading it as "we were too slow" would send the next person to optimise
/// code that was never the problem.
public enum TapDisableReason: String, Codable, Sendable {
    case timeout
    case userInput
}
// **`TapDisabledInterval.disabledBy` is optional, and that is this measurement
// made structural.** The reason arrives only on the notification, and the
// notification is exactly what a `.listenOnly` tap never receives. A poll can
// see that the tap is off; nothing tells it why. Defaulting that to `.timeout`
// would be an accusation — "this app's callback was too slow" — minted by a
// code path that measured nothing, in the one field a reader uses to decide
// whether to go and optimise something.

/// How the **lower** edge of a `TapDisabledInterval` was derived. The three
/// possibilities differ by orders of magnitude in tightness, and which one
/// applies is not a detail: it is how much of the interval's width is the gap
/// and how much is ignorance.
///
/// `.lastEnabledPoll` — the most recent poll that read the tap as *enabled*.
/// This is normally the tightest, and it is the one that matters, because of
/// what a disabled tap does to the alternative: **no events arrive while the
/// tap is off**, so `lastObservedEvent` freezes at the moment of the disable
/// and stops improving. The poll keeps ticking regardless, so its own
/// timestamps are what bound the window from below during exactly the period
/// nothing else can.
///
/// `.lastObservedEvent` — the last event the observer saw. Tighter than the
/// poll when input is dense and the disable happened between two polls.
///
/// `.observationStart` — nothing had been observed and nothing had been
/// polled, so the only defensible lower bound is the moment observing began.
/// The interval is then as wide as the run so far, and a consumer must treat
/// it as "we do not know", not as a measurement.
public enum TapBlindWindowLowerBound: String, Codable, Sendable {
    case lastEnabledPoll
    case lastObservedEvent
    case observationStart
}

/// Which channel noticed that the tap had been switched off.
///
/// **Two channels because one of them does not work for the tap this app
/// creates, and that was measured rather than assumed.** A `.listenOnly` tap
/// is disabled by the system **without `kCGEventTapDisabledByTimeout` ever
/// being delivered to its callback**. Swept with a deliberate stall in the
/// callback — 10, 50, 100, 200, 400, 800, 1600 ms, three seconds a rung, mouse
/// moving throughout — the notification count was **0 at every rung**, while
/// `CGEvent.tapIsEnabled(tap:)` read `false` from 50 ms upward. A `.defaultTap`
/// positive control in the same run received the notification at 400 ms, so
/// the channel itself is real; it is the tap *kind* that never sees it.
///
/// **What that sweep is not.** It stalled on every `mouseMoved`, at 60–120 Hz,
/// so the rungs where the flag read false are *sustained overload* and not a
/// per-callback budget — a later run stalling 125 ms on clicks alone, 18
/// stalls over 30 s, left the tap enabled. The dead-notification finding above is
/// unaffected (it held at every rung, disabled or not); only the threshold
/// reading of the same table was wrong, and it is corrected at length in
/// `Soredemo/Capture/AXObserver.swift`'s header.
///
/// So `.notification` is retained and is not dead code — `.tapDisabledByUserInput`
/// may still arrive, and other tap kinds get both — but `.enabledPoll` is what
/// actually catches the case this app is exposed to. A recording whose blind
/// windows are all `.enabledPoll` is the expected shape, not a fallback.
public enum TapDisableDetection: String, Codable, Sendable {
    case notification
    case enabledPoll
}

/// An interval that **contains** a window during which the event tap was
/// switched off and this observer therefore saw nothing (`ARCHITECTURE.md`
/// D6a).
///
/// **This replaced a count, and the replacement is the whole point.** A count
/// says the loss happened N times and cannot say for how long: a recording
/// that lost 400 ms of pointer track read identically to one that lost 4 ms,
/// and `framing-gates`' `observation stale` refusal — "this beat spans a gap
/// in the pointer record" — had nothing to test against. The number of lost
/// events is genuinely unknowable, because nothing counts what never arrived.
/// The lost *time range* is not, and the time range is what the consumer
/// needs.
///
/// **An enclosing bound, not the window itself, and the direction is the
/// opposite of `SecureInputInterval`'s.** That type's interval is contained
/// *within* the true one (its start is the first observed instant *inside*
/// it). This one contains the true one: the instant the system disabled the
/// tap is not reported to anybody, so the earliest moment it could have
/// happened is just after the last event that did arrive. So:
///
/// ```
///        │← true blind window →│
/// ───────┼─────────────────────┼──────
///   last event observed    tap re-enabled
///        │←   this interval   →│
/// ```
///
/// A consumer must read `interval` as *"the gap is somewhere in here"*, and
/// `lowerBoundFrom` as how much to trust its left edge. Reading it as the gap
/// itself over-states the loss, which for a refusal code is the safe
/// direction — but it is still not what was measured, and this comment is
/// where that is said.
/// **An empty list of these means nothing on its own.** Whether any window
/// happened and whether anything was looking are different questions, and
/// `InputObserver.Diagnostics.tapEnabledPolls` is the answer to the second —
/// see `tapAccounting`. This type deliberately has no "and we checked N times"
/// field: that is a property of the run, not of a window, and putting it here
/// would make it absent from precisely the run that recorded no windows.
public struct TapDisabledInterval: Hashable, Codable, Sendable {
    public let kind: String
    public let interval: HostRange
    /// `nil` when the window was found by polling, which cannot know why —
    /// never defaulted to `.timeout`. See the note above `TapDisableReason`.
    public let disabledBy: TapDisableReason?
    public let lowerBoundFrom: TapBlindWindowLowerBound
    /// Which channel noticed. For this app's `.listenOnly` tap this is
    /// expected to be `.enabledPoll` every time; see `TapDisableDetection`.
    public let detectedBy: TapDisableDetection

    public init(interval: HostRange, disabledBy: TapDisableReason?,
                lowerBoundFrom: TapBlindWindowLowerBound,
                detectedBy: TapDisableDetection) {
        self.kind = "tapDisabled"
        self.interval = interval
        self.disabledBy = disabledBy
        self.lowerBoundFrom = lowerBoundFrom
        self.detectedBy = detectedBy
    }
}

// MARK: - `ObservationRecord` conformances
//
// One extension per type, each stating only `epochs` — `kind` is already a
// stored property on every one of them. Written out per type rather than
// derived, because "which instants does this record hold" is a fact about the
// type's fields and a new field carrying a new instant must show up here as a
// compile-time edit rather than being silently missed by a reflection walk.

extension PointerSample: ObservationRecord {
    public var epochs: [BootEpoch] { [instant.epoch] }
}

extension ButtonEvent: ObservationRecord {
    public var epochs: [BootEpoch] { [instant.epoch] }
}

extension KeySample: ObservationRecord {
    public var epochs: [BootEpoch] { [instant.epoch] }
}

extension SecureInputInterval: ObservationRecord {
    public var epochs: [BootEpoch] { [interval.epoch] }
}

extension TapDisabledInterval: ObservationRecord {
    public var epochs: [BootEpoch] { [interval.epoch] }
}
