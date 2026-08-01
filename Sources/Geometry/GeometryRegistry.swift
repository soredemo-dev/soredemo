import Foundation

/// Maps a `GeometryRevision` back to the `DisplayGeometry` it was derived from,
/// and to when it was first seen (D-P2).
///
/// **The same invariant — `key == recompute(value).revision` — is checked in two
/// places, with two different failure modes, because the inputs differ in
/// kind:**
///
/// - `insert` **traps**. A revision collision reached while merging registries is
///   a *programmer error*: a 64-bit non-cryptographic digest (`fnv1a64`, see
///   `FNV1a.swift`) mapping two distinct geometries onto one revision would make
///   those two geometries compare **equal**, which is the silent, dangerous
///   direction, and it is only detectable exactly here, at the point of
///   collision.
/// - `init(from:)` **throws**. A registry decoded from disk is *input*, not
///   program state — it may have been corrupted, hand-edited, or written by a
///   future version of this app. Trapping on untrusted input is how a bad file
///   becomes an unopenable document, so decoding validates the same invariant
///   and reports a typed error instead.
///
/// `firstObserved` is stored per revision but never digested: ordering is kept
/// out of identity, so *when* a geometry was first seen cannot affect *which*
/// revision it has.
public struct GeometryRegistry: Hashable, Sendable {
    /// A registry decoded from disk whose stored key does not match the
    /// recomputed revision of its stored geometry — corruption, a hand edit, or
    /// a future encoding this version does not understand. Thrown, never
    /// trapped: see the type's documentation.
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

    /// Records that `geometry` was observed, at `observedAt`. First observation
    /// wins: re-inserting an already-known geometry — the ordinary case, e.g.
    /// two observation records citing the same display — is a no-op that
    /// preserves the original `firstObserved` rather than overwriting it with
    /// the later timestamp.
    ///
    /// Traps if `geometry`'s revision is already present under a *different*
    /// geometry. That is a merge-time collision: two distinct `DisplayGeometry`
    /// values hashed to the same 64-bit revision, which would make them compare
    /// equal from here on — the silent direction a non-cryptographic digest can
    /// fail in, and the only place it is detectable. This is a programmer-error
    /// trap, not input validation; untrusted input goes through the throwing
    /// `init(from:)` instead.
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

    /// Hand-written. Synthesised `Codable` for `[GeometryRevision: DisplayGeometry]`
    /// would encode as an *unkeyed* container in `Dictionary`'s iteration order,
    /// and that order comes from a per-process random hash seed —
    /// `JSONEncoder.sortedKeys` does not help, because it sorts keyed containers
    /// only (design doc § Canonical encoding). These bytes end up inside
    /// `ProjectSnapshot`, which Phase 8's approval gate binds to, so a registry
    /// that encoded differently per process would make approvals unverifiable.
    ///
    /// The encoding is a **flat array sorted by `revision.id`** — deterministic
    /// by construction, independent of both `Dictionary`'s order and the order
    /// entries were inserted in. That guarantee covers array *position* only.
    ///
    /// Measured, not assumed: `JSONEncoder`'s ordering of keys *within* one
    /// object (e.g. whether `"revision"` or `"geometry"` prints first) is
    /// **also** not stable across processes without `.sortedKeys` — ten
    /// subprocesses of this exact type produced ten different byte strings, all
    /// with revision ids in the same sorted order but differently-ordered object
    /// keys inside each entry. That is a second, separate manifestation of the
    /// per-process-seed hazard, distinct from the Dictionary-as-unkeyed-container
    /// one above, and it does not threaten this type's contract — only the array
    /// order is promised, not a specific byte string. It matters for whoever
    /// next hashes raw `JSONEncoder` output directly for a digest anywhere in
    /// this project (e.g. a naive `ContentDigest` over `ProjectSnapshot`): that
    /// caller must pass `.sortedKeys`, or bypass `Codable` entirely the way
    /// `DisplayGeometry.canonicalBytes` does.
    public func encode(to encoder: any Encoder) throws {
        let sorted = entries.keys.sorted { $0.id < $1.id }.map { revision in
            Entry(revision: revision, geometry: entries[revision]!, firstObserved: observed[revision] ?? 0)
        }
        var container = encoder.singleValueContainer()
        try container.encode(sorted)
    }

    /// Untrusted input: validates `key == recompute(value).revision` for every
    /// entry and throws `DecodingFailure` on the first mismatch, rather than
    /// trapping. See the type's documentation for why this differs from
    /// `insert`.
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
