import Foundation
import Geometry
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

/// What sits behind the recorded card.
///
/// **The gradient case is why this is an enum and not three colour fields.** A solid
/// background is what the first renderer could draw, and it is what makes a recording look
/// like a screenshot on a coloured rectangle. Every comparable tool — Screen Studio, a Rust recorder,
/// `../opensource/a Swift recorder` — defaults to a gradient, because the card's shadow has
/// nothing to fall across on a flat fill and the frame reads as unfinished. Adding the case
/// here rather than a `isGradient` flag beside the colours keeps a solid background costing
/// no gradient filter at all, which `aSolidBackgroundDrawsNoGradient` pins.
public enum StageBackground: Hashable, Codable, Sendable {
    case solid(red: Double, green: Double, blue: Double)
    /// Two colours interpolated along a line at `angleDegrees`, measured counter-clockwise
    /// from the +x axis so 0° runs left→right and 90° bottom→top — the CoreImage convention
    /// the renderer works in, stated here so the value means one thing wherever it is read.
    ///
    /// **Interpolated in the working colour space, not in sRGB gamma.** A gradient between
    /// two saturated colours mixed in gamma space passes through a desaturated band in the
    /// middle; the renderer uses `CISmoothLinearGradient`, whose easing also removes the
    /// Mach banding a linear ramp shows on a flat fill.
    case linearGradient(startRed: Double, startGreen: Double, startBlue: Double,
                        endRed: Double, endGreen: Double, endBlue: Double,
                        angleDegrees: Double)

    /// A picture behind the card, by its filename inside the project package.
    ///
    /// **A filename, not a path.** An absolute path is a background that works until the file
    /// is moved, renamed, or the project is opened on another machine — and a wallpaper that
    /// silently becomes black is worse than one that was never offered. The chosen image is
    /// copied into `<package>/backgrounds/` when it is picked, so the background travels with
    /// the recording exactly as the media and the observation log already do.
    ///
    /// **No path separators.** This name is joined to a directory by a renderer; a value
    /// carrying `../` would reach outside the package. `Codable` cannot be trusted to hand back
    /// what was written, so the decoder rejects it — rule 8's case.
    case image(filename: String)

    /// The presets the picker offers. Named rather than anonymous tuples because a project
    /// records which one was chosen and a name survives a value being retuned.
    public static let presets: [(name: String, background: StageBackground)] = [
        ("Charcoal", .solid(red: 0.09, green: 0.09, blue: 0.11)),
        ("Dusk", .linearGradient(startRed: 0.10, startGreen: 0.11, startBlue: 0.22,
                                 endRed: 0.35, endGreen: 0.16, endBlue: 0.36,
                                 angleDegrees: 115)),
        ("Ember", .linearGradient(startRed: 0.38, startGreen: 0.13, startBlue: 0.20,
                                  endRed: 0.86, endGreen: 0.44, endBlue: 0.22,
                                  angleDegrees: 70)),
        ("Tide", .linearGradient(startRed: 0.05, startGreen: 0.24, startBlue: 0.33,
                                 endRed: 0.16, endGreen: 0.55, endBlue: 0.52,
                                 angleDegrees: 60)),
        ("Paper", .linearGradient(startRed: 0.93, startGreen: 0.92, startBlue: 0.89,
                                  endRed: 0.82, endGreen: 0.83, endBlue: 0.85,
                                  angleDegrees: 100)),
    ]

    /// The directory an image background's file lives in, inside the package.
    public static let imageDirectory = "backgrounds"

    /// True when `filename` is a plain name this type will accept.
    ///
    /// Rejects anything with a separator or a leading dot: the name is joined to a directory by
    /// whoever draws it, and `../../etc/passwd` is a filename as far as a string is concerned.
    public static func isSafeImageFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && !filename.hasPrefix(".")
            && !filename.contains("/")
            && !filename.contains("\\")
    }

    public init(from decoder: any Decoder) throws {
        // Hand-written so the image case can be validated. The other two are value-only and
        // decode exactly as the synthesised conformance would.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let solid = try container.decodeIfPresent(Solid.self, forKey: .solid) {
            self = .solid(red: solid.red, green: solid.green, blue: solid.blue)
        } else if let gradient = try container.decodeIfPresent(Gradient.self,
                                                               forKey: .linearGradient) {
            self = .linearGradient(startRed: gradient.startRed, startGreen: gradient.startGreen,
                                   startBlue: gradient.startBlue, endRed: gradient.endRed,
                                   endGreen: gradient.endGreen, endBlue: gradient.endBlue,
                                   angleDegrees: gradient.angleDegrees)
        } else if let image = try container.decodeIfPresent(ImageName.self, forKey: .image) {
            guard Self.isSafeImageFilename(image.filename) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "a background image filename may not contain a path: "
                        + image.filename))
            }
            self = .image(filename: image.filename)
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "no known background case"))
        }
    }

    private enum CodingKeys: String, CodingKey { case solid, linearGradient, image }
    private struct Solid: Codable { let red, green, blue: Double }
    private struct Gradient: Codable {
        let startRed, startGreen, startBlue, endRed, endGreen, endBlue, angleDegrees: Double
    }
    private struct ImageName: Codable { let filename: String }
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

    /// **The camera, as two plain numbers rather than a type.** `CameraState` lives in
    /// `Framing`, and `Render` does not depend on it — nor should it: `Render` is the
    /// deterministic planning tier and `Framing` is a sibling, so a type here would be an
    /// edge in the wrong direction. `Compositing` depends on both and does the conversion.
    ///
    /// The zoom applies to the CONTENT inside the card, never to the card itself: the
    /// rounded window stays where the stage style put it and the recording inside it grows.
    /// Scaling the card would break the inset margin that style exists to keep.
    public let contentZoom: Double
    /// The point in normalised SOURCE coordinates the camera is centred on.
    public let contentCentre: NormalizedPoint

    /// The caption to burn into this frame, or `nil` for none. Resolved per frame rather than
    /// per clip because a caption changes several times a second and the plan is what a frame
    /// is drawn from.
    public let caption: CaptionOverlay?
    /// Text overlays on this frame, back to front. Several at once, unlike the caption: two
    /// captions on screen is a bug and a title over a lower third is a layout.
    public let texts: [TextOverlay]
    /// Parts of the SOURCE to hide, in the source's own normalised coordinates. Applied before
    /// the camera moves the picture — see `RedactionArt`.
    public let redactions: [RedactionRegion]
    /// How the drawn cursor looks. Carried on the plan rather than read from a static by the
    /// renderer, so a frame's appearance is a function of its plan — which is what makes a
    /// render reproducible from one.
    public let cursorStyle: CursorStyle

    public init(outputWidth: Int, outputHeight: Int, card: StageRect, cornerRadius: Double,
                style: StageStyle, pointer: NormalizedPointerPlacement?,
                contentZoom: Double = 1.0,
                contentCentre: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
                caption: CaptionOverlay? = nil,
                texts: [TextOverlay] = [],
                redactions: [RedactionRegion] = [],
                cursorStyle: CursorStyle = .default) {
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.card = card
        self.cornerRadius = cornerRadius
        self.style = style
        self.pointer = pointer
        self.contentZoom = contentZoom
        self.contentCentre = contentCentre
        self.caption = caption
        self.texts = texts
        self.redactions = redactions
        self.cursorStyle = cursorStyle
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
    /// Where inside the drawn art its own hotspot sits, 0…1 of the art's bounding box.
    /// `nil` falls back to the art's path origin, which is right for the arrow and wrong
    /// for everything else — see `PointerSample.hotspot`.
    public let hotspot: NormalizedPoint?

    public init(x: Double, y: Double, ripplePhase: Double?, shape: PointerShape? = nil,
                hotspot: NormalizedPoint? = nil) {
        self.x = x; self.y = y; self.ripplePhase = ripplePhase
        self.shape = shape; self.hotspot = hotspot
    }
}


extension RenderPlan {
    /// Where a normalised source x lands in output pixels, under the camera. **One owner
    /// for the mapping**: the renderer transforms the image by this and `StagePlanner`
    /// places the pointer by it, so the two cannot drift into disagreeing about where a
    /// point is (`thePointerMovesWithTheZoomedContent`).
    ///
    /// At zoom `z` the content is `z`× the card and shifted so `contentCentre` sits at the
    /// card's centre.
    public func contentX(ofNormalised x: Double) -> Double {
        let scaledWidth = card.width * contentZoom
        let originX = card.x + card.width / 2 - contentCentre.x * scaledWidth
        return originX + x * scaledWidth
    }

    public func contentY(ofNormalised y: Double) -> Double {
        let scaledHeight = card.height * contentZoom
        let originY = card.y + card.height / 2 - contentCentre.y * scaledHeight
        return originY + y * scaledHeight
    }
}
