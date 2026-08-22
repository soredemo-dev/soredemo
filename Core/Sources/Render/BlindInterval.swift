import Foundation
import Project
import Timeline

/// A stretch of output time for which the observation track has nothing, **and why**.
///
/// The `cause` is a `GapSite` — the existing vocabulary — and not a new enum. Two
/// vocabularies for one fact is how two instruments start disagreeing, which this project has
/// already paid for once (`AGENTS.md`, the definite-singular audit's row 3).
public struct BlindInterval: Hashable, Sendable {
    public let start: Nanoseconds
    public let duration: Nanoseconds
    public let cause: GapSite

    public init(start: Nanoseconds, duration: Nanoseconds, cause: GapSite) {
        precondition(duration.rawValue >= 0,
                     "BlindInterval duration must be non-negative, got \(duration.rawValue)")
        self.start = start
        self.duration = duration
        self.cause = cause
    }

    public var end: Nanoseconds { Nanoseconds(start.rawValue + duration.rawValue) }

    public func contains(_ time: Nanoseconds) -> Bool {
        time.rawValue >= start.rawValue && time.rawValue < end.rawValue
    }
}

extension BlindInterval: Codable {
    /// Matches the synthesised shape exactly — `start`, `duration`, `cause` — so this
    /// hand-written conformance changes validation, not the wire form. Same rule-8 reason as
    /// `StageRect.init(from:)` / `HostRange.init(from:)`: the synthesised `init(from:)` would
    /// assign stored properties directly and never call the validating memberwise `init`, so a
    /// negative duration read off disk would decode successfully and only trap later, far from
    /// where it was read.
    private enum CodingKeys: String, CodingKey {
        case start, duration, cause
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(Nanoseconds.self, forKey: .start)
        let duration = try container.decode(Nanoseconds.self, forKey: .duration)
        let cause = try container.decode(GapSite.self, forKey: .cause)
        guard duration.rawValue >= 0 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "BlindInterval duration must be non-negative, got \(duration.rawValue)"))
        }
        self.start = start
        self.duration = duration
        self.cause = cause
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(duration, forKey: .duration)
        try container.encode(cause, forKey: .cause)
    }
}
