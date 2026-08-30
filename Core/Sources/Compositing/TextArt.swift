import CoreGraphics
import CoreImage
import CoreText
import Foundation
import Render

/// Drawing text over the picture, and measuring it.
///
/// **One path for captions and titles.** `CaptionArt` is a thin adapter over this file, because
/// a caption is a piece of text that happens to be centred at the bottom on a black plate. Two
/// renderers that lay text out the same way diverge: the plate padding gets tuned in one and not
/// the other, and nobody notices until a screenshot puts them side by side.
///
/// **Measuring and drawing are the same code.** `CaptionBuilder` breaks a line when a caller's
/// `fits` says it does not fit; if that measurement came from anywhere other than the thing that
/// later draws the line, breaks would be computed against one font and rendered in another — and
/// the failure looks like text that overflows only at some export sizes.
public enum TextArt {
    /// Padding around the text inside its plate, as a fraction of the type size. Horizontal is
    /// larger than vertical because a plate that hugs the text sideways reads as clipped.
    static let horizontalPaddingRatio = 0.7
    static let verticalPaddingRatio = 0.32

    /// Where a project's own font files live, set by the app tier alongside the image base.
    ///
    /// A URL rather than the bytes, and the FILE rather than an installed name — which is what
    /// makes the old objection to naming fonts go away. A name that is not installed falls back
    /// silently to something of a different width; a file that travels inside the project is
    /// either there or it is not, and it is there on every machine the project is opened on.
    public nonisolated(unsafe) static var fontBaseURL: URL?

    /// The directory a project keeps its fonts in, beside `backgrounds` and `music`.
    public static let fontDirectory = "fonts"

    /// Loaded fonts, keyed by file, size and weight.
    ///
    /// **A cache because this is called per line per frame**, and building a `CTFont` from a
    /// file reads and parses it. The key includes the size because a `CTFont` IS a size —
    /// there is no cheap way to rescale one — and the weight because a family's bold face is a
    /// different file inside the same collection.
    private nonisolated(unsafe) static var fontCache: [FontKey: CTFont] = [:]
    private static let fontCacheLock = NSLock()

    private struct FontKey: Hashable {
        let filename: String
        let pointSize: Double
        let bold: Bool
    }

    /// The font to lay text out in: a project's own if it names one and the file loads, the
    /// system UI font otherwise.
    ///
    /// **A fallback here cannot make text overflow**, which was the objection that kept fonts
    /// out. `CaptionBuilder` decides its line breaks through `TextArt.width`, which calls this
    /// same function with the same arguments — so a font that fails to load changes what the
    /// breaking measures and what the drawing draws by exactly the same amount. The seam is what
    /// makes the fallback safe, and it is why measurement and drawing must never grow two ways
    /// of choosing a font.
    static func font(pointSize: Double, bold: Bool, filename: String? = nil) -> CTFont {
        if let filename, let loaded = projectFont(filename, pointSize: pointSize, bold: bold) {
            return loaded
        }
        let ui = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, pointSize, nil)
        return ui ?? CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
    }

    /// One font file, or `nil` for every way that can fail: no base, an unsafe name, a missing
    /// file, bytes Core Graphics will not read.
    ///
    /// **`bold` is applied as a trait rather than by picking a face.** A single `.ttf` is one
    /// weight, and asking Core Text to synthesise the bold is the same thing AppKit does when a
    /// family has no bold member — the alternative is refusing to embolden a project font at
    /// all, which would make the toggle silently do nothing for exactly the fonts a person went
    /// to the trouble of choosing.
    private static func projectFont(_ filename: String, pointSize: Double,
                                    bold: Bool) -> CTFont? {
        let key = FontKey(filename: filename, pointSize: pointSize, bold: bold)
        if let cached = fontCacheLock.withLock({ unsafe fontCache[key] }) { return cached }
        guard StageBackground.isSafeImageFilename(filename),
              let base = unsafe fontBaseURL else { return nil }
        let url = base.appending(path: fontDirectory, directoryHint: .isDirectory)
            .appending(path: filename)
        guard let provider = CGDataProvider(url: url as CFURL),
              let graphics = CGFont(provider) else { return nil }
        var font = CTFontCreateWithGraphicsFont(graphics, pointSize, nil, nil)
        if bold, let emboldened = CTFontCreateCopyWithSymbolicTraits(
            font, pointSize, nil, .traitBold, .traitBold) {
            font = emboldened
        }
        fontCacheLock.withLock { unsafe fontCache[key] = font }
        return font
    }

    /// Forgets every loaded font.
    ///
    /// **Because a project can be closed and another opened in one process.** The cache is keyed
    /// on a filename, and two projects may each have a `Brand.ttf` that is not the same file —
    /// a cache that outlived the base URL would draw the first project's font in the second's
    /// captions, which is the kind of wrong that looks like a rendering bug rather than a stale
    /// cache.
    public static func forgetProjectFonts() {
        fontCacheLock.withLock { unsafe fontCache.removeAll() }
    }

    /// One laid-out line, with its colour, its dimmed runs and its outline already in it.
    ///
    /// **The outline is an attribute rather than a second pass.** Stroking separately means
    /// laying the same text out twice and lining the two up, which is the drift
    /// `line`'s dimmed-run comment describes: two layouts of one string are not guaranteed to
    /// agree at every size. Core Text strokes the glyphs it is laying out.
    private static func line(_ text: String, pointSize: Double, bold: Bool,
                             filename: String? = nil,
                             dim: DimmedRun? = nil, colour: CGColor? = nil,
                             outline: (width: Double, colour: CGColor)? = nil) -> CTLine {
        // `kCTFontAttributeName`, not `.font`: that key is AppKit's, and `HeadlessCheck` bans
        // AppKit in this target. Core Text reads its own key regardless of who set it.
        let attributed = NSMutableAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(pointSize: pointSize,
                                                                        bold: bold,
                                                                        filename: filename),
        ])
        if let colour {
            attributed.addAttribute(
                NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                value: colour, range: NSRange(location: 0, length: attributed.length))
        }
        if let outline, outline.width > 0 {
            let whole = NSRange(location: 0, length: attributed.length)
            // **NEGATIVE, and the sign is the whole behaviour.** Core Text reads `strokeWidth`
            // as a percentage of the type size; positive strokes ONLY, leaving hollow letters,
            // and negative fills and strokes. A caption wants both.
            attributed.addAttribute(
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String),
                value: -outline.width * 100, range: whole)
            attributed.addAttribute(
                NSAttributedString.Key(kCTStrokeColorAttributeName as String),
                value: outline.colour, range: whole)
        }
        if let dim, let colour {
            // **Everything OUTSIDE the highlight is dimmed, inside ONE laid-out line.** The
            // alternatives — drawing the line twice, or padding the unspoken words with spaces —
            // have to reproduce Core Text's own spacing to line the two up, and drift from it at
            // every font size. Colouring a range inside one line cannot drift, because there is
            // only one layout.
            let faded = colour.copy(alpha: colour.alpha * dim.alpha) ?? colour
            for range in dim.rangesOutside(length: attributed.length) {
                attributed.addAttribute(
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                    value: faded, range: range)
            }
        }
        return CTLineCreateWithAttributedString(attributed as CFAttributedString)
    }

    /// The characters drawn at full strength, and how faint everything else is.
    public struct DimmedRun: Hashable, Sendable {
        public let range: Range<Int>
        public let alpha: Double

        public init(range: Range<Int>, alpha: Double) {
            self.range = range
            self.alpha = alpha
        }

        /// The spans either side of the highlight, clamped into `length`. Written out rather than
        /// done at the call site because an empty leading span is legal and an
        /// `NSRange(location: 0, length: 0)` is not the same as no range at all.
        func rangesOutside(length: Int) -> [NSRange] {
            let lower = Swift.min(Swift.max(range.lowerBound, 0), length)
            let upper = Swift.min(Swift.max(range.upperBound, lower), length)
            var spans: [NSRange] = []
            if lower > 0 { spans.append(NSRange(location: 0, length: lower)) }
            if upper < length { spans.append(NSRange(location: upper, length: length - upper)) }
            return spans
        }
    }

    /// The lines of `text`, with the blank ones kept — a blank line in a title is a gap a person
    /// typed, and dropping it would move everything below it up.
    static func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// How wide this text draws, in output pixels, including the plate's padding. The WIDEST
    /// line, since a plate has to hold all of them.
    public static func width(of text: String, pointSize: Double, bold: Bool,
                             filename: String? = nil) -> Double {
        let widest = lines(of: text).reduce(0.0) { widest, one in
            guard !one.isEmpty else { return widest }
            return max(widest, HeadlessGeometryBridge.typographicBounds(
                of: line(one, pointSize: pointSize, bold: bold, filename: filename)).width)
        }
        return widest == 0 ? 0 : widest + pointSize * horizontalPaddingRatio * 2
    }

    /// The text as an image the size of the whole frame, or `nil` when there is nothing to draw
    /// or the bitmap could not be made.
    ///
    /// Frame-sized rather than text-sized-and-translated: a `CIImage` composited at an offset
    /// needs its own transform, and the position is a property of the frame anyway.
    public static func image(_ overlay: TextOverlay,
                             outputWidth: Int, outputHeight: Int,
                             dim: DimmedRun? = nil) -> CIImage? {
        let style = overlay.style
        let drawnLines = lines(of: overlay.text)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard drawnLines.contains(where: { !$0.isEmpty }),
              outputWidth > 0, outputHeight > 0 else { return nil }

        let size = style.pointSize(forOutputHeight: outputHeight)
        let horizontalPadding = size * horizontalPaddingRatio
        let verticalPadding = size * verticalPaddingRatio
        let gap = size * style.lineGapRatio

        // The glyph colour is set on the line rather than on the context when a run is dimmed:
        // `setFillColor` applies to the whole line, and a per-range alpha needs the attribute.
        let outlined = style.outlineWidthFraction > 0
        // **Always, and this is a repair.** The colour used to be attached only when a word was
        // being highlighted; otherwise the glyphs carried no foreground attribute and the code
        // relied on `setFillColor` below to colour them. Core Text does not work that way: an
        // attributed string with no `kCTForegroundColorAttributeName` and no
        // `kCTForegroundColorFromContextAttributeName` draws BLACK, whatever the context's fill
        // colour is.
        //
        // Measured by asking for red on white and getting black. So `TextOverlayStyle.red`,
        // `.green` and `.blue` have never reached a glyph except on a highlighted line — every
        // caption and every text overlay this app has drawn was black, on a plate that defaults
        // to black. The tests looked for ink near the bottom of the frame and found it, which is
        // true of black ink too.
        let glyphColour = CGColor(red: style.red, green: style.green, blue: style.blue,
                                  alpha: style.alpha)
        let outline: (width: Double, colour: CGColor)? = outlined
            ? (style.outlineWidthFraction,
               CGColor(red: style.outlineRed, green: style.outlineGreen,
                       blue: style.outlineBlue, alpha: style.alpha))
            : nil
        let typeset = drawnLines.map { text -> (line: CTLine, width: Double, ascent: Double, descent: Double) in
            // A dimmed run is only meaningful on a single-line caption; a title broken over two
            // lines has no spoken word, so nothing is dimmed there.
            let made = line(text, pointSize: size, bold: style.isBold,
                            filename: style.fontFilename,
                            dim: drawnLines.count == 1 ? dim : nil, colour: glyphColour,
                            outline: outline)
            let bounds = HeadlessGeometryBridge.typographicBounds(of: made)
            return (made, bounds.width, bounds.ascent, bounds.descent)
        }
        let textWidth = typeset.reduce(0.0) { max($0, $1.width) }
        let lineHeights = typeset.map { $0.ascent + $0.descent }
        let textHeight = lineHeights.reduce(0, +) + gap * Double(max(0, typeset.count - 1))

        let plateWidth = textWidth + horizontalPadding * 2
        let plateHeight = textHeight + verticalPadding * 2
        // `anchor` decides what `x` points at, so a title pinned left stays pinned left when its
        // text gets longer — which is the whole reason an anchor exists rather than a centre.
        let plateX: Double
        switch style.anchor {
        case .leading: plateX = Double(outputWidth) * style.x
        case .center: plateX = Double(outputWidth) * style.x - plateWidth / 2
        case .trailing: plateX = Double(outputWidth) * style.x - plateWidth
        }
        let plateY = Double(outputHeight) * style.y

        // `data: nil`: CGContext owns its backing store and no raw pointer is read here.
        guard let bitmap = unsafe CGContext(
            data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        if style.plateOpacity > 0 {
            bitmap.addPath(HeadlessGeometryBridge.roundedPlate(
                x: plateX, y: plateY, width: plateWidth, height: plateHeight,
                cornerRadius: Double(outputHeight) * style.plateCornerFraction))
            bitmap.setFillColor(CGColor(red: style.plateRed, green: style.plateGreen,
                                        blue: style.plateBlue, alpha: style.plateOpacity))
            bitmap.fillPath()
        }

        if style.shadowOpacity > 0 {
            // No offset, matching the stage's own ambient shadow: the style models blur and
            // opacity and nothing else, and inventing a direction would be a value it cannot
            // round-trip. `CoreImageFrameRenderer.shadowImage` makes the same argument.
            bitmap.setShadow(
                offset: HeadlessGeometryBridge.noOffset(),
                blur: Double(outputHeight) * style.shadowBlurFraction,
                color: CGColor(red: 0, green: 0, blue: 0, alpha: style.shadowOpacity))
        }

        bitmap.setFillColor(CGColor(red: style.red, green: style.green, blue: style.blue,
                                    alpha: style.alpha))
        // Top line first, walking down. The baseline of each sits `descent` above its own row's
        // bottom, which is what keeps a descender inside the plate rather than through its edge.
        var cursor = plateY + plateHeight - verticalPadding
        for (index, entry) in typeset.enumerated() {
            cursor -= entry.ascent
            if !drawnLines[index].isEmpty {
                let lineX: Double
                switch style.anchor {
                case .leading: lineX = plateX + horizontalPadding
                case .center: lineX = plateX + (plateWidth - entry.width) / 2
                case .trailing: lineX = plateX + plateWidth - horizontalPadding - entry.width
                }
                bitmap.textPosition = HeadlessGeometryBridge.point(x: lineX, y: cursor)
                CTLineDraw(entry.line, bitmap)
            }
            cursor -= entry.descent + gap
        }

        guard let image = bitmap.makeImage() else { return nil }
        let drawn = CIImage(cgImage: image)
        guard overlay.animation.opacity < 1 || overlay.animation.rise != 0
                || overlay.animation.scale != 1 else { return drawn }

        // **Scaled and lifted about the text's OWN centre**, not the frame's: scaling a
        // frame-sized image about the origin would fly the words off the corner. The plate's
        // centre is where the words are, so that is the anchor.
        let centreX = plateX + plateWidth / 2
        let centreY = plateY + plateHeight / 2
        let scale = overlay.animation.scale
        let lift = overlay.animation.rise * size
        let transform = CGAffineTransform(translationX: -centreX, y: -centreY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: centreX, y: centreY - lift))
        let moved = drawn.transformed(by: transform)
        guard overlay.animation.opacity < 1 else { return moved }
        return moved.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: overlay.animation.opacity),
        ])
    }
}
