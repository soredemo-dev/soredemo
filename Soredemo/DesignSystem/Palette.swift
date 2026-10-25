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
        var oklabLightness: Double { oklab.lightness }

        /// OKLCH's hue in degrees, 0…360 — what a token keeps of the brand colour it comes from.
        var oklchHue: Double {
            let lab = oklab
            let degrees = atan2(lab.b, lab.a) * 180 / .pi
            return degrees < 0 ? degrees + 360 : degrees
        }

        /// OKLCH's chroma — how far from grey. Ink and paper are near zero; the record red is not.
        var oklchChroma: Double {
            let lab = oklab
            return (lab.a * lab.a + lab.b * lab.b).squareRoot()
        }

        private var oklab: (lightness: Double, a: Double, b: Double) {
            let (r, g, b) = (Self.linear(red), Self.linear(green), Self.linear(blue))
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
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

    /// The daruma's four colours (`assets/tokens/colors.json`). The tokens below keep their hues
    /// and take the lightness each job needs — see `docs/design/2026-10-25-the-daruma-theme.md`.
    enum Brand {
        static let sumi = RGB(hex: 0x16171B)
        static let washi = RGB(hex: 0xF4F3EF)
        static let shu = RGB(hex: 0xFA3D4A)
        static let kin = RGB(hex: 0xC8A24A)
        /// The dark mark's body, a paper a shade off white (the brand kit's dark logomark).
        static let paper = RGB(hex: 0xF4F4F5)
        /// The vermilion daruma's body (shu-nuri), when a person chose that icon.
        static let shuNuri = RGB(hex: 0xE8452C)
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
        /// The accent as the colour of words and small glyphs. The same ink as `accent` today; kept
        /// separate because a fill and a word have different contrast needs, measured apart.
        let accentText: RGB
        /// A label drawn ON the accent — the accent is ink, so this is the paper it is not.
        let onAccent: RGB
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

    /// The daruma's colours (`Brand`): sumi is the dark panel and the light text, washi the light
    /// panel and the dark text, and **the accent is ink** — washi on sumi, sumi on washi — because
    /// the record red only means "recording" while nothing else is red. Caution keeps kin's hue.
    /// The base sits a step behind the panel and the raised surface a step forward.
    static let dark = Values(
        base: RGB(hex: 0x0F1013), panel: Brand.sumi, raised: RGB(hex: 0x26272D),
        primaryText: Brand.washi, secondaryText: RGB(hex: 0x9A9AA3),
        tertiaryText: RGB(hex: 0x7C7C85), line: RGB(hex: 0xFFFFFF),
        accent: Brand.washi, accentText: Brand.washi, onAccent: Brand.sumi,
        caution: .oklch(lightness: 0.80, chroma: 0.11, hue: 86),
        onLane: RGB(hex: 0x000000), onLaneOpacity: 0.75,
        laneLightness: 0.82, laneChroma: 0.085)

    static let light = Values(
        base: RGB(hex: 0xE7E6E0), panel: Brand.washi, raised: RGB(hex: 0xFFFFFF),
        primaryText: Brand.sumi, secondaryText: RGB(hex: 0x5E606B),
        tertiaryText: RGB(hex: 0x767883), line: RGB(hex: 0x000000),
        accent: Brand.sumi, accentText: Brand.sumi, onAccent: Brand.washi,
        caution: .oklch(lightness: 0.52, chroma: 0.10, hue: 86),
        onLane: RGB(hex: 0xFFFFFF), onLaneOpacity: 0.9,
        laneLightness: 0.46, laneChroma: 0.09)

    static func values(for mode: Mode) -> Values { mode == .dark ? dark : light }
}
