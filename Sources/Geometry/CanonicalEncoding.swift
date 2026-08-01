/// Rules for any bytes that get digested. See the design doc § Canonical encoding.
///
/// A canonical encoding is byte-identical for equal values, across processes and
/// across time. Three separate things break that, and each fails silently:
///
/// 1. **Dictionaries do not encode deterministically.** With a key that is not
///    `String` or `Int`, `Codable` synthesis emits an *unkeyed* container of
///    alternating key/value in iteration order, and iteration order comes from
///    the per-process random hash seed. `JSONEncoder.sortedKeys` does not help —
///    it sorts keyed containers only. So: **no type whose bytes are digested may
///    rely on synthesised `Codable` for a dictionary.** Nothing in this file's
///    encoding path goes through `Codable` at all; `Codable` conformances here
///    are the document path, and the two are deliberately separate.
/// 2. **Field order and shape must be frozen** — hence `version` below.
/// 3. **Floating point needs a bit-exact rule** — digest `Double.bitPattern`,
///    never a decimal rendering, with preconditions rejecting values for which
///    the encoding would not be well defined.
public enum CanonicalEncoding {
    /// Leading byte of every canonical encoding.
    ///
    /// Adding a field to a digested type, or reordering existing ones, changes
    /// every previously computed digest. The failure is not a validation error —
    /// it is validation quietly checking a different thing, which is worse. This
    /// byte makes such a change explicit and detectable. Bump it ONLY as a
    /// deliberate breaking change shipping with a re-approval path.
    ///
    /// Deliberately **not** `ProjectSnapshot.schemaVersion`: a document schema
    /// upgrade must leave existing approvals verifiable, so the two version
    /// lines move independently.
    public static let version: UInt8 = 1
}

extension UInt64 {
    /// Little-endian, fixed at eight bytes. Fixed width is what lets fields be
    /// concatenated without separators and still parse back unambiguously —
    /// a variable-width encoding of adjacent integers is where two distinct
    /// values collapse onto one byte string.
    var littleEndianBytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: (self >> (8 * UInt64($0))) & 0xff) }
    }
}
