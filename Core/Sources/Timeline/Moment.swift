import Foundation

/// Which clock a moment is on. **Never instantiated** — a clock is a name the compiler checks.
public protocol TimelineClock: Sendable {}

/// The recording's own clock: what the observation log, the steps, the notes and the playhead
/// are on. Cuts do not move it.
public enum RecordingClock: TimelineClock {}

/// The edited video's clock: where a moment plays once cuts and speed changes have moved
/// everything after them.
public enum EditClock: TimelineClock {}

/// A moment on one clock. See `docs/design/2026-11-09-two-clocks-two-types.md`: the editor's two
/// clocks were one type, and a conversion done the wrong way round compiled.
///
/// **A length has no clock** and stays `Nanoseconds`: two moments on one clock subtract to a
/// length, a moment and a length add to a moment on that clock, and nothing mixes clocks.
public struct Moment<Clock: TimelineClock>: Hashable, Comparable, Sendable {
    public let nanoseconds: Nanoseconds

    public init(_ nanoseconds: Nanoseconds) {
        self.nanoseconds = nanoseconds
    }

    public init(nanos: Int64) {
        nanoseconds = Nanoseconds(nanos)
    }

    public var rawValue: Int64 { nanoseconds.rawValue }

    public static var zero: Moment { Moment(nanos: 0) }

    public static func < (lhs: Moment, rhs: Moment) -> Bool { lhs.nanoseconds < rhs.nanoseconds }

    public static func + (moment: Moment, length: Nanoseconds) -> Moment {
        Moment(nanos: moment.rawValue + length.rawValue)
    }

    public static func - (moment: Moment, length: Nanoseconds) -> Moment {
        Moment(nanos: moment.rawValue - length.rawValue)
    }

    /// How long from `earlier` to `later`, on the clock they share.
    public static func - (later: Moment, earlier: Moment) -> Nanoseconds {
        Nanoseconds(later.rawValue - earlier.rawValue)
    }
}

/// **Encoded exactly as the wrapped `Nanoseconds`**, so a moment on disk reads the same as the
/// `Nanoseconds` it replaced. The clock is not written: it is the reader's type that says it.
extension Moment: Codable {
    public init(from decoder: any Decoder) throws {
        nanoseconds = try Nanoseconds(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try nanoseconds.encode(to: encoder)
    }
}

/// A moment in the recording.
public typealias SourceTime = Moment<RecordingClock>
/// A moment in the edited video.
public typealias OutputTime = Moment<EditClock>
