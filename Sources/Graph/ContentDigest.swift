/// 32 opaque bytes identifying the exact content evidence was cited against.
///
/// This package compares digests and never computes one; the value is injected by
/// whoever produced the evidence (the app, via CryptoKit SHA-256). Never a
/// non-cryptographic hash such as `fnv1a64`: constructible collisions would let an
/// approval bound to reviewed content be redeemed against substituted content.
///
/// `init(_:)` traps on the wrong byte count (programmer error); `init(from:)` throws,
/// because a digest decoded from disk is untrusted input.
public struct ContentDigest: Hashable, Sendable {
    /// SHA-256 output length. Frozen: changing it breaks every digest on disk.
    public static let byteCount = 32

    public let bytes: [UInt8]

    /// Traps if `bytes.count != Self.byteCount`.
    public init(_ bytes: [UInt8]) {
        precondition(bytes.count == Self.byteCount,
                     "ContentDigest must be \(Self.byteCount) bytes, got \(bytes.count)")
        self.bytes = bytes
    }
}

extension ContentDigest: Codable {
    /// A decoded digest whose byte count is not `ContentDigest.byteCount`.
    public struct DecodingFailure: Error, Equatable {
        public let byteCount: Int
    }

    /// Untrusted input: throws `DecodingFailure` rather than trapping when the
    /// decoded byte count is wrong.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode([UInt8].self)
        guard decoded.count == Self.byteCount else {
            throw DecodingFailure(byteCount: decoded.count)
        }
        self.bytes = decoded
    }

    /// Encodes as a flat JSON array of 32 numbers: no wrapping object, so there is no
    /// key order and no per-process byte-order hazard.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

extension ContentDigest: CustomStringConvertible {
    /// Fixed-width hex, so a digest is greppable in a log rather than an array literal.
    public var description: String {
        let hex = bytes.map { byte -> String in
            let s = String(byte, radix: 16)
            return s.count == 1 ? "0" + s : s
        }.joined()
        return "ContentDigest(\(hex))"
    }
}
