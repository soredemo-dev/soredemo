import Foundation
import Testing
@testable import Geometry

// The rectangle actually being recorded — a display, or a window's rect inside one. It
// exists so the pointer normaliser can depend on WHAT IS RECORDED rather than on a display
// arrangement, which is the right rectangle only when the capture happens to be a display.

private let displayUUID = UUID(uuidString: "D15D1A00-1111-4222-8333-444455556666")!

/// A 2000×1000-pixel display at scale 2 — 1000×500 POINTS — placed at the global origin.
private func retinaDisplay() -> DisplayGeometry {
    DisplayGeometry(displayUUID: displayUUID, pixelWidth: 2000, pixelHeight: 1000, scale: 2.0)
}

// MARK: - the whole-display case

/// A display viewport normalises exactly as the arrangement did, so the display path is
/// unchanged by the abstraction that was introduced for the window path.
@Test func aDisplayViewportNormalisesAPointWithinItself() throws {
    let viewport = CaptureViewport(geometry: retinaDisplay(),
                                   globalOriginX: 0, globalOriginY: 0,
                                   widthInPoints: 1000, heightInPoints: 500)
    let centre = try #require(viewport.normalise(globalTopLeftX: 500, globalTopLeftY: 250))
    #expect(abs(centre.x - 0.5) < 1e-9)
    #expect(abs(centre.y - 0.5) < 1e-9)
}

/// Top-left in, bottom-left out: a point in the TOP half must land above 0.5. A missing
/// flip returns a plausible number in the wrong half and every pointer is drawn mirrored.
@Test func theViewportFlipsVerticallyOnTheWayIn() throws {
    let viewport = CaptureViewport(geometry: retinaDisplay(),
                                   globalOriginX: 0, globalOriginY: 0,
                                   widthInPoints: 1000, heightInPoints: 500)
    let nearTop = try #require(viewport.normalise(globalTopLeftX: 300, globalTopLeftY: 50))
    let nearBottom = try #require(viewport.normalise(globalTopLeftX: 300, globalTopLeftY: 450))
    #expect(nearTop.y > 0.5)
    #expect(nearBottom.y < 0.5)
}

@Test func aPointOutsideTheViewportNormalisesToNothing() {
    let viewport = CaptureViewport(geometry: retinaDisplay(),
                                   globalOriginX: 0, globalOriginY: 0,
                                   widthInPoints: 1000, heightInPoints: 500)
    #expect(viewport.normalise(globalTopLeftX: 1500, globalTopLeftY: 250) == nil)
    #expect(viewport.normalise(globalTopLeftX: -1, globalTopLeftY: 250) == nil)
}

// MARK: - the window case, which is why this type exists

/// **The defect this abstraction fixes.** A window occupying the display's right half:
/// its own centre is at global (750, 250), and normalised against the WINDOW that is
/// (0.5, 0.5). Normalised against the DISPLAY it would be (0.75, 0.5) — the systematic
/// offset a real recording showed.
@Test func aWindowViewportNormalisesAgainstTheWindowNotTheDisplay() throws {
    let window = CaptureViewport(geometry: retinaDisplay(),
                                 globalOriginX: 500, globalOriginY: 0,
                                 widthInPoints: 500, heightInPoints: 500)
    let centre = try #require(window.normalise(globalTopLeftX: 750, globalTopLeftY: 250))
    #expect(abs(centre.x - 0.5) < 1e-9, "the window's own centre normalised to \(centre.x)")

    let display = CaptureViewport(geometry: retinaDisplay(),
                                  globalOriginX: 0, globalOriginY: 0,
                                  widthInPoints: 1000, heightInPoints: 500)
    let againstDisplay = try #require(display.normalise(globalTopLeftX: 750, globalTopLeftY: 250))
    #expect(abs(againstDisplay.x - 0.75) < 1e-9,
            "the two bases must genuinely differ, or this test proves nothing")
}

/// A point on the display but outside the window is outside the RECORDING, so it
/// normalises to nothing. Clamping would put a real-looking coordinate in the log for a
/// pointer that was never in shot.
@Test func aPointOnTheDisplayButOutsideTheWindowIsNotInTheRecording() {
    let window = CaptureViewport(geometry: retinaDisplay(),
                                 globalOriginX: 500, globalOriginY: 0,
                                 widthInPoints: 500, heightInPoints: 500)
    #expect(window.normalise(globalTopLeftX: 100, globalTopLeftY: 250) == nil)
}

/// The geometry travels with the viewport: a normalised point is only meaningful against
/// the revision it was measured in, and a window viewport's revision is the one its
/// segment recorded — not the display's, which would let two coordinate systems compare.
@Test func theViewportCarriesTheRevisionItsPointsBelongTo() {
    let geometry = retinaDisplay()
    let window = CaptureViewport(geometry: geometry, globalOriginX: 500, globalOriginY: 0,
                                 widthInPoints: 500, heightInPoints: 500)
    #expect(window.revision == geometry.revision)
}

/// A degenerate viewport normalises nothing rather than dividing by zero. It cannot arrive
/// from a real capture, but this type is public and pure.
@Test func aZeroSizedViewportNormalisesToNothing() {
    let flat = CaptureViewport(geometry: retinaDisplay(), globalOriginX: 0, globalOriginY: 0,
                               widthInPoints: 0, heightInPoints: 500)
    #expect(flat.normalise(globalTopLeftX: 0, globalTopLeftY: 0) == nil)
}
