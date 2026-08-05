import Foundation

/// Maps a `GeometryRevision` back to the `DisplayGeometry` it was derived from and
/// to when it was first seen.
///
/// The invariant `key == recompute(value).revision` is enforced twice: `insert`
/// traps (a collision between two distinct geometries is a programmer error,
/// detectable only there), `init(from:)` throws (a decoded registry is untrusted
/// input). `firstObserved` is stored but never digested, so when a geometry was
/// first seen cannot affect which revision it has.
public struct GeometryRegistry: Hashable, Sendable {
    /// A decoded entry whose stored key does not match the recomputed revision of its
    /// stored geometry. Thrown, never trapped: decoded registries are untrusted.
    public struct DecodingFailure: Error, Equatable {
        public let revision: GeometryRevision
    }

    private var entries: [GeometryRevision: DisplayGeometry]
    private var observed: [GeometryRevision: Int64]

    public init() {
        entries = [:]
        observed = [:]
    }

    public func geometry(for revision: GeometryRevision) -> DisplayGeometry? {
        entries[revision]
    }

    public func firstObserved(for revision: GeometryRevision) -> Int64? {
        observed[revision]
    }

    public var revisions: Set<GeometryRevision> {
        Set(entries.keys)
    }

    /// Records that `geometry` was observed at `observedAt`. First observation wins:
    /// re-inserting a known geometry is a no-op that preserves the original
    /// `firstObserved`. Traps if the revision is already present under a *different*
    /// geometry — a 64-bit digest collision, which would make the two compare equal.
    public mutating func insert(_ geometry: DisplayGeometry, observedAt: Int64) {
        let revision = geometry.revision
        if let existing = entries[revision] {
            precondition(existing == geometry,
                         "geometry revision collision on \(revision): \(existing) vs \(geometry)")
            return
        }
        entries[revision] = geometry
        observed[revision] = observedAt
    }
}

extension GeometryRegistry: Codable {
    /// The wire shape of one entry.
    private struct Entry: Codable {
        let revision: GeometryRevision
        let geometry: DisplayGeometry
        let firstObserved: Int64
    }

    /// A flat array sorted by `revision.id`. Hand-written because synthesised
    /// `Codable` for a non-`String`-keyed dictionary emits an unkeyed container in
    /// per-process-seeded order, which `JSONEncoder.sortedKeys` does not fix. Only
    /// array position is promised, not a byte string: object key order still varies
    /// per process, so anything digesting `JSONEncoder` output must set `.sortedKeys`.
    public func encode(to encoder: any Encoder) throws {
        let sorted = entries.keys.sorted { $0.id < $1.id }.map { revision in
            Entry(revision: revision, geometry: entries[revision]!, firstObserved: observed[revision] ?? 0)
        }
        var container = encoder.singleValueContainer()
        try container.encode(sorted)
    }

    /// Untrusted input: validates `key == recompute(value).revision` for every entry
    /// and throws `DecodingFailure` on the first mismatch rather than trapping.
    public init(from decoder: any Decoder) throws {
        let list = try decoder.singleValueContainer().decode([Entry].self)
        entries = [:]
        observed = [:]
        for entry in list {
            guard entry.geometry.revision == entry.revision else {
                throw DecodingFailure(revision: entry.revision)
            }
            entries[entry.revision] = entry.geometry
            observed[entry.revision] = entry.firstObserved
        }
    }
}
