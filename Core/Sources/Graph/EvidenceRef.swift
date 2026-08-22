import Foundation
import Timeline

/// What kind of record `EvidenceRef.id` names.
public enum EvidenceKind: String, Hashable, Codable, Sendable {
    /// An entry in the observation log — input-observation or ax-observation.
    case observation
    /// A transcript segment.
    case transcript
    /// A prior release, cited when a generated value derives from what was already
    /// published rather than from a fresh observation.
    case release
}

/// A citation to one piece of evidence: its kind, which record, the content it was
/// cited against, and the interval of it used where the evidence sits in time.
///
/// `contentDigest` records the evidence as cited, not as it is now; a mismatch
/// against a freshly computed digest is how staleness is detected. `id` is minted by
/// the app, never by this package.
public struct EvidenceRef: Hashable, Codable, Sendable {
    public let kind: EvidenceKind
    public let id: UUID
    public let contentDigest: ContentDigest
    /// Host time, stamped with its boot epoch: `mach_absolute_time()` restarts at
    /// boot, so a bare `TimeRange` from one session compares wrongly against another.
    public let sourceInterval: HostRange?

    public init(kind: EvidenceKind, id: UUID, contentDigest: ContentDigest,
                sourceInterval: HostRange? = nil) {
        self.kind = kind
        self.id = id
        self.contentDigest = contentDigest
        self.sourceInterval = sourceInterval
    }
}
