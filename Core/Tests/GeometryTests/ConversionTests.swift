import Testing
import Foundation
@testable import Geometry

/// A 1000×800 display at 2x scale, sized so every normalised fraction below is
/// an exact `Double` and the tolerance cannot hide a formula bug.
private let testGeometry = DisplayGeometry(
    displayUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    pixelWidth: 1000,
    pixelHeight: 800,
    scale: 2.0
)

private let otherGeometry = DisplayGeometry(
    displayUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
    pixelWidth: 1920,
    pixelHeight: 1080,
    scale: 1.0
)

private let context = NormalizationContext(geometry: testGeometry)

// MARK: - direction: top vs. bottom

// Pins the sign of the flip; `(0.5, 0.5)` alone could not.
@Test func rectAtTheInputTopLeftCornerLandsAtHighNormalizedY() {
    let f = context.normalize(topLeftX: 0, topLeftY: 0, width: 100, height: 50)
    #expect(f.origin.y > 0.9, "a rect at the top of the display must normalise near y=1, got \(f.origin.y)")
}

@Test func rectAtTheInputBottomLeftCornerLandsAtLowNormalizedY() {
    // topLeftY + height == pixelHeight: flush against the bottom edge.
    let f = context.normalize(topLeftX: 0, topLeftY: 750, width: 100, height: 50)
    #expect(f.origin.y.isApproximatelyEqual(to: 0),
            "a rect at the bottom of the display must normalise near y=0, got \(f.origin.y)")
}

@Test func pointAtTheInputTopLandsAtHighNormalizedY() {
    let p = context.normalize(topLeftX: 500, topLeftY: 0)
    #expect(p.y > 0.9, "a point at the top of the display must normalise near y=1, got \(p.y)")
}

@Test func pointAtTheInputBottomLandsAtLowNormalizedY() {
    let p = context.normalize(topLeftX: 500, topLeftY: 800)
    #expect(p.y.isApproximatelyEqual(to: 0),
            "a point at the bottom of the display must normalise near y=0, got \(p.y)")
}

// MARK: - centre

@Test func pointAtExactCentreMapsToHalfHalf() {
    let p = context.normalize(topLeftX: 500, topLeftY: 400)
    #expect(p.x.isApproximatelyEqual(to: 0.5))
    #expect(p.y.isApproximatelyEqual(to: 0.5))
}

// MARK: - the anchor: top edge vs. bottom edge of the rect

@Test func normalizedYAnchorsOnTheRectsBottomEdgeNotItsTopEdge() {
    // The rect's TOP edge sits at the display's vertical centre, so the wrong
    // top-edge formula gives exactly 0.5 and the bottom-edge one lands below it.
    let f = context.normalize(topLeftX: 0, topLeftY: 400, width: 0, height: 100)
    let expected = 1 - (500.0 / 800.0) // (topLeftY + height) / pixelHeight, flipped
    #expect(f.origin.y.isApproximatelyEqual(to: expected))
    #expect(f.origin.y < 0.5, "using the rect's top edge instead of its bottom edge as the anchor")
}

// MARK: - round trip — a rect that is NOT vertically centred

// Off-centre on purpose: a centred rect round-trips even under an inverted flip.
@Test func denormalizeInvertsNormalizeForANonCentredRect() {
    let original = PixelRect(x: 50, y: 100, width: 200, height: 120)
    let frame = context.normalize(topLeftX: original.x, topLeftY: original.y,
                                   width: original.width, height: original.height)
    let roundTripped = context.denormalize(frame)
    #expect(roundTripped.x.isApproximatelyEqual(to: original.x))
    #expect(roundTripped.y.isApproximatelyEqual(to: original.y))
    #expect(roundTripped.width.isApproximatelyEqual(to: original.width))
    #expect(roundTripped.height.isApproximatelyEqual(to: original.height))
}

@Test func denormalizeInvertsNormalizeForAPointSizedRectAtTheOrigin() {
    let original = PixelRect(x: 0, y: 0, width: 0, height: 0)
    let frame = context.normalize(topLeftX: original.x, topLeftY: original.y,
                                   width: original.width, height: original.height)
    let roundTripped = context.denormalize(frame)
    #expect(roundTripped.x.isApproximatelyEqual(to: original.x))
    #expect(roundTripped.y.isApproximatelyEqual(to: original.y))
}

// MARK: - revision

@Test func normalizedFrameCarriesTheContextsDisplayRevision() {
    let f = context.normalize(topLeftX: 10, topLeftY: 10, width: 20, height: 20)
    #expect(f.revision == testGeometry.revision)
}

@Test func differentDisplaysProduceDifferentRevisionsOnTheirFrames() {
    let otherContext = NormalizationContext(geometry: otherGeometry)
    let a = context.normalize(topLeftX: 10, topLeftY: 10, width: 20, height: 20)
    let b = otherContext.normalize(topLeftX: 10, topLeftY: 10, width: 20, height: 20)
    #expect(a.revision != b.revision)
}

// MARK: - denormalize's revision precondition
//
// No crash expectation exists, so the cross-revision trap is verified
// out-of-process; this is only its negative control.
@Test func denormalizeOfASameRevisionFrameNeverTraps() {
    let f = context.normalize(topLeftX: 10, topLeftY: 10, width: 20, height: 20)
    let r = context.denormalize(f)
    #expect(r.width.isApproximatelyEqual(to: 20))
}

// MARK: - PixelRect

@Test func pixelRectZeroSizeIsAllowed() {
    _ = PixelRect(x: 0, y: 0, width: 0, height: 0)
}

@Test func pixelRectRoundTripsThroughCodable() throws {
    let r = PixelRect(x: 12.5, y: 34.5, width: 100, height: 50)
    let decoded = try JSONDecoder().decode(PixelRect.self, from: JSONEncoder().encode(r))
    #expect(decoded == r)
}

private extension Double {
    func isApproximatelyEqual(to other: Double, tolerance: Double = 1e-9) -> Bool {
        abs(self - other) <= tolerance
    }
}
