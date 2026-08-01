import Testing
import Foundation
@testable import Geometry

/// A two-display arrangement: a "main" display at the global origin whose
/// **point**-space size is 1000×800, and a "secondary" whose point-space
/// size is 800×600, placed `sideOriginX` points to the right (or, for a
/// negative value, to the left) of it.
///
/// **Both displays are `scale: 2`, deliberately not `scale: 1`.** `scale: 1`
/// is the identity of the points↔pixels conversion — every Phase 1 fixture
/// used it, which is exactly why 97 green tests coexisted with `route`
/// comparing points against raw pixel dimensions directly (design doc §
/// Geometry: the Y-axis flip; `AGENTS.md`'s fixture rule). Native pixel
/// dimensions here are double the point-space numbers above — 2000×1600 and
/// 1600×1200 — chosen so that every global/local coordinate used below is
/// still the exact point-space value a reader expects, while `pixelWidth`/
/// `pixelHeight` genuinely disagree with it. A mutation dropping the scale
/// division in `route` compares against these doubled pixel numbers instead
/// and lets a point through that point-space bounds would reject.
///
/// Numbers are chosen so the routing arithmetic in the tests below lands on
/// exact `Double`s, the same reasoning `ConversionTests.swift` uses for its
/// fixture geometry.
private func arrangement(sideOriginX: Double = 1000) -> DisplayArrangement {
    let main = DisplayGeometry(
        displayUUID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
        pixelWidth: 2000, pixelHeight: 1600, scale: 2.0)
    let secondary = DisplayGeometry(
        displayUUID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!,
        pixelWidth: 1600, pixelHeight: 1200, scale: 2.0)
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
    // `hit.localX`/`hit.localY` are POINTS (400, 300 — secondary's point-space
    // width is 800). `normalize` requires PIXELS, so the pipeline's missing
    // middle step (design doc § Geometry: the Y-axis flip) has to run here:
    // convert via `DisplayGeometry.pixels(from:)` before calling `normalize`.
    // Skipping it would divide by the display's *pixel* width (1600) instead
    // of its point width (800) and silently halve `p.x`.
    let pixels = hit.geometry.pixels(from: PointRect(x: hit.localX, y: hit.localY, width: 0, height: 0))
    let p = NormalizationContext(geometry: hit.geometry).normalize(topLeftX: pixels.x, topLeftY: pixels.y)
    #expect(p.x == 0.5)   // pixels.x == 800; 800/1600, not 1400/1000 and not 400/1600
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

// MARK: - boundary: half-open, so adjacent displays cannot both claim a point

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
    // Main is 1000 points wide (pixelWidth 2000 at scale 2) at origin 0, so
    // x == 1000 is one past its last point column — and also the
    // secondary's own left edge in the default arrangement, so this
    // simultaneously proves the two displays don't overlap-claim that
    // column.
    let a = arrangement()
    let hit = try #require(a.route(globalTopLeftX: 1000, globalTopLeftY: 400),
                           "x==1000 belongs to the secondary, not nobody")
    #expect(hit.geometry.revision == a.placements[1].geometry.revision,
            "x==1000 must route to the secondary (whose left edge it is), not the main display")
}

@Test func pointOnBottomEdgeDoesNotBelongToTheDisplay() {
    // Main is 800 points tall (pixelHeight 1600 at scale 2) at origin 0, so
    // y == 800 is one past its last point row, and no other display in this
    // arrangement occupies that row.
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

// MARK: - the Task 10.5 defect, reproduced exactly and confirmed fixed
//
// The design doc's own worked example: a single 3840×2160 display at
// `scale: 2` is 1920×1080 POINTS. `route(globalTopLeftX: 2500, …)` — a point
// value, exactly what `CGEventGetLocation` would report — must be routed
// against the 1920-point width, not the 3840-pixel width. Before the fix,
// `route` compared 2500 against 3840 directly and accepted it.

private func singleDisplay3840x2160Scale2() -> DisplayArrangement {
    let display = DisplayGeometry(
        displayUUID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
        pixelWidth: 3840, pixelHeight: 2160, scale: 2.0)
    return DisplayArrangement(placements: [
        .init(geometry: display, globalOriginX: 0, globalOriginY: 0),
    ])
}

// This is the mutation-catching test (see task report): removing the `/
// placement.geometry.scale` division from `route`'s bounds computation makes
// `widthInPoints` equal `3840` again, `2500 < 3840` becomes true, and this
// assertion — expecting `nil` — goes red.
@Test func pointPastPointWidthButInsidePixelWidthIsOnNoDisplay() {
    #expect(singleDisplay3840x2160Scale2().route(globalTopLeftX: 2500, globalTopLeftY: 100) == nil,
            "2500 points is past the display's 1920-point width, even though it is well inside its 3840-pixel width")
}

@Test func pointInsidePointWidthRoutesToTheDisplay() throws {
    let hit = try #require(singleDisplay3840x2160Scale2().route(globalTopLeftX: 1000, globalTopLeftY: 100))
    #expect(hit.localX == 1000)
    #expect(hit.localY == 100)
}

@Test func pointExactlyAtThePointWidthIsOnNoDisplay() {
    // 1920 points is the display's point-space width — half-open, so this
    // is exactly one point past the last column, distinct from (and a
    // tighter bound than) the 2500 case above.
    #expect(singleDisplay3840x2160Scale2().route(globalTopLeftX: 1920, globalTopLeftY: 100) == nil)
}
