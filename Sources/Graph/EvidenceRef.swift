import Foundation
import Timeline

/// What kind of record `EvidenceRef.id` names.
public enum EvidenceKind: String, Hashable, Codable, Sendable {
    /// An entry in the observation log — input-observation or ax-observation.
    case observation
    /// A transcript segment.
    case transcript
    /// A prior release — cited when a generated value derives from what was
    /// already published, not from a fresh observation.
    case release
}

/// A citation to one piece of evidence: what kind of record it is, which
/// record, the content it was cited against, and — when the evidence has a
/// natural place in time — the interval of it that was actually used
/// (design doc D-P4).
///
/// **`contentDigest` records the evidence as cited, not the evidence as it is
/// now.** Comparing it against a freshly computed digest of the current
/// record is how staleness is detected: a mismatch means the cited content
/// has since changed underneath the citation. See `ContentDigest`'s
/// documentation for why this is SHA-256, injected, and never `fnv1a64`.
///
/// `id` is a plain `UUID` — minted by the app, never by this package (design
/// doc § Determinism): this type only ever receives one, it never constructs
/// one.
public struct EvidenceRef: Hashable, Codable, Sendable {
    public let kind: EvidenceKind
    public let id: UUID
    public let contentDigest: ContentDigest
    /// Host time, stamped with its boot epoch. `TimeRange` was not enough:
    /// `mach_absolute_time()` restarts at boot, so a bare interval from one
    /// session compares silently and wrongly against another (D2-11).
    public let sourceInterval: HostRange?

    public init(kind: EvidenceKind, id: UUID, contentDigest: ContentDigest,
                sourceInterval: HostRange? = nil) {
        self.kind = kind
        self.id = id
        self.contentDigest = contentDigest
        self.sourceInterval = sourceInterval
    }
}
