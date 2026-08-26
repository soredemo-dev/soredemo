import CoreMedia
import Foundation
import Render
import Testing
import Timeline
@testable import Compositing

/// **The loop, measured through `pointerPlacement` against the real recording.** `CursorLoop`'s
/// own tests pin the arithmetic; this pins the wiring — that the compositor reads the style,
/// finds the video's opening position, knows the output's length, and applies all three in
/// output time rather than source time.
///
/// Extends the serialized suite because it writes `editTimeline` and `cursorStyle`, both
/// process-global.
extension StageCompositorTests {
    private static let second: Int64 = 1_000_000_000

    /// **A trimmed timeline, deliberately.** Output time 0 is source time 9.5 s, so a loop that
    /// glided back to the SOURCE's opening position — the take's first frame, which this edit
    /// cut — would land somewhere other than the exported video's first frame. The distinction
    /// is the reason `CursorLoop` is a function of output time, and this is the test that would
    /// catch it being fed source time.
    ///
    /// **Why 9.5 s to 19.5 s.** The fixture's 251 pointer samples sit in three clusters —
    /// 0–1 s, 9–11 s and 17–20 s — with nothing between them, and the compositor draws no
    /// pointer where the recording has none. A first draft trimmed 2 s to 7 s, which is inside
    /// the first gap, and every placement came back `nil`. Measured from the fixture's own
    /// bytes rather than guessed at; the instants sampled below sit inside clusters too.
    private static func tenSecondsFromNineAndAHalf() -> EditTimeline {
        EditTimeline.whole(duration: Nanoseconds(30 * second))
            .trimmed(toSource: (9 * second + second / 2)..<(19 * second + second / 2))
    }
    /// **The last FRAME, not the end instant.** The edit is half-open, so output time 10.0 s maps
    /// to no source time and `pointerPlacement` answers `nil` there — which is correct, because
    /// no frame is composed at 10.0 s. The last frame of a 60 fps export of this edit is one
    /// frame duration earlier, and that is the frame the loop promises will match the first.
    private static let lastFrameSeconds = 10.0 - 1.0 / 60

    private func placement(_ compositor: StageCompositor, atOutputSeconds seconds: Double,
                           plan: RenderPlan) -> NormalizedPointerPlacement? {
        compositor.pointerPlacement(at: CMTime(seconds: seconds, preferredTimescale: 600),
                                    in: plan)
    }

    @Test func withTheLoopOnTheLastFrameOfTheOutputMatchesItsFirst() throws {
        let saved = StageCompositor.settings()
        defer { StageCompositor.apply(saved) }
        unsafe StageCompositor.observationLogURL = try recordedObservationLog()
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = Self.tenSecondsFromNineAndAHalf()
        let plan = stagePlan(pointer: nil)

        // — loop off: where the cursor actually is at the two ends —
        unsafe StageCompositor.cursorStyle = .default
        let off = StageCompositor()
        let first = try #require(placement(off, atOutputSeconds: 0, plan: plan),
                                 "the fixture has no drawn pointer at source 9.5 s; pick another span")
        let lastUnlooped = try #require(placement(off, atOutputSeconds: Self.lastFrameSeconds, plan: plan))
        // The test proves nothing if the recording happened to end where it began.
        let apart = (pow(lastUnlooped.x - first.x, 2) + pow(lastUnlooped.y - first.y, 2)).squareRoot()
        #expect(apart > 2, """
            the fixture's cursor is only \(apart) px from its opening position at the end, so a loop \
            that did nothing would pass below — choose a span where it moved
            """)

        // — loop on —
        unsafe StageCompositor.cursorStyle = CursorStyle.default.changing(loopsToStart: true)
        let on = StageCompositor()
        let firstLooped = try #require(placement(on, atOutputSeconds: 0, plan: plan))
        let lastLooped = try #require(placement(on, atOutputSeconds: Self.lastFrameSeconds, plan: plan))

        // The first frame is untouched — the glide is at the END, and a loop that also moved the
        // start would be chasing itself.
        #expect(firstLooped.x == first.x && firstLooped.y == first.y)
        // And the last frame IS the first. Exact, for `CursorLoop.position`'s reason: both go
        // through the same `contentX/contentY` mapping from the same normalised point.
        #expect(abs(lastLooped.x - first.x) < 1e-9 && abs(lastLooped.y - first.y) < 1e-9, """
            with the loop on, the last frame drew the cursor at (\(lastLooped.x), \(lastLooped.y)) \
            and the first at (\(first.x), \(first.y))
            """)
    }

    /// Before the lead begins the loop changes nothing at all — not "nearly nothing". A loop
    /// that nudged the cursor for the whole video would be a different feature.
    @Test func beforeTheLeadTheLoopLeavesTheCursorExactlyAlone() throws {
        let saved = StageCompositor.settings()
        defer { StageCompositor.apply(saved) }
        unsafe StageCompositor.observationLogURL = try recordedObservationLog()
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = Self.tenSecondsFromNineAndAHalf()
        let plan = stagePlan(pointer: nil)

        unsafe StageCompositor.cursorStyle = .default
        let off = StageCompositor()
        unsafe StageCompositor.cursorStyle = CursorStyle.default.changing(loopsToStart: true)
        let on = StageCompositor()

        // Well before the 0.8 s lead (10 − 0.8 = 9.2), and each inside a sample cluster —
        // source 9.7 s, 10.3 s and 17.5 s — so every placement is a drawn one.
        for seconds in [0.2, 0.8, 8.0] {
            let a = try #require(placement(off, atOutputSeconds: seconds, plan: plan))
            let b = try #require(placement(on, atOutputSeconds: seconds, plan: plan))
            #expect(a.x == b.x && a.y == b.y, "at \(seconds) s the loop moved the cursor early")
        }
    }

    /// The style is the only switch. A compositor with the loop OFF must draw the last frame
    /// where the recording put it — otherwise the previous test's `apart > 2` control is the
    /// thing being measured, not the loop.
    @Test func withTheLoopOffTheLastFrameIsWhereTheRecordingLeftIt() throws {
        let saved = StageCompositor.settings()
        defer { StageCompositor.apply(saved) }
        unsafe StageCompositor.observationLogURL = try recordedObservationLog()
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = Self.tenSecondsFromNineAndAHalf()
        unsafe StageCompositor.cursorStyle = .default
        let plan = stagePlan(pointer: nil)
        let off = StageCompositor()
        let first = try #require(placement(off, atOutputSeconds: 0, plan: plan))
        let last = try #require(placement(off, atOutputSeconds: Self.lastFrameSeconds, plan: plan))
        #expect(!(last.x == first.x && last.y == first.y))
    }
}

// MARK: - the press reaches the pixels

/// **A pressed cursor is drawn smaller, and this is measured off the frame.** `CursorPressTests`
/// pins the curve; this pins that the curve reaches the picture — the failure
/// `CameraOverlayStyle.borderOpacity` had, where a public option computed a value nothing drew.
extension StageCompositorTests {
    @Test func aPressedCursorCoversLessOfTheFrameThanAnUnpressedOne() throws {
        let saved = StageCompositor.settings()
        defer { StageCompositor.apply(saved) }
        unsafe StageCompositor.style = .default
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = nil
        // No ripple: the ring is drawn into the same bitmap, and a test that counted every
        // non-background pixel would be measuring the ripple's growth rather than the press.
        unsafe StageCompositor.cursorStyle = CursorStyle.default.changing(clickEffect: CursorStyle.ClickEffect.none)

        let renderer: any FrameRendering
        do { renderer = try CoreImageFrameRenderer() }
        catch FrameRenderingError.noRenderDevice {
            Issue.record("no Metal render device on this machine — a real answer, not a skip")
            return
        }

        /// How many pixels the drawn cursor puts on the frame at `press`. The art is white with
        /// a black stroke over a mid-blue source, so "near-white" is the cursor and nothing else.
        func cursorPixels(press: Double) throws -> Int {
            let source = try makePixelBuffer(width: 640, height: 360, fill: sourceFill)
            let destination = try makePixelBuffer(width: 640, height: 360, fill: (0, 0, 0))
            let base = StagePlanner.plan(outputWidth: 640, outputHeight: 360,
                                         sourceWidth: 640, sourceHeight: 360, style: .default)
            let placement = NormalizedPointerPlacement(x: 320, y: 180, ripplePhase: nil,
                                                       pressScale: press)
            let plan = RenderPlan(outputWidth: base.outputWidth, outputHeight: base.outputHeight,
                                  card: base.card, cornerRadius: base.cornerRadius,
                                  style: base.style, pointer: placement,
                                  cursorStyle: unsafe StageCompositor.cursorStyle)
            try renderer.render(plan, source: source, camera: nil, into: destination)
            return try pixels(of: destination)
                .count { $0.r > 200 && $0.g > 200 && $0.b > 200 }
        }

        let full = try cursorPixels(press: 1)
        #expect(full > 0, """
            no cursor was drawn at all, so the comparison below would be between two zeroes
            """)
        let pressed = try cursorPixels(press: CursorPress.pressedScale)
        #expect(pressed < full, """
            a cursor pressed to \(CursorPress.pressedScale) covered \(pressed) pixels against an \
            unpressed \(full). The press is computed and not drawn.
            """)
        // Roughly the square of the scale, since it is an area. Loose bounds: antialiasing and
        // the black stroke's share both move with size, and the claim is "smaller", not "smaller
        // by exactly this much".
        let ratio = Double(pressed) / Double(full)
        let expected = CursorPress.pressedScale * CursorPress.pressedScale
        #expect(abs(ratio - expected) < 0.15, """
            the pressed cursor covers \(ratio) of the full one; a scale of \
            \(CursorPress.pressedScale) should be about \(expected) of the area
            """)
    }

    /// The hotspot stays where the recording put it. Scaling the art about the bitmap's corner
    /// instead of its hotspot walks the cursor a few points toward the frame's origin on every
    /// click — visible as the pointer twitching away from what it is clicking.
    @Test func aPressedCursorStaysOnItsOwnHotspot() throws {
        let saved = StageCompositor.settings()
        defer { StageCompositor.apply(saved) }
        unsafe StageCompositor.style = .default
        unsafe StageCompositor.cursorStyle = CursorStyle.default.changing(clickEffect: CursorStyle.ClickEffect.none)

        let renderer: any FrameRendering
        do { renderer = try CoreImageFrameRenderer() }
        catch FrameRenderingError.noRenderDevice {
            Issue.record("no Metal render device on this machine — a real answer, not a skip")
            return
        }

        /// The tip of whatever the cursor drew: the arrow extends toward +x and −y from its
        /// tip, so the minimum-x of the topmost white row IS the tip.
        func tip(press: Double) throws -> (x: Int, y: Int)? {
            let source = try makePixelBuffer(width: 640, height: 360, fill: sourceFill)
            let destination = try makePixelBuffer(width: 640, height: 360, fill: (0, 0, 0))
            let base = StagePlanner.plan(outputWidth: 640, outputHeight: 360,
                                         sourceWidth: 640, sourceHeight: 360, style: .default)
            let plan = RenderPlan(outputWidth: base.outputWidth, outputHeight: base.outputHeight,
                                  card: base.card, cornerRadius: base.cornerRadius,
                                  style: base.style,
                                  pointer: NormalizedPointerPlacement(x: 320, y: 180,
                                                                      ripplePhase: nil,
                                                                      pressScale: press),
                                  cursorStyle: unsafe StageCompositor.cursorStyle)
            try renderer.render(plan, source: source, camera: nil, into: destination)
            let frame = try pixels(of: destination)
            for row in 0..<360 {
                for column in 0..<640 {
                    let p = frame[row * 640 + column]
                    if p.r > 200 && p.g > 200 && p.b > 200 { return (column, row) }
                }
            }
            return nil
        }

        let unpressed = try #require(try tip(press: 1), "no cursor drawn unpressed")
        let pressed = try #require(try tip(press: CursorPress.pressedScale),
                                   "no cursor drawn pressed")
        // Within two pixels: the art is antialiased and shrinking it moves which subpixel
        // crosses the threshold, but the tip must not travel.
        #expect(abs(pressed.x - unpressed.x) <= 2 && abs(pressed.y - unpressed.y) <= 2, """
            the tip moved from (\(unpressed.x), \(unpressed.y)) to (\(pressed.x), \(pressed.y)) \
            when the cursor was pressed — it is being scaled about the bitmap's corner rather \
            than about its hotspot
            """)
    }
}
