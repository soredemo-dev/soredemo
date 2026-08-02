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
