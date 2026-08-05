import CoreGraphics
import Foundation
import Headless
import Testing

/// The arrow's bounding box scales linearly with `scale` — the real path is built and a fact the
/// drawing determines is asserted, not merely that the type exists.
@Test func theArrowPathScalesWithItsScaleArgument() {
    let unit = CursorArt.pointerPath(scale: 1).boundingBox
    let doubled = CursorArt.pointerPath(scale: 2).boundingBox

    #expect(!unit.isEmpty, "the arrow outline is seven points; an empty box means no path was built")
    #expect(abs(doubled.width - unit.width * 2) < 0.001)
    #expect(abs(doubled.height - unit.height * 2) < 0.001)
}

/// The tip is at the origin — the hot-spot convention every downstream position assertion rests
/// on: translating the path onto a recorded position is only correct if the tip is at (0, 0).
@Test func theArrowsTipIsAtTheOrigin() {
    let box = CursorArt.pointerPath(scale: 1).boundingBox
    // The outline runs toward +x and -y, so the tip is the box's top-left: maxY == minX == 0.
    #expect(abs(box.maxY) < 0.001, "the tip is not at y = 0; box: \(box)")
    #expect(abs(box.minX) < 0.001, "the tip is not at x = 0; box: \(box)")
}

/// `ripplePath(phase:)` clamps out-of-range phases. Both ends, because a clamp written on one
/// side only is the commonest way this is got wrong.
@Test func theRipplePhaseIsClampedAtBothEnds() {
    let atZero = CursorArt.ripplePath(phase: 0).boundingBox
    let belowZero = CursorArt.ripplePath(phase: -5).boundingBox
    let atOne = CursorArt.ripplePath(phase: 1).boundingBox
    let aboveOne = CursorArt.ripplePath(phase: 17).boundingBox

    #expect(abs(belowZero.width - atZero.width) < 0.001)
    #expect(abs(aboveOne.width - atOne.width) < 0.001)
    #expect(atOne.width > atZero.width, "the ripple must grow with phase")
}

/// `pointerMaxExtent`/`rippleEndRadius` really do bound the paths they describe — callers size a
/// canvas from them, and a constant smaller than the path clips the arrow. Checked against the
/// geometry, not against their own literals, which would assert nothing.
@Test func theStatedExtentsBoundThePathsTheyDescribe() {
    let arrow = CursorArt.pointerPath(scale: 1).boundingBox
    let largestArrowMagnitude = max(max(abs(arrow.minX), abs(arrow.maxX)),
                                    max(abs(arrow.minY), abs(arrow.maxY)))
    #expect(abs(largestArrowMagnitude - CursorArt.pointerMaxExtent) < 0.001, """
        pointerMaxExtent is \(CursorArt.pointerMaxExtent) but the arrow's largest coordinate \
        magnitude at scale 1 is \(largestArrowMagnitude). A caller sizes a canvas from that \
        constant; if it is smaller than the path, the arrow is clipped.
        """)

    // The phase-1 ripple is a circle of radius `rippleEndRadius`, so its box is twice that.
    let ripple = CursorArt.ripplePath(phase: 1).boundingBox
    #expect(abs(ripple.width - CursorArt.rippleEndRadius * 2) < 0.001,
            "rippleEndRadius is \(CursorArt.rippleEndRadius) but the phase-1 ripple is \(ripple.width) across")
}
