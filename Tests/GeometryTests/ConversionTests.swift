import Testing
import Foundation
@testable import Geometry

/// A 1000×800 display at 2x scale. Numbers chosen so pixel/normalised
/// fractions are exact `Double`s (no repeating binary fractions), which keeps
/// the tolerance in `isApproximatelyEqual` doing nothing but guard against
/// genuine floating-point round-off, not hide a formula bug.
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

// This is the test that actually pins the sign of the flip. `(0.5, 0.5)`
// alone is symmetric under `1 - y` vs. `y` — this is not.
@Test func rectAtTheInputTopLeftCornerLandsAtHighNormalizedY() {
    // topLeftY: 0, i.e. flush against the top edge in top-left pixel space.
    let f = context.normalize(topLeftX: 0, topLeftY: 0, width: 100, height: 50)
    #expect(f.origin.y > 0.9, "a rect at the top of the display must normalise near y=1, got \(f.origin.y)")
}

@Test func rectAtTheInputBottomLeftCornerLandsAtLowNormalizedY() {
    // topLeftY + height == pixelHeight, i.e. flush against the bottom edge.
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

// MARK: - centre — necessary but not sufficient on its own

@Test func pointAtExactCentreMapsToHalfHalf() {
    let p = context.normalize(topLeftX: 500, topLeftY: 400)
    #expect(p.x.isApproximatelyEqual(to: 0.5))
    #expect(p.y.isApproximatelyEqual(to: 0.5))
}

// MARK: - the anchor: top edge vs. bottom edge of the rect

@Test func normalizedYAnchorsOnTheRectsBottomEdgeNotItsTopEdge() {
    // A rect whose TOP edge sits exactly at the display's vertical centre.
    // Using the (wrong) top-edge formula `1 - topLeftY/H` would put origin.y
    // at exactly 0.5. The correct, bottom-edge formula
    // `1 - (topLeftY + height)/H` must instead land below 0.5, by exactly
    // height/H.
    let f = context.normalize(topLeftX: 0, topLeftY: 400, width: 0, height: 100)
    let expected = 1 - (500.0 / 800.0) // (topLeftY + height) / pixelHeight, flipped
    #expect(f.origin.y.isApproximatelyEqual(to: expected))
    #expect(f.origin.y < 0.5, "using the rect's top edge instead of its bottom edge as the anchor")
}

// MARK: - round trip — a rect that is NOT vertically centred

// A vertically centred rect round-trips even if the flip were inverted, by
// symmetry — it would not catch a sign error. This rect's vertical centre
// (100 + 120/2 = 160) is far from the display's (400), so it doesn't share
// that blind spot.
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
// A `precondition` failure kills the process; Swift Testing has no crash
// expectation, so the cross-revision trap on `denormalize` cannot be
// exercised with `#expect` in this suite — same limitation as
// `NormalizedFrame.contains`/`intersects` (see `NormalizedTests.swift`). It
// is verified out-of-process instead, recorded in the task report, not here.
// What CAN be shown in-process is the negative control: denormalizing a
// frame that DOES match the context's revision never traps, which the round
// trip tests above already demonstrate by not crashing.
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
