import Foundation

/// The colours of both themes as numbers, with the arithmetic that chose them.
///
/// **Numbers here, `Color` in `Theme`.** Keeping the values plain means the contrast of every
/// pairing is a test (`PaletteTests`) rather than a judgement made once and never re-checked —
/// which is how the dark theme carried a 2.39:1 button label for months.
/// `docs/design/2026-09-27-light-and-dark.md` has the measurements and the reasons.
nonisolated enum Palette {
    enum Mode: CaseIterable, Sendable { case dark, light }

    /// A colour in sRGB, 0…1 per channel.
    struct RGB: Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(hex: Int) {
            self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                      blue: Double(hex & 0xFF) / 255)
        }

        /// OKLCH to sRGB, **clamped into gamut** — a colour just outside is drawn at its nearest
        /// displayable neighbour, and the tests measure the clamped value because that is what
        /// is drawn. Björn Ottosson's published matrices.
        static func oklch(lightness: Double, chroma: Double, hue: Double) -> RGB {
            let a = chroma * cos(hue * .pi / 180)
            let b = chroma * sin(hue * .pi / 180)
            let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
            let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
            let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
            func encode(_ linear: Double) -> Double {
                let v = min(max(linear, 0), 1)
                return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
            }
            return RGB(red: encode(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                       green: encode(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                       blue: encode(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
        }

        private static func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }

        var relativeLuminance: Double {
            0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
        }

        /// OKLab's L — perceived lightness, the quantity the lanes are held equal on.
        var oklabLightness: Double {
            let (r, g, b) = (Self.linear(red), Self.linear(green), Self.linear(blue))
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        }

        /// The WCAG 2 contrast ratio, 1…21.
        func contrast(with other: RGB) -> Double {
            let (a, b) = (relativeLuminance, other.relativeLuminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        /// This colour at `opacity` over `ground` — what is actually on screen.
        func over(_ ground: RGB, opacity: Double) -> RGB {
            RGB(red: red * opacity + ground.red * (1 - opacity),
                green: green * opacity + ground.green * (1 - opacity),
                blue: blue * opacity + ground.blue * (1 - opacity))
        }
    }

    /// One tint per timeline track. The hue is the lane's; lightness and chroma are the theme's.
    enum Lane: CaseIterable, Sendable {
        case video, audio, zoom, text, caption, hide, mark, chapter

        /// OKLCH degrees. The closest pair is 30° apart (`noTwoLanesShareAHue`).
        var hue: Double {
            switch self {
            case .video: 268
            case .audio: 155
            case .zoom: 300
            case .text: 75
            case .caption: 205
            case .hide: 350
            // Between text's amber and hide's magenta, away from both: an annotation is a mark a
            // person made, like a title, and the two tracks are read side by side.
            case .mark: 30
            // Yellow-green, the widest gap left: a chapter flag sits above every other lane.
            case .chapter: 125
            }
        }
    }

    struct Values: Sendable {
        let base: RGB
        let panel: RGB
        let raised: RGB
        let primaryText: RGB
        let secondaryText: RGB
        let tertiaryText: RGB
        /// White on dark, black on light; hairlines and fills are this at low opacity.
        let line: RGB
        let accent: RGB
        /// The accent as the colour of words and small glyphs. Separate from `accent`, which is a
        /// fill under a white label and on the dark ground reads at 3.48:1 — an edge, not text.
        let accentText: RGB
        let caution: RGB
        /// Text drawn ON a lane-coloured block, at `onLaneOpacity`.
        let onLane: RGB
        let onLaneOpacity: Double
        let laneLightness: Double
        let laneChroma: Double

        var surfaces: [RGB] { [base, panel, raised] }

        func lane(_ lane: Lane) -> RGB {
            .oklch(lightness: laneLightness, chroma: laneChroma, hue: lane.hue)
        }
    }

    /// The brand's own dark values (`assets/tokens/colors.json`) for the grounds; the two text
    /// greys and the accent moved, because as they were they failed contrast.
    static let dark = Values(
        base: RGB(hex: 0x101114), panel: RGB(hex: 0x1A1A1D), raised: RGB(hex: 0x2B2B31),
        primaryText: RGB(hex: 0xFFFFFF), secondaryText: RGB(hex: 0x9A9AA3),
        tertiaryText: RGB(hex: 0x7C7C85), line: RGB(hex: 0xFFFFFF),
        accent: .oklch(lightness: 0.55, chroma: 0.15, hue: 268),
        accentText: .oklch(lightness: 0.82, chroma: 0.085, hue: 268),
        caution: .oklch(lightness: 0.80, chroma: 0.13, hue: 60),
        onLane: RGB(hex: 0x000000), onLaneOpacity: 0.75,
        laneLightness: 0.82, laneChroma: 0.085)

    static let light = Values(
        base: RGB(hex: 0xE4E5EA), panel: RGB(hex: 0xF4F4F7), raised: RGB(hex: 0xFFFFFF),
        primaryText: RGB(hex: 0x15161A), secondaryText: RGB(hex: 0x5E606B),
        tertiaryText: RGB(hex: 0x767883), line: RGB(hex: 0x000000),
        accent: .oklch(lightness: 0.50, chroma: 0.13, hue: 268),
        accentText: .oklch(lightness: 0.50, chroma: 0.13, hue: 268),
        caution: .oklch(lightness: 0.52, chroma: 0.11, hue: 60),
        onLane: RGB(hex: 0xFFFFFF), onLaneOpacity: 0.9,
        laneLightness: 0.46, laneChroma: 0.09)

    static func values(for mode: Mode) -> Values { mode == .dark ? dark : light }
}
