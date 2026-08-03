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
    public let start: Nanoseconds
    public let duration: Nanoseconds

    public init(start: Nanoseconds, duration: Nanoseconds) {
        precondition(duration.rawValue >= 0,
                     "CursorOverride duration must be non-negative, got \(duration.rawValue)")
        self.start = start
        self.duration = duration
    }

    public func contains(_ time: Nanoseconds) -> Bool {
        time.rawValue >= start.rawValue && time.rawValue < start.rawValue + duration.rawValue
    }
}

extension CursorOverride: Codable {
    /// Matches the synthesised shape exactly — `start`, `duration` — so this hand-written
    /// conformance changes validation, not the wire form. Same rule-8 reason as
    /// `BlindInterval.init(from:)` above.
    private enum CodingKeys: String, CodingKey {
        case start, duration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(Nanoseconds.self, forKey: .start)
        let duration = try container.decode(Nanoseconds.self, forKey: .duration)
        guard duration.rawValue >= 0 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "CursorOverride duration must be non-negative, got \(duration.rawValue)"))
        }
        self.start = start
        self.duration = duration
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(duration, forKey: .duration)
    }
}
