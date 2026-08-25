import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Framing

// `framing-depth`'s row carries an unusual requirement: **verify it actually varies**
// rather than collapsing to two values. That is a claim about the MAPPING, not about the
// function existing, so the spread test below is the row's real content.

private let revision = GeometryRevision(id: 3)

private func target(extent: Double, role: String = "AXButton") -> FramingTarget {
    // Square in normalised space so `extent` is unambiguously the binding dimension;
    // the rectangular case has its own test.
    FramingTarget(frame: NormalizedFrame(origin: NormalizedPoint(x: 0.2, y: 0.2),
                                         size: NormalizedSize(width: extent, height: extent),
                                         revision: revision),
                  role: role)
}

/// Realistic control extents on a 1920×1080 recording, smallest first. Named rather than
/// numeric so the spread test below is arguing about controls, not about arithmetic.
///
/// **Documented, not measured.** `framing-depth`'s row asks for verification on real data;
/// the only recording committed to this repo carries three AX chains, which cannot show a
/// spread. These are the sizes real controls have — a 16 px checkbox, a 28 px toolbar
/// button, a 300 px text field — and the gap between "documented" and "measured" is stated
/// here rather than implied by a green test.
private let realisticExtents: [(name: String, extent: Double)] = [
    ("16 px checkbox", 16.0 / 1080),
    ("24 px dialog button", 24.0 / 1080),
    ("28 px toolbar button", 28.0 / 1080),
    ("200 px sidebar row", 200.0 / 1920),
    ("300 px text field", 300.0 / 1920),
    ("500 px wide toolbar", 500.0 / 1920),
    ("700 px small pane", 700.0 / 1920),
]

// MARK: - the row's own requirement

/// **The anti-collapse test.** A naive "make the control fill half the frame" rule saturates
/// at the ceiling for every control under ~4% of the screen — which is most controls — and
/// the whole mapping degenerates to two values. Across seven realistic sizes this one must
/// produce at least five distinct depths.
@Test func depthVariesAcrossRealisticControlSizesRatherThanCollapsing() {
    let depths = realisticExtents.map { FramingDepth.zoom(for: target(extent: $0.extent), coverage: 1) }
    let distinct = Set(depths)
    #expect(distinct.count >= 5, """
        seven realistic control sizes produced only \(distinct.count) distinct depths \
        (\(zip(realisticExtents, depths).map { "\($0.0.name): \($0.1)" }.joined(separator: ", "))) \
        — the mapping has collapsed, which is exactly what this row exists to prevent
        """)
}

/// Bigger control, never deeper zoom. Monotonicity is what makes the depth READ as a
/// consequence of size; a non-monotonic mapping would zoom further into a larger button
/// than a smaller one and look like a bug with no way to describe it.
@Test func aLargerControlNeverZoomsDeeper() {
    let ascending = realisticExtents.sorted { $0.extent < $1.extent }
    let depths = ascending.map { FramingDepth.zoom(for: target(extent: $0.extent), coverage: 1) }
    for (earlier, later) in zip(depths, depths.dropFirst()) {
        #expect(earlier >= later, "depth rose with size: \(depths)")
    }
}

// MARK: - bounded

@Test func depthNeverZoomsOutAndNeverExceedsTheCeiling() {
    for extent in [0.001, 0.01, 0.05, 0.2, 0.5, 0.95] {
        let zoom = FramingDepth.zoom(for: target(extent: extent), coverage: 1)
        #expect(zoom >= FramingDepth.minimumZoom, "\(extent) produced \(zoom), below the floor")
        #expect(zoom <= FramingDepth.maximumZoom, "\(extent) produced \(zoom), above the ceiling")
    }
}

/// **The target must survive its own zoom.** At depth `z` the viewport shows `1/z` of the
/// frame, so a target wider than that would be cropped by the very move meant to show it.
/// Asserted across the whole range including the degenerate large end.
@Test func theTargetAlwaysFitsInsideTheViewportItsDepthImplies() {
    for extent in [0.001, 0.02, 0.104, 0.3, 0.5, 0.8, 0.95] {
        let zoom = FramingDepth.zoom(for: target(extent: extent), coverage: 1)
        #expect(extent <= 1.0 / zoom, """
            a \(extent) target at depth \(zoom) needs a viewport of \(1.0 / zoom) — it would \
            be cropped by its own zoom
            """)
    }
}

// MARK: - quantised

/// Quantisation is why two clicks on similarly-sized buttons produce the SAME depth: the
/// camera then has no reason to make a small pointless adjustment between them. Without it
/// every pixel of size difference becomes a distinct zoom level.
@Test func depthIsQuantisedToTheStep() {
    for extent in stride(from: 0.02, through: 0.4, by: 0.011) {
        let zoom = FramingDepth.zoom(for: target(extent: extent), coverage: 1)
        let steps = zoom / FramingDepth.quantisationStep
        #expect(abs(steps - steps.rounded()) < 1e-9, "\(zoom) is not a multiple of the step")
    }
}

/// Two controls a few pixels apart land on one depth — the point of quantising, asserted
/// as a behaviour rather than inferred from the constant.
@Test func twoNearlyIdenticalControlsShareADepth() {
    let a = FramingDepth.zoom(for: target(extent: 200.0 / 1920), coverage: 1)
    let b = FramingDepth.zoom(for: target(extent: 206.0 / 1920), coverage: 1)
    #expect(a == b)
}

// MARK: - which dimension binds

/// A wide, short control is bound by its WIDTH: zooming as if it were 24 px tall would
/// crop its ends. The binding dimension is the larger one, and the two orientations must
/// agree — a mapping that read only `height` passes the first and fails the second.
@Test func theBindingDimensionIsTheLargerOne() {
    let wide = FramingTarget(
        frame: NormalizedFrame(origin: NormalizedPoint(x: 0.1, y: 0.4),
                               size: NormalizedSize(width: 0.3, height: 0.02),
                               revision: revision), role: "AXTextField")
    let tall = FramingTarget(
        frame: NormalizedFrame(origin: NormalizedPoint(x: 0.4, y: 0.1),
                               size: NormalizedSize(width: 0.02, height: 0.3),
                               revision: revision), role: "AXScrollBar")
    #expect(FramingDepth.zoom(for: wide, coverage: 1) == FramingDepth.zoom(for: tall, coverage: 1))
    #expect(FramingDepth.zoom(for: wide, coverage: 1) == FramingDepth.zoom(for: target(extent: 0.3), coverage: 1))
}

/// A degenerate target cannot arrive from `FramingGate` — it refuses one — but this
/// function is public and pure, and returning a depth of infinity for a zero-sized frame
/// would put a non-finite number into the camera. The floor is the answer.
@Test func aZeroSizedTargetTakesTheFloorRatherThanInfinity() {
    let flat = FramingTarget(
        frame: NormalizedFrame(origin: NormalizedPoint(x: 0.5, y: 0.5),
                               size: NormalizedSize(width: 0, height: 0),
                               revision: revision), role: nil)
    let zoom = FramingDepth.zoom(for: flat, coverage: 1)
    #expect(zoom.isFinite)
    #expect(zoom <= FramingDepth.maximumZoom)
}

// MARK: - the ceiling: a zoom is a magnification of recorded pixels

/// **The ceiling is a function of pixel density, not a constant.** The same card carries a
/// deeper zoom from a Retina capture than from a 1x one, because a source pixel may only be
/// stretched `maximumMagnification` times. Two captures, one card — the fixture the rule
/// exists to distinguish; a constant ceiling would return the same number for both.
@Test func theCeilingIsDeeperForADenserRecording() {
    let card = 2661.0
    let retina = FramingDepth.zoomCeiling(sourcePixels: 3024, cardPixels: card)
    let onePixel = FramingDepth.zoomCeiling(sourcePixels: 1920, cardPixels: card)
    #expect(retina > onePixel)
    // At the ceiling the magnification is exactly the maximum: z × card / source.
    #expect(abs(retina * card / 3024 - FramingDepth.maximumMagnification) < 1e-9)
    #expect(abs(onePixel * card / 1920 - FramingDepth.maximumMagnification) < 1e-9)
}

/// A card the recording cannot fill at 1× — a 720p capture in a 4K stage — gives "no zoom",
/// never a zoom out; and a degenerate size is the floor, not a NaN handed to a camera.
@Test func theCeilingNeverFallsBelowNoZoom() {
    #expect(FramingDepth.zoomCeiling(sourcePixels: 1280, cardPixels: 3379) == FramingDepth.minimumZoom)
    #expect(FramingDepth.zoomCeiling(sourcePixels: 0, cardPixels: 100) == FramingDepth.minimumZoom)
    #expect(FramingDepth.zoomCeiling(sourcePixels: 100, cardPixels: .infinity) == FramingDepth.minimumZoom)
}

// MARK: - writing a depth down

/// **Every depth the curve can produce writes itself back exactly.** This is the property
/// `%.1f` broke: the timeline labelled a 2.25× zoom "2.2×" and a 1.25× zoom "1.2×", because
/// `String(format:)` rounds half to even and one decimal cannot hold a quarter. The loop
/// walks every quantised step from the floor to the ceiling, so a new step size is caught
/// here rather than by someone reading a lane.
@Test func everyQuantisedDepthWritesItselfBack() {
    var value = FramingDepth.minimumZoom
    var checked = 0
    while value <= FramingDepth.maximumZoom + 1e-9 {
        let label = FramingDepth.label(for: value)
        let read = Double(label.replacingOccurrences(of: "\u{00D7}", with: ""))
        #expect(read != nil, "\(value) produced \"\(label)\", which is not a number")
        #expect(abs((read ?? .nan) - value) < 0.005, "\(value) was written as \"\(label)\"")
        checked += 1
        value += FramingDepth.quantisationStep
    }
    #expect(checked >= 8, "only \(checked) depths were checked; the walk covered almost nothing")
}

/// The calibration: the formatter this replaced really does get two of those steps wrong, so
/// the test above is measuring a repair rather than restating an identity.
@Test func oneDecimalPlaceMisreportsAQuarterStep() {
    // `unsafe`, marked at the site as the gate requires: `String(format:)` is a C-variadic
    // call, and calling it here is the whole point — this test exists to show what the
    // formatter `FramingDepth.label(for:)` replaced actually does with a quarter step.
    #expect(unsafe String(format: "%.1f", 2.25) == "2.2", "the premise of the fix no longer holds")
    #expect(unsafe String(format: "%.1f", 1.25) == "1.2", "the premise of the fix no longer holds")
    #expect(FramingDepth.label(for: 2.25) == "2.25\u{00D7}")
    #expect(FramingDepth.label(for: 1.25) == "1.25\u{00D7}")
}

/// Trailing zeros are trimmed and a non-finite depth cannot reach a lane as "nan×".
@Test func aWholeDepthLosesItsDecimalsAndANonFiniteOneIsRefused() {
    #expect(FramingDepth.label(for: 2) == "2\u{00D7}")
    #expect(FramingDepth.label(for: 1) == "1\u{00D7}")
    #expect(FramingDepth.label(for: 1.5) == "1.5\u{00D7}")
    #expect(FramingDepth.label(for: 2.05) == "2.05\u{00D7}", "a fraction under ten lost its zero")
    #expect(FramingDepth.label(for: .nan) == "—")
    #expect(FramingDepth.label(for: .infinity) == "—")
    #expect(FramingDepth.label(for: -1) == "—", "a negative depth is not a depth")
}

// MARK: - the variant the depth is decided for

/// **Coverage is an AREA share; an extent is a length.** The two differ by a square root,
/// and using coverage directly would shrink a control to a third rather than to a little
/// over half — deepening every portrait zoom by far more than the picture actually lost.
@Test func theLinearShareIsTheSquareRootOfTheAreaShare() {
    // A 16:9 recording covers 0.31640625 of a 9:16 frame — `AspectVariant`'s own number.
    #expect(abs(FramingDepth.linearShare(ofCoverage: 0.31640625) - 0.5625) < 1e-12)
    #expect(FramingDepth.linearShare(ofCoverage: 1) == 1)
}

/// **A coverage that cannot be a coverage is treated as the recording's own shape.** It
/// arrives from a picker and from a decoder; a `precondition` here would trap a person's
/// project open, and a zero would make every depth the ceiling.
@Test func aNonsenseCoverageIsTreatedAsTheRecordingsOwnShape() {
    for bad in [0.0, -0.5, Double.nan, .infinity] {
        #expect(FramingDepth.linearShare(ofCoverage: bad) == 1, "\(bad) was not refused")
    }
    // Above 1 clamps rather than going shallower than the recording's own shape.
    #expect(FramingDepth.linearShare(ofCoverage: 4) == 1)
}

/// **The regression guard.** Every depth this project produced before coverage existed was
/// computed at the recording's own shape, so coverage 1 must reproduce all of them exactly —
/// otherwise this change would have silently re-cut every landscape export ever made.
@Test func aVariantMatchingTheRecordingChangesNoDepth() {
    for (name, extent) in realisticExtents {
        let zoom = FramingDepth.zoom(for: target(extent: extent), coverage: 1)
        // The pre-coverage formula, restated rather than referenced, so this test would
        // catch the curve being changed as well as the parameter being misapplied.
        let clamped = min(max(extent, FramingDepth.deepestAtExtent), FramingDepth.shallowestAtExtent)
        let position = log(clamped / FramingDepth.deepestAtExtent)
            / log(FramingDepth.shallowestAtExtent / FramingDepth.deepestAtExtent)
        var expected = FramingDepth.maximumZoom
            - (FramingDepth.maximumZoom - FramingDepth.minimumZoom) * position
        if extent > 0 { expected = min(expected, 1.0 / (extent * 1.2)) }
        let stepped = (expected / FramingDepth.quantisationStep).rounded() * FramingDepth.quantisationStep
        #expect(zoom == min(max(stepped, FramingDepth.minimumZoom), FramingDepth.maximumZoom),
                "\(name) moved at the recording's own shape")
    }
}

/// **The defect, stated as a test.** `StagePlanner` fits and never crops, so a 16:9
/// recording in a 9:16 frame is a strip covering 0.32 of it and every control in it is
/// 0.5625 of the length it had. Depth was computed from the extent within the RECORDING, so
/// portrait inherited landscape's depths and its controls came out a little over half the
/// size. Deeper is the whole point; equal is the bug.
@Test func aPortraitExportZoomsDeeperThanTheLandscapeItInherited() {
    let portrait = 0.31640625
    var deeper = 0
    for (name, extent) in realisticExtents {
        let landscape = FramingDepth.zoom(for: target(extent: extent), coverage: 1)
        let tall = FramingDepth.zoom(for: target(extent: extent), coverage: portrait)
        #expect(tall >= landscape, "\(name) got a SHALLOWER zoom in portrait")
        if tall > landscape { deeper += 1 }
    }
    // Not "every one": the smallest controls are already at `maximumZoom` in landscape and
    // have nowhere to go, which is the ceiling doing its job rather than the parameter
    // failing. A majority moving is the claim.
    #expect(deeper * 2 > realisticExtents.count,
            "only \(deeper) of \(realisticExtents.count) controls zoomed deeper in portrait")
}

/// **The safety property the shrunken extent must not break.** `minimumContextMultiple`
/// exists so a depth cannot crop the very thing it frames, and it is a statement inside the
/// RECORDING's coordinates — a target is cropped or not regardless of what shape it is
/// exported to. Feeding the shrunken extent to that clamp instead of the raw one would let
/// exactly this fail, and it binds MORE often in portrait because the depths are deeper.
@Test func aTargetStillFitsInsideTheViewportItsDepthImpliesAtEveryCoverage() {
    for coverage in [1.0, 0.5625, 0.31640625, 0.1] {
        for extent in stride(from: 0.02, through: 0.49, by: 0.01) {
            let zoom = FramingDepth.zoom(for: target(extent: extent), coverage: coverage)
            // At depth `zoom` the viewport shows `1 / zoom` of the recording.
            #expect(extent <= 1.0 / zoom + 1e-9, """
                    at coverage \(coverage) a control of \(extent) got depth \(zoom), whose \
                    viewport is only \(1.0 / zoom) wide — the zoom crops its own target
                    """)
        }
    }
}
