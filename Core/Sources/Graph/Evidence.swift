/// A non-empty collection of `EvidenceRef`, cited by everything generated.
///
/// Emptiness is unrepresentable — one required element plus the rest — so an
/// uncited generated value cannot be spelled, with no runtime check to skip. The
/// stored property is `head`, not `first`: a stored `first` silently shadows
/// `Collection.first`, resolving non-optional on the concrete type and optional
/// through a generic context, with no diagnostic either way. Conforms to
/// `RandomAccessCollection` so callers never touch `head`/`tail` directly.
public struct Evidence: Hashable, Sendable {
    public let head: EvidenceRef
    public let tail: [EvidenceRef]

    /// Variadic convenience for call sites that know their citations up front.
    public init(_ head: EvidenceRef, _ tail: EvidenceRef...) {
        self.head = head
        self.tail = tail
    }

    /// The only way an already-built array reaches `Evidence`: Swift cannot splat an
    /// array into a variadic parameter. Returns `nil` for an empty array — the
    /// in-memory half of the non-empty guarantee, mirrored by `init(from:)`.
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
    /// An `Evidence` whose decoded JSON array was empty. Thrown, never trapped:
    /// decoded documents are untrusted input.
    public struct DecodingFailure: Error, Equatable {}

    /// Decodes a flat JSON array and throws `DecodingFailure` on `[]`: the disk half
    /// of the non-empty guarantee.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let refs = try container.decode([EvidenceRef].self)
        guard let head = refs.first else {
            throw DecodingFailure()
        }
        self.head = head
        self.tail = Array(refs.dropFirst())
    }

    /// Encodes as a flat JSON array, not a `head`/`tail` object, so the wire shape
    /// matches `[EvidenceRef]` exactly.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([head] + tail)
    }
}
