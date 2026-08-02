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
///
/// **4. Variable-length fields are permitted only behind a length prefix
/// (added by Task 13).** Task 6 recorded that no variable-length field may be
/// appended to `DisplayGeometry.canonicalBytes`, because its fields are
/// unambiguous only by virtue of being fixed-width. `Derived.approvalBytes`
/// cannot honour that as written: `Evidence` is variable-length by nature and
/// `ProducerID` is a string. So the discipline is extended rather than broken —
/// a variable-length field is always preceded by a **fixed-width `UInt64`
/// little-endian** count (of bytes, or of records), written by
/// `appendLengthPrefixed`/`appendCount` below. That restores the property the
/// fixed-width rule was protecting: every field boundary is determined by bytes
/// already read, so no two distinct values can concatenate to the same string.
/// The rule that remains absolute is that a variable-length field may never be
/// appended *without* one.
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

    /// Appends `payload` preceded by its byte count as a fixed-width `UInt64`.
    /// The only sanctioned way to put a variable-length field into a canonical
    /// encoding — see point 4 above.
    public static func appendLengthPrefixed(_ payload: [UInt8], to bytes: inout [UInt8]) {
        appendCount(payload.count, to: &bytes)
        bytes.append(contentsOf: payload)
    }

    /// Appends a `String` as its raw UTF-8, length-prefixed.
    ///
    /// **No Unicode normalisation.** Two canonically-equivalent strings — `"é"`
    /// as one scalar versus `"e"` plus a combining acute — compare `==` in Swift
    /// yet encode to different bytes here. That is deliberate: normalising would
    /// make every digest depend on the ICU tables of whichever OS version is
    /// running, so an OS update could silently change bytes that human approvals
    /// are already bound to. Raw UTF-8 depends on nothing outside the value. The
    /// residual asymmetry fails *closed* — it asks for a re-approval, it never
    /// lets an approval be redeemed against different text.
    public static func appendLengthPrefixed(_ string: String, to bytes: inout [UInt8]) {
        appendLengthPrefixed(Array(string.utf8), to: &bytes)
    }

    /// Appends a non-negative count as a fixed-width `UInt64`. Used for element
    /// counts of variable-length collections, where the elements themselves are
    /// fixed-width and so need no prefix of their own.
    public static func appendCount(_ count: Int, to bytes: inout [UInt8]) {
        precondition(count >= 0, "canonical encoding count must be non-negative, got \(count)")
        bytes.append(contentsOf: UInt64(count).littleEndianBytes)
    }

    /// Appends a signed integer as eight bytes, two's complement little-endian.
    public static func appendInt64(_ value: Int64, to bytes: inout [UInt8]) {
        bytes.append(contentsOf: UInt64(bitPattern: value).littleEndianBytes)
    }

    /// Appends a `Double` as its IEEE-754 bit pattern, little-endian — never a
    /// decimal rendering, which is lossy, locale- and formatter-dependent, and
    /// is exactly what `JSONEncoder` would emit for the same value.
    ///
    /// Traps on a non-finite value: NaN has many bit patterns, so a NaN field
    /// would be many encodings of one value and the encoding would not be well
    /// defined. Callers whose types already reject non-finite values at
    /// construction (`NormalizedPoint`, `DisplayGeometry.scale`) can never reach
    /// this.
    public static func appendDouble(_ value: Double, to bytes: inout [UInt8]) {
        precondition(value.isFinite, "canonical encoding requires a finite Double, got \(value)")
        bytes.append(contentsOf: value.bitPattern.littleEndianBytes)
    }
}

/// A value whose canonical bytes this package controls.
///
/// **Why this exists rather than `Codable`.** `Derived<Value>.approvalBytes` is
/// what Phase 8's `approval-gate` binds human approval to. If `Value` were
/// constrained to `Codable`, the only route to the payload's bytes would be an
/// encoder — and `JSONEncoder`, even with `.sortedKeys`, renders `Double` as
/// decimal text, which is precisely what `DisplayGeometry` rejects one layer up.
/// The payload is the part actually being approved (a framing target, a beat, a
/// post's text), so routing it through `Codable` would move the determinism
/// hazard inward, to the layer that matters most.
///
/// `Codable` stays — it is the document/JSON path — and the two are deliberately
/// separate, the same split Task 12 recorded for `EvidenceRef`.
///
/// **The conformance is required by the type system, not by convention.**
/// `Derived` constrains `Value` to this protocol, so a payload type that forgets
/// to conform does not compile. A guarantee that degrades silently — falling
/// back to whatever `Codable` gives — is the failure mode this project keeps
/// recording.
///
/// **Contract for an implementation.**
/// * Append only; never clear or reorder what is already in `bytes`.
/// * Emit **no** `CanonicalEncoding.version` byte. The version is written once,
///   by the outermost encoding (`approvalBytes`), not once per nested value.
/// * Every field fixed-width, little-endian; `Double` via `appendDouble`.
/// * Any variable-length field goes through `appendLengthPrefixed`, and any
///   variable-length collection through `appendCount` followed by fixed-width
///   elements.
/// * The layout is frozen: changing it changes every digest ever computed, so it
///   changes only alongside `CanonicalEncoding.version` and a re-approval path.
public protocol CanonicallyEncodable {
    func encodeCanonically(into bytes: inout [UInt8])
}

// MARK: - Conformances for the payload types that exist today
//
// Kept together so "what is digest-significant" is auditable in one place.

extension Int: CanonicallyEncodable {
    /// Eight bytes, two's complement little-endian — the width is fixed at 64
    /// rather than `Int.bitWidth`, so the encoding does not change if this ever
    /// builds for a 32-bit target.
    public func encodeCanonically(into bytes: inout [UInt8]) {
        CanonicalEncoding.appendInt64(Int64(self), to: &bytes)
    }
}

extension String: CanonicallyEncodable {
    /// Length-prefixed raw UTF-8. See `appendLengthPrefixed(_:to:)` for why
    /// there is no Unicode normalisation.
    public func encodeCanonically(into bytes: inout [UInt8]) {
        CanonicalEncoding.appendLengthPrefixed(self, to: &bytes)
    }
}

extension Double: CanonicallyEncodable {
    public func encodeCanonically(into bytes: inout [UInt8]) {
        CanonicalEncoding.appendDouble(self, to: &bytes)
    }
}

extension GeometryRevision: CanonicallyEncodable {
    /// 8 bytes: `id`, little-endian.
    public func encodeCanonically(into bytes: inout [UInt8]) {
        bytes.append(contentsOf: id.littleEndianBytes)
    }
}

extension NormalizedPoint: CanonicallyEncodable {
    /// 16 bytes: `x` ‖ `y`, bit patterns, little-endian.
    public func encodeCanonically(into bytes: inout [UInt8]) {
        CanonicalEncoding.appendDouble(x, to: &bytes)
        CanonicalEncoding.appendDouble(y, to: &bytes)
    }
}

extension NormalizedSize: CanonicallyEncodable {
    /// 16 bytes: `width` ‖ `height`, bit patterns, little-endian.
    public func encodeCanonically(into bytes: inout [UInt8]) {
        CanonicalEncoding.appendDouble(width, to: &bytes)
        CanonicalEncoding.appendDouble(height, to: &bytes)
    }
}

extension NormalizedFrame: CanonicallyEncodable {
    /// 40 bytes, fixed width: `origin` (16) ‖ `size` (16) ‖ `revision` (8).
    ///
    /// The revision is part of the digest for the same reason it is part of the
    /// type (D-P2): the same numbers normalised against a different display
    /// configuration describe a different physical rectangle, and an approval
    /// must not carry across one.
    public func encodeCanonically(into bytes: inout [UInt8]) {
        origin.encodeCanonically(into: &bytes)
        size.encodeCanonically(into: &bytes)
        revision.encodeCanonically(into: &bytes)
    }
}

extension UInt64 {
    /// Little-endian, fixed at eight bytes. Fixed width is what lets fields be
    /// concatenated without separators and still parse back unambiguously —
    /// a variable-width encoding of adjacent integers is where two distinct
    /// values collapse onto one byte string.
    ///
    /// `public` since Task 13: `Graph`'s `approvalBytes` needs the same
    /// primitive, and a second copy of a little-endian writer in another module
    /// is two canonical encoders that can drift apart silently.
    public var littleEndianBytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: (self >> (8 * UInt64($0))) & 0xff) }
    }
}
