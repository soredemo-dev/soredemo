import Foundation
import Framing
import Timeline

/// A project opened for the surface: what the verbs read, and nothing they could write through.
public struct OpenedProject: Sendable {
    /// The package itself, for an adapter that needs to read more of it — the audio, say.
    public let package: URL
    public let name: String
    public let mediaFilename: String
    /// The observation log, found by its header's join field; `nil` for a recording made
    /// without one.
    public let log: Log?
    /// What a person has cut. The whole recording when nobody has.
    public let edit: EditTimeline?
    /// The cut proposals a person said no to.
    public let dismissed: Set<CutProposal.Key>

    public struct Log: Sendable {
        public let url: URL
        public let anchor: EpochAnchor
        /// **From the log's trailer, not from the media.** The editor reads the media's length;
        /// the two agree to within a frame on a recording that closed cleanly, and the status
        /// verb says which one it used, so a disagreement is visible rather than assumed away.
        public let duration: Nanoseconds

        public init(url: URL, anchor: EpochAnchor, duration: Nanoseconds) {
            self.url = url
            self.anchor = anchor
            self.duration = duration
        }
    }

    public init(package: URL, name: String, mediaFilename: String, log: Log?, edit: EditTimeline?,
                dismissed: Set<CutProposal.Key>) {
        self.package = package
        self.name = name
        self.mediaFilename = mediaFilename
        self.log = log
        self.edit = edit
        self.dismissed = dismissed
    }
}

/// How a project is read. **The verbs depend on this, not on a file format**: the package reader
/// lives in the runnable tier with the log readers, and a test hands the verbs a fixture.
public protocol ProjectReading: Sendable {
    func open(_ path: String) throws -> OpenedProject
    /// The take, with `speech` — offsets into the recording — as what was heard.
    func take(of log: OpenedProject.Log, speech: [Range<Int64>]) throws -> TakeActivity
    func framing(of log: OpenedProject.Log) throws -> FramingPlan
}

/// What was heard in a recording, for telling a narrated pause from dead air.
public enum Heard: Sendable, Equatable {
    /// Where something could be heard, as offsets into the recording.
    case sound([Range<Int64>])
    /// Nothing was read, and why — said in the output, because it changes what the proposals mean.
    case nothing(String)
}

/// Separate from `ProjectReading` because it is the one slow, media-decoding part, and a verb
/// that does not need it should not hold it.
public protocol Hearing: Sendable {
    func heard(in project: OpenedProject) async -> Heard
}
