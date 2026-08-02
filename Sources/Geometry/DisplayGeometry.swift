import Foundation

/// The intrinsic geometry of one display: what is needed to interpret a
/// normalised coordinate on it, and nothing else.
///
/// **`displayUUID`, never `CGDirectDisplayID`** (D-P2). The window server assigns
/// display IDs dynamically; they are not stable across reboot or replug. Digesting
/// one would make this decision's own justification false — record Monday, reboot,
/// record Tuesday on the same monitor at the same resolution, and one document
/// holds two revisions for identical geometry, which is exactly the false trap a
/// monotonic counter scheme was rejected for. The persistent identity is
/// `CGDisplayCreateUUIDFromDisplayID`, looked up in the app, bridged to a
/// Foundation `UUID`, and passed in here as a plain value. This module never
/// touches CoreGraphics.
///
/// Display identity stays *in* the digest: two identical monitors side by side
/// would otherwise collapse to one revision, and "40% across *a* display" is not
/// a comparable coordinate when there are two.
///
/// Global arrangement stays *out* — see `DisplayArrangement` in the design doc.
/// `CGDisplayBounds` origins shift when the arrangement changes, so digesting
/// them would let rearranging display B silently invalidate footage from A.
public struct DisplayGeometry: Hashable, Sendable {
    public let displayUUID: UUID
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scale: Double

    public init(displayUUID: UUID, pixelWidth: Int, pixelHeight: Int, scale: Double) {
        precondition(pixelWidth > 0 && pixelHeight > 0,
                     "display must have positive dimensions, got \(pixelWidth)×\(pixelHeight)")
        precondition(scale.isFinite && scale > 0,
                     "scale must be finite and positive, got \(scale)")
        self.displayUUID = displayUUID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
    }

    /// The frozen canonical encoding. 41 bytes, fixed width, no separators:
    ///
    /// | offset | bytes | field |
    /// | --- | --- | --- |
    /// | 0 | 1 | `CanonicalEncoding.version` |
    /// | 1 | 16 | `displayUUID`, RFC 4122 byte order |
    /// | 17 | 8 | `pixelWidth`, little-endian two's complement |
    /// | 25 | 8 | `pixelHeight`, little-endian two's complement |
    /// | 33 | 8 | `scale.bitPattern`, little-endian |
    ///
    /// Hand-written rather than routed through `Codable`: synthesised encoding is
    /// not a stable contract, and its byte order and field order are not ours.
    /// Changing this layout changes every revision ever computed, so it changes
    /// only alongside `CanonicalEncoding.version`.
    var canonicalBytes: [UInt8] {
        var bytes: [UInt8] = [CanonicalEncoding.version]
        // Expanded explicitly rather than via `withUnsafeBytes`, because
        // `.strictMemorySafety()` is enabled package-wide. The tuple order is
        // the UUID's own network byte order, so this is endian-independent.
        let u = displayUUID.uuid
        bytes.append(contentsOf: [u.0, u.1, u.2,  u.3,  u.4,  u.5,  u.6,  u.7,
                                  u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
        bytes.append(contentsOf: UInt64(bitPattern: Int64(pixelWidth)).littleEndianBytes)
        bytes.append(contentsOf: UInt64(bitPattern: Int64(pixelHeight)).littleEndianBytes)
        // Bit pattern, never a decimal rendering: `"\(scale)"` is a lossy,
        // locale- and formatter-dependent view of the value. The initialiser's
        // precondition is what makes this well defined — NaN has many bit
        // patterns, so a NaN scale would be two revisions for one value.
        bytes.append(contentsOf: scale.bitPattern.littleEndianBytes)
        return bytes
    }

    /// Stable across processes, machines, and reopens. Not `hashValue`.
    public var revision: GeometryRevision { GeometryRevision(id: fnv1a64(canonicalBytes)) }

    // MARK: - Points ↔ pixels (Task 10.5)
    //
    // `DisplayGeometry` carries native pixels; `CGDisplayBounds`,
    // `CGEventGetLocation`, and AX frames report points. The two coincide
    // only when `scale == 1`, which is why every Phase 1 fixture that used
    // `scale: 1` could compare them directly and still pass. These two
    // methods are the only sanctioned crossing between `PointRect` and
    // `PixelRect` (see both types' documentation) — named so the direction
    // is unmistakable at the call site: `pixels(from:)` returns pixels,
    // `points(from:)` returns points.

    /// Converts a rect reported in points — `CGDisplayBounds`,
    /// `CGEventGetLocation`, an AX frame — into this display's native
    /// pixels, by multiplying every field by `scale`.
    public func pixels(from rect: PointRect) -> PixelRect {
        PixelRect(x: rect.x * scale, y: rect.y * scale,
                  width: rect.width * scale, height: rect.height * scale)
    }

    /// The inverse of `pixels(from:)`: converts a rect in this display's
    /// native pixels back into points, by dividing every field by `scale`.
    public func points(from rect: PixelRect) -> PointRect {
        PointRect(x: rect.x / scale, y: rect.y / scale,
                  width: rect.width / scale, height: rect.height / scale)
    }
}

extension DisplayGeometry: Codable {
    /// Matches the synthesised shape exactly — `displayUUID`, `pixelWidth`,
    /// `pixelHeight`, `scale` — so this hand-written conformance changes
    /// validation, not the wire form.
    private enum CodingKeys: String, CodingKey {
        case displayUUID, pixelWidth, pixelHeight, scale
    }

    /// Untrusted input: decodes the four fields into a keyed container
    /// identical to synthesis's, then re-checks both of `init`'s
    /// preconditions — positive dimensions, and a finite positive scale —
    /// and throws `DecodingError.dataCorrupted` rather than trapping. Same
    /// shape as `HostRange.init(from:)`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let displayUUID = try container.decode(UUID.self, forKey: .displayUUID)
        let pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        let pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        let scale = try container.decode(Double.self, forKey: .scale)
        guard pixelWidth > 0 && pixelHeight > 0 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "DisplayGeometry must have positive dimensions, got \(pixelWidth)×\(pixelHeight)"))
        }
        guard scale.isFinite && scale > 0 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "DisplayGeometry scale must be finite and positive, got \(scale)"))
        }
        self.displayUUID = displayUUID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayUUID, forKey: .displayUUID)
        try container.encode(pixelWidth, forKey: .pixelWidth)
        try container.encode(pixelHeight, forKey: .pixelHeight)
        try container.encode(scale, forKey: .scale)
    }
}
