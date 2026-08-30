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
