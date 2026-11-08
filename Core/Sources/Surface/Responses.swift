import Framing
import Timeline

/// Every response, in one envelope: the same top-level shape for every verb and for every
/// failure, so a caller parses one thing.
///
/// **`schemaVersion` is a promise about meaning.** A new field is additive and keeps the number;
/// a field that changes what it means, or disappears, moves it — the rule `ProjectSnapshot`
/// already keeps for the file format.
public struct Envelope<Result: Encodable & Sendable>: Encodable, Sendable {
    public static var schemaVersion: Int { 1 }
    public let schemaVersion: Int
    public let verb: String?
    public let ok: Bool
    public let result: Result?
    public let error: Failure?

    static func success(_ verb: Verb, _ result: Result) -> Envelope {
        Envelope(schemaVersion: schemaVersion, verb: verb.rawValue, ok: true, result: result, error: nil)
    }
}

/// A failure, named by a code a program can branch on and a message a person can act on.
public struct Failure: Encodable, Sendable, Equatable {
    public enum Code: String, Encodable, Sendable {
        case usage
        case cannotOpenProject
        case noObservationLog
        case unreadableObservationLog
    }

    public let code: Code
    public let message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    /// The process's exit status for this failure — `sysexits(3)`'s numbers, so a shell script
    /// can tell "called wrongly" from "could not read the project" without parsing a message.
    public var exitCode: Int32 {
        switch code {
        case .usage: 64            // EX_USAGE
        case .cannotOpenProject: 66 // EX_NOINPUT
        case .noObservationLog, .unreadableObservationLog: 65 // EX_DATAERR
        }
    }
}

/// The JSON's empty result, for a failure envelope.
public struct Nothing: Encodable, Sendable {}

// MARK: - results

public struct VerbsResult: Encodable, Sendable {
    public struct Row: Encodable, Sendable {
        public let name: String
        public let kind: Verb.Kind
        public let summary: String
        public let usage: String
    }
    public let verbs: [Row]
    /// Said in the listing an agent reads first, so it does not go looking.
    public let note: String
}

public struct TimeSpan: Encodable, Sendable, Equatable {
    /// Nanoseconds from the recording's start.
    public let startNanos: Int64
    public let endNanos: Int64
}

public struct StatusResult: Encodable, Sendable {
    public struct Proposals: Encodable, Sendable {
        public let pending: Int
        public let alreadyCut: Int
        public let dismissed: Int
        public let unplaceable: Int
    }
    public let project: String
    public let media: String
    /// The log's filename, or `nil` when the recording has none.
    public let observationLog: String?
    public let durationNanos: Int64?
    /// Where the length came from, because the editor reads it from the media instead.
    public let durationFrom: String?
    public let outputDurationNanos: Int64?
    public let edited: Bool
    public let steps: Int?
    public let clicks: Int?
    public let framedClicks: Int?
    /// Proposals as the rules make them without listening to the audio; `propose-cut` hears it.
    public let proposals: Proposals?
}

public struct StepsResult: Encodable, Sendable {
    public struct Row: Encodable, Sendable {
        public let number: Int
        public let label: String
        public let role: String?
        public let application: String?
        public let span: TimeSpan
    }
    public let steps: [Row]
}

public struct FramingResult: Encodable, Sendable {
    public struct Row: Encodable, Sendable {
        public let atNanos: Int64
        public let framed: Bool
        /// The role of what was framed, when something was.
        public let role: String?
        /// The gate that refused it, by its stable name, when it was refused.
        public let refusedBecause: String?
    }
    public let clicks: [Row]
    public let framed: Int
    public let refused: Int
}

public struct ProposalsResult: Encodable, Sendable {
    public struct Bound: Encodable, Sendable, Equatable {
        public let kind: String
        public let step: Int?
    }
    public struct Key: Encodable, Sendable, Equatable {
        public let reason: String
        public let boot: String
        public let quietStartHostNanos: Int64
    }
    public struct Row: Encodable, Sendable {
        public let key: Key
        public let reason: String
        public let quiet: TimeSpan
        public let removes: TimeSpan
        public let openedBy: Bound
        public let closedBy: Bound
        public let duringStep: Int?
        /// `whole` or `partly`: how much of `removes` the edit still plays.
        public let survival: String
    }
    public let proposals: [Row]
    public let alreadyCut: Int
    public let dismissed: Int
    public let unplaceable: Int
    /// `sound` or `nothing`, and what it means for the list.
    public let hearing: String
    public let hearingNote: String
    /// Always false. In the output so nobody has to infer it from a missing verb.
    public let applied: Bool
}
