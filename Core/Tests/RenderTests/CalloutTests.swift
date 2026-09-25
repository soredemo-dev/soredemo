import Testing
import Foundation
@testable import Render

// A callout: a text bubble with a tail, pointing at something in the RECORDING. It is an
// annotation rather than a text overlay because only annotations are anchored to the picture —
// a tail that stayed put while the camera zoomed would point at the wrong thing on every frame
// after the zoom. See `docs/design/2026-09-25-the-callout.md`.

@Test func aCalloutIsAFilledShapeAndTheLinesAreNot() {
    #expect(AnnotationShape.callout.canBeFilled, "the bubble is a filled shape")
    #expect(!AnnotationShape.arrow.canBeFilled)
    #expect(!AnnotationShape.line.canBeFilled)
    #expect(AnnotationShape.callout.displayName == "Callout")
}

/// **A callout with nothing written in it has nothing to say**, so it is empty in the same sense
/// a zero-length drag is: nothing is drawn, rather than an empty bubble being drawn.
@Test func aCalloutWithNoTextIsEmpty() {
    let blank = AnnotationOverlay(shape: .callout, startX: 100, startY: 100,
                                  endX: 300, endY: 200, style: .default, text: "")
    #expect(blank.isEmpty)
    let spoken = AnnotationOverlay(shape: .callout, startX: 100, startY: 100,
                                   endX: 300, endY: 200, style: .default, text: "Click here")
    #expect(!spoken.isEmpty)
}

/// Whitespace is not text. A bubble around three spaces is an empty bubble with extra steps.
@Test func aCalloutOfNothingButSpacesIsEmpty() {
    let blank = AnnotationOverlay(shape: .callout, startX: 0, startY: 0, endX: 50, endY: 50,
                                  style: .default, text: "   \n\t ")
    #expect(blank.isEmpty)
}

/// The rule that empties a callout must not empty an arrow — an arrow says what it says by
/// pointing, and has never carried text.
@Test func anArrowWithNoTextIsStillDrawn() {
    let arrow = AnnotationOverlay(shape: .arrow, startX: 0, startY: 0, endX: 80, endY: 40,
                                  style: .default, text: "")
    #expect(!arrow.isEmpty)
}

/// **Text is stored on every shape, not refused on the ones that cannot draw it** — the rule
/// `fillOpacity` already follows on an arrow. Switching a callout to an arrow and back must not
/// silently discard what somebody typed.
@Test func textSurvivesOnAShapeThatCannotDrawIt() {
    let arrow = AnnotationOverlay(shape: .arrow, startX: 0, startY: 0, endX: 80, endY: 40,
                                  style: .default, text: "kept")
    #expect(arrow.text == "kept")
}

/// A fraction of the output's shorter edge, like every other measurement here, and clamped for
/// `strokeWidthFraction`'s reason: a slider and a decoder both reach the initialiser, and a text
/// size of zero is a callout that silently says nothing.
@Test func theTextSizeIsAFractionAndIsClamped() {
    #expect(AnnotationStyle.default.textSizeFraction > 0)
    let tiny = AnnotationStyle.default.changing(textSizeFraction: -4)
    let huge = AnnotationStyle.default.changing(textSizeFraction: 99)
    #expect(tiny.textSizeFraction == AnnotationStyle.smallestTextFraction)
    #expect(huge.textSizeFraction == AnnotationStyle.largestTextFraction)
    #expect(tiny.textSizeFraction > 0)
}

/// `changing` rebuilds the whole struct, so a field it forgets is reset — the defect
/// `StageStylePicker.apply` had. Every other field must survive a change to the text size.
@Test func everyAnnotationStyleFieldSurvivesAChangeToTheTextSize() {
    let distinctive = AnnotationStyle(strokeWidthFraction: 0.011, red: 0.2, green: 0.3, blue: 0.4,
                                      alpha: 0.9, fillOpacity: 0.35, shadowOpacity: 0.2,
                                      shadowBlurFraction: 0.01, textSizeFraction: 0.04)
    let changed = distinctive.changing(textSizeFraction: 0.05)
    #expect(changed.strokeWidthFraction == distinctive.strokeWidthFraction)
    #expect(changed.red == distinctive.red && changed.green == distinctive.green
            && changed.blue == distinctive.blue)
    #expect(changed.alpha == distinctive.alpha)
    #expect(changed.fillOpacity == distinctive.fillOpacity)
    #expect(changed.shadowOpacity == distinctive.shadowOpacity)
    #expect(changed.shadowBlurFraction == distinctive.shadowBlurFraction)
    #expect(changed.textSizeFraction == 0.05)
}

/// Rule 8: the synthesised decode assigns stored properties directly, so a saved project could
/// otherwise carry a text size the initialiser exists to refuse.
@Test func decodingAnAnnotationStyleClampsTheTextSize() throws {
    let wild = Data(#"""
        {"strokeWidthFraction":0.006,"red":1,"green":0,"blue":0,"alpha":1,"fillOpacity":0,
         "shadowOpacity":0,"shadowBlurFraction":0,"textSizeFraction":900}
        """#.utf8)
    let decoded = try JSONDecoder().decode(AnnotationStyle.self, from: wild)
    #expect(decoded.clamped.textSizeFraction == AnnotationStyle.largestTextFraction)
}
