import Foundation
import Testing
@testable import Render

// MARK: - the six that were literals, and the compatibility that adding them nearly broke

/// **A project saved before these fields existed still opens.** `CaptionStyle` had a synthesised
/// `Codable`, and a synthesised decode requires every key — so adding a field would have stopped
/// every existing project from opening, silently, at the moment somebody double-clicked it.
///
/// The defaults a missing key falls back to are `CaptionStyle.default`'s, not zeroes: absence
/// means the field did not exist when the file was written, and what the caption looked like
/// then is what the default was.
@Test func aStyleSavedBeforeTheseFieldsExistedStillDecodes() throws {
    let older = Data("""
        {"heightFraction":0.05,"bottomInsetFraction":0.08,"maximumWidthFraction":0.9,
         "backgroundOpacity":0.5,"backgroundCornerFraction":0.012,
         "red":1,"green":1,"blue":1,"highlightsSpokenWord":false,"unspokenOpacity":0.55}
        """.utf8)
    let decoded = try JSONDecoder().decode(CaptionStyle.self, from: older)
    #expect(decoded.heightFraction == 0.05, "a field that WAS in the file was not read")
    #expect(decoded.alignment == CaptionStyle.default.alignment)
    #expect(decoded.horizontalFraction == CaptionStyle.default.horizontalFraction)
    #expect(decoded.isBold == CaptionStyle.default.isBold)
    #expect(decoded.plateRed == CaptionStyle.default.plateRed)
    #expect(decoded.shadowOpacity == CaptionStyle.default.shadowOpacity)
}

/// The synthesised decode also assigned straight past the clamping initialiser. A file claiming
/// a caption two frames tall is corrupt, not a decision, and it must not reach the renderer.
@Test func decodingClampsWhatTheInitialiserClamps() throws {
    let absurd = Data("""
        {"heightFraction":1000,"bottomInsetFraction":-5,"maximumWidthFraction":9,
         "backgroundOpacity":4,"backgroundCornerFraction":0.012,
         "red":9,"green":-1,"blue":0.5,"highlightsSpokenWord":true,"unspokenOpacity":0,
         "horizontalFraction":7,"shadowOpacity":3,"shadowBlurFraction":900}
        """.utf8)
    let decoded = try JSONDecoder().decode(CaptionStyle.self, from: absurd)
    #expect(decoded.heightFraction <= 0.5)
    #expect(decoded.bottomInsetFraction >= 0)
    #expect(decoded.red <= 1 && decoded.green >= 0)
    #expect(decoded.horizontalFraction <= 1)
    #expect(decoded.shadowOpacity <= 1)
    #expect(decoded.shadowBlurFraction <= 0.05,
            "a blur wider than the text is a smear, and minutes of Core Image per frame")
    #expect(decoded.unspokenOpacity >= 0.15,
            "at zero the caption becomes one word at a time, which is a different feature")
}

/// **Every one of the six reaches the renderer.** They were literals in `asTextStyle` — a
/// caption was always centred, never bold, always on a black plate and never had a shadow — so
/// the failure worth catching is a field that exists, is saved, and is still not drawn.
@Test func everyNewFieldSurvivesTheConversionToATextStyle() {
    let styled = CaptionStyle.default.changing(
        red: 0.2, green: 0.4, blue: 0.6,
        alignment: .leading, horizontalFraction: 0.15, isBold: true,
        plateRed: 0.9, plateGreen: 0.8, plateBlue: 0.7,
        shadowOpacity: 0.5, shadowBlurFraction: 0.01)
    let text = styled.asTextStyle

    #expect(text.anchor == .leading)
    #expect(text.x == 0.15)
    #expect(text.isBold)
    #expect(text.red == 0.2 && text.green == 0.4 && text.blue == 0.6)
    #expect(text.plateRed == 0.9 && text.plateGreen == 0.8 && text.plateBlue == 0.7)
    #expect(text.shadowOpacity == 0.5)
    #expect(text.shadowBlurFraction == 0.01)

    // And the default still converts to what it always did, so nothing about an untouched
    // caption moved.
    let untouched = CaptionStyle.default.asTextStyle
    #expect(untouched.anchor == .center)
    #expect(untouched.x == 0.5)
    #expect(untouched.isBold == false)
    #expect(untouched.plateRed == 0 && untouched.plateGreen == 0 && untouched.plateBlue == 0)
    #expect(untouched.shadowOpacity == 0)
}

/// A style round-trips through its own encoder unchanged. `changing` is sixteen parameters now,
/// and the failure it invites is one field quietly dropped on the way through.
@Test func everyFieldSurvivesItsOwnRoundTrip() throws {
    let styled = CaptionStyle.default.changing(
        heightFraction: 0.06, bottomInsetFraction: 0.1, backgroundOpacity: 0.3,
        highlightsSpokenWord: true, unspokenOpacity: 0.4,
        red: 0.1, green: 0.2, blue: 0.3,
        alignment: .trailing, horizontalFraction: 0.8, isBold: true,
        plateRed: 0.4, plateGreen: 0.5, plateBlue: 0.6,
        shadowOpacity: 0.7, shadowBlurFraction: 0.02)
    let coded = try JSONDecoder().decode(CaptionStyle.self,
                                         from: try JSONEncoder().encode(styled))
    #expect(coded == styled)
}

// MARK: - presets

/// **Each preset answers a different question, and this is what stops them becoming a palette.**
///
/// Four rows that differ only in colour would be a colour well with extra steps. The distinction
/// that matters is HOW each buys legibility over unknown footage — a plate, an outline, or the
/// word being lit — so that is what is asserted, not that the values are unequal.
@Test func everyPresetBuysLegibilityADifferentWay() throws {
    let byName = Dictionary(uniqueKeysWithValues: CaptionStyle.presets.map { ($0.name, $0.style) })
    #expect(byName.count == CaptionStyle.presets.count, "two presets share a name")

    let broadcast = try #require(byName["Broadcast"])
    let overPicture = try #require(byName["Over the picture"])
    let wordByWord = try #require(byName["Word by word"])
    let vertical = try #require(byName["Vertical"])

    // A plate, or not. This is the axis a person is actually choosing on.
    #expect(broadcast.backgroundOpacity > 0)
    #expect(vertical.backgroundOpacity > broadcast.backgroundOpacity,
            """
            the vertical preset's plate is not more opaque than broadcast's — it is for a frame \
            whose bottom is somebody else's interface, and a fainter plate there is not a \
            different answer
            """)
    #expect(overPicture.backgroundOpacity == 0, "a preset called Over the picture draws a plate")
    #expect(wordByWord.backgroundOpacity == 0)

    // The two that drop the plate must replace it, or they are the same caption with the
    // legibility taken out.
    for (name, style) in [("Over the picture", overPicture), ("Word by word", wordByWord)] {
        #expect(style.outlineWidthFraction > 0 && style.shadowOpacity > 0,
                """
                \(name) has no plate and no outline or shadow either — it is unreadable over \
                anything bright, which is the case it exists for
                """)
        #expect(style.isBold,
                """
                \(name) strokes an outline down the middle of the letterform, which thins light \
                type; it is bold for that reason and this one is not
                """)
    }

    // Only one lights the word, and only that one needs word timings.
    let highlighting = CaptionStyle.presets.filter { $0.style.highlightsSpokenWord }
    #expect(highlighting.map(\.name) == ["Word by word"],
            """
            the presets that light the spoken word are \(highlighting.map(\.name)) — exactly one \
            should, or the name stops meaning anything
            """)

    // The vertical one is the only one that clears the bottom of the frame by more than the
    // ordinary inset, which is the entire reason it exists.
    #expect(vertical.bottomInsetFraction > 2 * broadcast.bottomInsetFraction)
    #expect(vertical.heightFraction > broadcast.heightFraction)
}

/// The picker names what is on the screen, or nothing.
@Test func aStyleMovedOffAPresetMatchesNoPreset() throws {
    for preset in CaptionStyle.presets {
        #expect(preset.style.matchingPreset?.name == preset.name,
                """
                \(preset.name) does not match itself — `matchingPreset` is full equality, so this \
                means two presets are identical
                """)
    }

    // One control moved, and the picker must stop claiming the preset. Height is used because
    // it is the first slider in the panel; any field would do, which is the point of equality.
    let edited = CaptionStyle.default.changing(heightFraction: 0.08)
    #expect(edited != CaptionStyle.default)
    #expect(edited.matchingPreset == nil,
            """
            a style with a moved slider still names a preset — the picker would be labelling \
            something that is not on the screen
            """)

    // And a font is part of the style, not an ornament on top of it: uploading one leaves every
    // preset behind, which is truthful rather than harsh.
    #expect(CaptionStyle.default.changing(fontFilename: "Brand.ttf").matchingPreset == nil)
}

/// **The values are what a project keeps, and the name is not.** A file that stored "Broadcast"
/// would open looking different the day somebody edited the table — the producer-value rule, in
/// the place it is easiest to break.
@Test func aPresetSurvivesTheRoundTripAsValuesRatherThanAsAName() throws {
    for preset in CaptionStyle.presets {
        let coded = try JSONDecoder().decode(
            CaptionStyle.self, from: try JSONEncoder().encode(preset.style))
        #expect(coded == preset.style, "\(preset.name) did not survive a round trip")

        // Nothing in the encoded form names the preset. If a `name` key ever appears here, the
        // style has started remembering which button was pressed instead of what it looks like.
        let object = try #require(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(preset.style)) as? [String: Any])
        #expect(object["name"] == nil && object["preset"] == nil,
                "the encoded style carries the preset's identity, not only its values")
    }
}

/// Every preset says what it is for, and says it once.
@Test func everyPresetCarriesASentenceThatIsNotItsName() {
    for preset in CaptionStyle.presets {
        #expect(!preset.name.isEmpty)
        #expect(preset.detail.count > preset.name.count,
                """
                \(preset.name)'s detail is not a sentence — the picker shows it to somebody who \
                is deciding, not auditing
                """)
        #expect(preset.detail.contains(";") || preset.detail.contains("—")
                    || preset.detail.contains(". "),
                "\(preset.name)'s detail names a benefit with no cost beside it")
    }
}
