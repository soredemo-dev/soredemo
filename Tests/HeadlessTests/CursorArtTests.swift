import CoreGraphics
import Foundation
import Headless
import Testing

/// **The entry rule's first discharge, and the standard every later one is held to.**
///
/// The rule is CONSTRUCT AND EXERCISE. A test asserting `CursorArt.self != nil` would
/// satisfy the scanner in `HeadlessEntryRuleTests` and defeat the rule entirely —
/// that scanner is a necessary condition, and this is what the sufficient one looks
/// like: the real path is built and something the drawing actually determines is
/// asserted.
@Test func theArrowPathScalesWithItsScaleArgument() {
    let unit = CursorArt.pointerPath(scale: 1).boundingBox
    let doubled = CursorArt.pointerPath(scale: 2).boundingBox

    #expect(!unit.isEmpty, "the arrow outline is seven points; an empty box means no path was built")
    #expect(abs(doubled.width - unit.width * 2) < 0.001)
    #expect(abs(doubled.height - unit.height * 2) < 0.001)
}

/// The tip is the origin — the hot-spot convention `pointerPath`'s own header states,
/// and the fact Task 6's position assertion rests on. A path translated so its tip
/// lands on the recorded position is only correct if the tip really is at (0, 0).
@Test func theArrowsTipIsAtTheOrigin() {
    let box = CursorArt.pointerPath(scale: 1).boundingBox
    // The outline runs toward positive x and negative y from the tip, so the tip is
    // the box's top-left corner: maxY is 0 and minX is 0.
    #expect(abs(box.maxY) < 0.001, "the tip is not at y = 0; box: \(box)")
    #expect(abs(box.minX) < 0.001, "the tip is not at x = 0; box: \(box)")
}

/// `ripplePath(phase:)` clamps out-of-range phases rather than building a circle from
/// a radius outside its documented range. Both ends, because a clamp written on one
/// side only is the commonest way this shape is got wrong.
@Test func theRipplePhaseIsClampedAtBothEnds() {
    let atZero = CursorArt.ripplePath(phase: 0).boundingBox
    let belowZero = CursorArt.ripplePath(phase: -5).boundingBox
    let atOne = CursorArt.ripplePath(phase: 1).boundingBox
    let aboveOne = CursorArt.ripplePath(phase: 17).boundingBox

    #expect(abs(belowZero.width - atZero.width) < 0.001)
    #expect(abs(aboveOne.width - atOne.width) < 0.001)
    #expect(atOne.width > atZero.width, "the ripple must grow with phase")
}

/// `pointerMaxExtent` and `rippleEndRadius` are the two constants
/// `CoreImageFrameRenderer.cursorImage(for:outputHeight:)` sizes its canvas from, so
/// they are `public` and therefore carry the same obligation the two functions above
/// do. Exercised against the geometry they claim to describe rather than compared to
/// their own literals: a test that reads `24.5` back out of the file that wrote it
/// asserts nothing.
@Test func theStatedExtentsBoundThePathsTheyDescribe() {
    let arrow = CursorArt.pointerPath(scale: 1).boundingBox
    let largestArrowMagnitude = max(max(abs(arrow.minX), abs(arrow.maxX)),
                                    max(abs(arrow.minY), abs(arrow.maxY)))
    #expect(abs(largestArrowMagnitude - CursorArt.pointerMaxExtent) < 0.001, """
        pointerMaxExtent is \(CursorArt.pointerMaxExtent) but the arrow's largest coordinate \
        magnitude at scale 1 is \(largestArrowMagnitude). A caller sizes a canvas from that \
        constant; if it is smaller than the path, the arrow is clipped.
        """)

    // The fully-expanded ripple is a circle of radius `rippleEndRadius` centred on the
    // origin, so its bounding box is twice that across.
    let ripple = CursorArt.ripplePath(phase: 1).boundingBox
    #expect(abs(ripple.width - CursorArt.rippleEndRadius * 2) < 0.001,
            "rippleEndRadius is \(CursorArt.rippleEndRadius) but the phase-1 ripple is \(ripple.width) across")
}
