import Foundation
import Geometry
import Timeline

/// One line of an observation log. `epochs` is why this protocol exists: an
/// `ObservationLog` is keyed on one `BootEpoch`, so its writer must be able to
/// ask any record, without knowing its type, which epochs its instants carry.
/// `kind` matches the stored property every record already has; no wire key is
/// added by conforming.
public protocol ObservationRecord: Codable, Sendable {
    /// The `kind` discriminator this record writes, read back by
    /// `ObservationLog.kind(of:)` without decoding the record.
    var kind: String { get }

    /// Every boot epoch any instant in this record is stamped with, in field
    /// declaration order. Never empty — `ObservationLog.checkEpoch(of:against:)`
    /// treats an empty list as a fault. A conforming type must list every
    /// epoch-bearing field; nothing checks that it has.
    var epochs: [BootEpoch] { get }
}

/// A pointer position sample. The whole track is kept, never thinned: the
/// required density depends on render tuning, and a thinned track cannot be
/// re-tuned.
/// The cursor's SHAPE at a sample, as the classified identity of the system cursor —
/// never its image. Recorded since the recorder-parity decision (2026-08-19): before it,
/// every pointer drew as an arrow, and an I-beam over a text field was a lie the render
/// told about the recording.
///
/// `String`-raw and `Codable` because it is persisted per sample; a new case is additive.
/// `.other` is a REAL classification — "the system cursor was something this enum does not
/// name" — distinct from `nil` on the sample, which means "no reader was injected or the
/// recording predates the field". The renderer treats both as the arrow; the review UI can
/// tell them apart, which is the reason they are not one value.
public enum PointerShape: String, Codable, Sendable {
    case arrow, iBeam, pointingHand, crosshair
    case resizeLeftRight, resizeUpDown
    case other
}

public struct PointerSample: Hashable, Codable, Sendable {
    public let kind: String
    public let instant: HostInstant
    public let position: NormalizedPoint
    public let revision: GeometryRevision
    /// `nil` means unrecorded — an older log, or no shape reader injected — which is a
    /// different fact from `.other` (recorded, and not a shape this schema names).
    /// Optional so every schema-2 line ever written decodes unchanged: absence here is
    /// honest history, not the ambiguity `CursorOverride.epoch` refused to allow.
    public let shape: PointerShape?

    public init(instant: HostInstant, position: NormalizedPoint, revision: GeometryRevision,
                shape: PointerShape? = nil) {
        self.kind = "pointer"
        self.instant = instant
        self.position = position
        self.revision = revision
        self.shape = shape
    }
}

public enum PointerButton: String, Codable, Sendable { case left, right, other }
public enum ButtonPhase: String, Codable, Sendable { case down, up }

/// A mouse button transition; the AX chain recorded against the same instant is
/// its object half.
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

/// A keystroke, already filtered to approved shortcuts by the observer; the
/// package never sees an unfiltered keystroke, so there is nothing to redact.
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

/// Why a `SecureInputInterval` closed. `.secureInputDisabled` makes the interval
/// a measurement; `.observationStopped` makes its end when observing stopped, not
/// when secure input did, so the interval is only a lower bound.
public enum SecureInputIntervalEnd: String, Codable, Sendable {
    case secureInputDisabled
    case observationStopped
}

/// An interval during which `IsSecureEventInputEnabled()` was true and the
/// observer emitted nothing at all, marking the gap so a derivation cannot
/// mistake it for stillness. `interval` is always contained within the true one:
/// `start` is the first observed instant inside it, not when secure input began.
public struct SecureInputInterval: Hashable, Codable, Sendable {
    public let kind: String
    /// Half-open, epoch-stamped. `HostRange` already refuses a negative duration,
    /// so this type adds no ordering precondition of its own.
    public let interval: HostRange
    public let endedBy: SecureInputIntervalEnd

    public init(interval: HostRange, endedBy: SecureInputIntervalEnd) {
        self.kind = "secureInput"
        self.interval = interval
        self.endedBy = endedBy
    }
}

/// Why the system switched the tap off, when that is knowable at all.
/// `.timeout` means this app's callback took too long; `.userInput` means the
/// system disabled the tap on a user action and nothing the observer does
/// changes it.
public enum TapDisableReason: String, Codable, Sendable {
    case timeout
    case userInput
}
// `TapDisabledInterval.disabledBy` is optional because the reason arrives only
// on the notification, which a `.listenOnly` tap never receives. A poll sees
// that the tap is off but never why, and must not default to `.timeout`.

/// How the lower edge of a `TapDisabledInterval` was derived; the three differ by
/// orders of magnitude in tightness. `.lastEnabledPoll` is the most recent poll
/// reading the tap enabled, `.lastObservedEvent` the last event seen, and
/// `.observationStart` means nothing was observed or polled — not a measurement.
public enum TapBlindWindowLowerBound: String, Codable, Sendable {
    case lastEnabledPoll
    case lastObservedEvent
    case observationStart
}

/// Which channel noticed that the tap had been switched off. A `.listenOnly` tap
/// is disabled without `kCGEventTapDisabledByTimeout` ever reaching its callback,
/// so `.enabledPoll` is the expected value here, not a fallback; `.notification`
/// is retained for `.tapDisabledByUserInput` and for other tap kinds.
public enum TapDisableDetection: String, Codable, Sendable {
    case notification
    case enabledPoll
}

/// An interval that encloses — never sits inside, unlike `SecureInputInterval` —
/// a window during which the event tap was off and this observer saw nothing.
/// Read it as "the gap is somewhere in here", with `lowerBoundFrom` saying how
/// much to trust its left edge. An empty list of these says nothing on its own.
public struct TapDisabledInterval: Hashable, Codable, Sendable {
    public let kind: String
    public let interval: HostRange
    /// `nil` when the window was found by polling, which cannot know why — never
    /// defaulted to `.timeout`.
    public let disabledBy: TapDisableReason?
    public let lowerBoundFrom: TapBlindWindowLowerBound
    /// Which channel noticed; expected to be `.enabledPoll` every time for this
    /// app's `.listenOnly` tap.
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
// One extension per type, each stating only `epochs`; `kind` is already stored.
// Nothing enforces that these stay complete: adding an instant-bearing field to
// an existing type still compiles, encodes and decodes with `epochs` silently
// omitting it. When you add such a field, add it below.

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
