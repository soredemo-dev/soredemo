import Foundation
import Geometry
import Testing
import Timeline
@testable import Framing

/// Finding where somebody tapped, from nothing but how the picture changed.
///
/// **Every grid here is written by hand**, which is the point of keeping the decoding out of
/// this type: each rule is exercised against an input whose answer is known before the code
/// runs, rather than against a recording somebody has to watch.
@Suite struct MotionActivityTests {
    private let epoch = BootEpoch(id: UUID(uuidString: "5E2C1A80-33B4-4D6F-9A08-11FE2D3C4B5A")!)
    private let revision = GeometryRevision(id: 7)
    private let columns = 8
    private let rows = 12

    private func instant(_ seconds: Double) -> HostInstant {
        HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64(seconds * 1e9)))
    }

    /// A frame whose tiles are all `level`, except `hot` which are `spike`.
    private func change(_ seconds: Double, level: Double = 0.002,
                        hot: [Int] = [], spike: Double = 0) -> MotionActivity.Change {
        var tiles = [Double](repeating: level, count: columns * rows)
        for index in hot where tiles.indices.contains(index) { tiles[index] = spike }
        return MotionActivity.Change(instant: instant(seconds), columns: columns, rows: rows,
                                     tiles: tiles)
    }

    /// `count` quiet frames at 60 fps starting at `from`.
    private func quiet(_ count: Int, from: Double = 0) -> [MotionActivity.Change] {
        (0..<count).map { change(from + Double($0) / 60) }
    }

    private var settle: Int { MotionActivity.Settings.default.baselineFrames }

    // MARK: - finding an event

    @Test func aStillRecordingProducesNoZooms() {
        let clicks = MotionActivity.clicks(from: quiet(200), revision: revision)
        #expect(clicks.isEmpty, "\(clicks.count) taps found in a recording where nothing moved")
    }

    /// **A recording shorter than the baseline decides nothing.** A baseline of two frames is
    /// not a baseline, and every frame in a short clip would look like a burst against it.
    @Test func aRecordingTooShortToEstablishABaselineDecidesNothing() {
        let clicks = MotionActivity.clicks(from: quiet(settle), revision: revision)
        #expect(clicks.isEmpty)
    }

    @Test func aSuddenLocalChangeIsFoundAsATap() throws {
        var frames = quiet(settle + 1)
        frames.append(change(2.0, hot: [30, 31, 38, 39], spike: 0.6))
        frames += quiet(40, from: 2.1)

        let clicks = MotionActivity.clicks(from: frames, revision: revision)
        #expect(clicks.count == 1, "\(clicks.count) taps found where one frame changed")
        let click = try #require(clicks.first)
        #expect(click.instant == instant(2.0))
    }

    /// **The target is where the change was, not the middle of the picture.** A plain centroid
    /// over every tile drifts to the centre whenever anything at all is moving elsewhere — on a
    /// phone, the status-bar clock, every minute.
    @Test func theTargetSitsOverTheTilesThatChanged() throws {
        // Tiles 4 and 5 of row 1 — well right of centre and near the top.
        var frames = quiet(settle + 1)
        frames.append(change(2.0, hot: [12, 13], spike: 0.9))
        let clicks = MotionActivity.clicks(from: frames, revision: revision)
        let frame = try #require(clicks.first?.target.frame)

        let centreX = frame.origin.x + frame.size.width / 2
        let centreY = frame.origin.y + frame.size.height / 2
        #expect(centreX > 0.5, "the target's centre is at x \(centreX), left of where it changed")
        #expect(centreY < 0.4, "the target's centre is at y \(centreY), below where it changed")
    }

    /// **One tap is one zoom.** A tap changes the picture over several frames; without the quiet
    /// period a single press becomes a burst of five zooms half a frame apart.
    @Test func oneTapSpreadOverSeveralFramesIsOneZoom() {
        var frames = quiet(settle + 1)
        // The same spike on six consecutive frames — what a real tap's animation looks like.
        for i in 0..<6 { frames.append(change(2.0 + Double(i) / 60, hot: [30, 31], spike: 0.7)) }
        frames += quiet(40, from: 2.2)

        let clicks = MotionActivity.clicks(from: frames, revision: revision)
        #expect(clicks.count == 1, "\(clicks.count) zooms for one tap")
    }

    /// Two taps far enough apart are two zooms — the other side of the same rule.
    ///
    /// **Four tiles, not one, and the first draft's one is why this note is here.** A single
    /// tile at 0.7 against this fixture's baseline is 2.8× — just under the 3× threshold — so
    /// the test failed and the code was right. A tap on a phone lights up a control, not a
    /// pixel; the other fixtures here use four tiles for the same reason.
    @Test func twoTapsWellApartAreTwoZooms() {
        var frames = quiet(settle + 1)
        frames.append(change(2.0, hot: [30, 31, 38, 39], spike: 0.6))
        frames += quiet(120, from: 2.1)
        frames.append(change(4.2, hot: [70, 71, 78, 79], spike: 0.6))
        frames += quiet(40, from: 4.3)

        #expect(MotionActivity.clicks(from: frames, revision: revision).count == 2)
    }

    // MARK: - what must NOT be found

    /// **A ratio, not an absolute, and this is the case that needs it.** An app playing video
    /// changes a great deal every frame; the change is the background, not an event.
    @Test func anAppThatChangesConstantlyIsABackgroundRatherThanTaps() {
        // Every frame loud, none louder than the rest.
        let busy = (0..<200).map { change(Double($0) / 60, level: 0.4) }
        let clicks = MotionActivity.clicks(from: busy, revision: revision)
        #expect(clicks.isEmpty, "\(clicks.count) taps found in a video playing at a steady level")
    }

    /// **The floor is what stops silence becoming taps.** Against a baseline of zero, any noise
    /// at all is infinitely louder — so sensor noise in a perfectly still recording would read
    /// as a tap on every frame.
    @Test func sensorNoiseAgainstPerfectStillnessIsNotATap() {
        var frames = (0..<settle).map { change(Double($0) / 60, level: 0) }
        frames.append(change(1.0, hot: [30], spike: 0.0005))
        frames += (0..<40).map { change(1.1 + Double($0) / 60, level: 0) }

        let clicks = MotionActivity.clicks(from: frames, revision: revision)
        #expect(clicks.isEmpty, "a change of 0.0005 against absolute stillness read as a tap")
    }

    /// A malformed grid is skipped, not interpreted. The caller builds these from a decoder and
    /// a frame that failed to decode should cost its own frame and nothing else.
    @Test func aMalformedGridIsSkippedRatherThanInterpreted() {
        var frames = quiet(settle + 1)
        frames.append(MotionActivity.Change(instant: instant(2.0), columns: 8, rows: 12,
                                            tiles: [0.9, 0.9]))
        frames.append(MotionActivity.Change(instant: instant(2.1), columns: 0, rows: 0,
                                            tiles: []))
        frames += quiet(20, from: 2.2)
        #expect(MotionActivity.clicks(from: frames, revision: revision).isEmpty)
    }

    // MARK: - the target's shape

    /// **A target that overhangs an edge is MOVED, not shrunk.** Clipping makes it smaller, and
    /// a smaller target means a deeper zoom — so a tap in a corner would zoom further in than
    /// the same tap in the middle, which is the opposite of what anybody expects.
    @Test func aTapInTheCornerIsFramedAsWideAsOneInTheMiddle() throws {
        var corner = quiet(settle + 1)
        corner.append(change(2.0, hot: [0], spike: 0.9))
        let cornerFrame = try #require(
            MotionActivity.clicks(from: corner, revision: revision).first?.target.frame)

        var middle = quiet(settle + 1)
        middle.append(change(2.0, hot: [rows / 2 * columns + columns / 2], spike: 0.9))
        let middleFrame = try #require(
            MotionActivity.clicks(from: middle, revision: revision).first?.target.frame)

        // **The FAR corner, and the first draft only tested the near one.** Clamping the origin
        // to zero is harmless at top-left — there is room to the right — so a clipping
        // implementation passed. It bites at bottom-right, where the frame runs off the end.
        var far = quiet(settle + 1)
        far.append(change(2.0, hot: [columns * rows - 1], spike: 0.9))
        let farFrame = try #require(
            MotionActivity.clicks(from: far, revision: revision).first?.target.frame)

        for (name, frame) in [("top-left", cornerFrame), ("bottom-right", farFrame)] {
            #expect(abs(frame.size.width - middleFrame.size.width) < 1e-9, """
                a \(name) tap is framed \(frame.size.width) wide against \
                \(middleFrame.size.width) in the middle, so it would zoom DEEPER for being near \
                an edge — the opposite of what anybody expects
                """)
            #expect(abs(frame.size.height - middleFrame.size.height) < 1e-9,
                    "a \(name) tap is framed \(frame.size.height) tall against \(middleFrame.size.height)")
            // And it stayed inside the picture.
            #expect(frame.origin.x >= 0 && frame.origin.y >= 0)
            #expect(frame.origin.x + frame.size.width <= 1 + 1e-9)
            #expect(frame.origin.y + frame.size.height <= 1 + 1e-9)
        }
    }

    /// **The baseline is what came BEFORE, never including the frame being judged.**
    ///
    /// Including it pulls the average up by exactly the thing being measured against it, so a
    /// large enough event partly hides itself — and worse the larger it is, which is the
    /// opposite of what a detector should do.
    ///
    /// A first version of this suite could not see that: every fixture spiked at seven times the
    /// threshold, where self-inclusion still leaves the ratio above three. This one sits just
    /// over the line, which is where the difference lives.
    @Test func theBaselineExcludesTheFrameBeingJudged() throws {
        // **The arithmetic, because the margin is narrow and has to be.**
        //
        // 96 tiles at 0.01 gives a quiet total Q = 0.96 over a 30-frame baseline. For an event
        // of total T:
        //
        //   excluding this frame:  T / Q                     must exceed 3
        //   including this frame:  30T / (29Q + T)           must fall under 3
        //
        // The second rearranges to T < 3.22 Q, so the window is 3 Q < T < 3.22 Q — 2.88 to 3.09.
        // T = 3.0: four tiles at 0.52 plus ninety-two at 0.01.
        //
        //   excluded: 3.00 / 0.96                = 3.13  ✓ found
        //   included: 90.0 / (27.84 + 3.00)      = 2.92  ✗ missed
        //
        // A first draft used 0.70 per tile, which is 3.9× excluded and still 3.5× included —
        // over the line either way, so the mutation that broke this rule left the test green.
        let level = 0.01
        var frames = (0..<(settle)).map { change(Double($0) / 60, level: level) }
        frames.append(change(2.0, level: level, hot: [30, 31, 38, 39], spike: 0.52))
        frames += (0..<20).map { change(2.1 + Double($0) / 60, level: level) }

        let clicks = MotionActivity.clicks(from: frames, revision: revision)
        #expect(clicks.count == 1, """
            \(clicks.count) taps found. If zero, the baseline is including the frame it is \
            judging, which hides an event behind itself.
            """)
    }

    /// A single tile is a target nobody could follow, so the frame is grown around it.
    @Test func aSingleChangedTileIsGrownToSomethingAViewerCanFollow() throws {
        var frames = quiet(settle + 1)
        frames.append(change(2.0, hot: [30], spike: 0.9))
        let frame = try #require(
            MotionActivity.clicks(from: frames, revision: revision).first?.target.frame)
        #expect(frame.size.width >= MotionActivity.minimumTargetFraction)
        #expect(frame.size.height >= MotionActivity.minimumTargetFraction)
    }

    /// Every frame carries the caller's revision. A `NormalizedFrame` compared across revisions
    /// is a precondition failure, and this type has no revision of its own to offer.
    @Test func everyTargetCarriesTheRevisionItWasGiven() {
        var frames = quiet(settle + 1)
        frames.append(change(2.0, hot: [30], spike: 0.8))
        for click in MotionActivity.clicks(from: frames, revision: revision) {
            #expect(click.target.frame.revision == revision)
        }
    }

    /// **The role is `nil`, and it has to be.** `FramingTarget.role` is the accessibility role of
    /// what was framed, for a reviewer asking "what did it pick". Motion has no answer, and
    /// inventing one — "Button" — would be the true-sounding sentence with nothing underneath it
    /// that this project's rules exist to refuse.
    @Test func aMotionTargetClaimsNoAccessibilityRole() {
        var frames = quiet(settle + 1)
        frames.append(change(2.0, hot: [30], spike: 0.8))
        for click in MotionActivity.clicks(from: frames, revision: revision) {
            #expect(click.target.role == nil)
        }
    }

    // MARK: - the settings

    @Test func settingsClampRatherThanTrap() {
        #expect(MotionActivity.Settings(burstRatio: .nan, floor: .nan, quietSeconds: .nan,
                                        baselineFrames: 0).burstRatio == 3)
        #expect(MotionActivity.Settings(burstRatio: 0, floor: 0, quietSeconds: 0,
                                        baselineFrames: 0).burstRatio == 1.1)
        #expect(MotionActivity.Settings(burstRatio: 999, floor: 999, quietSeconds: 999,
                                        baselineFrames: 9999).baselineFrames == 600)
    }

    /// D6 rule 8: a project file could otherwise carry a ratio of zero, which turns every frame
    /// into a zoom.
    @Test func aDecodedSettingIsValidatedRatherThanTrusted() throws {
        let hostile = Data(#"{"burstRatio":0,"floor":0,"quietSeconds":0,"baselineFrames":0}"#.utf8)
        let decoded = try JSONDecoder().decode(MotionActivity.Settings.self, from: hostile)
        #expect(decoded.burstRatio == 1.1)
        #expect(decoded.baselineFrames == 2)
        let old = try JSONDecoder().decode(MotionActivity.Settings.self, from: Data("{}".utf8))
        #expect(old == MotionActivity.Settings.default)
    }
}

/// The four rules a real recording taught, each of which produced zoom blocks reading "1×" over
/// a video that never zoomed.
///
/// **All four were found the same way**: the timeline drew blocks, `FramingDepth` answered 1.000
/// for every one of them, and nothing was wrong anywhere in the pipeline. The blocks were
/// honestly derived from targets that honestly covered the whole picture.
@Suite struct MotionActivityDepthTests {
    private let epoch = BootEpoch(id: UUID(uuidString: "7B3D2E60-11C4-4A9F-8E07-55AB1C2D3E4F")!)
    private let revision = GeometryRevision(id: 4)
    private let columns = 8
    private let rows = 12

    private func instant(_ seconds: Double) -> HostInstant {
        HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64(seconds * 1e9)))
    }

    private func change(_ seconds: Double, level: Double = 0.002,
                        hot: [Int] = [], spike: Double = 0) -> MotionActivity.Change {
        var tiles = [Double](repeating: level, count: columns * rows)
        for index in hot where tiles.indices.contains(index) { tiles[index] = spike }
        return MotionActivity.Change(instant: instant(seconds), columns: columns, rows: rows,
                                     tiles: tiles)
    }

    private func quiet(_ count: Int, from: Double = 0) -> [MotionActivity.Change] {
        (0..<count).map { change(from + Double($0) / 60) }
    }

    private var settle: Int { MotionActivity.Settings.default.baselineFrames }

    /// **The target is a fixed size around the centre, not the extent of everything that moved.**
    ///
    /// The first version used the bounding box of every qualifying tile. Measured on a 4K iPad
    /// demo, that box spanned half the picture at 8×12, 16×24 and 24×32 alike — a finer grid
    /// changed nothing, because the change really does span that much when tapping a folder
    /// reflows the grid around it. `FramingDepth.shallowestAtExtent` is 0.5, so every one of
    /// those targets was worth no magnification at all.
    ///
    /// Motion says WHERE. It has no opinion about size, and claiming one from a bounding box was
    /// claiming precision the signal does not have.
    @Test func everyTargetIsTheSameSizeHoweverWidelyTheChangeIsSpread() throws {
        // Four adjacent tiles, and then four spread over a quarter of the frame.
        //
        // **The wide one stays under `maximumTargetArea`, and a first draft did not.** It smeared
        // across the whole picture, which this correctly refuses as a scene change — so the test
        // compared one target against nothing and failed for a reason that was not the rule it
        // is about. Columns 0–3 by rows 0–5 is half the width by half the height: 0.25.
        var tight = quiet(settle + 1)
        tight.append(change(2.0, hot: [30, 31, 38, 39], spike: 0.6))
        var wide = quiet(settle + 1)
        wide.append(change(2.0, hot: [0, 3, 40, 43], spike: 0.6))

        let tightFrame = try #require(
            MotionActivity.clicks(from: tight, revision: revision).first?.target.frame)
        let wideFrame = try #require(
            MotionActivity.clicks(from: wide, revision: revision).first?.target.frame)

        #expect(tightFrame.size.width == wideFrame.size.width)
        #expect(tightFrame.size.height == wideFrame.size.height)
        #expect(tightFrame.size.width == MotionActivity.minimumTargetFraction)
    }

    /// **And that size earns a real zoom.** The whole point: a target this size is worth more
    /// than 1.0, which is what every bounding-box target was worth.
    @Test func aMotionTargetIsWorthAnActualMagnification() throws {
        var frames = quiet(settle + 1)
        frames.append(change(2.0, hot: [30, 31, 38, 39], spike: 0.6))
        let clicks = MotionActivity.clicks(from: frames, revision: revision)
        let blocks = ZoomBlock.blocks(for: clicks, coverage: 1, intensity: 1)
        let block = try #require(blocks.first)
        #expect(block.zoom > 1.0, """
            a motion zoom is worth \(block.zoom)× — the timeline would draw a block reading "1×" \
            over a video that does not zoom, which is the state this suite exists to prevent
            """)
    }

    /// **Events are spaced beyond the window `ZoomBlock` merges within.**
    ///
    /// Blocks span `[t − 0.4, t + 1.0]` and any two that overlap become one whose target is the
    /// UNION. Three taps spread across an iPad screen merged into a union covering 0.83 × 0.86 —
    /// worth no zoom, correctly. A camera cannot follow taps a third of a second apart anyway.
    @Test func twoEventsAreNeverCloserThanTheBlockMergeWindow() throws {
        var frames = quiet(settle + 1)
        // Taps every 0.5 s for four seconds — far closer than a block is wide.
        for i in 0..<8 {
            frames.append(change(2.0 + Double(i) * 0.5, hot: [30 + i, 38 + i], spike: 0.7))
            frames += quiet(28, from: 2.0 + Double(i) * 0.5 + 0.02)
        }
        let clicks = MotionActivity.clicks(from: frames, revision: revision)
        try #require(clicks.count > 1, "only \(clicks.count) event found, so spacing is untested")

        let gaps = zip(clicks, clicks.dropFirst()).map {
            Double($1.instant.hostTime.rawValue - $0.instant.hostTime.rawValue) / 1e9
        }
        let mergeWindow = 1.4
        #expect(gaps.allSatisfy { $0 >= mergeWindow }, """
            events \(gaps.map { ($0 * 100).rounded() / 100 }) s apart — anything under \
            \(mergeWindow) s merges into one block whose target is the union of both, which is \
            worth no zoom.
            """)
        // And the blocks really do stay separate.
        let blocks = ZoomBlock.blocks(for: clicks, coverage: 1, intensity: 1)
        #expect(blocks.count == clicks.count, """
            \(clicks.count) events became \(blocks.count) blocks — they are still merging.
            """)
    }

    /// **A change across most of the screen is a transition, and it is dropped.**
    ///
    /// Measured: an event covering 0.688 of the frame was a page changing. Merged with the tap
    /// beside it, the union was the whole picture. Zooming to everything is not zooming, so
    /// there was nothing to lose by dropping it.
    @Test func aChangeCoveringMostOfTheScreenIsNotATap() {
        var frames = quiet(settle + 1)
        // Every tile loud at once — a page turn.
        frames.append(MotionActivity.Change(
            instant: instant(2.0), columns: columns, rows: rows,
            tiles: [Double](repeating: 0.8, count: columns * rows)))
        frames += quiet(40, from: 2.1)

        #expect(MotionActivity.clicks(from: frames, revision: revision).isEmpty, """
            a frame where everything changed was framed as a tap. Its target is the whole \
            picture and zooming to the whole picture is not zooming.
            """)
    }

    /// **The target comes from the loudest tiles, not from everything above average.**
    ///
    /// A real screen is never still — scrolling, animation and compression noise put a little
    /// change in almost every tile — so "above the frame's average" is almost every tile, and
    /// its centre is the middle of the picture whatever actually happened.
    @Test func aQuietBackgroundEverywhereDoesNotDragTheTargetToTheMiddle() throws {
        var frames = quiet(settle + 1)
        // A loud corner over a noisy background: every tile busy, one region far busier.
        var tiles = [Double](repeating: 0.05, count: columns * rows)
        for index in [93, 94, 85, 86] { tiles[index] = 0.9 }
        frames.append(MotionActivity.Change(instant: instant(2.0), columns: columns, rows: rows,
                                            tiles: tiles))
        frames += quiet(40, from: 2.1)

        let frame = try #require(
            MotionActivity.clicks(from: frames, revision: revision).first?.target.frame)
        // **The thresholds are where the two rules differ, and 0.55 was not.** The loud tiles
        // sit at (0.75, 0.92); weighting every tile above the frame's average instead puts the
        // centre near (0.60, 0.66), because ninety-two quiet tiles outweigh four loud ones. A
        // first draft asked for more than 0.55 and both rules cleared it, so the mutation that
        // swapped them left this green.
        let centreX = frame.origin.x + frame.size.width / 2
        let centreY = frame.origin.y + frame.size.height / 2
        #expect(centreX > 0.70, """
            centre x \(centreX) — the loud tiles are at 0.75, and weighting everything above \
            the frame's average pulls the centre left of them
            """)
        #expect(centreY > 0.75, """
            centre y \(centreY) — the loud tiles are at 0.92, and the quiet background pulls \
            the centre up towards the middle
            """)
    }
}
