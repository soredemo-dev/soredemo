import Foundation

/// A half-open host-clock interval, stamped with its boot epoch. Replaces `TimeRange`
/// wherever a value crosses a session boundary.
public struct HostRange: Hashable, Sendable {
    public let epoch: BootEpoch
    public let start: Nanoseconds
    public let duration: Nanoseconds

    /// Traps if `duration` is negative.
    public init(epoch: BootEpoch, start: Nanoseconds, duration: Nanoseconds) {
        precondition(duration.rawValue >= 0, "a negative duration is not a range")
        self.epoch = epoch
        self.start = start
        self.duration = duration
    }

    public var end: Nanoseconds { start + duration }

    /// Whether this range and `instant` share an epoch. Separate from `contains` so a
    /// caller can ask why a containment test failed instead of inferring it.
    public func isComparable(with instant: HostInstant) -> Bool { instant.epoch == epoch }

    /// Whether `instant` falls in this range. Returns `false` for an instant from
    /// another epoch rather than trapping as `HostInstant.<` does: asking across
    /// epochs is legitimate when a project holds several recordings. A caller needing
    /// to distinguish the two `false` cases should call `isComparable(with:)`.
    public func contains(_ instant: HostInstant) -> Bool {
        guard isComparable(with: instant) else { return false }
        return instant.hostTime >= start && instant.hostTime < end
    }
}

extension HostRange: Codable {
    /// Matches the synthesised shape exactly, so this hand-written conformance
    /// changes validation, not the wire form.
    private enum CodingKeys: String, CodingKey {
        case epoch, start, duration
    }

    /// Untrusted input: validates `duration >= 0` and throws
    /// `DecodingError.dataCorrupted` rather than trapping.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let epoch = try container.decode(BootEpoch.self, forKey: .epoch)
        let start = try container.decode(Nanoseconds.self, forKey: .start)
        let duration = try container.decode(Nanoseconds.self, forKey: .duration)
        guard duration.rawValue >= 0 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "HostRange duration must be non-negative, got \(duration.rawValue)"))
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
