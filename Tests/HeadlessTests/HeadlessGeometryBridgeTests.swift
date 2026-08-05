import CoreGraphics
import Foundation
import Headless
import Testing

/// The render tier's three CoreGraphics exits, exercised. Trivial functions, and the
/// entry rule does not exempt trivial ones: `outputCanvas` and `renderSize` differ
/// only in which of two same-shaped CG types they build, which is exactly the pair a
/// copy-paste swaps.
@Test func theOutputCanvasIsOriginedAtZeroWithTheGivenExtent() {
    let canvas = HeadlessGeometryBridge.outputCanvas(width: 1920, height: 1080)
    #expect(canvas.origin.x == 0 && canvas.origin.y == 0)
    #expect(canvas.width == 1920 && canvas.height == 1080)
}

@Test func theRenderSizeCarriesWidthAndHeightInThatOrder() {
    let size = HeadlessGeometryBridge.renderSize(width: 1280, height: 720)
    #expect(size.width == 1280 && size.height == 720)
}

@Test func thePointBridgeCarriesXAndYInThatOrder() {
    let point = HeadlessGeometryBridge.point(x: 3.5, y: -17.25)
    #expect(point.x == 3.5 && point.y == -17.25)
}
