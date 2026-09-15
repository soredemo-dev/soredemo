import Foundation
import Testing
@testable import Geometry

// A window recorded on a display that is not the primary one. Two defects found on real
// hardware 2026-09-16 — a 2x built-in beside a 1x external at global origin (-1920, -63) —
// both of which are invisible on a single-display Mac because the primary display's origin is
// zero and its scale is the only scale there is:
//
//   * the scale used to normalise pointer samples came from the MAIN display rather than the
//     window's own, so every sample was multiplied by mainScale / trueScale;
//   * `WindowCapture.sourceRect` was handed a GLOBAL rectangle where the type means a
//     DISPLAY-LOCAL one, so `viewport(scale:displayUUID:)` added the display's origin to a
//     rectangle that already carried it and placed the recording a whole display away.
//
// `cross-boundary-digest-probe` § 29 catches both against the real capture stack, and only on a
// machine that has two differently-scaled displays attached. This file is the half that needs no
// hardware: it states the RULE over a grid of display sizes, origins and scales, so "it works on
// the monitor that happened to be plugged in" is not what is being claimed.

/// The display arrangements to check. Sizes are real panel sizes in POINTS with the scale a Mac
/// drives them at; the origins put the display left of, right of, above and below the primary,
/// including the fractional-looking offsets a menu-bar height produces.
private struct Arrangement {
    let name: String
    let widthInPoints: Double
    let heightInPoints: Double
    let scale: Double
    let originX: Double
    let originY: Double
}

private let panels: [(name: String, width: Double, height: Double, scale: Double)] = [
    ("1280x720 @1x", 1280, 720, 1),
    ("1920x1080 @1x", 1920, 1080, 1),
    ("1920x1080 @2x", 1920, 1080, 2),
    ("2560x1440 @1x", 2560, 1440, 1),
    ("3440x1440 ultrawide @1x", 3440, 1440, 1),
    ("3840x2160 @1x", 3840, 2160, 1),
    ("3840x2160 @2x", 3840, 2160, 2),
    ("5120x2880 @2x", 5120, 2880, 2),
    ("1512x982 built-in @2x", 1512, 982, 2),
    ("1728x1117 built-in @2x", 1728, 1117, 2),
    // A non-integer scale, which macOS drives scaled modes at. The rule must not depend on the
    // scale being a whole number.
    ("1707x1067 scaled @1.5x", 1707, 1067, 1.5),
]

private let placements: [(name: String, x: Double, y: Double)] = [
    ("at the origin", 0, 0),
    ("to the left", -1920, 0),
    ("to the left and raised", -1920, -63),
    ("to the right", 1512, 0),
    ("to the right and dropped", 1512, 420),
    ("above", 0, -1080),
    ("below", 0, 982),
    ("far left, offset", -3840, 300),
]

private let displayUUID = UUID(uuidString: "D15D1A00-2222-4333-8444-555566667777")!

private func arrangements() -> [Arrangement] {
    panels.flatMap { panel in
        placements.map { placement in
            Arrangement(name: "\(panel.name) \(placement.name)",
                        widthInPoints: panel.width, heightInPoints: panel.height,
                        scale: panel.scale, originX: placement.x, originY: placement.y)
        }
    }
}

/// The viewport a window capture builds, written the way `CaptureSource.viewport(scale:displayUUID:)`
/// writes it: **the display's global origin plus a DISPLAY-LOCAL source rect**, against a buffer
/// sized from the window in the window display's scale.
///
/// Restated here rather than called because `CaptureSource` needs an `SCWindow` and an
/// `SCDisplay`, neither of which can be constructed in a test — which is the whole reason § 29
/// of the probe exists. What is shared is the arithmetic, and that is what is pinned.
///
/// **`sourceRect` is a parameter, and that is the point of the file.** An earlier version
/// derived it here as `global - origin` and then added the origin back, which is a tautology: it
/// passed no matter what the rule was. The defect being guarded against is a caller handing this
/// a GLOBAL rectangle, so the rectangle has to come from outside.
private func windowViewport(in arrangement: Arrangement,
                            sourceRectX: Double, sourceRectY: Double,
                            windowWidth: Double, windowHeight: Double) -> CaptureViewport {
    let geometry = DisplayGeometry(
        displayUUID: displayUUID,
        pixelWidth: Int((windowWidth * arrangement.scale).rounded()),
        pixelHeight: Int((windowHeight * arrangement.scale).rounded()),
        scale: arrangement.scale)
    return CaptureViewport(geometry: geometry,
                           globalOriginX: arrangement.originX + sourceRectX,
                           globalOriginY: arrangement.originY + sourceRectY,
                           widthInPoints: windowWidth, heightInPoints: windowHeight)
}

/// The same viewport for a window at a known global position, with the rebase done correctly.
private func correctViewport(in arrangement: Arrangement,
                             windowGlobalX: Double, windowGlobalY: Double,
                             windowWidth: Double, windowHeight: Double) -> CaptureViewport {
    windowViewport(in: arrangement,
                   sourceRectX: windowGlobalX - arrangement.originX,
                   sourceRectY: windowGlobalY - arrangement.originY,
                   windowWidth: windowWidth, windowHeight: windowHeight)
}

/// **The centre of the recorded window is the centre of the recording.** True whatever the
/// display's size, scale or position, which is what makes it an oracle rather than a
/// restatement of the formula: it is a claim about what the numbers MEAN.
@Test func aWindowsCentreIsTheCentreOfItsRecordingOnEveryDisplay() throws {
    for arrangement in arrangements() {
        // A window a quarter of the way in, sized so it fits the smallest panel here.
        let width = 640.0, height = 400.0
        let x = arrangement.originX + arrangement.widthInPoints / 4
        let y = arrangement.originY + arrangement.heightInPoints / 4
        let viewport = correctViewport(in: arrangement, windowGlobalX: x, windowGlobalY: y,
                                       windowWidth: width, windowHeight: height)
        let centre = try #require(
            viewport.normalise(globalTopLeftX: x + width / 2, globalTopLeftY: y + height / 2),
            "\(arrangement.name): the window's own centre fell outside the recording")
        #expect(abs(centre.x - 0.5) < 1e-9, "\(arrangement.name): x was \(centre.x)")
        #expect(abs(centre.y - 0.5) < 1e-9, "\(arrangement.name): y was \(centre.y)")
    }
}

/// **Where a display sits must not change where the cursor is drawn.** The metamorphic relation:
/// move the display and the window together and every normalised sample is unchanged. A global
/// rectangle used where a local one is meant breaks exactly this, and breaks it by the distance
/// the arrangement moved — which is why the symptom on real hardware was a cursor that had left
/// the frame entirely rather than one that was slightly off.
@Test func movingTheWholeArrangementChangesNothing() throws {
    for panel in panels {
        let base = Arrangement(name: panel.name, widthInPoints: panel.width,
                               heightInPoints: panel.height, scale: panel.scale,
                               originX: 0, originY: 0)
        let width = 640.0, height = 400.0
        let baseViewport = correctViewport(in: base, windowGlobalX: 100, windowGlobalY: 50,
                                           windowWidth: width, windowHeight: height)
        for placement in placements {
            let moved = Arrangement(name: panel.name, widthInPoints: panel.width,
                                    heightInPoints: panel.height, scale: panel.scale,
                                    originX: placement.x, originY: placement.y)
            let movedViewport = correctViewport(in: moved,
                                                windowGlobalX: 100 + placement.x,
                                                windowGlobalY: 50 + placement.y,
                                                windowWidth: width, windowHeight: height)
            // The same sample, in each arrangement's own global space.
            let here = try #require(baseViewport.normalise(globalTopLeftX: 300,
                                                           globalTopLeftY: 200))
            let there = try #require(
                movedViewport.normalise(globalTopLeftX: 300 + placement.x,
                                        globalTopLeftY: 200 + placement.y),
                "\(panel.name) \(placement.name): the sample left the recording")
            #expect(abs(here.x - there.x) < 1e-9,
                    "\(panel.name) \(placement.name): x moved \(here.x) → \(there.x)")
            #expect(abs(here.y - there.y) < 1e-9,
                    "\(panel.name) \(placement.name): y moved \(here.y) → \(there.y)")
        }
    }
}

/// **The scale cancels, and that was a surprise worth pinning.**
///
/// The first version of this file asserted the opposite: that normalising with the main
/// display's scale against a buffer built at the window display's would move every sample by
/// the ratio between them. It does not. `CaptureViewport` does not divide by the geometry's
/// pixel extent — it rebuilds the divisor as `widthInPoints * geometry.scale`, so the scale
/// appears once in the numerator and once in the denominator and leaves. `globalPoint(of:)`
/// cancels it the same way on the way back. The test failed, and the failure was right.
///
/// So the scale defect this file was written for does NOT move the drawn cursor. What it does
/// is put a number in the recorded `DisplayGeometry` — and in the `GeometryRevision` digested
/// from it — that is not the scale the display runs at. Nothing reads it back today, which is
/// precisely how it sat wrong; `cross-boundary-digest-probe` § 29.2 is what holds it, against
/// the real capture stack, because `SCDisplay` cannot be constructed here.
///
/// This test pins the cancellation so that a future change which makes the scale matter again
/// fails HERE, next to the explanation, rather than silently reviving the defect.
@Test func theScaleCancelsInsideAViewportAndLeavesTheSampleAlone() throws {
    let scales = Array(Set(panels.map(\.scale))).sorted()
    for panel in panels {
        let width = 640.0, height = 400.0
        let x = -1920.0 + 200, y = -63.0 + 100
        var answers: [Double] = []
        for scale in scales {
            // The buffer keeps the WINDOW display's scale — `WindowTargets` sizes it — and only
            // the normalising scale varies, which is exactly the defect's shape.
            let geometry = DisplayGeometry(
                displayUUID: displayUUID,
                pixelWidth: Int((width * panel.scale).rounded()),
                pixelHeight: Int((height * panel.scale).rounded()),
                scale: scale)
            let viewport = CaptureViewport(geometry: geometry,
                                           globalOriginX: x, globalOriginY: y,
                                           widthInPoints: width, heightInPoints: height)
            let sample = try #require(
                viewport.normalise(globalTopLeftX: x + width / 2, globalTopLeftY: y + height / 2),
                "\(panel.name) at \(scale)x: the centre fell outside the recording")
            #expect(abs(sample.x - 0.5) < 1e-9 && abs(sample.y - 0.5) < 1e-9,
                    "\(panel.name) at \(scale)x: centre was (\(sample.x), \(sample.y))")
            answers.append(sample.x)
        }
        #expect(Set(answers.map { ($0 * 1e9).rounded() }).count == 1,
                "\(panel.name): the scale changed the answer — \(answers)")
    }
}

/// **The round trip is the same rectangle, at every scale and every origin.** `globalPoint(of:)`
/// divides by the scale that `normalise` multiplied by, so a point that leaves and comes back
/// must be where it started. Checked across the grid because the two halves are written
/// separately and nothing else compares them.
@Test func aPointSurvivesTheRoundTripOnEveryDisplay() throws {
    for arrangement in arrangements() {
        let width = 640.0, height = 400.0
        let x = arrangement.originX + arrangement.widthInPoints / 4
        let y = arrangement.originY + arrangement.heightInPoints / 4
        let viewport = correctViewport(in: arrangement, windowGlobalX: x, windowGlobalY: y,
                                       windowWidth: width, windowHeight: height)
        for (dx, dy) in [(1.0, 1.0), (width / 2, height / 2), (width - 2, height - 2)] {
            let normalised = try #require(
                viewport.normalise(globalTopLeftX: x + dx, globalTopLeftY: y + dy),
                "\(arrangement.name): (\(dx), \(dy)) fell outside the recording")
            let back = viewport.globalPoint(of: normalised)
            #expect(abs(back.x - (x + dx)) < 1e-6 && abs(back.y - (y + dy)) < 1e-6,
                    """
                    \(arrangement.name): (\(x + dx), \(y + dy)) came back as \(back)
                    """)
        }
    }
}

/// **The defect, reproduced: a global rectangle where a display-local one is meant.**
///
/// This is the control that makes the three tests above mean something. `WindowTargets.source(for:)`
/// handed `SCWindow.frame` — global — straight into `WindowCapture.sourceRect`, which
/// `viewport(scale:displayUUID:)` then rebases by adding the display's origin. On a display at
/// the global origin that is harmless; anywhere else the recorded rectangle is placed a whole
/// display away from the window, and every pointer sample falls outside it.
///
/// **`normalise` returns `nil` rather than clamping**, so the symptom is not a cursor slightly
/// off — it is no cursor at all, for the whole recording. Asserted here for every arrangement
/// whose origin is not zero; the zero-origin ones are the case that hid it, and they are
/// expected to pass through unharmed.
@Test func aGlobalRectangleWhereALocalOneIsMeantPutsTheWindowOffTheRecording() throws {
    var offOrigin = 0
    for arrangement in arrangements() {
        let width = 640.0, height = 400.0
        let x = arrangement.originX + arrangement.widthInPoints / 4
        let y = arrangement.originY + arrangement.heightInPoints / 4
        // The bug: the GLOBAL frame passed where a display-local rect belongs.
        let wrong = windowViewport(in: arrangement, sourceRectX: x, sourceRectY: y,
                                   windowWidth: width, windowHeight: height)
        let centre = wrong.normalise(globalTopLeftX: x + width / 2,
                                     globalTopLeftY: y + height / 2)
        if arrangement.originX == 0 && arrangement.originY == 0 {
            // The case that hid the defect for as long as it existed.
            let unharmed = try #require(
                centre, "\(arrangement.name): a display at the global origin is unaffected")
            #expect(abs(unharmed.x - 0.5) < 1e-9 && abs(unharmed.y - 0.5) < 1e-9)
        } else {
            offOrigin += 1
            #expect(centre == nil, """
                \(arrangement.name): the centre still normalised to \(centre as Any) with a \
                global rectangle used as a local one — this control cannot see the defect.
                """)
        }
    }
    #expect(offOrigin > 0, "no arrangement had a non-zero origin, so nothing was controlled")
}
