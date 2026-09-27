import CoreGraphics
import Testing
@testable import Capture

// The notch surface's outline: the body hangs below the top edge, its top corners curl OUTWARD
// into the menu bar the way the hardware notch's do, and its bottom corners are rounded. Checked
// by what the path contains, because that is what a person sees — not by its elements.

private let width = 300.0, height = 32.0, flare = 6.0, radius = 12.0

@Test func theOutlineSpansTheWholeWidthAtTheTopAndItsBodyHangsBetweenTheFlares() {
    let path = CGGeometryBridge.notchOutline(width: width, height: height, flare: flare, bottomRadius: radius)
    let box = path.boundingBoxOfPath
    #expect(box.minX == 0 && box.maxX == width && box.minY == 0 && box.maxY == height)
    #expect(path.contains(CGPoint(x: width / 2, y: height / 2)), "the middle is inside")
    #expect(path.contains(CGPoint(x: flare + 1, y: height / 2)), "just inside the body's side is inside")
    #expect(!path.contains(CGPoint(x: flare / 2, y: height / 2)), "left of the body, below the flare, is outside")
    #expect(!path.contains(CGPoint(x: width - flare / 2, y: height / 2)), "and on the right")
}

/// The flare is concave: at one x inside the flare, the shape holds the point near the top edge
/// and not the point further down. The curve is thin at its tip — at y = 0.1 it begins at x ≈ 1.45
/// for a flare of 6 — so the points are computed from the quadratic, not guessed: at x = 0.6f,
/// y = 0.5 is inside (the curve is at x ≈ 2.97 there) and y = 0.9f is outside (x ≈ 5.98).
@Test func theTopCornersCurlOutwardIntoTheMenuBar() {
    let path = CGGeometryBridge.notchOutline(width: width, height: height, flare: flare, bottomRadius: radius)
    #expect(path.contains(CGPoint(x: flare * 0.6, y: 0.5)), "near the top edge the flare is part of the shape")
    #expect(!path.contains(CGPoint(x: flare * 0.6, y: flare * 0.9)), "further down it has curled away")
    // Concave, not a chamfer: a straight diagonal would hold (1.5, 0.5); the curl begins at 2.97.
    #expect(!path.contains(CGPoint(x: flare * 0.25, y: 0.5)), "the curl is concave, not a straight cut")
}

@Test func theBottomCornersAreRoundedAndASquareOutlineHasNone() {
    let rounded = CGGeometryBridge.notchOutline(width: width, height: height, flare: flare, bottomRadius: radius)
    let square = CGGeometryBridge.notchOutline(width: width, height: height, flare: flare, bottomRadius: 0)
    let corner = CGPoint(x: flare + 1, y: height - 1)
    #expect(!rounded.contains(corner), "a rounded corner leaves its tip outside")
    #expect(square.contains(corner), "control: the same point is inside a square corner")
}
