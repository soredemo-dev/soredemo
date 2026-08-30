import CoreImage
import Foundation
import Render

/// A caption, as a piece of text.
///
/// **An adapter over `TextArt`, not a second renderer.** A caption IS text: centred, at the
/// bottom, on a black plate. Two renderers laying text out the same way diverge — the plate
/// padding gets tuned in one and not the other, and nobody notices until a screenshot puts them
/// side by side. `CaptionStyle.asTextStyle` is the conversion and it lives beside the style.
///
/// This file stays because the caption path has one thing titles do not: `fits`, which is the
/// seam that keeps `CaptionBuilder`'s line breaking measuring the same font the renderer draws.
public enum CaptionArt {
    /// How wide this text draws, in output pixels, including the plate's padding. What a caller
    /// compares against `CaptionStyle.maximumWidth(forOutputWidth:)`.
    public static func width(of text: String, style: CaptionStyle, outputHeight: Int) -> Double {
        // **Bold and the font are passed, and passing neither was a defect.** This is the
        // measurement `CaptionBuilder` breaks lines by, and the drawing uses `style.isBold` and
        // `style.fontFilename`; measuring a lighter, narrower face than the one that will be
        // drawn breaks the lines too late and the caption overflows its own limit. The seam
        // this function IS only holds while both sides ask the same question.
        TextArt.width(of: text, pointSize: style.pointSize(forOutputHeight: outputHeight),
                      bold: style.isBold, filename: style.fontFilename)
    }

    /// A `fits` closure for `CaptionBuilder`, bound to one output size and style — the seam that
    /// keeps breaking and drawing agreeing.
    public static func fits(style: CaptionStyle, outputWidth: Int, outputHeight: Int)
    -> @Sendable (String) -> Bool {
        let limit = style.maximumWidth(forOutputWidth: outputWidth)
        return { text in width(of: text, style: style, outputHeight: outputHeight) <= limit }
    }

    /// The caption as an image the size of the whole frame, positioned by the style.
    ///
    /// **Word highlighting is two draws, not a per-word layout.** The dim line is drawn once and
    /// the spoken word is drawn again over it at full opacity — which keeps the layout identical
    /// between the two, where laying each word out separately would need this file to reproduce
    /// Core Text's own spacing and would drift from it at every font size. The cost is one extra
    /// bitmap on the frames where a word is being said.
    public static func image(_ overlay: CaptionOverlay,
                             outputWidth: Int, outputHeight: Int) -> CIImage? {
        let style = overlay.style
        guard style.highlightsSpokenWord, !overlay.words.isEmpty,
              overlay.words.contains(where: \.isSpoken) else {
            return TextArt.image(TextOverlay(text: overlay.text, style: style.asTextStyle),
                                 outputWidth: outputWidth, outputHeight: outputHeight)
        }

        let dim = TextArt.image(
            TextOverlay(text: overlay.text,
                        style: style.asTextStyle.changing(alpha: style.unspokenOpacity)),
            outputWidth: outputWidth, outputHeight: outputHeight)
        // The spoken word alone, with everything else replaced by spaces of the same length —
        // so it lands in exactly the position it occupies in the full line.
        let masked = overlay.words
            .map { $0.isSpoken ? $0.text : String(repeating: "\u{2007}", count: $0.text.count) }
            .joined(separator: " ")
        let bright = TextArt.image(TextOverlay(text: masked, style: style.asTextStyle),
                                   outputWidth: outputWidth, outputHeight: outputHeight)
        guard let dim else { return bright }
        guard let bright else { return dim }
        return bright.composited(over: dim)
    }
    /// Which characters of `text` the spoken word occupies.
    ///
    /// **Matched by ALPHANUMERIC COUNT, not by splitting on spaces.** A recogniser's runs do not
    /// split on spaces — "don't" can arrive as three — which is why `CaptionBuilder` times
    /// phrases the same way; `text.split(" ")[n]` is not `words[n]`. Counting letters and digits
    /// is stable under every one of those, and it is the technique this project already uses for
    /// exactly this mismatch.
    ///
    /// `nil` when no word is marked, or when the counts run past the end of the line — which
    /// means the two disagree, and drawing the whole line undimmed is the honest answer.
    static func highlightRange(in text: String, words: [CaptionWord]) -> Range<Int>? {
        guard let spokenIndex = words.firstIndex(where: \.isSpoken) else { return nil }
        let before = words[..<spokenIndex].reduce(0) { $0 + lettersAndDigits(in: $1.text) }
        let length = lettersAndDigits(in: words[spokenIndex].text)
        guard length > 0 else { return nil }

        var counted = 0
        var lower: Int?
        var upper: Int?
        for (offset, character) in text.enumerated() where character.isLetter || character.isNumber {
            if counted == before, lower == nil { lower = offset }
            counted += 1
            if counted == before + length { upper = offset + 1; break }
        }
        guard let lower, let upper, upper > lower else { return nil }
        return lower..<upper
    }

    private static func lettersAndDigits(in text: String) -> Int {
        text.filter { $0.isLetter || $0.isNumber }.count
    }
}
