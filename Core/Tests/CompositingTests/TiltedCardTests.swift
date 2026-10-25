import Testing
import Foundation
import CoreVideo
import Render
@testable import Compositing

// The card, turned. `StageTiltTests` pins the arithmetic; this pins that the arithmetic reaches
// the pixels, and reaches them the right way round — the two are different claims, and the notch
// work in this project is the reminder of what happens when only the first is checked.

private let outputWidth = 640
private let outputHeight = 360

private func frame(tilt: StageTilt) throws -> (pixels: [(r: UInt8, g: UInt8, b: UInt8)],
                                               width: Int, height: Int) {
    let style = StageStyle(insetFraction: 0.08, cornerRadius: 12, shadowRadius: 0,
                           shadowOpacity: 0, background: .solid(red: 0, green: 0, blue: 0),
                           tilt: tilt)
    let plan = StagePlanner.plan(outputWidth: outputWidth, outputHeight: outputHeight,
                                 sourceWidth: 1280, sourceHeight: 720, style: style)
    let source = try makePixelBuffer(width: 1280, height: 720, fill: sourceFill)
    let destination = try makePixelBuffer(width: outputWidth, height: outputHeight,
                                          fill: (0, 0, 0))
    try CoreImageFrameRenderer().render(plan, source: source, camera: nil, into: destination)
    return (try pixels(of: destination), outputWidth, outputHeight)
}

/// How tall the drawn card is in a given column — the count of rows whose pixel is the source's
/// own blue. Measured from the PICTURE, so it cannot agree with `StageTilt` by sharing its
/// arithmetic.
private func cardHeight(inColumn x: Int,
                        _ frame: (pixels: [(r: UInt8, g: UInt8, b: UInt8)], width: Int, height: Int))
-> Int {
    (0..<frame.height).count { y in
        let p = frame.pixels[y * frame.width + x]
        return Int(p.b) > 120 && Int(p.r) < 120
    }
}

/// Layer one: a tilt changes the pixels at all. The flat frame is rendered twice first — without
/// determinism a difference between two frames proves nothing about the tilt.
@Test func aTiltChangesTheFrameAtAll() throws {
    let flat = try frame(tilt: .flat)
    let flatAgain = try frame(tilt: .flat)
    try #require(zip(flat.pixels, flatAgain.pixels).allSatisfy { $0 == $1 }, """
        rendering the same flat plan twice produced two different frames, so a difference \
        below could not be attributed to the tilt
        """)
    let turned = try frame(tilt: StageTilt(pitch: 0, yaw: 35, distance: 2.5))
    #expect(zip(flat.pixels, turned.pixels).contains { $0 != $1 },
            "a 35-degree yaw produced a frame identical to the flat one — nothing was turned")
}

/// Layer two: it is turned the way the arithmetic says. A positive yaw turns the RIGHT edge away,
/// so the card must be drawn shorter on the right than on the left — which is foreshortening, and
/// is exactly what an affine transform could not produce.
@Test func aPositiveYawDrawsTheRightSideShorter() throws {
    let turned = try frame(tilt: StageTilt(pitch: 0, yaw: 35, distance: 2.5))
    // Sampled inside the card's own span rather than at the output's edges, which are background.
    let left = cardHeight(inColumn: outputWidth / 4, turned)
    let right = cardHeight(inColumn: outputWidth * 3 / 4, turned)
    #expect(left > 0 && right > 0, "the card was not drawn in one of the sampled columns")
    #expect(right < left, "the turned-away side should be drawn shorter: left \(left), right \(right)")
}

/// And a flat card is drawn with both sides the same, so the check above is measuring the tilt
/// rather than something the stage does anyway.
@Test func aFlatCardIsDrawnTheSameHeightOnBothSides() throws {
    let flat = try frame(tilt: .flat)
    let left = cardHeight(inColumn: outputWidth / 4, flat)
    let right = cardHeight(inColumn: outputWidth * 3 / 4, flat)
    #expect(left > 0)
    #expect(abs(left - right) <= 1, "a flat card differed by \(abs(left - right)) rows")
}

private func styledFrame(_ style: StageStyle) throws -> (pixels: [(r: UInt8, g: UInt8, b: UInt8)],
                                                         width: Int, height: Int) {
    let plan = StagePlanner.plan(outputWidth: outputWidth, outputHeight: outputHeight,
                                 sourceWidth: 1280, sourceHeight: 720, style: style)
    let source = try makePixelBuffer(width: 1280, height: 720, fill: sourceFill)
    let destination = try makePixelBuffer(width: outputWidth, height: outputHeight, fill: (0, 0, 0))
    try CoreImageFrameRenderer().render(plan, source: source, camera: nil, into: destination)
    return (try pixels(of: destination), outputWidth, outputHeight)
}

/// **The card's edge turns with the card** (reported by the owner, 2026-10-25: the edge did not
/// follow the angle). In a column where the turned card is foreshortened, the light border's first
/// row must be where the picture's first row is — not where the FLAT card's top was. Sampled on
/// the turned-away side, where the two differ most; on the near side as well, so a border that
/// merely moved is not mistaken for one that turned.
@Test func theBorderTurnsWithTheCard() throws {
    let style = StageStyle(insetFraction: 0.08, cornerRadius: 0, shadowRadius: 0, shadowOpacity: 0,
                           background: .solid(red: 0, green: 0, blue: 0), borderOpacity: 1,
                           tilt: StageTilt(pitch: 0, yaw: 35, distance: 2.5))
    let frame = try styledFrame(style)
    for x in [outputWidth / 4, outputWidth * 3 / 4] {
        let rows = 0..<frame.height
        let firstLight = rows.first { y in
            let p = frame.pixels[y * frame.width + x]; return p.r > 100 && p.g > 100 && p.b > 100
        }
        let firstBlue = rows.first { y in
            let p = frame.pixels[y * frame.width + x]; return Int(p.b) > 120 && Int(p.r) < 120
        }
        let light = try #require(firstLight, "no border drawn in column \(x)")
        let blue = try #require(firstBlue, "no card drawn in column \(x)")
        #expect(abs(light - blue) <= 3, "column \(x): the border's top is row \(light), the card's \(blue)")
    }
}

/// **The device body turns with the card it holds.** Measured as the lit span of a column — the
/// first lit row to the last, body and picture together — on each side. A body drawn flat around
/// a turned card is the taller thing in both columns and shows as two equal spans. (A count of
/// lit pixels was tried first and measured nothing: through the picture it counts only the two
/// bezel strips, 30 rows either side.)
@Test func theDeviceBodyTurnsWithTheCard() throws {
    let style = StageStyle(insetFraction: 0.1, cornerRadius: 12, shadowRadius: 0, shadowOpacity: 0,
                           background: .solid(red: 0, green: 0, blue: 0),
                           deviceModel: .iPad, deviceFinish: .silver,
                           tilt: StageTilt(pitch: 0, yaw: 35, distance: 2.5))
    let frame = try styledFrame(style)
    func bodyHeight(_ x: Int) -> Int {
        let lit = (0..<frame.height).filter { y in
            let p = frame.pixels[y * frame.width + x]
            return Int(p.r) + Int(p.g) + Int(p.b) > 60
        }
        guard let first = lit.first, let last = lit.last else { return 0 }
        return last - first + 1
    }
    // Inside the turned body on both sides: foreshortening narrows it too.
    let left = bodyHeight(outputWidth * 3 / 10), right = bodyHeight(outputWidth * 7 / 10)
    #expect(left > 0 && right > 0, "no body in a sampled column: left \(left), right \(right)")
    #expect(right < left - 2, "the turned-away side of the body should be shorter: left \(left), right \(right)")
}

/// **A turned card has a thickness, and shows it on the side that faces the camera** (asked for by
/// the owner, 2026-10-25: turned, it read as paper). A positive yaw brings the LEFT edge toward the
/// camera, so a strip of the edge's colour lies just outside the picture's left edge, and nothing
/// lies outside its right one. The flat card, rendered the same way, shows no edge on either side —
/// so the strip is the tilt's, not something the stage draws anyway.
@Test func aTurnedCardShowsItsEdgeOnTheSideThatFacesTheCamera() throws {
    func style(_ tilt: StageTilt) -> StageStyle {
        StageStyle(insetFraction: 0.12, cornerRadius: 0, shadowRadius: 0, shadowOpacity: 0,
                   background: .solid(red: 0, green: 0, blue: 0), tilt: tilt)
    }
    func edges(_ frame: (pixels: [(r: UInt8, g: UInt8, b: UInt8)], width: Int, height: Int))
    -> (left: Int, right: Int) {
        let y = frame.height / 2
        let row = (0..<frame.width).map { frame.pixels[y * frame.width + $0] }
        let blue = { (p: (r: UInt8, g: UInt8, b: UInt8)) in Int(p.b) > 120 && Int(p.r) < 120 }
        let lit = { (p: (r: UInt8, g: UInt8, b: UInt8)) in Int(p.r) + Int(p.g) + Int(p.b) > 24 }
        guard let first = row.firstIndex(where: blue), let last = row.lastIndex(where: blue) else { return (-1, -1) }
        let left = row[..<first].reversed().prefix { lit($0) && !blue($0) }.count
        let right = row[(last + 1)...].prefix { lit($0) && !blue($0) }.count
        return (left, right)
    }
    let flat = edges(try styledFrame(style(.flat)))
    #expect(flat.left <= 1 && flat.right <= 1, "a flat card showed an edge: \(flat)")
    let turned = edges(try styledFrame(style(StageTilt(pitch: 0, yaw: 35, distance: 2.5))))
    #expect(turned.left >= 3, "the side facing the camera shows no thickness: \(turned)")
    #expect(turned.right <= 1, "the side turned away shows an edge it could not: \(turned)")
}
