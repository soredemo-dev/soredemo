import Testing
import AppKit
import Foundation
@testable import Soredemo

/// The palette's numbers, checked the way `docs/design/2026-09-27-light-and-dark.md` measured
/// them — so a retuned colour that fails a pairing fails here, not on somebody's screen.
@Suite struct PaletteTests {
    /// Positive control for the conversion, with an answer known independently of this code:
    /// CSS Color 4 gives `oklch(62.796% 0.25768 29.2339)` as sRGB red.
    @Test func oklchConvertsAKnownColourToItsKnownSRGB() {
        let red = Palette.RGB.oklch(lightness: 0.62796, chroma: 0.25768, hue: 29.2339)
        #expect(abs(red.red - 1) < 0.002 && red.green < 0.002 && red.blue < 0.002)
        let white = Palette.RGB.oklch(lightness: 1, chroma: 0, hue: 0)
        #expect(abs(white.red - 1) < 0.001 && abs(white.green - 1) < 0.001 && abs(white.blue - 1) < 0.001)
    }

    /// Positive control for the ratio: black on white is 21 by definition.
    @Test func contrastIsTheWCAGRatio() {
        #expect(abs(Palette.RGB(hex: 0x000000).contrast(with: Palette.RGB(hex: 0xFFFFFF)) - 21) < 0.01)
        #expect(Palette.RGB(hex: 0x777777).contrast(with: Palette.RGB(hex: 0x777777)) == 1)
    }

    @Test(arguments: Palette.Mode.allCases)
    func textReadsOnEverySurface(_ mode: Palette.Mode) {
        let palette = Palette.values(for: mode)
        for surface in palette.surfaces {
            #expect(palette.primaryText.contrast(with: surface) >= 4.5, "\(mode) primary")
            #expect(palette.secondaryText.contrast(with: surface) >= 4.5, "\(mode) secondary")
            #expect(palette.tertiaryText.contrast(with: surface) >= 3, "\(mode) tertiary")
        }
        #expect(palette.caution.contrast(with: palette.panel) >= 4.5, "\(mode) caution")
        // The accent as TEXT is a separate colour: the fill accent is 3.48:1 on a dark panel,
        // enough for a button's edge and not for words.
        for surface in palette.surfaces {
            #expect(palette.accentText.contrast(with: surface) >= 4.5, "\(mode) accent text")
        }
    }

    @Test(arguments: Palette.Mode.allCases)
    func aLabelReadsOnTheAccentAndTheAccentOnThePanel(_ mode: Palette.Mode) {
        let palette = Palette.values(for: mode)
        #expect(Palette.RGB(hex: 0xFFFFFF).contrast(with: palette.accent) >= 4.5)
        #expect(palette.accent.contrast(with: palette.panel) >= 3)
    }

    /// A block is drawn at 75 % over the lane's track, which is the line colour at 7 % over the
    /// panel — the composite is what the eye compares, so that is what is measured.
    @Test(arguments: Palette.Mode.allCases)
    func everyLaneStandsOffItsTrackAndCarriesALabel(_ mode: Palette.Mode) {
        let palette = Palette.values(for: mode)
        let track = palette.line.over(palette.panel, opacity: 0.07)
        #expect(Palette.Lane.allCases.count == 8)
        for lane in Palette.Lane.allCases {
            let colour = palette.lane(lane)
            let block = colour.over(track, opacity: 0.75)
            #expect(block.contrast(with: track) >= 3, "\(mode) \(lane) block")
            #expect(colour.contrast(with: track) >= 4.5, "\(mode) \(lane) as text")
            #expect(palette.onLane.over(colour, opacity: palette.onLaneOpacity).contrast(with: colour) >= 4.5,
                    "\(mode) label on \(lane)")
        }
    }

    /// The rule the lanes exist to keep: one family, equally light. Same OKLCH lightness for
    /// every lane in a theme — the thing HSB brightness claimed and did not deliver.
    @Test(arguments: Palette.Mode.allCases)
    func lanesShareOneLightness(_ mode: Palette.Mode) {
        let lightnesses = Palette.Lane.allCases.map { Palette.values(for: mode).lane($0).oklabLightness }
        #expect(lightnesses.max()! - lightnesses.min()! < 0.02, "\(mode): \(lightnesses)")
    }

    @Test func noTwoLanesShareAHue() {
        let hues = Palette.Lane.allCases.map(\.hue).sorted()
        let gaps = zip(hues, hues.dropFirst() + [hues[0] + 360]).map { $1 - $0 }
        #expect(gaps.min()! >= 30, "closest lanes are \(gaps.min()!)° apart")
    }
}

@Suite struct AppearanceTests {
    @Test func systemIsTheDefault() {
        #expect(Appearance(storedValue: nil) == .system)
        #expect(Appearance(storedValue: "sepia") == .system)
    }

    @Test func eachChoiceNamesTheAppearanceItApplies() {
        #expect(Appearance.system.appearanceName == nil)
        #expect(Appearance.light.appearanceName == .aqua)
        #expect(Appearance.dark.appearanceName == .darkAqua)
        for choice in Appearance.allCases { #expect(Appearance(storedValue: choice.rawValue) == choice) }
    }
}
