import Foundation

/// How a burnt-in caption looks. Fractions of the OUTPUT, never pixels.
///
/// **Everything is a fraction of the frame's height, and that is the whole point.** A caption
/// sized in points is right at one export size and wrong at every other, and this project
/// re-renders the same recording at 1920, at 640 for a GIF, and at whatever a portrait variant
/// works out to. A caption specified in fractions is the same caption in all of them.
///
/// Height rather than width, for the font: a line of text scaled by the frame's WIDTH gets
/// taller when a landscape recording is exported as portrait, which is backwards.
public struct CaptionStyle: Hashable, Codable, Sendable {
    /// Cap height of the type as a fraction of the frame's height. 0.045 is roughly what a
    /// broadcast caption occupies.
    public let heightFraction: Double
    /// The gap between the caption's baseline box and the bottom of the frame.
    public let bottomInsetFraction: Double
    /// The widest a line may be before `CaptionBuilder` breaks it.
    public let maximumWidthFraction: Double
    /// The plate behind the text. 0 draws none — legible over a dark recording, unreadable over
    /// a white one, which is why the default is not 0.
    public let backgroundOpacity: Double
    /// The plate's corner radius, as a fraction of the frame's height, so it scales too.
    public let backgroundCornerFraction: Double
    public let red: Double
    public let green: Double
    public let blue: Double
    /// Which edge the caption is aligned to, and where across the frame it sits.
    ///
    /// **Both, because one without the other cannot express what people ask for.** Alignment
    /// alone puts every caption at the middle; a position alone leaves a left-aligned block
    /// growing rightwards off the frame. `TextOverlayStyle` has carried the pair since it
    /// shipped and the caption conversion was passing `x: 0.5, anchor: .center` as literals.
    public let alignment: TextAnchor
    public let horizontalFraction: Double
    /// Heavier type, which is the usual answer for a caption over moving footage.
    public let isBold: Bool
    /// The plate's colour. Black was a literal in the conversion until now, which is right for
    /// most footage and wrong for a light brand.
    public let plateRed: Double
    public let plateGreen: Double
    public let plateBlue: Double
    /// A drop shadow behind the text, as a fraction of full opacity and a blur in fractions of
    /// the frame's height.
    ///
    /// **The cheap half of legibility over arbitrary footage.** A plate is the other half and
    /// costs a rectangle across the picture; a shadow separates the text from what is behind it
    /// without covering anything. `TextOverlayStyle` could already draw one and captions were
    /// passing zero.
    public let shadowOpacity: Double
    public let shadowBlurFraction: Double
    /// A font file inside the project, or `nil` for the system's own. See
    /// `TextOverlayStyle.fontFilename`.
    public let fontFilename: String?
    /// The outline around each letter, as a fraction of the type size, and its colour.
    /// See `TextOverlayStyle.outlineWidthFraction` for what it costs and why it is centred.
    public let outlineWidthFraction: Double
    public let outlineRed: Double
    public let outlineGreen: Double
    public let outlineBlue: Double
    /// **Highlight the word being said.** The recogniser gives a time for every word and until
    /// now nothing read them — `TranscribedWord.start`/`.end` were stored, retimed through cuts,
    /// clipped at cut boundaries, and never drawn. Comparable editors all
    /// animate captions word by word; it is the single thing that makes a burnt-in caption look
    /// authored rather than pasted on.
    public let highlightsSpokenWord: Bool
    /// What the words not being said look like, as a fraction of full opacity. Dimmed rather
    /// than hidden: a caption whose other words vanish is one a person cannot read ahead in, and
    /// reading ahead is how anyone follows one.
    public let unspokenOpacity: Double

    public static let `default` = CaptionStyle(
        heightFraction: 0.045, bottomInsetFraction: 0.07, maximumWidthFraction: 0.9,
        backgroundOpacity: 0.55, backgroundCornerFraction: 0.012,
        red: 1, green: 1, blue: 1,
        highlightsSpokenWord: false, unspokenOpacity: 0.55)

    public init(heightFraction: Double, bottomInsetFraction: Double,
                maximumWidthFraction: Double, backgroundOpacity: Double,
                backgroundCornerFraction: Double,
                red: Double, green: Double, blue: Double,
                highlightsSpokenWord: Bool = false, unspokenOpacity: Double = 0.55,
                alignment: TextAnchor = .center, horizontalFraction: Double = 0.5,
                isBold: Bool = false,
                plateRed: Double = 0, plateGreen: Double = 0, plateBlue: Double = 0,
                shadowOpacity: Double = 0, shadowBlurFraction: Double = 0,
                outlineWidthFraction: Double = 0, outlineRed: Double = 0,
                outlineGreen: Double = 0, outlineBlue: Double = 0,
                fontFilename: String? = nil) {
        // Clamped rather than trapped: every one of these reaches here from a slider, and a
        // style is also decoded from a saved project — rule 8 says never `precondition` on an
        // untrusted input. Clamping is the same answer on both paths, so there is one path.
        self.heightFraction = min(max(heightFraction, 0.005), 0.5)
        self.bottomInsetFraction = min(max(bottomInsetFraction, 0), 0.9)
        self.maximumWidthFraction = min(max(maximumWidthFraction, 0.1), 1)
        self.backgroundOpacity = min(max(backgroundOpacity, 0), 1)
        self.backgroundCornerFraction = min(max(backgroundCornerFraction, 0), 0.5)
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.highlightsSpokenWord = highlightsSpokenWord
        // Floored well above zero: at 0 the unspoken words disappear and the caption becomes one
        // word at a time, which is a different feature and a worse one to arrive at by accident.
        self.unspokenOpacity = min(max(unspokenOpacity, 0.15), 1)
        self.alignment = alignment
        self.horizontalFraction = min(max(horizontalFraction, 0), 1)
        self.isBold = isBold
        self.plateRed = min(max(plateRed, 0), 1)
        self.plateGreen = min(max(plateGreen, 0), 1)
        self.plateBlue = min(max(plateBlue, 0), 1)
        self.shadowOpacity = min(max(shadowOpacity, 0), 1)
        // Floored at zero and capped well below the frame: a blur wider than the text is a
        // smear rather than a shadow, and a very large one is minutes of Core Image per frame.
        self.shadowBlurFraction = min(max(shadowBlurFraction, 0), 0.05)
        self.fontFilename = fontFilename.flatMap {
            StageBackground.isSafeImageFilename($0) ? $0 : nil
        }
        self.outlineWidthFraction = min(max(outlineWidthFraction, 0), 0.14)
        self.outlineRed = min(max(outlineRed, 0), 1)
        self.outlineGreen = min(max(outlineGreen, 0), 1)
        self.outlineBlue = min(max(outlineBlue, 0), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case heightFraction, bottomInsetFraction, maximumWidthFraction
        case backgroundOpacity, backgroundCornerFraction
        case red, green, blue, highlightsSpokenWord, unspokenOpacity
        case alignment, horizontalFraction, isBold
        case plateRed, plateGreen, plateBlue, shadowOpacity, shadowBlurFraction
        case outlineWidthFraction, outlineRed, outlineGreen, outlineBlue
        case fontFilename
    }

    /// **Every field optional on the way in, and routed through the clamping initialiser.**
    ///
    /// Two things the synthesised decode got wrong, and adding fields made the first fatal. A
    /// synthesised decode requires every key, so a project saved before these existed would have
    /// stopped opening — every project anybody has. And it assigns straight past the clamping
    /// above, so a corrupt file could set a height of a thousand and this would carry it into the
    /// renderer. `decodeIfPresent` and one constructor answer both.
    ///
    /// The defaults are `CaptionStyle.default`'s, not zeroes: a missing key means the field did
    /// not exist when the file was written, and what it looked like then is what the default was.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ fallback: Double) throws -> Double {
            try container.decodeIfPresent(Double.self, forKey: key) ?? fallback
        }
        let fallback = CaptionStyle.default
        self.init(
            heightFraction: try value(.heightFraction, fallback.heightFraction),
            bottomInsetFraction: try value(.bottomInsetFraction, fallback.bottomInsetFraction),
            maximumWidthFraction: try value(.maximumWidthFraction, fallback.maximumWidthFraction),
            backgroundOpacity: try value(.backgroundOpacity, fallback.backgroundOpacity),
            backgroundCornerFraction: try value(.backgroundCornerFraction,
                                                fallback.backgroundCornerFraction),
            red: try value(.red, fallback.red),
            green: try value(.green, fallback.green),
            blue: try value(.blue, fallback.blue),
            highlightsSpokenWord: try container.decodeIfPresent(
                Bool.self, forKey: .highlightsSpokenWord) ?? fallback.highlightsSpokenWord,
            unspokenOpacity: try value(.unspokenOpacity, fallback.unspokenOpacity),
            alignment: try container.decodeIfPresent(TextAnchor.self, forKey: .alignment)
                ?? fallback.alignment,
            horizontalFraction: try value(.horizontalFraction, fallback.horizontalFraction),
            isBold: try container.decodeIfPresent(Bool.self, forKey: .isBold) ?? fallback.isBold,
            plateRed: try value(.plateRed, fallback.plateRed),
            plateGreen: try value(.plateGreen, fallback.plateGreen),
            plateBlue: try value(.plateBlue, fallback.plateBlue),
            shadowOpacity: try value(.shadowOpacity, fallback.shadowOpacity),
            shadowBlurFraction: try value(.shadowBlurFraction, fallback.shadowBlurFraction),
            outlineWidthFraction: try value(.outlineWidthFraction,
                                            fallback.outlineWidthFraction),
            outlineRed: try value(.outlineRed, fallback.outlineRed),
            outlineGreen: try value(.outlineGreen, fallback.outlineGreen),
            outlineBlue: try value(.outlineBlue, fallback.outlineBlue),
            fontFilename: try container.decodeIfPresent(String.self, forKey: .fontFilename))
    }

    /// The same style with one field changed — `TextOverlayStyle.changing`'s shape, for its
    /// reason: a nine-argument initialiser repeated per control is nine chances to misplace one.
    public func changing(heightFraction: Double? = nil, bottomInsetFraction: Double? = nil,
                         backgroundOpacity: Double? = nil,
                         highlightsSpokenWord: Bool? = nil,
                         unspokenOpacity: Double? = nil,
                         red: Double? = nil, green: Double? = nil, blue: Double? = nil,
                         alignment: TextAnchor? = nil, horizontalFraction: Double? = nil,
                         isBold: Bool? = nil,
                         plateRed: Double? = nil, plateGreen: Double? = nil,
                         plateBlue: Double? = nil,
                         shadowOpacity: Double? = nil,
                         shadowBlurFraction: Double? = nil,
                         outlineWidthFraction: Double? = nil,
                         outlineRed: Double? = nil, outlineGreen: Double? = nil,
                         outlineBlue: Double? = nil,
                         fontFilename: String?? = nil) -> CaptionStyle {
        CaptionStyle(heightFraction: heightFraction ?? self.heightFraction,
                     bottomInsetFraction: bottomInsetFraction ?? self.bottomInsetFraction,
                     maximumWidthFraction: maximumWidthFraction,
                     backgroundOpacity: backgroundOpacity ?? self.backgroundOpacity,
                     backgroundCornerFraction: backgroundCornerFraction,
                     red: red ?? self.red, green: green ?? self.green, blue: blue ?? self.blue,
                     highlightsSpokenWord: highlightsSpokenWord ?? self.highlightsSpokenWord,
                     unspokenOpacity: unspokenOpacity ?? self.unspokenOpacity,
                     alignment: alignment ?? self.alignment,
                     horizontalFraction: horizontalFraction ?? self.horizontalFraction,
                     isBold: isBold ?? self.isBold,
                     plateRed: plateRed ?? self.plateRed,
                     plateGreen: plateGreen ?? self.plateGreen,
                     plateBlue: plateBlue ?? self.plateBlue,
                     shadowOpacity: shadowOpacity ?? self.shadowOpacity,
                     shadowBlurFraction: shadowBlurFraction ?? self.shadowBlurFraction,
                     outlineWidthFraction: outlineWidthFraction ?? self.outlineWidthFraction,
                     outlineRed: outlineRed ?? self.outlineRed,
                     outlineGreen: outlineGreen ?? self.outlineGreen,
                     outlineBlue: outlineBlue ?? self.outlineBlue,
                     // A double optional, so "set it to nothing" and "leave it alone" are
                     // different asks — `MusicBed.changing(filename:)`'s shape, for its reason:
                     // choosing the system font is a decision and not an absence of one.
                     fontFilename: fontFilename ?? self.fontFilename)
    }

    /// The type size in output pixels.
    public func pointSize(forOutputHeight height: Int) -> Double {
        Double(height) * heightFraction
    }

    /// The widest a line may be drawn, in output pixels.
    public func maximumWidth(forOutputWidth width: Int) -> Double {
        Double(width) * maximumWidthFraction
    }
}

/// One word of a caption, and whether it is the one being said.
public struct CaptionWord: Hashable, Sendable {
    public let text: String
    public let isSpoken: Bool

    public init(text: String, isSpoken: Bool) {
        self.text = text
        self.isSpoken = isSpoken
    }
}

/// The caption on this frame: what it says and how it should look.
///
/// **A `String`, not a `CaptionCue`.** `Captions` is a sibling of `Render` in the deterministic
/// tier, so a cue type here would be an edge in the wrong direction — the same reasoning
/// `RenderPlan.contentZoom` gives for taking two numbers rather than a `CameraState`.
/// `Compositing` depends on both and resolves the cue.
public struct CaptionOverlay: Hashable, Sendable {
    public let text: String
    public let style: CaptionStyle
    /// The line split into words with the spoken one marked, or empty when the recogniser gave
    /// no word timings — a real case for some languages, and the reason this is a field rather
    /// than something the renderer derives by splitting `text`.
    public let words: [CaptionWord]

    public init(text: String, style: CaptionStyle, words: [CaptionWord] = []) {
        self.text = text
        self.style = style
        self.words = words
    }
}
