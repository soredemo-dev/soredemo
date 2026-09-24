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
