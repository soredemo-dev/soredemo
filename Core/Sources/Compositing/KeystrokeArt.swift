import CoreImage
import Foundation
import Render

/// The badge as a frame-sized image, through `TextArt` — the same glyph path captions and
/// titles use, so a badge's plate, shadow and corners are the family's, not a fourth look.
nonisolated enum KeystrokeArt {
    static func image(_ badge: KeystrokeBadge, outputWidth: Int, outputHeight: Int) -> CIImage? {
        guard badge.opacity > 0, !badge.text.isEmpty else { return nil }
        return TextArt.image(TextOverlay(text: badge.text,
                                         style: KeystrokeBadgeStyle.textStyle(opacity: badge.opacity)),
                             outputWidth: outputWidth, outputHeight: outputHeight)
    }
}
