/// Identity of a display configuration, derived from the geometry rather than the
/// event that observed it, so the same configuration yields the same revision in any
/// session and on any machine. `id` is a content digest, never `hashValue`, which is
/// seeded per process.
public struct GeometryRevision: Hashable, Codable, Sendable {
    public let id: UInt64

    public init(id: UInt64) {
        self.id = id
    }
}

extension GeometryRevision: CustomStringConvertible {
    /// Fixed-width hex, so revisions are greppable and comparable in a log.
    public var description: String {
        var hex = String(id, radix: 16)
        if hex.count < 16 { hex = String(repeating: "0", count: 16 - hex.count) + hex }
        return "GeometryRevision(\(hex))"
    }
}
