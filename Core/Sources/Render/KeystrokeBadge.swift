import Foundation

/// What the renderer draws for a pressed shortcut: the glyphs and how far through its fade
/// it is. **In `Render`, not beside its track in `Overlays`**, for `CaptionOverlay`'s reason:
/// the plan carries it and the plan lives here, and `Overlays` already depends on this module.
public struct KeystrokeBadge: Hashable, Sendable {
    public let text: String
    public let opacity: Double

    public init(text: String, opacity: Double) {
        self.text = text
        self.opacity = opacity.isFinite ? min(max(opacity, 0), 1) : 0
    }
}

/// How a badge looks. **Fixed, not a per-project style**, at least until somebody asks: a
/// badge is a small bold plate at the bottom of the frame in every reference recorder, and a
/// style a person cannot see the need for is a style they have to skip past. Everything here
/// is a fraction of the output height, so a 4K export and a 720p one draw the same badge.
public enum KeystrokeBadgeStyle {
    /// The glyph height. A shade larger than the caption's 0.045 — a shortcut is three glyphs
    /// and has to be read in under a second. **Uncalibrated.**
    public static let heightFraction: Double = 0.05
    /// Above the caption's slot (`CaptionStyle.default.bottomInsetFraction` 0.07 plus its
    /// height), so the two never overlap when both are on. **Uncalibrated.**
    public static let bottomFraction: Double = 0.16
    public static let plateOpacity: Double = 0.72
    public static let plateCornerFraction: Double = 0.012

    /// The badge as the text style the art draws with — bold white glyphs on a dark plate,
    /// centred, at `opacity` from the badge's fade.
    public static func textStyle(opacity: Double) -> TextOverlayStyle {
        TextOverlayStyle(heightFraction: heightFraction, x: 0.5, y: bottomFraction,
                         anchor: .center, isBold: true,
                         red: 1, green: 1, blue: 1, alpha: opacity,
                         plateOpacity: plateOpacity * opacity,
                         plateCornerFraction: plateCornerFraction,
                         plateRed: 0.08, plateGreen: 0.08, plateBlue: 0.1,
                         shadowOpacity: 0.35 * opacity, shadowBlurFraction: 0.01,
                         maximumWidthFraction: 0.6, lineGapRatio: 0.2)
    }
}
