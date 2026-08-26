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
