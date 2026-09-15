import Render
import Testing
@testable import Soredemo

/// Turning this Mac's caption appearance into a `CaptionStyle`, decided without a Mac.
///
/// **The read and the conversion are separate so that this file can exist.** Reading System
/// Settings is one impure call; everything below is arithmetic between two vocabularies — the
/// system speaks in absolute points and per-line colours, `CaptionStyle` speaks in fractions of
/// the output height, because a caption has to hold its size when the same project is exported
/// at 1080p and at 4K.
@Suite struct SystemCaptionStyleTests {

    private func appearance(
        textScale: Double = 1, red: Double = 1, green: Double = 1, blue: Double = 1,
        textOpacity: Double = 1, plateOpacity: Double = 0.8,
        plateCornerFraction: Double = 0.012, prefersEdge: Bool = false
    ) -> SystemCaptionAppearance {
        SystemCaptionAppearance(textScale: textScale, red: red, green: green, blue: blue,
                                textOpacity: textOpacity, plateOpacity: plateOpacity,
                                plateCornerFraction: plateCornerFraction,
                                prefersEdge: prefersEdge)
    }

    /// The system's size setting is a multiplier on the default, not an absolute.
    @Test @MainActor func theSystemScaleMultipliesTheDefaultHeight() {
        let doubled = appearance(textScale: 2).style()
        #expect(doubled.heightFraction > CaptionStyle.default.heightFraction)
        let halved = appearance(textScale: 0.5).style()
        #expect(halved.heightFraction < CaptionStyle.default.heightFraction)
    }

    /// **Clamped, and the reason is that this number is not about this app.** A person dragging
    /// a system-wide caption slider to its maximum is not deciding that Soredemo's exports
    /// should carry type across a third of the frame.
    @Test @MainActor func anExtremeSystemScaleIsClamped() {
        #expect(appearance(textScale: 10).style().heightFraction <= 0.12)
        #expect(appearance(textScale: 0.01).style().heightFraction >= 0.02)
    }

    /// **An outline and a plate are alternatives, not a stack.** Somebody who asked for an edge
    /// asked not to have the picture covered; drawing both would give them the plate anyway.
    @Test @MainActor func askingForAnEdgeTurnsThePlateOff() {
        let edged = appearance(plateOpacity: 0.9, prefersEdge: true).style()
        #expect(edged.backgroundOpacity == 0)
        #expect(edged.outlineWidthFraction > 0)
        // Bold, because an outline eats into the letterform from both sides — the same reason
        // the "Over the picture" preset is bold.
        #expect(edged.isBold)
    }

    @Test @MainActor func aPlateWithoutAnEdgeKeepsItsOpacity() {
        let plated = appearance(plateOpacity: 0.65, prefersEdge: false).style()
        #expect(plated.backgroundOpacity == 0.65)
        #expect(plated.outlineWidthFraction == 0)
    }

    /// The colour comes through unchanged. A person who set yellow captions gets yellow ones.
    @Test @MainActor func theSystemColourIsCarriedThrough() {
        let yellow = appearance(red: 1, green: 0.9, blue: 0).style()
        #expect(yellow.red == 1)
        #expect(yellow.green == 0.9)
        #expect(yellow.blue == 0)
    }

    /// A corner radius of zero means the system has no opinion, so the app's own is kept rather
    /// than square corners being read as a choice.
    @Test @MainActor func anAbsentCornerRadiusFallsBackRatherThanSquaring() {
        let absent = appearance(plateCornerFraction: 0).style()
        #expect(absent.backgroundCornerFraction == CaptionStyle.default.backgroundCornerFraction)
    }
}
