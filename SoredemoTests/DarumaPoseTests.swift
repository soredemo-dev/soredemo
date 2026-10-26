import AppKit
import SwiftUI
import Testing
@testable import Soredemo

/// The daruma's poses, and the drawing checked against the mark the script baked.
/// `docs/design/2026-10-25-a-daruma-that-answers.md`.
@MainActor @Suite struct DarumaPoseTests {
    @Test func theHeaderLooksTowardTheCardUnderThePointer() {
        #expect(DarumaPose.looking(at: .screen).look == -1)
        #expect(DarumaPose.looking(at: .window).look == 0)
        #expect(DarumaPose.looking(at: .area).look == 1)
        #expect(DarumaPose.looking(at: nil) == .resting)
    }

    /// **Seen at the size it is drawn.** In the 18-point header a unit is a fifth of a point, so
    /// the large mark's three-unit glance moved the eye half a point — and Window, looking
    /// straight ahead, did not move it at all. The cards must sit a point or more apart; from
    /// rest, ¾ of a point is what the face allows — the resting eye is already on the right, and
    /// computed with a margin, Area can leave it by 4.5 units at most.
    @Test func eachCardMovesTheHeadersEyeVisiblyAndKeepsItInTheFace() {
        let unitsPerPoint = 100 / 18.0
        let rest = DarumaView.templateEye(.resting)
        let cards = [CaptureTarget.screen, .window, .area].map { DarumaView.templateEye(.looking(at: $0)) }
        for (i, eye) in cards.enumerated() {
            #expect(hypot(eye.x - rest.x, eye.y - rest.y) >= 0.75 * unitsPerPoint, "card \(i) from rest")
            for other in cards[(i + 1)...] {
                #expect(hypot(eye.x - other.x, eye.y - other.y) >= unitsPerPoint, "card \(i)")
            }
            // Every point of the eye's outer edge (9 + 2.3), plus a unit and a half, is inside the
            // face — 58 × 44 about (50, 47). Sampled round the circle, not tested at its centre.
            let outside = stride(from: 0.0, to: 2 * .pi, by: .pi / 90).filter { t in
                let x = eye.x + 12.8 * cos(t), y = eye.y + 12.8 * sin(t)
                return pow((x - 50) / 29, 2) + pow((y - 47) / 22, 2) > 1
            }
            #expect(outside.isEmpty, "card \(i) at \(eye) leaves the face")
        }
        #expect(rest.x == 62 && rest.y == 47, "the resting eye is the baked mark's")
    }

    /// One eye per permission: each is painted by its own grant and by nothing else.
    @Test func eachPermissionPaintsItsOwnEye() {
        #expect(DarumaPose.permissions(screenRecording: false, accessibility: false)
                == DarumaPose(recordFill: 0, waitingPainted: false))
        #expect(DarumaPose.permissions(screenRecording: true, accessibility: false)
                == DarumaPose(recordFill: 1, waitingPainted: false))
        #expect(DarumaPose.permissions(screenRecording: false, accessibility: true)
                == DarumaPose(recordFill: 0, waitingPainted: true))
        #expect(DarumaPose.permissions(screenRecording: true, accessibility: true)
                == DarumaPose(recordFill: 1, waitingPainted: true))
    }

    /// **Two places draw one mark**: the script baked `Logomark`, and `DarumaView` draws it in
    /// code. The centre of the record red in each is measured and compared, so a drawing that
    /// drifts from the brand's geometry fails here rather than looking subtly wrong.
    @Test func theDrawnMarkPutsItsRecordEyeWhereTheBakedOneIs() throws {
        let side = 112
        let drawn = try #require(ImageRenderer(content: DarumaView(icon: .black).frame(width: Double(side), height: Double(side))
            .environment(\.colorScheme, .light)).nsImage)
        let baked = try #require(NSImage(named: "Logomark"))
        let a = try redCentre(of: drawn, side: side)
        let b = try redCentre(of: baked, side: side)
        #expect(abs(a.x - b.x) < 0.02 && abs(a.y - b.y) < 0.02, "drawn eye at \(a), baked eye at \(b)")
    }

    /// The record red's centre as a share of the body's ink box — the two images frame the mark
    /// differently (the asset is cropped to the body), so positions are compared within the body.
    private func redCentre(of image: NSImage, side: Int) throws -> (x: Double, y: Double) {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var sumX = 0.0, sumY = 0.0, count = 0.0
        var minX = side, maxX = 0, minY = side, maxY = 0
        for y in 0..<side {
            for x in 0..<side {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                guard c.redComponent > 0.8, c.greenComponent < 0.45, c.blueComponent < 0.45 else { continue }
                sumX += Double(x); sumY += Double(y); count += 1
            }
        }
        try #require(count > 20, "no record red found: \(count) pixels")
        try #require(maxX > minX && maxY > minY, "no body found")
        return ((sumX / count - Double(minX)) / Double(maxX - minX),
                (sumY / count - Double(minY)) / Double(maxY - minY))
    }

    /// **The small mark is ink and paper in the right places**, read off the one even-odd path
    /// the header fills: body ink, face paper, the eye a ring until it fills. In a 100-point box
    /// so a unit is a point.
    @Test func theSmallMarkIsInkAndPaperWhereTheBakedOneIs() {
        func ink(_ pose: DarumaPose, _ x: Double, _ y: Double) -> Bool {
            DarumaView.templatePath(width: 100, height: 100, pose: pose)
                .contains(CGPoint(x: x, y: y), eoFill: true)
        }
        #expect(ink(.resting, 50, 85), "the body below the face")
        #expect(!ink(.resting, 35, 47), "the face, left of the eye")
        #expect(ink(.resting, 62 + 9, 47), "the eye's ring")
        #expect(!ink(.resting, 62, 47), "the ring's hole")
        #expect(ink(DarumaPose(recordFill: 1), 62, 47), "a filled eye has no hole")
        #expect(!ink(.resting, 5, 5), "outside the body")
    }

    /// **The count rings the record eye, a second at a time, and the last second paints it.**
    /// The ring is the menu bar's — what is left of this second — so the two say the same thing;
    /// the eye fills only as the last ring drains, so it is painted as the recording begins.
    @Test func theCountRingsTheEyeAndTheLastSecondPaintsIt() {
        let early = DarumaPose.counting(remaining: 3, ringRemaining: 0.7)
        #expect(early.countRing == 0.7)
        #expect(early.recordFill == 0, "a second that is not the last paints nothing")
        let last = DarumaPose.counting(remaining: 1, ringRemaining: 0.25)
        #expect(last.countRing == 0.25)
        #expect(last.recordFill == 0.75, "the eye fills as the last ring drains")
        #expect(DarumaPose.counting(remaining: 1, ringRemaining: 1).recordFill == 0)
        #expect(DarumaPose.resting.countRing == nil, "nothing counted is no ring")
    }

    /// **The notch's daruma has a face per state**, after the owner's Grok reference: resting
    /// when it is offered, its record eye filled while a take runs and empty while it is paused,
    /// and both eyes painted when the take is done — the daruma's own custom for a wish granted.
    @Test func theNotchsDarumaHasAFacePerState() {
        #expect(DarumaPose.notch(.glance, isPaused: false) == .resting)
        #expect(DarumaPose.notch(.open, isPaused: false) == .resting)
        #expect(DarumaPose.notch(.live(expanded: false), isPaused: false).recordFill == 1)
        #expect(DarumaPose.notch(.live(expanded: true), isPaused: false).recordFill == 1)
        #expect(DarumaPose.notch(.live(expanded: false), isPaused: true).recordFill == 0)
        let done = DarumaPose.notch(.finished, isPaused: false)
        #expect(done.recordFill == 1 && done.waitingPainted)
        #expect(!DarumaPose.notch(.live(expanded: false), isPaused: false).waitingPainted,
                "the second eye is painted when the take is done, not while it runs")
    }

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
