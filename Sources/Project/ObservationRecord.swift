import Foundation
import Geometry
import Timeline

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

/// Why the system switched the tap off. Two causes with two different
/// diagnoses, and collapsing them would hide which.
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

/// How the **lower** edge of a `TapDisabledInterval` was derived, because the
/// two possibilities differ by orders of magnitude in tightness.
///
/// `.lastObservedEvent` — the last event the observer saw before the silence.
/// With a moving pointer that is within a frame or two of the true disable.
/// `.observationStart` — no event had been observed at all, so the only
/// defensible lower bound is the moment observing began. The interval is then
/// as wide as the run so far, and a consumer must treat it as "we do not
/// know", not as a measurement.
public enum TapBlindWindowLowerBound: String, Codable, Sendable {
    case lastObservedEvent
    case observationStart
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
public struct TapDisabledInterval: Hashable, Codable, Sendable {
    public let kind: String
    public let interval: HostRange
    public let disabledBy: TapDisableReason
    public let lowerBoundFrom: TapBlindWindowLowerBound

    public init(interval: HostRange, disabledBy: TapDisableReason,
                lowerBoundFrom: TapBlindWindowLowerBound) {
        self.kind = "tapDisabled"
        self.interval = interval
        self.disabledBy = disabledBy
        self.lowerBoundFrom = lowerBoundFrom
    }
}
