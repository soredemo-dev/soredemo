import CoreGraphics
import Foundation
@testable import Compositing
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
    // **The arrow DEFINES the constant and the others must fit under it**, which is why the
    // arrow is asserted equal and the rest no larger: a shape that outgrew it would be drawn
    // into a canvas sized for the arrow and lose whatever hung over the edge.
    for (name, path) in namedShapes() where name != "arrow" {
        let box = path.boundingBox
        let largest = max(max(abs(box.minX), abs(box.maxX)), max(abs(box.minY), abs(box.maxY)))
        #expect(largest <= CursorArt.pointerMaxExtent + 0.001, """
            \(name) reaches \(largest) at scale 1, past the \(CursorArt.pointerMaxExtent) canvas \
            every shape is drawn into — its corner would be clipped
            """)
    }

    // The phase-1 ripple is a circle of radius `rippleEndRadius`, so its box is twice that.
    let ripple = CursorArt.ripplePath(phase: 1).boundingBox
    #expect(abs(ripple.width - CursorArt.rippleEndRadius * 2) < 0.001,
            "rippleEndRadius is \(CursorArt.rippleEndRadius) but the phase-1 ripple is \(ripple.width) across")
}


// MARK: - the four shapes that used to be arrows (design audit item 5)

/// Every shape at `scale`, by name. One list, so a test cannot silently cover five of six.
/// A function rather than a global constant: `CGPath` is not `Sendable`, and a `let` holding
/// one is a concurrency error under this package's strict settings.
func namedShapes(scale: Double = 1) -> [(String, CGPath)] {
    [
        ("arrow", CursorArt.pointerPath(scale: scale)),
        ("iBeam", CursorArt.iBeamPath(scale: scale)),
        ("pointingHand", CursorArt.pointingHandPath(scale: scale)),
        ("crosshair", CursorArt.crosshairPath(scale: scale)),
        ("resizeLeftRight", CursorArt.resizeLeftRightPath(scale: scale)),
        ("resizeUpDown", CursorArt.resizeUpDownPath(scale: scale)),
    ]
}

/// **Each shape is built around its own hotspot at the origin**, which is the contract the
/// renderer relies on when it draws that origin at the recorded position and applies no offset
/// (`CoreImageFrameRenderer.cursorImage`'s "no hotspot offset, and removing one was the repair").
/// The arrow's hotspot is its tip — the box's top-left; every other shape here is centred on
/// its hotspot except the hand, whose hotspot is the fingertip at the top.
@Test func everyShapeIsBuiltAroundItsOwnHotspot() {
    for (name, path) in namedShapes() {
        let box = path.boundingBox
        #expect(!box.isEmpty, "\(name) built an empty path")
        switch name {
        case "arrow":
            #expect(abs(box.maxY) < 0.001 && abs(box.minX) < 0.001, "the arrow's tip left the origin")
        case "pointingHand":
            // The fingertip is the topmost point, and the hand hangs below it.
            #expect(abs(box.maxY) < 0.001, "\(name)'s fingertip is not at y = 0; box: \(box)")
            #expect(box.minX < 0 && box.maxX > 0, "\(name) does not straddle the fingertip in x")
        default:
            #expect(abs(box.midX) < 0.001 && abs(box.midY) < 0.001,
                    "\(name) is not centred on its hotspot; box: \(box)")
        }
    }
}

/// Every shape scales linearly, like the arrow. A path built from a constant that forgot to
/// multiply by `scale` would draw the same size at every export resolution.
@Test func everyShapeScalesWithItsScaleArgument() {
    for ((name, unit), (_, twice)) in zip(namedShapes(), namedShapes(scale: 2)) {
        #expect(abs(twice.boundingBox.width - unit.boundingBox.width * 2) < 0.001,
                "\(name) does not scale in width")
        #expect(abs(twice.boundingBox.height - unit.boundingBox.height * 2) < 0.001,
                "\(name) does not scale in height")
    }
}

/// **No two shapes are the same drawing** — the property that would go red if any of them fell
/// back to the arrow, which is exactly what all four did until this. Compared pairwise on the
/// paths' own geometry rather than on the renderer, so it holds without a GPU; the pixels are
/// checked in `everyPointerShapeDrawsItsOwnSilhouette`.
@Test func noTwoShapesShareABoundingBox() {
    let shapes = namedShapes()
    for (indexA, (nameA, pathA)) in shapes.enumerated() {
        for (nameB, pathB) in shapes.dropFirst(indexA + 1) {
            let a = pathA.boundingBox, b = pathB.boundingBox
            let identical = abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001
                && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
            #expect(!identical, "\(nameA) and \(nameB) are the same drawing: \(a)")
        }
    }
}
