import Foundation

/// A stable identity for a node in the derivation graph: the app's key for one
/// `Derived` value, independent of the value's type, which is what lets
/// `ReverseIndex` avoid being generic over every producer's payload.
///
/// `rawValue` is minted by the app, never by this package; this type only receives
/// a `UUID`, it never constructs one.
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

/// "What depended on this observation": the inverse of `Derivation.evidence`.
///
/// A cache, always computed from the forward citations in `.generated` origins and
/// never written independently. `dependents(of:)` returns empty whenever the index
/// is not current, never the last-known set — a stale answer would silently
/// under-invalidate, an empty one is visibly wrong.
public struct ReverseIndex: Sendable {
    /// One forward edge as recorded by a node. `rebuild(from:)` inverts every
    /// `.generated` origin's evidence into `dependents(of:)`; `.authored` origins
    /// cite nothing and so contribute no edges at all.
    public struct Entry: Sendable {
        public let node: NodeID
        public let origin: Origin

        public init(node: NodeID, origin: Origin) {
            self.node = node
            self.origin = origin
        }
    }

    /// Keyed by `EvidenceRef.id`, not the full `EvidenceRef`: a caller invalidating
    /// over an edited observation knows its identity, not the `contentDigest` or
    /// `sourceInterval` under which a node cited it.
    private var edgesByEvidenceID: [UUID: Set<NodeID>]

    /// Whether the edges reflect the most recent `rebuild(from:)` with no
    /// `invalidate()` since. Starts `false`; never-built and stale are treated
    /// identically by `dependents(of:)`.
    public private(set) var isCurrent: Bool

    public init() {
        self.edgesByEvidenceID = [:]
        self.isCurrent = false
    }

    /// Replaces the entire edge set from `entries` and marks the index current.
    /// Replaces, never merges: a node dropped from `entries` must stop appearing in
    /// every `dependents(of:)` result, or an edge would outlive its forward citation.
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

    /// Every node whose `.generated` origin cited `evidenceID` (`EvidenceRef.id`) as
    /// of the last `rebuild(from:)`. Returns the empty set whenever `isCurrent` is
    /// `false`, regardless of what the index held before.
    public func dependents(of evidenceID: UUID) -> Set<NodeID> {
        guard isCurrent else { return [] }
        return edgesByEvidenceID[evidenceID] ?? []
    }

    /// Marks the index stale: `dependents(of:)` answers empty until the next
    /// `rebuild(from:)`. Cached edges are hidden, not discarded.
    public mutating func invalidate() {
        isCurrent = false
    }
}
