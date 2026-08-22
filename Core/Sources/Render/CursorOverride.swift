import Foundation
import Timeline

/// A reviewer's permanent decision to draw no pointer over a range.
///
/// First-class and stored with the project, like every other override. It exists because the one
/// thing the automatic path cannot know is whether the real screen showed a cursor: macOS hides
/// the pointer while the user types, keyboard events are deliberately not captured, so "the user
/// is typing" is absent from this app's data by design. Spike E measured that the hidden state is
/// not readable — `NSCursor.currentSystem` is identical hidden and visible, and both CG
/// cursor-visibility functions are unavailable at the 26.0 floor.
public struct CursorOverride: Hashable, Sendable {
    /// **The boot session `start` is measured in — and the reason this field exists.**
    ///
    /// `start` is an instant in the ABSOLUTE host clock, the domain every observation record is
    /// stamped in and the domain `PointerTrack.position(at:)` is queried in. Nothing about a bare
    /// `Nanoseconds` says so. `HostInstant` and `HostRange` — this project's other two persisted
    /// time types — both carry their epoch for exactly this reason; this type was the one that
    /// did not, and a reviewer UI writing `CursorOverride(start: Nanoseconds(3_200_000_000), …)`
    /// (the shape every unit test writes) would be a silent recurrence of `1a98402`, where a
    /// composition-relative number was compared against an absolute-clock track and matched
    /// nothing, on every frame, for a whole phase.
    ///
    /// **Added while zero files exist.** This type is `Codable` and has no writer: no `.soredemo`
    /// package on disk carries an override. That is the only window in which adding this field is
    /// not a migration — after the first file is written, old overrides would be permanently
    /// ambiguous about which clock they meant, with no way to decide retroactively.
    ///
    /// **The deferred behaviour arrived 2026-08-12**: `PointerTrack.position(at:)` now takes a
    /// `HostInstant` and compares this epoch before the interval, so an override recorded against
    /// another boot session no longer suppresses by host-time coincidence
    /// (`anOverrideFromAnotherEpochDoesNotSuppress`). The field is still required on decode rather
    /// than defaulted precisely so it cannot be quietly omitted: a file without it fails to decode
    /// instead of inheriting whatever the reader assumes.
    public let epoch: BootEpoch
    public let start: Nanoseconds
    public let duration: Nanoseconds

    public init(epoch: BootEpoch, start: Nanoseconds, duration: Nanoseconds) {
        precondition(duration.rawValue >= 0,
                     "CursorOverride duration must be non-negative, got \(duration.rawValue)")
        self.epoch = epoch
        self.start = start
        self.duration = duration
    }

    public func contains(_ time: Nanoseconds) -> Bool {
        time.rawValue >= start.rawValue && time.rawValue < start.rawValue + duration.rawValue
    }
}

extension CursorOverride: Codable {
    /// Matches the synthesised shape exactly — `epoch`, `start`, `duration` — so this hand-written
    /// conformance changes validation, not the wire form. Same rule-8 reason as
    /// `BlindInterval.init(from:)` above.
    private enum CodingKeys: String, CodingKey {
        case epoch, start, duration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `decode`, not `decodeIfPresent`: see `epoch`'s own doc comment. A file that does not say
        // which clock its override is in is not a file this type can read.
        let epoch = try container.decode(BootEpoch.self, forKey: .epoch)
        let start = try container.decode(Nanoseconds.self, forKey: .start)
        let duration = try container.decode(Nanoseconds.self, forKey: .duration)
        guard duration.rawValue >= 0 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "CursorOverride duration must be non-negative, got \(duration.rawValue)"))
        }
        self.epoch = epoch
        self.start = start
        self.duration = duration
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(start, forKey: .start)
        try container.encode(duration, forKey: .duration)
    }
}
