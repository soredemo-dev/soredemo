/// A non-empty collection of `EvidenceRef`, cited by everything generated
/// (design doc D-P4).
///
/// **Why not `[EvidenceRef]`.** A plain array permits `[]`, which would make
/// "an uncited generated value is unrepresentable" — the sentence D-P4
/// exists to make true — false. `Evidence` makes emptiness unrepresentable by
/// storing one required element plus the rest, so there is no path to zero
/// evidence through the type at all, not even a runtime check that could be
/// skipped.
///
/// **The stored property is `head`, not `first`.** A stored property literally
/// named `first` shadows `Collection.first`: it resolves to the non-optional
/// `EvidenceRef` when accessed on the concrete type, but to the *inherited*
/// `Collection.first: EvidenceRef?` when accessed through a generic context
/// (e.g. `some Collection<EvidenceRef>`) — with no compiler diagnostic in
/// either direction. Verified by compiling both access paths on this
/// toolchain. Naming it `head` sidesteps the trap entirely rather than
/// relying on nobody hitting it.
///
/// Conforms to `RandomAccessCollection` so ordinary `Sequence`/`Collection`
/// call sites (`for ref in evidence`, `.map`, `.contains`) work without
/// callers ever touching `head`/`tail` directly.
public struct Evidence: Hashable, Sendable {
    public let head: EvidenceRef
    public let tail: [EvidenceRef]

    /// Variadic convenience for call sites that know their citations up
    /// front: `Evidence(ref)`, `Evidence(ref1, ref2)`.
    public init(_ head: EvidenceRef, _ tail: EvidenceRef...) {
        self.head = head
        self.tail = tail
    }

    /// Swift cannot splat an array into a variadic parameter, and Phase 3's
    /// framing producers hold `[EvidenceRef]` — so this is not a convenience
    /// overload, it is the only way an already-built array reaches
    /// `Evidence` at all. Returns `nil` for an empty array: this is the
    /// in-memory half of the "evidence cannot be empty" guarantee, mirrored
    /// on the decode side by `init(from:)` below.
    public init?(_ refs: [EvidenceRef]) {
        guard let head = refs.first else { return nil }
        self.head = head
        self.tail = Array(refs.dropFirst())
    }
}

extension Evidence: RandomAccessCollection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { 1 + tail.count }

    public subscript(position: Int) -> EvidenceRef {
        position == 0 ? head : tail[position - 1]
    }
}

extension Evidence: Codable {
    /// An `Evidence` decoded from disk whose JSON array was empty —
    /// corruption, a hand edit, or a document written by something that
    /// skipped this type's guarantee entirely. Thrown, never trapped: this is
    /// untrusted input, the same split used throughout this package (see
    /// `ContentDigest`, `GeometryRegistry`).
    public struct DecodingFailure: Error, Equatable {}

    /// Decodes a flat JSON array and rejects `[]`. This is the disk half of
    /// the non-empty guarantee: without this check, a document written once
    /// while the guarantee held (or written by a version of this package
    /// with a bug) could read back as valid, empty evidence — the guarantee
    /// would be true only in memory, never proven by a round trip.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let refs = try container.decode([EvidenceRef].self)
        guard let head = refs.first else {
            throw DecodingFailure()
        }
        self.head = head
        self.tail = Array(refs.dropFirst())
    }

    /// Encodes as a flat JSON array — `[ref, ref, ...]`, not an object with
    /// `head`/`tail` keys — so the wire shape matches `[EvidenceRef]` exactly
    /// and neither carries information the other lacks.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([head] + tail)
    }
}
