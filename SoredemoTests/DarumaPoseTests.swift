import AppKit
import Render
import SwiftUI
import Testing
@testable import Soredemo

/// The daruma character: its poses — every reason it moves is a function here — and its figure,
/// the geometry one pose draws. `docs/design/2026-10-26-a-character-not-a-logo.md`.
@MainActor @Suite struct DarumaPoseTests {
    // MARK: - poses

    /// The panel's header looks down at the card under the pointer: left, middle, right.
    @Test func theHeaderLooksDownAtTheCardUnderThePointer() {
        let screen = DarumaPose.looking(at: .screen), window = DarumaPose.looking(at: .window),
            area = DarumaPose.looking(at: .area)
        #expect(screen.yaw < 0 && window.yaw == 0 && area.yaw > 0)
        #expect([screen, window, area].allSatisfy { $0.pitch > 0 }, "down, at the cards below it")
        #expect(DarumaPose.looking(at: nil) == .resting)
    }

    /// One eye per permission: the left opens with Accessibility, the right — the record eye —
    /// lights with Screen Recording. Neither granted is a sleeping daruma.
    @Test func eachPermissionOpensItsOwnEye() {
        let none = DarumaPose.permissions(screenRecording: false, accessibility: false)
        #expect(none.left == .closed && none.right == .closed)
        let screen = DarumaPose.permissions(screenRecording: true, accessibility: false)
        #expect(screen.left == .closed && screen.right == .record)
        let both = DarumaPose.permissions(screenRecording: true, accessibility: true)
        #expect(both.left == .open && both.right == .record)
    }

    /// The count rings the right eye, a second at a time, and the last second lights it.
    @Test func theCountRingsTheEyeAndTheLastSecondLightsIt() {
        let early = DarumaPose.counting(remaining: 3, ringRemaining: 0.7)
        #expect(early.countRing == 0.7 && early.right == .open)
        let last = DarumaPose.counting(remaining: 1, ringRemaining: 0.25)
        #expect(last.countRing == 0.25 && last.right == .record)
        #expect(DarumaPose.resting.countRing == nil, "nothing counted is no ring")
    }

    /// A face per notch state: offered, it rests; recording, the record eye is lit; paused,
    /// its eyes are the pause symbol; done, it smiles with both eyes — the second eye painted.
    @Test func theNotchsDarumaHasAFacePerState() {
        #expect(DarumaPose.notch(.glance, isPaused: false) == .resting)
        #expect(DarumaPose.notch(.live(expanded: true), isPaused: false).right == .record)
        let paused = DarumaPose.notch(.live(expanded: false), isPaused: true)
        #expect(paused.left == .pause && paused.right == .pause, "paused, its eyes are the pause symbol")
        #expect(DarumaMark.pose(for: .paused).left == .pause && DarumaMark.pose(for: .paused).right == .pause)
        let done = DarumaPose.notch(.finished, isPaused: false)
        #expect(done.left == .happy && done.right == .happy)
    }

    /// The record eye is painted in over the last second's final 0.4, finishing as the ring
    /// closes; before that it is an ink eye, and an earlier second paints nothing.
    @Test func theLastSecondPaintsTheRecordEyeAsTheRingCloses() {
        #expect(DarumaPose.counting(remaining: 1, ringRemaining: 0.8).recordPaint == 0)
        #expect(abs(DarumaPose.counting(remaining: 1, ringRemaining: 0.2).recordPaint - 0.5) < 1e-9)
        #expect(DarumaPose.counting(remaining: 1, ringRemaining: 0).recordPaint == 1)
        #expect(DarumaPose.counting(remaining: 2, ringRemaining: 0.1).right == .open)
        #expect(DarumaPose.resting.recordPaint == 1, "an eye lit any other way is lit whole")
    }

    /// Poked, it squeezes its eyes shut — but a lit record eye stays lit, and a smile stays.
    @Test func aSqueezeClosesOpenEyesAndLeavesTheRecordEyeLit() {
        let squeezed = DarumaPose(right: .record).squeezed()
        #expect(squeezed.left == .closed && squeezed.right == .record)
        #expect(DarumaPose(left: .happy, right: .sad).squeezed() == DarumaPose(left: .happy, right: .closed))
    }

    // MARK: - the drawing

    /// The small mark is ink and paper in the right places: body ink, face paper, eyes ink —
    /// read off the one even-odd path the menu bar and the header fill.
    @Test func theSmallMarkIsInkAndPaperWhereTheFigureSays() {
        let f = DarumaFigure.make(.resting)
        let path = DarumaView.templatePath(f, width: 100, height: 100)
        func ink(_ x: Double, _ y: Double) -> Bool { path.contains(CGPoint(x: x, y: y), eoFill: true) }
        #expect(ink(50, 85), "the body below the face")
        #expect(!ink(f.face.x, f.face.y + f.face.ry * 0.7), "the face, below the eyes")
        #expect(ink(f.eyes[0].x, f.eyes[0].y) && ink(f.eyes[1].x, f.eyes[1].y), "the eyes")
        #expect(!ink(3, 3), "outside the body")
    }

    // MARK: - the header's hover

    /// Moving from one card to the next may report the new card's entry before the old one's exit;
    /// the late exit must not clear the glance the new card just took.
    @Test func aLateExitDoesNotClearTheNextCardsGlance() {
        let glance = PanelGlance()
        glance.hover(.screen, true)
        glance.hover(.window, true)
        glance.hover(.screen, false)
        #expect(glance.target == .window)
        glance.hover(.window, false)
        #expect(glance.target == nil)
    }
}
