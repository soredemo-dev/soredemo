/// Rules for any bytes that get digested — byte-identical for equal values, across processes and
/// across time. Four constraints, each of which fails silently if broken:
///
/// 1. No digested type may rely on synthesised `Codable` for a dictionary: with a non-`String`,
///    non-`Int` key it emits an unkeyed container in hash-seed-dependent order, and
///    `JSONEncoder.sortedKeys` sorts only keyed containers. Nothing here goes through `Codable`,
///    which is the separate document path.
/// 2. Field order and shape are frozen — hence `version` below.
/// 3. `Double` is digested as its bit pattern, never as a decimal rendering.
/// 4. A variable-length field may only be appended behind a fixed-width `UInt64` little-endian
///    count, via `appendLengthPrefixed`/`appendCount`. That keeps every field boundary determined
///    by bytes already read, so no two distinct values concatenate to the same string.
public enum CanonicalEncoding {
    /// Leading byte of every canonical encoding. Bump it only as a deliberate breaking change
    /// shipping with a re-approval path, since adding or reordering a field in a digested type
    /// changes every previously computed digest.
    ///
    /// Deliberately not `ProjectSnapshot.schemaVersion`: a document schema upgrade must leave
    /// existing approvals verifiable, so the two version lines move independently.
    public static let version: UInt8 = 1

    /// Appends `payload` preceded by its byte count as a fixed-width `UInt64`. The only sanctioned
    /// way to put a variable-length field into a canonical encoding.
    public static func appendLengthPrefixed(_ payload: [UInt8], to bytes: inout [UInt8]) {
        appendCount(payload.count, to: &bytes)
        bytes.append(contentsOf: payload)
    }

    /// Appends a `String` as its raw UTF-8, length-prefixed. No Unicode normalisation, so two
    /// canonically-equivalent strings that compare `==` in Swift encode differently: normalising
    /// would tie every digest to the running OS's ICU tables. The asymmetry fails closed.
    public static func appendLengthPrefixed(_ string: String, to bytes: inout [UInt8]) {
        appendLengthPrefixed(Array(string.utf8), to: &bytes)
    }

    /// Appends a non-negative count as a fixed-width `UInt64`, for collections whose elements are
    /// themselves fixed-width. Traps on a negative count.
    public static func appendCount(_ count: Int, to bytes: inout [UInt8]) {
        precondition(count >= 0, "canonical encoding count must be non-negative, got \(count)")
        bytes.append(contentsOf: UInt64(count).littleEndianBytes)
    }

    /// Appends a signed integer as eight bytes, two's complement little-endian.
    public static func appendInt64(_ value: Int64, to bytes: inout [UInt8]) {
        bytes.append(contentsOf: UInt64(bitPattern: value).littleEndianBytes)
    }

    /// Appends a `Double` as its IEEE-754 bit pattern, little-endian, never a decimal rendering.
    /// Traps on a non-finite value: NaN has many bit patterns, so the encoding would not be well
    /// defined.
    public static func appendDouble(_ value: Double, to bytes: inout [UInt8]) {
        precondition(value.isFinite, "canonical encoding requires a finite Double, got \(value)")
        bytes.append(contentsOf: value.bitPattern.littleEndianBytes)
    }
}

/// A value whose canonical bytes this package controls. Separate from `Codable`, which is the
/// document path and renders `Double` as decimal text; `Derived` constrains `Value` to this
/// protocol so a payload that forgets to conform does not compile.
///
/// An implementation must: append only; emit no `CanonicalEncoding.version` byte (the outermost
/// encoding writes it once); keep every field fixed-width little-endian, with `Double` via
/// `appendDouble`; route any variable-length field through `appendLengthPrefixed` and any
/// collection through `appendCount` plus fixed-width elements. The layout is frozen and changes
/// only alongside `CanonicalEncoding.version` and a re-approval path.
public protocol CanonicallyEncodable {
    func encodeCanonically(into bytes: inout [UInt8])
}

// MARK: - Payload conformances
//
// Kept together so "what is digest-significant" is auditable in one place.

extension Int: CanonicallyEncodable {
    /// Eight bytes, two's complement little-endian. Fixed at 64 rather than `Int.bitWidth`, so a
    /// 32-bit target would not change the encoding.
    public func encodeCanonically(into bytes: inout [UInt8]) {
        CanonicalEncoding.appendInt64(Int64(self), to: &bytes)
    }
}

extension String: CanonicallyEncodable {
    /// Length-prefixed raw UTF-8, with no Unicode normalisation.
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
    /// 40 bytes, fixed width: `origin` (16) ‖ `size` (16) ‖ `revision` (8). The revision is
    /// digested because the same numbers under a different display configuration describe a
    /// different physical rectangle.
    public func encodeCanonically(into bytes: inout [UInt8]) {
        origin.encodeCanonically(into: &bytes)
        size.encodeCanonically(into: &bytes)
        revision.encodeCanonically(into: &bytes)
    }
}

extension UInt64 {
    /// Little-endian, fixed at eight bytes, so adjacent fields concatenate without separators and
    /// still parse back unambiguously. `public` so `Graph` uses this writer rather than a second
    /// copy that could drift.
    public var littleEndianBytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: (self >> (8 * UInt64($0))) & 0xff) }
    }
}
