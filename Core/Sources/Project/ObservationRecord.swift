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
    /// Where inside the cursor's own image the pointer actually is, 0…1 of the image, or
    /// `nil` when unrecorded. **This is what makes a drawn cursor land where the user
    /// pointed.** Measured on this machine: the arrow's hotspot is its tip, but the
    /// crosshair's is (0.458, 0.458) and the live cursor sampled while writing this was
    /// (0.522, 0.500) — its centre. Art drawn with its own path origin at the recorded
    /// position is correct only when that origin IS the hotspot, and for anything but the
    /// arrow it is not. Optional for the same reason `shape` is: every line already written
    /// decodes unchanged.
    public let hotspot: NormalizedPoint?
    /// `nil` means unrecorded — an older log, or no shape reader injected — which is a
    /// different fact from `.other` (recorded, and not a shape this schema names).
    /// Optional so every schema-2 line ever written decodes unchanged: absence here is
    /// honest history, not the ambiguity `CursorOverride.epoch` refused to allow.
    public let shape: PointerShape?

    public init(instant: HostInstant, position: NormalizedPoint, revision: GeometryRevision,
                shape: PointerShape? = nil, hotspot: NormalizedPoint? = nil) {
        self.kind = "pointer"
        self.instant = instant
        self.position = position
        self.revision = revision
        self.shape = shape
        self.hotspot = hotspot
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

/// Why a `StillInterval` closed. `.thePictureChanged` makes the interval a
/// measurement — the complete frame that ended it is its exact right edge.
/// `.theSegmentEnded` puts the segment's end there instead of stillness's, so
/// the interval is a lower bound, the same distinction `SecureInputInterval`
/// draws with `.observationStopped`.
public enum StillIntervalEnd: String, Codable, Sendable {
    case thePictureChanged
    case theSegmentEnded
}

/// A stretch during which ScreenCaptureKit drew nothing: every callback inside
/// it carried `SCFrameStatus.idle`.
///
/// **This is the compositor's own statement, not an inference from pixels.**
/// Measured on this machine: a completely static window produced 1 complete
/// frame and 1210 idle ones over twenty seconds, and every one of those idle
/// callbacks arrived with **no image buffer at all** — there was nothing to
/// compare, because nothing was drawn. A screen that was changing produced
/// roughly thirty complete frames a second over the same span. Recording where
/// the idle stretches were costs nothing, because the status is already read on
/// every callback; deriving the same answer afterwards costs a decode of the
/// whole recording.
///
/// It is deliberately the conservative signal of the two. A one-pixel change
/// redraws the frame, so ScreenCaptureKit reports `.complete` where a pixel
/// threshold would still call the picture still. The disagreement therefore
/// falls on the side of *not* cutting something that moved, never on cutting
/// something that did.
///
/// `idleFrames` is recorded because a range alone cannot tell stillness from a
/// stalled stream. Ten seconds spanned by six hundred idle callbacks is a still
/// picture; ten seconds spanned by two is a stream that stopped delivering, and
/// a cut across the second is a cut across footage nobody looked at.
public struct StillInterval: Hashable, Codable, Sendable {
    /// Stretches shorter than this are not recorded. `StillnessReader` measures
    /// the picture in slices of this length, so anything below it is a stretch
    /// neither signal can resolve — recording it would be recording noise, and
    /// on a busy screen there are hundreds of them a minute.
    public static let shortestWorthRecording = Nanoseconds(250_000_000)

    public let kind: String
    /// Half-open and epoch-stamped, from the first idle callback of the run to
    /// the callback that ended it. Both edges are callback instants rather than
    /// presentation timestamps: an idle callback carries no frame, so it has no
    /// presentation timestamp worth the name.
    public let interval: HostRange
    public let endedBy: StillIntervalEnd
    /// How many idle callbacks the run covered. Never zero — a run with no
    /// callbacks in it is not a run.
    public let idleFrames: Int

    /// Traps on a run of no callbacks; untrusted input goes through
    /// `init(from:)` instead, which refuses rather than trapping. Same split as
    /// `GapWatch`.
    public init(interval: HostRange, endedBy: StillIntervalEnd, idleFrames: Int) {
        precondition(idleFrames > 0, "a still interval with no idle callbacks is not a measurement")
        self.kind = "still"
        self.interval = interval
        self.endedBy = endedBy
        self.idleFrames = idleFrames
    }

    private enum CodingKeys: String, CodingKey { case kind, interval, endedBy, idleFrames }

    /// Rule 8: the synthesised decode would accept `idleFrames: 0` and a `kind`
    /// naming some other record, and both would then travel as if a producer had
    /// vouched for them.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard kind == "still" else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "a StillInterval must carry kind \"still\", found \"\(kind)\"")
        }
        let idleFrames = try container.decode(Int.self, forKey: .idleFrames)
        guard idleFrames > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .idleFrames, in: container,
                debugDescription: "a still interval with no idle callbacks is not a measurement")
        }
        self.kind = kind
        self.interval = try container.decode(HostRange.self, forKey: .interval)
        self.endedBy = try container.decode(StillIntervalEnd.self, forKey: .endedBy)
        self.idleFrames = idleFrames
    }
}

/// Where the source drew inside the capture buffer, from the instant it started drawing there.
///
/// **The record that makes a window resized mid-recording survivable.** The stream's buffer is
/// fixed for the whole segment and deliberately so — Apple's own guidance is that changing a
/// stream's output dimension "frequently ... can lead to additional memory allocation and
/// therefore not recommended" — so when the window is resized, ScreenCaptureKit fits the new
/// content into the old buffer and leaves the remainder as background. That remainder is the
/// black band down the right or along the bottom of a recording nobody asked for, and the only
/// thing that can remove it afterwards is knowing where the content was. It is knowable ONLY at
/// capture time: the attachment does not survive into the master, and no amount of looking at
/// the pixels afterwards can tell a black band from a black window.
///
/// **Written on change, never per frame.** The attachment arrives on every complete frame and
/// is identical on almost all of them; see `CropRect.differs(from:byHalfAPixelIn:bufferHeight:)`
/// for the tolerance and why exact comparison would not do.
///
/// `contentScale` is the fit factor the stream applied, and it is here to state a cost rather
/// than to be used in the crop: above 1 the window shrank and its pixels were magnified into
/// the buffer, below 1 the window grew past the buffer and was downsampled to fit. Cropping
/// restores the FRAMING either way. It cannot restore resolution that was never written, and
/// this field is the only place a reader can find out that some was lost.
public struct ContentCropSample: Hashable, Codable, Sendable {
    public let kind: String
    public let instant: HostInstant
    /// The fraction of the buffer the source drew into — `.whole` when it filled it.
    public let content: CropRect
    /// Strictly positive; never defaulted to 1, because "the stream did not say" and "the
    /// stream said it applied no scaling" are different facts.
    public let contentScale: Double

    /// Traps on a scale that is not a measurement; untrusted input goes through `init(from:)`,
    /// which refuses instead. Same split as `StillInterval`.
    public init(instant: HostInstant, content: CropRect, contentScale: Double) {
        precondition(contentScale.isFinite && contentScale > 0,
                     "a content scale of \(contentScale) is not a measurement")
        self.kind = "contentCrop"
        self.instant = instant
        self.content = content
        self.contentScale = contentScale
    }

    private enum CodingKeys: String, CodingKey { case kind, instant, content, contentScale }

    /// Rule 8. The synthesised decode would accept a zero or infinite scale and a `kind` naming
    /// some other record, and both would then travel as if a producer had vouched for them.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard kind == "contentCrop" else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "a ContentCropSample must carry kind \"contentCrop\", found \"\(kind)\"")
        }
        let scale = try container.decode(Double.self, forKey: .contentScale)
        guard scale.isFinite, scale > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .contentScale, in: container,
                debugDescription: "a content scale of \(scale) is not a measurement")
        }
        self.kind = kind
        self.instant = try container.decode(HostInstant.self, forKey: .instant)
        self.content = try container.decode(CropRect.self, forKey: .content)
        self.contentScale = scale
    }
}

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

extension StillInterval: ObservationRecord {
    public var epochs: [BootEpoch] { [interval.epoch] }
}

extension ContentCropSample: ObservationRecord {
    public var epochs: [BootEpoch] { [instant.epoch] }
}

/// A person pressed "mark a chapter" during the take, at this instant.
///
/// **An observation, not an edit.** The moment is the person's, and it is kept where every other
/// moment of the take is kept, so a recording reopened without its project still has it. What the
/// editor makes of it — a chapter numbered in order — is derived, once, when a recording with no
/// saved edit is opened. See `docs/design/2026-09-28-notch-marks-and-audio-warnings.md`.
public struct ChapterMark: Hashable, Codable, Sendable {
    public let kind: String
    public let instant: HostInstant

    public init(instant: HostInstant) {
        self.kind = "mark"
        self.instant = instant
    }

    private enum CodingKeys: String, CodingKey { case kind, instant }

    /// Refuses a line wearing another record's `kind`, for `StillInterval`'s reason.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard kind == "mark" else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "a ChapterMark must carry kind \"mark\", found \"\(kind)\"")
        }
        self.kind = kind
        self.instant = try container.decode(HostInstant.self, forKey: .instant)
    }
}

extension ChapterMark: ObservationRecord {
    public var epochs: [BootEpoch] { [instant.epoch] }
}

/// Reads the chapter marks back out of a package's observation logs.
public enum ChapterMarkReader {
    /// Every mark in every log, oldest first. Sorted on the way out for
    /// `FramingPlanReader.pointerSamples`' reason: the logs are read in the order given, and a
    /// consumer numbering chapters from an unsorted list numbers them wrong.
    public static func marks(fromObservationLogsAt urls: [URL]) throws -> [ChapterMark] {
        var marks: [ChapterMark] = []
        for url in urls {
            for line in try JSONLReader.linesOfFile(at: url).lines
            where try ObservationLog.kind(of: line) == "mark" {
                marks.append(try ObservationLog.decode(line) as ChapterMark)
            }
        }
        return marks.sorted { $0.instant.hostTime.rawValue < $1.instant.hostTime.rawValue }
    }
}
