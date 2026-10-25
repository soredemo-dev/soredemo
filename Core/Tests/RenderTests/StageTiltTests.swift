import Testing
import Foundation
@testable import Render

// Turning the card. `StageTilt.quad(for:)` is the whole of the maths — the renderer only hands
// the four points to `CIPerspectiveTransform` — so this is where the effect is pinned.

private let card = StageRect(x: 100, y: 50, width: 800, height: 450)

@Test func aFlatTiltLeavesTheCardExactlyWhereItWas() {
    let quad = StageTilt.flat.quad(for: card)
    #expect(quad.topLeft.x == card.x)
    #expect(quad.topRight.x == card.x + card.width)
    #expect(quad.bottomLeft.y == card.y)
    #expect(quad.topLeft.y == card.y + card.height)
    #expect(StageTilt.flat.isFlat)
}

/// **The point of a perspective transform, and the reason an affine one will not do.** Turning
/// the card about its vertical axis must make one side SHORTER than the other; an affine
/// transform keeps them equal and reads as a shear.
@Test func yawMakesOneVerticalEdgeShorterThanTheOther() {
    let quad = StageTilt(pitch: 0, yaw: 30, distance: 2.5).quad(for: card)
    let left = quad.topLeft.y - quad.bottomLeft.y
    let right = quad.topRight.y - quad.bottomRight.y
    #expect(abs(left - right) > 1, "yaw produced two edges of the same height: \(left) vs \(right)")
}

@Test func pitchMakesOneHorizontalEdgeShorterThanTheOther() {
    let quad = StageTilt(pitch: 25, yaw: 0, distance: 2.5).quad(for: card)
    let top = quad.topRight.x - quad.topLeft.x
    let bottom = quad.bottomRight.x - quad.bottomLeft.x
    #expect(abs(top - bottom) > 1, "pitch produced two edges of the same width: \(top) vs \(bottom)")
}

/// The sign has to mean something a person can predict: a positive yaw turns the card's right
/// edge AWAY, so that edge is the shorter one.
@Test func aPositiveYawTurnsTheRightEdgeAway() {
    let quad = StageTilt(pitch: 0, yaw: 30, distance: 2.5).quad(for: card)
    let left = quad.topLeft.y - quad.bottomLeft.y
    let right = quad.topRight.y - quad.bottomRight.y
    #expect(right < left, "the turned-away edge should be shorter: right \(right), left \(left)")
}

/// **The same tilt on a bigger card must look the same.** The strength of a perspective is a
/// ratio, so the distance is in card-widths — a card twice the size tilted identically produces a
/// quad twice the size, and not a weaker effect.
@Test func theSameTiltLooksTheSameAtEverySize() {
    let tilt = StageTilt(pitch: 20, yaw: 20, distance: 2.5)
    let small = tilt.quad(for: StageRect(x: 0, y: 0, width: 400, height: 225))
    let large = tilt.quad(for: StageRect(x: 0, y: 0, width: 800, height: 450))
    #expect(abs(large.topLeft.x - small.topLeft.x * 2) < 0.001)
    #expect(abs(large.topLeft.y - small.topLeft.y * 2) < 0.001)
    #expect(abs(large.bottomRight.x - small.bottomRight.x * 2) < 0.001)
}

/// **No corner may land behind the camera**, and that is arranged by clamping rather than checked
/// at use. Every extreme a slider or a decoder can offer still projects to a finite quad.
@Test func everyExtremeStillProjectsToAFiniteQuad() {
    for pitch in [-720.0, -89, 0, 89, 720, .infinity, .nan] {
        for yaw in [-720.0, -89, 0, 89, 720, .infinity, .nan] {
            for distance in [-5.0, 0, 0.0001, 1, 50, .infinity, .nan] {
                let quad = StageTilt(pitch: pitch, yaw: yaw, distance: distance).quad(for: card)
                for point in [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft] {
                    #expect(point.x.isFinite && point.y.isFinite,
                            "pitch \(pitch) yaw \(yaw) distance \(distance) gave \(point)")
                }
            }
        }
    }
}

@Test func theAnglesAndTheDistanceAreClampedAtConstruction() {
    let wild = StageTilt(pitch: 200, yaw: -200, distance: 0.01)
    #expect(wild.pitch == StageTilt.steepestAngle)
    #expect(wild.yaw == -StageTilt.steepestAngle)
    #expect(wild.distance == StageTilt.nearestDistance)
    // A tilt that is not flat must not report itself flat — `isFlat` is what skips the filter.
    #expect(!wild.isFlat)
}

/// Rule 8. The synthesised decode assigns stored properties directly, so a document could
/// otherwise carry an angle the initialiser exists to refuse.
@Test func decodingATiltRefusesWhatTheInitialiserWouldClamp() throws {
    let good = StageTilt(pitch: 12, yaw: -8, distance: 3)
    let encoded = try JSONEncoder().encode(good)
    #expect(try JSONDecoder().decode(StageTilt.self, from: encoded) == good)

    let wild = Data(#"{"pitch":400,"yaw":-400,"distance":0.001}"#.utf8)
    let decoded = try JSONDecoder().decode(StageTilt.self, from: wild)
    #expect(decoded.pitch == StageTilt.steepestAngle)
    #expect(decoded.yaw == -StageTilt.steepestAngle)
    #expect(decoded.distance == StageTilt.nearestDistance)
}

/// **A point behind the card is a different point only when the card is turned.** At depth zero
/// the projection is the face's own — the pointer's placement rests on that — and a flat card
/// hides its back exactly behind its face. A card off the origin and not square, so a projection
/// that ignored the card's centre or swapped its axes cannot pass.
@Test func depthMovesAPointOnlyOnATurnedCard() {
    let card = StageRect(x: 120, y: 80, width: 640, height: 300)
    let point = StagePoint(x: 150, y: 330)
    let turned = StageTilt(pitch: 10, yaw: 30, distance: 2.5)
    #expect(turned.project(point, on: card, depth: 0) == turned.project(point, on: card))
    #expect(turned.project(point, on: card, depth: 12) != turned.project(point, on: card))
    #expect(StageTilt.flat.project(point, on: card, depth: 12) == point)
}
