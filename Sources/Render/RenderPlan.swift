import Foundation
// `PointerShape` rides on the placement since the recorder-parity work.
import Project

/// A rectangle in OUTPUT PIXELS, bottom-left origin.
///
/// Not `CGRect`: the package may not name Core Graphics types (D6 rule 2, enforced by the
/// plugin on every build), and the reason is not stylistic — `CGRect` in the package is how a
/// pixel value crosses a module boundary without anyone converting it.
public struct StageRect: Hashable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        precondition(x.isFinite && y.isFinite && width.isFinite && height.isFinite,
                     "StageRect requires finite components, got \(x) \(y) \(width) \(height)")
        precondition(width >= 0 && height >= 0,
                     "StageRect requires non-negative extent, got \(width)x\(height)")
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

extension StageRect {
    /// Matches the synthesised shape exactly — `x`, `y`, `width`, `height` — so
    /// this hand-written conformance changes validation, not the wire form. Same
    /// shape as `HostRange.init(from:)` / `DisplayGeometry.init(from:)`: rule 8
    /// (ARCHITECTURE.md D6, D2-14) requires a validating decoder initialiser on any
    /// `Codable` type whose memberwise `init` preconditions, because the synthesised
    /// `init(from:)` assigns stored properties directly and never calls it. The
    /// architecture-checker plugin refuses a `StageRect` written without it.
    private enum CodingKeys: String, CodingKey {
        case x, y, width, height
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Double.self, forKey: .x)
        let y = try container.decode(Double.self, forKey: .y)
        let width = try container.decode(Double.self, forKey: .width)
        let height = try container.decode(Double.self, forKey: .height)
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "StageRect requires finite components, got \(x) \(y) \(width) \(height)"))
        }
        guard width >= 0 && height >= 0 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "StageRect requires non-negative extent, got \(width)x\(height)"))
        }
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
    }
}

public enum StageBackground: Hashable, Codable, Sendable {
    case solid(red: Double, green: Double, blue: Double)
}

public struct StageStyle: Hashable, Codable, Sendable {
    public let insetFraction: Double
    public let cornerRadius: Double
    public let shadowRadius: Double
    public let shadowOpacity: Double
    public let background: StageBackground

    public static let `default` = StageStyle(
        insetFraction: 0.06, cornerRadius: 18, shadowRadius: 32, shadowOpacity: 0.35,
        background: .solid(red: 0.09, green: 0.09, blue: 0.11))

    public init(insetFraction: Double, cornerRadius: Double, shadowRadius: Double,
                shadowOpacity: Double, background: StageBackground) {
        precondition(insetFraction >= 0 && insetFraction < 0.5,
                     "insetFraction must be in [0, 0.5), got \(insetFraction)")
        self.insetFraction = insetFraction
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.background = background
    }
}

extension StageStyle {
    /// Matches the synthesised shape exactly — `insetFraction`, `cornerRadius`,
    /// `shadowRadius`, `shadowOpacity`, `background` — so this hand-written
    /// conformance changes validation, not the wire form. Same rule-8 reason as
    /// `StageRect.init(from:)` above.
    private enum CodingKeys: String, CodingKey {
        case insetFraction, cornerRadius, shadowRadius, shadowOpacity, background
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let insetFraction = try container.decode(Double.self, forKey: .insetFraction)
        let cornerRadius = try container.decode(Double.self, forKey: .cornerRadius)
        let shadowRadius = try container.decode(Double.self, forKey: .shadowRadius)
        let shadowOpacity = try container.decode(Double.self, forKey: .shadowOpacity)
        let background = try container.decode(StageBackground.self, forKey: .background)
        guard insetFraction >= 0 && insetFraction < 0.5 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "insetFraction must be in [0, 0.5), got \(insetFraction)"))
        }
        self.insetFraction = insetFraction
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.background = background
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(insetFraction, forKey: .insetFraction)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(shadowRadius, forKey: .shadowRadius)
        try container.encode(shadowOpacity, forKey: .shadowOpacity)
        try container.encode(background, forKey: .background)
    }
}

/// Everything a renderer needs to draw one frame, and nothing about HOW.
///
/// The pointer is optional because the track can be silent — see `PointerTrack.position(at:)`
/// and `BlindInterval`. A `nil` pointer means "draw none", never "draw the last one".
public struct RenderPlan: Hashable, Sendable {
    public let outputWidth: Int
    public let outputHeight: Int
    public let card: StageRect
    public let cornerRadius: Double
    public let style: StageStyle
    public let pointer: NormalizedPointerPlacement?

    public init(outputWidth: Int, outputHeight: Int, card: StageRect, cornerRadius: Double,
                style: StageStyle, pointer: NormalizedPointerPlacement?) {
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.card = card
        self.cornerRadius = cornerRadius
        self.style = style
        self.pointer = pointer
    }
}

/// Where the drawn pointer goes, in OUTPUT pixels, with the click state that decides the ripple.
public struct NormalizedPointerPlacement: Hashable, Sendable {
    public let x: Double
    public let y: Double
    /// 0 at the click instant, rising to 1 as the ripple finishes. `nil` when not clicking.
    public let ripplePhase: Double?
    /// The classified system-cursor shape at the sample being drawn; `nil` is
    /// "unrecorded" and renders as the arrow, same as `.other` — see `PointerShape`.
    public let shape: PointerShape?

    public init(x: Double, y: Double, ripplePhase: Double?, shape: PointerShape? = nil) {
        self.x = x; self.y = y; self.ripplePhase = ripplePhase; self.shape = shape
    }
}
