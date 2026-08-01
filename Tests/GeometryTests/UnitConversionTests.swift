import Testing
import Foundation
@testable import Geometry

/// Task 10.5: `PointRect` and `DisplayGeometry.pixels(from:)` /
/// `.points(from:)`. Every fixture here uses `scale: 2` — never `scale: 1`,
/// which is the identity of the conversion these tests exist to check
/// (`AGENTS.md`'s fixture rule; the same rule `ArrangementTests.swift` now
/// follows for the same reason).
private let scaledGeometry = DisplayGeometry(
    displayUUID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
    pixelWidth: 2000,
    pixelHeight: 1600,
    scale: 2.0
)

// MARK: - PointRect, mirroring PixelRect's own tests

@Test func pointRectZeroSizeIsAllowed() {
    _ = PointRect(x: 0, y: 0, width: 0, height: 0)
}

@Test func pointRectRoundTripsThroughCodable() throws {
    let r = PointRect(x: 12.5, y: 34.5, width: 100, height: 50)
    let decoded = try JSONDecoder().decode(PointRect.self, from: JSONEncoder().encode(r))
    #expect(decoded == r)
}

// MARK: - the conversion itself: `scale: 2`, so pixels and points genuinely differ

@Test func pixelsFromPointsMultipliesEveryFieldByScale() {
    let points = PointRect(x: 10, y: 20, width: 30, height: 40)
    let pixels = scaledGeometry.pixels(from: points)
    #expect(pixels.x == 20)
    #expect(pixels.y == 40)
    #expect(pixels.width == 60)
    #expect(pixels.height == 80)
}

@Test func pointsFromPixelsDividesEveryFieldByScale() {
    let pixels = PixelRect(x: 20, y: 40, width: 60, height: 80)
    let points = scaledGeometry.points(from: pixels)
    #expect(points.x == 10)
    #expect(points.y == 20)
    #expect(points.width == 30)
    #expect(points.height == 40)
}

// MARK: - round trip, both directions

@Test func pointsToPixelsToPointsRoundTrips() {
    let original = PointRect(x: 111, y: 222, width: 333, height: 444)
    let roundTripped = scaledGeometry.points(from: scaledGeometry.pixels(from: original))
    #expect(roundTripped == original)
}

@Test func pixelsToPointsToPixelsRoundTrips() {
    let original = PixelRect(x: 111, y: 222, width: 333, height: 444)
    let roundTripped = scaledGeometry.pixels(from: scaledGeometry.points(from: original))
    #expect(roundTripped == original)
}

// MARK: - negative control: at `scale: 1`, points and pixels genuinely coincide
//
// Not the primary evidence for the conversion (that's the scale-2 cases
// above, which are the only ones that can fail if the division/multiplication
// is dropped or inverted) — this just confirms `scale: 1` isn't itself
// mishandled as a special case.

private let unscaledGeometry = DisplayGeometry(
    displayUUID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!,
    pixelWidth: 1000,
    pixelHeight: 800,
    scale: 1.0
)

@Test func atScaleOnePointsAndPixelsCoincide() {
    let points = PointRect(x: 5, y: 6, width: 7, height: 8)
    let pixels = unscaledGeometry.pixels(from: points)
    #expect(pixels.x == points.x)
    #expect(pixels.y == points.y)
    #expect(pixels.width == points.width)
    #expect(pixels.height == points.height)
}
