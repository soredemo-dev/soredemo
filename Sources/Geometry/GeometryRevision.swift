/// Identity of a display configuration, derived from *the geometry* rather than
/// from the event that observed it, so the same configuration yields the same
/// revision in any session and on any machine (D-P2).
///
/// Two properties this buys: a display that changes and changes back restores
/// comparability, because the geometry genuinely is the same; and two sessions
/// that shared a display agree without coordination.
///
/// The `id` is a content digest — never `hashValue`, which is seeded per process.
public struct GeometryRevision: Hashable, Codable, Sendable {
    public let id: UInt64

    public init(id: UInt64) {
        self.id = id
    }
}

extension GeometryRevision: CustomStringConvertible {
    /// Fixed-width hex so revisions are greppable and comparable in a log —
    /// legibility was one of the reasons an opaque per-epoch UUID was rejected.
    public var description: String {
        var hex = String(id, radix: 16)
        if hex.count < 16 { hex = String(repeating: "0", count: 16 - hex.count) + hex }
        return "GeometryRevision(\(hex))"
    }
}
