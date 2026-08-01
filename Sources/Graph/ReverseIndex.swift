import Foundation

/// A stable identity for a node in the derivation graph — the app's key for
/// one `Derived` value, independent of what kind of value it holds.
///
/// `ReverseIndex` inverts `Origin`, which has the same shape (`.generated` /
/// `.authored`) no matter what `Value` the owning `Derived<Value>` carries.
/// `NodeID` is what lets the index name "the thing this `Origin` belongs to"
/// without becoming generic over every producer's payload type itself.
///
/// `rawValue` is a plain `UUID` — minted by the app, never by this package
/// (design doc § Determinism): this type only ever receives one, it never
/// constructs one. Same shape as `EvidenceRef.id`.
public struct NodeID: Hashable, Sendable, RawRepresentable {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
}

extension NodeID: Codable {
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// "What depended on this observation" — the inverse of `Derivation.evidence`
/// (design doc D-P4, § Reverse index).
///
/// Forward citations are the source of truth: a `Derived` value's
/// `.generated` origin names the evidence it used, and the type system
/// guarantees that citation exists whenever the origin does. `ReverseIndex`
/// answers the opposite question and is **computed from those forward
/// edges**, never written independently — which is what makes it a cache,
/// governed by `AGENTS.md`'s cache-invalidation-pairing rule rather than by
/// a write path of its own.
///
/// **Its consumer is Phase 4's `text-based-editing`.** Deleting a word from
/// the transcript must invalidate exactly the beats that cited it: too few
/// invalidated leaves a stale derivation next to text it no longer
/// describes; too many costs a person reviewed work they had no reason to
/// lose. Both are real failures, and the type is built to fail toward the
/// loud one.
///
/// **`dependents(of:)` returns empty whenever the index is not current —
/// never the last-known set.** A stale answer would silently
/// *under*-invalidate: beats that depended on deleted evidence would stay
/// alive with nothing downstream able to tell. Returning nothing is loud —
/// a caller that forgets to rebuild before querying gets a visibly wrong
/// (empty) answer, not a plausible-looking stale one.
public struct ReverseIndex: Sendable {
    /// One forward edge as recorded by a node: what it is, and where it came
    /// from. `rebuild(from:)` walks a list of these and inverts every
    /// `.generated` origin's evidence into `dependents(of:)`.
    ///
    /// `.authored` origins cite nothing (D-P4: a person owes no citation),
    /// so an authored entry contributes no edges at all — it appears in no
    /// `dependents(of:)` result, for any evidence.
    public struct Entry: Sendable {
        public let node: NodeID
        public let origin: Origin

        public init(node: NodeID, origin: Origin) {
            self.node = node
            self.origin = origin
        }
    }

    /// Keyed by `EvidenceRef.id` — "this observation" — not by the full
    /// `EvidenceRef`. A caller invalidating over an edited observation knows
    /// its identity, not necessarily the `contentDigest` or
    /// `sourceInterval` under which some node happened to cite it.
    private var edgesByEvidenceID: [UUID: Set<NodeID>]

    /// Whether the edges reflect the most recent `rebuild(from:)`, with no
    /// `invalidate()` since. Starts `false`: an index that has never been
    /// built is no more trustworthy than one that has gone stale, and
    /// `dependents(of:)` treats the two identically.
    public private(set) var isCurrent: Bool

    public init() {
        self.edgesByEvidenceID = [:]
        self.isCurrent = false
    }

    /// Replaces the entire edge set from `entries` and marks the index
    /// current.
    ///
    /// **Replaces, never merges.** A node dropped from `entries` — its
    /// citation removed, or the node itself deleted — must stop appearing
    /// in every `dependents(of:)` result, not merely stop being re-added to
    /// it. Merging would let an edge outlive the forward citation that was
    /// its only justification, which is precisely the staleness this cache
    /// exists to prevent; `rebuildAfterInvalidationReflectsNewEdges`
    /// exercises this with an edge set disjoint from the prior one, so an
    /// accidental merge cannot pass by coincidence.
    public mutating func rebuild(from entries: [Entry]) {
        var fresh: [UUID: Set<NodeID>] = [:]
        for entry in entries {
            guard case .generated(let derivation) = entry.origin else { continue }
            for ref in derivation.evidence {
                fresh[ref.id, default: []].insert(entry.node)
            }
        }
        edgesByEvidenceID = fresh
        isCurrent = true
    }

    /// Every node whose `.generated` origin cited the evidence identified by
    /// `evidenceID` (`EvidenceRef.id`), as of the last `rebuild(from:)`.
    ///
    /// Returns the empty set whenever `isCurrent` is `false`, regardless of
    /// what the index held before `invalidate()` was called. See the type's
    /// documentation for why silence, not staleness, is the safe failure
    /// here.
    public func dependents(of evidenceID: UUID) -> Set<NodeID> {
        guard isCurrent else { return [] }
        return edgesByEvidenceID[evidenceID] ?? []
    }

    /// Marks the index stale. `dependents(of:)` answers empty until the
    /// next `rebuild(from:)` — the cached edges are not discarded here,
    /// only hidden, which is what makes `rebuildAfterInvalidationReflectsNewEdges`
    /// a meaningful test: it proves the next rebuild *replaces* them rather
    /// than merging into whatever was left behind.
    public mutating func invalidate() {
        isCurrent = false
    }
}
