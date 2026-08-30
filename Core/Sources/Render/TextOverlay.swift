import Foundation

/// Where a piece of text sits horizontally, and what its `x` refers to.
public enum TextAnchor: String, Hashable, Codable, Sendable, CaseIterable {
    case leading, center, trailing

    public var displayName: String {
        switch self {
        case .leading: "Left"
        case .center: "Centre"
        case .trailing: "Right"
        }
    }
}

/// How a piece of text drawn over the picture looks and where it goes.
///
/// **Fractions of the output, for the reason `CaptionStyle` gives**: the same recording is
/// re-rendered at 1920, at 640 for a GIF, and at whatever a portrait variant works out to, and a
/// title specified in points is right in exactly one of them.
///
/// `y` is measured from the BOTTOM, like CoreGraphics and unlike AppKit views. Getting that
/// wrong puts a title on the wrong half of the frame, which is the sort of thing that survives
/// review because it looks deliberate.
///
/// **A deliberate subset of what a text style could carry.** A fuller version has
/// width/height axis scaling, tracking, line spacing, underline, strikethrough, overline, a
/// separate glyph outline with its own colour, a background with independent x/y padding and its
/// own outline, and a font-name field. Every one of those is a control a person has to
/// understand before they can put a word on the screen. What is here is what a title needs:
/// size, position, weight, colour, something to keep it legible over a busy screen.
public struct TextOverlayStyle: Hashable, Codable, Sendable {
    /// Type size as a fraction of the frame's height.
    public let heightFraction: Double
    /// 0…1 across the frame. What it points at depends on `anchor`.
    public let x: Double
    /// 0…1 up from the BOTTOM of the frame, to the bottom edge of the text's plate.
    public let y: Double
    public let anchor: TextAnchor
    public let isBold: Bool
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double
    /// The plate behind the text. 0 draws none.
    public let plateOpacity: Double
    public let plateCornerFraction: Double
    public let plateRed: Double
    public let plateGreen: Double
    public let plateBlue: Double
    /// A font file inside the project, or `nil` for the system's own.
    ///
    /// The FILE rather than an installed name: a name that is not installed on the machine the
    /// project is opened on falls back silently to something of a different width. A file
    /// travels with the project. `TextArt.font` resolves it and falls back when it will not
    /// load, which is safe only because line breaking measures through the same function.
    public let fontFilename: String?
    /// The outline drawn around each glyph, as a fraction of the type size, and its colour.
    ///
    /// **The half of legibility that does not cover the picture.** A plate is a rectangle across
    /// the frame and a shadow is a soft edge; an outline follows the letterforms, so it works
    /// over footage that is light in one part of the line and dark in another — the case a plate
    /// exists for and the case a shadow handles worst.
    ///
    /// Drawn by Core Text's own `strokeWidth`, a PERCENTAGE OF THE TYPE SIZE and therefore
    /// already the fraction this file expresses everything in; negative there means "fill and
    /// stroke", positive would leave the letters hollow. **Centred on the glyph outline, not
    /// outside it** — Core Text strokes down the middle of the path, so half the width eats into
    /// the letterform and a wide outline thins the type. The cap is set where that is invisible;
    /// drawing it outside would mean a second layout, which `line(...)` exists to avoid.
    public let outlineWidthFraction: Double
    public let outlineRed: Double
    public let outlineGreen: Double
    public let outlineBlue: Double
    /// A drop shadow under the glyphs. **The cheapest thing that keeps white text legible over a
    /// white window**, and the reason it is here when tracking and underline are not.
    public let shadowOpacity: Double
    public let shadowBlurFraction: Double
    /// The widest a line may be measured against, as a fraction of the frame's width.
    public let maximumWidthFraction: Double
    /// Gap between lines, as a fraction of the type size.
    public let lineGapRatio: Double

    public static let `default` = TextOverlayStyle(
        heightFraction: 0.075, x: 0.5, y: 0.55, anchor: .center, isBold: true,
        red: 1, green: 1, blue: 1, alpha: 1,
        plateOpacity: 0, plateCornerFraction: 0.02,
        plateRed: 0, plateGreen: 0, plateBlue: 0,
        shadowOpacity: 0.5, shadowBlurFraction: 0.008,
        maximumWidthFraction: 0.86, lineGapRatio: 0.2)

    public init(heightFraction: Double, x: Double, y: Double, anchor: TextAnchor,
                isBold: Bool, red: Double, green: Double, blue: Double, alpha: Double,
                plateOpacity: Double, plateCornerFraction: Double,
                plateRed: Double, plateGreen: Double, plateBlue: Double,
                shadowOpacity: Double, shadowBlurFraction: Double,
                maximumWidthFraction: Double, lineGapRatio: Double,
                outlineWidthFraction: Double = 0,
                outlineRed: Double = 0, outlineGreen: Double = 0, outlineBlue: Double = 0,
                fontFilename: String? = nil) {
        // Clamped rather than trapped, for `CaptionStyle`'s reason: every one of these arrives
        // from a slider AND from a decoder, and rule 8 forbids trapping on an untrusted input.
        self.heightFraction = min(max(heightFraction, 0.005), 0.6)
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.anchor = anchor
        self.isBold = isBold
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
        self.plateOpacity = min(max(plateOpacity, 0), 1)
        self.plateCornerFraction = min(max(plateCornerFraction, 0), 0.5)
        self.plateRed = min(max(plateRed, 0), 1)
        self.plateGreen = min(max(plateGreen, 0), 1)
        self.plateBlue = min(max(plateBlue, 0), 1)
        // 0.14 of the type size, which is thick by any published caption standard and is the
        // point past which the centred stroke visibly thins the letters. A cap here rather than
        // in the slider: the value also arrives from a decoder.
        // Refused rather than sanitised: a name with a slash in it is not a filename somebody
        // typed slightly wrong, and repairing it would be inventing a file to look for.
        self.fontFilename = fontFilename.flatMap {
            StageBackground.isSafeImageFilename($0) ? $0 : nil
        }
        self.outlineWidthFraction = min(max(outlineWidthFraction, 0), 0.14)
        self.outlineRed = min(max(outlineRed, 0), 1)
        self.outlineGreen = min(max(outlineGreen, 0), 1)
        self.outlineBlue = min(max(outlineBlue, 0), 1)
        self.shadowOpacity = min(max(shadowOpacity, 0), 1)
        self.shadowBlurFraction = min(max(shadowBlurFraction, 0), 0.1)
        self.maximumWidthFraction = min(max(maximumWidthFraction, 0.1), 1)
        self.lineGapRatio = min(max(lineGapRatio, 0), 2)
    }

    private enum CodingKeys: String, CodingKey {
        case heightFraction, x, y, anchor, isBold
        case red, green, blue, alpha
        case plateOpacity, plateCornerFraction, plateRed, plateGreen, plateBlue
        case outlineWidthFraction, outlineRed, outlineGreen, outlineBlue
        case shadowOpacity, shadowBlurFraction, maximumWidthFraction, lineGapRatio
        case fontFilename
    }

    /// **Every field optional, routed through the clamping initialiser** — `CaptionStyle`'s
    /// reason, and the same near-miss. A synthesised decode requires every key, so the outline
    /// fields could not have been added without every saved text overlay ceasing to decode; and
    /// it assigns past the clamping, so a corrupt file could put a stroke wider than the type
    /// into Core Text.
    ///
    /// The fallbacks are what the field meant before it existed: no outline is `0`, which is
    /// what every overlay written until now had.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ fallback: Double) throws -> Double {
            try container.decodeIfPresent(Double.self, forKey: key) ?? fallback
        }
        self.init(
            heightFraction: try value(.heightFraction, 0.05),
            x: try value(.x, 0.5), y: try value(.y, 0.5),
            anchor: try container.decodeIfPresent(TextAnchor.self, forKey: .anchor) ?? .center,
            isBold: try container.decodeIfPresent(Bool.self, forKey: .isBold) ?? false,
            red: try value(.red, 1), green: try value(.green, 1), blue: try value(.blue, 1),
            alpha: try value(.alpha, 1),
            plateOpacity: try value(.plateOpacity, 0),
            plateCornerFraction: try value(.plateCornerFraction, 0),
            plateRed: try value(.plateRed, 0), plateGreen: try value(.plateGreen, 0),
            plateBlue: try value(.plateBlue, 0),
            shadowOpacity: try value(.shadowOpacity, 0),
            shadowBlurFraction: try value(.shadowBlurFraction, 0),
            maximumWidthFraction: try value(.maximumWidthFraction, 0.9),
            lineGapRatio: try value(.lineGapRatio, 0.2),
            outlineWidthFraction: try value(.outlineWidthFraction, 0),
            outlineRed: try value(.outlineRed, 0),
            outlineGreen: try value(.outlineGreen, 0),
            outlineBlue: try value(.outlineBlue, 0),
            fontFilename: try container.decodeIfPresent(String.self, forKey: .fontFilename))
    }

    public func pointSize(forOutputHeight height: Int) -> Double {
        Double(height) * heightFraction
    }

    public func maximumWidth(forOutputWidth width: Int) -> Double {
        Double(width) * maximumWidthFraction
    }

    /// The same style with one field changed. Written once because the initialiser takes
    /// eighteen arguments and a UI that repeated it per slider would be eighteen chances to
    /// pass `green` where `blue` belongs.
    public func changing(heightFraction: Double? = nil, x: Double? = nil, y: Double? = nil,
                         anchor: TextAnchor? = nil, isBold: Bool? = nil,
                         red: Double? = nil, green: Double? = nil, blue: Double? = nil,
                         alpha: Double? = nil, plateOpacity: Double? = nil,
                         shadowOpacity: Double? = nil) -> TextOverlayStyle {
        TextOverlayStyle(
            heightFraction: heightFraction ?? self.heightFraction,
            x: x ?? self.x, y: y ?? self.y, anchor: anchor ?? self.anchor,
            isBold: isBold ?? self.isBold,
            red: red ?? self.red, green: green ?? self.green, blue: blue ?? self.blue,
            alpha: alpha ?? self.alpha,
            plateOpacity: plateOpacity ?? self.plateOpacity,
            plateCornerFraction: plateCornerFraction,
            plateRed: plateRed, plateGreen: plateGreen, plateBlue: plateBlue,
            shadowOpacity: shadowOpacity ?? self.shadowOpacity,
            shadowBlurFraction: shadowBlurFraction,
            maximumWidthFraction: maximumWidthFraction, lineGapRatio: lineGapRatio)
    }
}

/// How a piece of text arrives and leaves.
///
/// **A title that is simply there is a title nobody notices arriving.** Comparable tools
/// animate them — fade, rise, pop, slide, typewriter — and the reason is that a
/// whole `TextAnimator`. What is here is the four that read at a glance; a typewriter is the one
/// people ask for and the one that makes a two-second title take two seconds to become readable.
///
/// **The animation is a function of PROGRESS, not of time.** A caller hands in how far through
/// the lead-in or lead-out the frame is, so the same animation works at any duration and at any
/// frame rate — and an export at 60 fps and a preview at 30 produce the same picture.
public enum TextAnimation: String, Hashable, Codable, Sendable, CaseIterable {
    case none, fade, rise, pop

    public var displayName: String {
        switch self {
        case .none: "None"
        case .fade: "Fade"
        case .rise: "Rise"
        case .pop: "Pop"
        }
    }

    /// How long the entrance and the exit each take, as a fraction of the item's own duration —
    /// capped in seconds so a ten-second title does not spend two seconds arriving.
    public static let durationFraction: Double = 0.2
    public static let maximumSeconds: Double = 0.35

    /// The opacity, vertical offset (in multiples of the type size) and scale at `progress`,
    /// where 0 is "not yet on" and 1 is "fully on".
    ///
    /// `pop` overshoots deliberately: a scale that eases to 1 without passing it reads as a
    /// zoom, and the overshoot is what makes it read as a pop. It is small — 6% — because the
    /// same curve at 20% reads as a bounce, which is a different and more annoying thing.
    public func state(at progress: Double) -> (opacity: Double, rise: Double, scale: Double) {
        let p = min(max(progress, 0), 1)
        // Ease-out cubic: fast at the start, settling at the end. Motion that arrives slowly and
        // stops abruptly reads as a stutter.
        let eased = 1 - pow(1 - p, 3)
        switch self {
        case .none: return (1, 0, 1)
        case .fade: return (eased, 0, 1)
        case .rise: return (eased, (1 - eased) * 0.35, 1)
        case .pop:
            let overshoot = p >= 1 ? 1 : 1 + 0.06 * sin(p * .pi)
            return (eased, 0, 0.88 + 0.12 * eased * overshoot)
        }
    }
}

/// One piece of text to draw on this frame. Lines are split on `\n` and nothing else — a title
/// is short and its breaks are a decision, unlike a caption's, which `CaptionBuilder` computes.
public struct TextOverlay: Hashable, Sendable {
    public let text: String
    public let style: TextOverlayStyle
    /// The entrance or exit state for this frame — `(1, 0, 1)` when the text is simply on.
    public let animation: (opacity: Double, rise: Double, scale: Double)

    public init(text: String, style: TextOverlayStyle,
                animation: (opacity: Double, rise: Double, scale: Double) = (1, 0, 1)) {
        self.text = text
        self.style = style
        self.animation = animation
    }

    // Tuples are not `Hashable`, so the conformance is written out. Kept rather than boxing the
    // three into a struct: they are read once per frame by the renderer and a type here would be
    // a name for something with no behaviour.
    public static func == (lhs: TextOverlay, rhs: TextOverlay) -> Bool {
        lhs.text == rhs.text && lhs.style == rhs.style
            && lhs.animation == rhs.animation
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(text)
        hasher.combine(style)
        hasher.combine(animation.opacity)
        hasher.combine(animation.rise)
        hasher.combine(animation.scale)
    }
}

extension CaptionStyle {
    /// A caption IS a piece of text: centred, at the bottom, on a black plate.
    ///
    /// **One drawing path, not two.** The alternative was a second renderer for titles that
    /// happened to lay text out the same way, and two of those diverge — the plate padding gets
    /// tuned in one and not the other, and nobody notices until a screenshot puts them side by
    /// side.
    public var asTextStyle: TextOverlayStyle {
        // **Six literals used to sit here**, and each one was a control a person could not
        // reach: the caption was always centred, always at mid-frame, never bold, always on a
        // black plate, and never had a shadow. `TextOverlayStyle` could draw all of it the
        // whole time; only the conversion said otherwise.
        TextOverlayStyle(
            heightFraction: heightFraction, x: horizontalFraction, y: bottomInsetFraction,
            anchor: alignment,
            isBold: isBold, red: red, green: green, blue: blue, alpha: 1,
            plateOpacity: backgroundOpacity, plateCornerFraction: backgroundCornerFraction,
            plateRed: plateRed, plateGreen: plateGreen, plateBlue: plateBlue,
            shadowOpacity: shadowOpacity, shadowBlurFraction: shadowBlurFraction,
            maximumWidthFraction: maximumWidthFraction, lineGapRatio: 0.2,
            outlineWidthFraction: outlineWidthFraction, outlineRed: outlineRed,
            outlineGreen: outlineGreen, outlineBlue: outlineBlue,
            fontFilename: fontFilename)
    }
}
