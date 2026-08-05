import Testing
import Foundation
@testable import Geometry

private let revA = GeometryRevision(id: 1)
private let revB = GeometryRevision(id: 2)

private func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double,
                    revision: GeometryRevision = revA) -> NormalizedFrame {
    NormalizedFrame(origin: NormalizedPoint(x: x, y: y),
                    size: NormalizedSize(width: w, height: h),
                    revision: revision)
}

// MARK: - NormalizedPoint / NormalizedSize — plain value types

@Test func equalPointsCompareEqual() {
    #expect(NormalizedPoint(x: 0.5, y: 0.25) == NormalizedPoint(x: 0.5, y: 0.25))
}

@Test func differentPointsCompareUnequal() {
    #expect(NormalizedPoint(x: 0.5, y: 0.25) != NormalizedPoint(x: 0.5, y: 0.75))
}

@Test func equalSizesCompareEqual() {
    #expect(NormalizedSize(width: 0.4, height: 0.6) == NormalizedSize(width: 0.4, height: 0.6))
}

@Test func zeroSizeIsAllowed() {
    // A zero-area frame is legitimate; only NEGATIVE dimensions are rejected.
    _ = NormalizedSize(width: 0, height: 0)
}

@Test func pointRoundTripsThroughCodable() throws {
    let p = NormalizedPoint(x: 0.125, y: 0.875)
    let decoded = try JSONDecoder().decode(NormalizedPoint.self, from: JSONEncoder().encode(p))
    #expect(decoded == p)
}

@Test func sizeRoundTripsThroughCodable() throws {
    let s = NormalizedSize(width: 0.3, height: 0.9)
    let decoded = try JSONDecoder().decode(NormalizedSize.self, from: JSONEncoder().encode(s))
    #expect(decoded == s)
}

// MARK: - NormalizedFrame — edges

@Test func edgesAreDerivedFromOriginAndSize() {
    let f = frame(0.1, 0.2, 0.3, 0.4)
    #expect(f.minX == 0.1)
    #expect(f.minY == 0.2)
    #expect(f.maxX.isApproximatelyEqual(to: 0.4))
    #expect(f.maxY.isApproximatelyEqual(to: 0.6))
}

@Test func frameRoundTripsThroughCodable() throws {
    let f = frame(0.1, 0.2, 0.3, 0.4)
    let decoded = try JSONDecoder().decode(NormalizedFrame.self, from: JSONEncoder().encode(f))
    #expect(decoded == f)
}

// MARK: - contains — same revision

@Test func aFrameContainsItself() {
    let f = frame(0.2, 0.2, 0.3, 0.3)
    #expect(f.contains(f))
}

@Test func aFrameContainsAStrictSubFrame() {
    let outer = frame(0, 0, 1, 1)
    let inner = frame(0.25, 0.25, 0.5, 0.5)
    #expect(outer.contains(inner))
}

@Test func aFrameDoesNotContainAFrameThatEscapesIt() {
    let outer = frame(0, 0, 0.5, 0.5)
    let escaping = frame(0.25, 0.25, 0.5, 0.5)
    #expect(!outer.contains(escaping))
}

@Test func aSmallerFrameDoesNotContainALargerOne() {
    let small = frame(0.25, 0.25, 0.1, 0.1)
    let large = frame(0, 0, 1, 1)
    #expect(!small.contains(large))
}

// MARK: - intersects — same revision

@Test func overlappingFramesIntersect() {
    let a = frame(0, 0, 0.6, 0.6)
    let b = frame(0.4, 0.4, 0.6, 0.6)
    #expect(a.intersects(b))
    #expect(b.intersects(a))
}

@Test func disjointFramesDoNotIntersect() {
    let a = frame(0, 0, 0.2, 0.2)
    let b = frame(0.8, 0.8, 0.2, 0.2)
    #expect(!a.intersects(b))
    #expect(!b.intersects(a))
}

@Test func adjacentEdgeTouchingFramesDoNotIntersect() {
    // Sharing only a boundary edge is not an overlap.
    let a = frame(0, 0, 0.5, 0.5)
    let b = frame(0.5, 0, 0.5, 0.5)
    #expect(!a.intersects(b))
}

@Test func aFrameIntersectsItself() {
    let f = frame(0.2, 0.2, 0.3, 0.3)
    #expect(f.intersects(f))
}

@Test func containmentImpliesIntersection() {
    let outer = frame(0, 0, 1, 1)
    let inner = frame(0.25, 0.25, 0.5, 0.5)
    #expect(outer.contains(inner))
    #expect(outer.intersects(inner))
}

// MARK: - the cross-revision precondition
//
// Swift Testing has no crash expectation, so the trap is verified
// out-of-process; this is only its negative control.
@Test func sameRevisionFramesNeverReachThePreconditionEitherDirection() {
    let a = frame(0, 0, 1, 1, revision: revA)
    let b = frame(0, 0, 1, 1, revision: revA)
    #expect(a.contains(b))
    #expect(a.intersects(b))
}

private extension Double {
    func isApproximatelyEqual(to other: Double, tolerance: Double = 1e-9) -> Bool {
        abs(self - other) <= tolerance
    }
}
