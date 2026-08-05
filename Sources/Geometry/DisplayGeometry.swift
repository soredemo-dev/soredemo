import Foundation

/// The intrinsic geometry of one display: what is needed to interpret a normalised
/// coordinate on it, and nothing else.
///
/// Identified by `displayUUID`, never `CGDirectDisplayID`, which is reassigned across
/// reboot and replug. The app passes the `UUID` in; this module never touches
/// CoreGraphics. Display identity is digested (two identical side-by-side monitors
/// must not collapse to one revision); global arrangement is not (rearranging display
/// B would otherwise invalidate footage from A).
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

    /// The frozen canonical encoding: 41 bytes, fixed width, no separators.
    /// `CanonicalEncoding.version` (1) ‖ `displayUUID` (16, RFC 4122 byte order) ‖
    /// `pixelWidth` (8) ‖ `pixelHeight` (8), little-endian two's complement ‖
    /// `scale.bitPattern` (8, little-endian). Hand-written, not `Codable`, whose byte
    /// and field order are not ours. Changing the layout changes every revision ever
    /// computed, so it changes only alongside `CanonicalEncoding.version`.
    var canonicalBytes: [UInt8] {
        var bytes: [UInt8] = [CanonicalEncoding.version]
        // Expanded by hand: `.strictMemorySafety()` forbids `withUnsafeBytes`. The
        // tuple order is the UUID's network byte order, so this is endian-independent.
        let u = displayUUID.uuid
        bytes.append(contentsOf: [u.0, u.1, u.2,  u.3,  u.4,  u.5,  u.6,  u.7,
                                  u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
        bytes.append(contentsOf: UInt64(bitPattern: Int64(pixelWidth)).littleEndianBytes)
        bytes.append(contentsOf: UInt64(bitPattern: Int64(pixelHeight)).littleEndianBytes)
        // Bit pattern, never a decimal rendering, which is lossy and locale-dependent.
        // The initialiser's precondition makes this well defined: NaN has many bit
        // patterns, so a NaN scale would be many revisions for one value.
        bytes.append(contentsOf: scale.bitPattern.littleEndianBytes)
        return bytes
    }

    /// Stable across processes, machines, and reopens. Not `hashValue`.
    public var revision: GeometryRevision { GeometryRevision(id: fnv1a64(canonicalBytes)) }

    // MARK: - Points ↔ pixels
    //
    // `DisplayGeometry` carries native pixels; `CGDisplayBounds`,
    // `CGEventGetLocation`, and AX frames report points. The two coincide only when
    // `scale == 1`. These two methods are the only sanctioned crossing between
    // `PointRect` and `PixelRect`.

    /// Converts a rect reported in points into this display's native pixels by
    /// multiplying every field by `scale`.
    public func pixels(from rect: PointRect) -> PixelRect {
        PixelRect(x: rect.x * scale, y: rect.y * scale,
                  width: rect.width * scale, height: rect.height * scale)
    }

    /// The inverse of `pixels(from:)`: divides every field by `scale`.
    public func points(from rect: PixelRect) -> PointRect {
        PointRect(x: rect.x / scale, y: rect.y / scale,
                  width: rect.width / scale, height: rect.height / scale)
    }
}

extension DisplayGeometry: Codable {
    /// Matches the synthesised shape exactly, so this hand-written conformance
    /// changes validation, not the wire form.
    private enum CodingKeys: String, CodingKey {
        case displayUUID, pixelWidth, pixelHeight, scale
    }

    /// Untrusted input: re-checks `init`'s preconditions — positive dimensions, finite
    /// positive scale — and throws `DecodingError.dataCorrupted` rather than trapping.
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
