import Testing
import Foundation
@testable import Geometry

// The arithmetic the window-resize repair rests on. Every number in
// `theMeasuredConversionIsReproduced` came off a running stream against the bounding box of the
// pixels a window actually lit — see `CropRect.ofContent(inPoints:scaleFactor:...)` — so this
// file is where that measurement is kept from rotting into a comment nobody re-runs.

// MARK: - composing a person's crop with the capture's

@Test func composingWithTheWholeRecordingChangesNothingInEitherDirection() {
    let half = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    #expect(half.within(.whole) == half)
    #expect(CropRect.whole.within(half) == half)
}

@Test func anAuthoredCropIsReadAsAFractionOfWhatThePersonCouldSee() {
    // The capture put the window in the left 80% and the top 50% of the buffer.
    let content = CropRect(x: 0, y: 0, width: 0.8, height: 0.5)
    // On that picture, the person cropped to its right half.
    let authored = CropRect(x: 0.5, y: 0, width: 0.5, height: 1)

    let combined = authored.within(content)

    // Their "half way across the window" is 40% across the BUFFER, not 50%.
    #expect(abs(combined.x - 0.4) < 1e-12)
    #expect(abs(combined.width - 0.4) < 1e-12)
    // And the vertical is untouched by their crop but still bounded by the capture's.
    #expect(combined.y == 0)
    #expect(abs(combined.height - 0.5) < 1e-12)
}

@Test func composingTheOtherWayRoundIsADifferentRectangle() {
    // The mistake this method's name exists to make visible: `content.within(authored)` reads
    // the capture's rectangle as a fraction of the person's, which nobody ever meant.
    let content = CropRect(x: 0, y: 0, width: 0.8, height: 0.5)
    let authored = CropRect(x: 0.5, y: 0, width: 0.5, height: 1)
    #expect(authored.within(content) != content.within(authored))
}

@Test func aComposedCropStaysInsideTheRecording() {
    let content = CropRect(x: 0.6, y: 0.6, width: 0.4, height: 0.4)
    let authored = CropRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1)
    let combined = authored.within(content)
    #expect(combined.x >= 0 && combined.y >= 0)
    #expect(combined.x + combined.width <= 1 + 1e-12)
    #expect(combined.y + combined.height <= 1 + 1e-12)
}

// MARK: - the measured conversion

/// The three geometries measured on a 2× display against a fixed 1600×1064 buffer, with the
/// window resized underneath a running stream. Reproduced here as the recorded attachment
/// values, checked against the bounding box of the lit pixels the same run measured.
@Test func theMeasuredConversionIsReproduced() {
    let bufferWidth = 1600
    let bufferHeight = 1064

    // 1. The window as the stream was configured for it: content fills the buffer.
    let filling = CropRect.ofContent(inPoints: PointRect(x: 0, y: 0, width: 800, height: 532),
                                     scaleFactor: 2, bufferWidth: bufferWidth,
                                     bufferHeight: bufferHeight)
    #expect(filling == .whole)

    // 2. Shrunk to 400×300. The lit box was 1419×1064 of 1600×1064 — 181 columns of
    // background down the right, which is the black band this whole mechanism removes.
    let shrunk = CropRect.ofContent(
        inPoints: PointRect(x: 0, y: 0, width: 709.333324432373, height: 531.9999933242798),
        scaleFactor: 2, bufferWidth: bufferWidth, bufferHeight: bufferHeight)
    #expect(shrunk != nil)
    #expect(abs((shrunk?.width ?? 0) * Double(bufferWidth) - 1419) < 1)
    #expect(abs((shrunk?.height ?? 0) * Double(bufferHeight) - 1064) < 1)

    // 3. Grown to 1100×700. The lit box was 1600×1019 — the band is along the BOTTOM, and the
    // attachment still reported y = 0, which is what fixes `y` as running from the top.
    let grown = CropRect.ofContent(
        inPoints: PointRect(x: 0, y: 0, width: 800.0000238418579, height: 509.0909242630005),
        scaleFactor: 2, bufferWidth: bufferWidth, bufferHeight: bufferHeight)
    #expect(grown != nil)
    #expect(grown?.y == 0)
    #expect(abs((grown?.height ?? 0) * Double(bufferHeight) - 1019) < 1)
}

@Test func theRivalConversionsAreNotQuietlyRight() {
    // A guard against somebody "simplifying" the factor away. Against the shrunk case, using
    // the rect as-is or the content scale instead of `scaleFactor` misses the measured box by
    // hundreds of pixels; the test above would still pass under a change that swapped them
    // only if they happened to agree, and on this geometry they do not.
    let asIs = CropRect.ofContent(
        inPoints: PointRect(x: 0, y: 0, width: 709.333324432373, height: 531.9999933242798),
        scaleFactor: 1, bufferWidth: 1600, bufferHeight: 1064)
    #expect(((asIs?.width ?? 0) * 1600) < 800)   // measured box was 1419
}

@Test func anUnusableMeasurementIsRefusedRatherThanGuessed() {
    let rect = PointRect(x: 0, y: 0, width: 800, height: 532)
    #expect(CropRect.ofContent(inPoints: rect, scaleFactor: 2,
                               bufferWidth: 0, bufferHeight: 1064) == nil)
    #expect(CropRect.ofContent(inPoints: rect, scaleFactor: 0,
                               bufferWidth: 1600, bufferHeight: 1064) == nil)
    #expect(CropRect.ofContent(inPoints: rect, scaleFactor: .nan,
                               bufferWidth: 1600, bufferHeight: 1064) == nil)
    #expect(CropRect.ofContent(inPoints: PointRect(x: 0, y: 0, width: 0, height: 532),
                               scaleFactor: 2, bufferWidth: 1600, bufferHeight: 1064) == nil)
}

// MARK: - the change detection, which is the writer's whole cost control

@Test func floatingPointNoiseInTheAttachmentIsNotAResize() {
    let steady = CropRect(x: 0, y: 0, width: 0.8866666555404663, height: 1)
    // The same rectangle as the stream reports it one frame later, differing in the low digits.
    let again = CropRect(x: 0, y: 0, width: 0.8866666555404664, height: 1)
    #expect(!again.differs(from: steady, byHalfAPixelIn: 1600, bufferHeight: 1064))
}

@Test func aResizeOfAWholePixelIsAResize() {
    let before = CropRect(x: 0, y: 0, width: 1419.0 / 1600, height: 1)
    let after = CropRect(x: 0, y: 0, width: 1418.0 / 1600, height: 1)
    #expect(after.differs(from: before, byHalfAPixelIn: 1600, bufferHeight: 1064))
}

@Test func aMoveTooSmallToSeeIsNotWritten() {
    let before = CropRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    // A quarter of a pixel on each edge, in both axes.
    let after = CropRect(x: 0.4 + 0.25 / 1600, y: 0.4 + 0.25 / 1064,
                         width: 0.2, height: 0.2)
    #expect(!after.differs(from: before, byHalfAPixelIn: 1600, bufferHeight: 1064))
}

@Test func withNoBufferToMeasureAgainstOnlyExactEqualityWillDo() {
    // A zero buffer cannot say what half a pixel is, so the comparison must not silently
    // become "everything is the same" — which is the shape that would stop every record.
    let a = CropRect(x: 0, y: 0, width: 0.5, height: 1)
    let b = CropRect(x: 0, y: 0, width: 0.5000000001, height: 1)
    #expect(a.differs(from: b, byHalfAPixelIn: 0, bufferHeight: 0))
    #expect(!a.differs(from: a, byHalfAPixelIn: 0, bufferHeight: 0))
}
