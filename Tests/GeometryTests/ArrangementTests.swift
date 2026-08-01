import Testing
import Foundation
@testable import Geometry

/// A two-display arrangement: a 1000×800 "main" display at the global
/// origin, and an 800×600 "secondary" placed `sideOriginX` pixels to the
/// right (or, for a negative value, to the left) of it.
///
/// Numbers are chosen so the routing arithmetic in the tests below lands on
/// exact `Double`s, the same reasoning `ConversionTests.swift` uses for its
/// fixture geometry.
private func arrangement(sideOriginX: Double = 1000) -> DisplayArrangement {
    let main = DisplayGeometry(
        displayUUID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
        pixelWidth: 1000, pixelHeight: 800, scale: 1.0)
    let secondary = DisplayGeometry(
        displayUUID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!,
        pixelWidth: 800, pixelHeight: 600, scale: 1.0)
    return DisplayArrangement(placements: [
        .init(geometry: main, globalOriginX: 0, globalOriginY: 0),
        .init(geometry: secondary, globalOriginX: sideOriginX, globalOriginY: 0),
    ])
}

// MARK: - the two tests the brief pins verbatim

@Test func rearrangingDisplaysChangesNoRevision() {
    let before = arrangement(sideOriginX: 1000).placements.map(\.geometry.revision)
    let after  = arrangement(sideOriginX: -800).placements.map(\.geometry.revision)
    #expect(before == after)
}

@Test func clickOnSecondaryNormalizesAgainstSecondary() throws {
    let hit = try #require(arrangement().route(globalTopLeftX: 1400, globalTopLeftY: 300))
    let p = NormalizationContext(geometry: hit.geometry).normalize(topLeftX: hit.localX, topLeftY: hit.localY)
    #expect(p.x == 0.5)   // 400/800, not 1400/1000
}

// MARK: - routing to the main display

@Test func clickOnMainNormalizesAgainstMain() throws {
    let hit = try #require(arrangement().route(globalTopLeftX: 500, globalTopLeftY: 400))
    #expect(hit.geometry.revision == arrangement().placements[0].geometry.revision)
    #expect(hit.localX == 500)
    #expect(hit.localY == 400)
}

// MARK: - off every display

@Test func pointOnNoDisplayReturnsNil() {
    // Between the two displays' relevant band vertically, and past the last
    // display's right edge horizontally: on neither.
    #expect(arrangement().route(globalTopLeftX: 5000, globalTopLeftY: 5000) == nil)
}

// MARK: - boundary: half-open, so adjacent displays cannot both claim a pixel

@Test func pointOnLeftEdgeBelongsToTheDisplay() throws {
    // Secondary's left edge is exactly at its global origin.
    let hit = try #require(arrangement(sideOriginX: 1000).route(globalTopLeftX: 1000, globalTopLeftY: 0))
    #expect(hit.localX == 0)
    #expect(hit.localY == 0)
}

@Test func pointOnTopEdgeBelongsToTheDisplay() throws {
    let hit = try #require(arrangement().route(globalTopLeftX: 500, globalTopLeftY: 0))
    #expect(hit.localY == 0)
}

@Test func pointOnRightEdgeDoesNotBelongToTheDisplay() throws {
    // Main is 1000 wide at origin 0, so x == 1000 is one past its last pixel
    // column — and also the secondary's own left edge in the default
    // arrangement, so this simultaneously proves the two displays don't
    // overlap-claim that column.
    let a = arrangement()
    let hit = try #require(a.route(globalTopLeftX: 1000, globalTopLeftY: 400),
                           "x==1000 belongs to the secondary, not nobody")
    #expect(hit.geometry.revision == a.placements[1].geometry.revision,
            "x==1000 must route to the secondary (whose left edge it is), not the main display")
}

@Test func pointOnBottomEdgeDoesNotBelongToTheDisplay() {
    // Main is 800 tall at origin 0, so y == 800 is one past its last pixel
    // row, and no other display in this arrangement occupies that row.
    #expect(arrangement().route(globalTopLeftX: 500, globalTopLeftY: 800) == nil)
}

// MARK: - negative global origins (a secondary placed to the left of main)

@Test func negativeGlobalOriginRoutesCorrectly() throws {
    let a = arrangement(sideOriginX: -800) // secondary occupies global x in [-800, 0)
    let hit = try #require(a.route(globalTopLeftX: -400, globalTopLeftY: 300))
    #expect(hit.geometry.revision == a.placements[1].geometry.revision)
    #expect(hit.localX == 400)   // -400 - (-800)
    #expect(hit.localY == 300)
}

@Test func pointJustLeftOfANegativelyPlacedSecondaryIsOnNoDisplay() {
    let a = arrangement(sideOriginX: -800) // secondary's left edge is at -800
    #expect(a.route(globalTopLeftX: -801, globalTopLeftY: 300) == nil)
}
