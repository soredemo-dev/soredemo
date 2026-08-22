import Foundation
import Testing
@testable import Timeline

private func ns(_ value: Int64) -> Nanoseconds { Nanoseconds(value) }

/// **Two clocks, and confusing them is this project's recurring fault.** With no edits, SOURCE
/// and OUTPUT time are equal — which is exactly why a bug here stays invisible until the first
/// cut. Every test below therefore edits.
@Suite struct EditTimelineTests {
    private let tenSeconds = ns(10_000_000_000)

    @Test func anUneditedTimelineMapsBothWaysIdentically() {
        let timeline = EditTimeline.whole(duration: tenSeconds)
        #expect(timeline.outputDuration == tenSeconds)
        for probe: Int64 in [0, 1, 4_000_000_000, 9_999_999_999] {
            #expect(timeline.sourceTime(atOutput: ns(probe)) == ns(probe))
            #expect(timeline.outputTime(atSource: ns(probe)) == ns(probe))
        }
    }

    /// Past the end is `nil`, never the last frame. A caller asking about a time that does not
    /// exist has a bug, and clamping lets it run undetected.
    @Test func aTimePastTheEndHasNoAnswer() {
        let timeline = EditTimeline.whole(duration: tenSeconds)
        #expect(timeline.sourceTime(atOutput: tenSeconds) == nil)
        #expect(timeline.sourceTime(atOutput: ns(-1)) == nil)
        #expect(timeline.outputTime(atSource: tenSeconds) == nil)
    }

    // MARK: - cut

    /// The whole point of the type: after a cut, output time and source time diverge.
    @Test func aCutMakesOutputAndSourceTimeDisagree() {
        // Remove 2s–5s from a 10s recording. 7s survive.
        let timeline = EditTimeline.whole(duration: tenSeconds)
            .removing(sourceRange: 2_000_000_000..<5_000_000_000)

        #expect(timeline.clips.count == 2)
        #expect(timeline.outputDuration == ns(7_000_000_000))

        // Before the cut the two clocks still agree…
        #expect(timeline.sourceTime(atOutput: ns(1_000_000_000)) == ns(1_000_000_000))
        // …and after it they are three seconds apart.
        #expect(timeline.sourceTime(atOutput: ns(2_000_000_000)) == ns(5_000_000_000))
        #expect(timeline.sourceTime(atOutput: ns(6_999_999_999)) == ns(9_999_999_999))
        #expect(timeline.sourceTime(atOutput: ns(7_000_000_000)) == nil)
    }

    /// **`nil` means CUT, and it is a different answer from zero.** A caller that drew the
    /// pointer at output 0 for every removed sample would pile the whole cut span onto the
    /// first frame.
    @Test func aSourceTimeInsideTheCutHasNoOutputTime() {
        let timeline = EditTimeline.whole(duration: tenSeconds)
            .removing(sourceRange: 2_000_000_000..<5_000_000_000)
        #expect(timeline.outputTime(atSource: ns(2_000_000_000)) == nil)
        #expect(timeline.outputTime(atSource: ns(4_999_999_999)) == nil)
        // The boundaries either side survive, and land where the cut put them.
        #expect(timeline.outputTime(atSource: ns(1_999_999_999)) == ns(1_999_999_999))
        #expect(timeline.outputTime(atSource: ns(5_000_000_000)) == ns(2_000_000_000))
    }

    /// The two directions must be inverses wherever both are defined. Asserted over the whole
    /// surviving range rather than at chosen points, because an off-by-one in one direction
    /// and not the other is exactly what a handful of samples misses.
    @Test func theTwoDirectionsAreInverses() {
        let timeline = EditTimeline.whole(duration: ns(1_000))
            .removing(sourceRange: 200..<500)
            .removing(sourceRange: 800..<900)
        for output in 0..<timeline.outputDuration.rawValue {
            let source = timeline.sourceTime(atOutput: ns(output))
            let back = source.flatMap { timeline.outputTime(atSource: $0) }
            #expect(back == ns(output), "output \(output) round-tripped to \(String(describing: back))")
        }
    }

    @Test func aCutAtTheStartAndAtTheEndBothWork() {
        let whole = EditTimeline.whole(duration: tenSeconds)
        let headless = whole.removing(sourceRange: 0..<3_000_000_000)
        #expect(headless.clips.count == 1)
        #expect(headless.sourceTime(atOutput: ns(0)) == ns(3_000_000_000))

        let tailless = whole.removing(sourceRange: 7_000_000_000..<10_000_000_000)
        #expect(tailless.outputDuration == ns(7_000_000_000))
        #expect(tailless.sourceTime(atOutput: ns(6_999_999_999)) == ns(6_999_999_999))
    }

    @Test func cuttingEverythingLeavesAnEmptyTimeline() {
        let timeline = EditTimeline.whole(duration: tenSeconds)
            .removing(sourceRange: 0..<10_000_000_000)
        #expect(timeline.isEmpty)
        #expect(timeline.outputDuration == ns(0))
        #expect(timeline.sourceTime(atOutput: ns(0)) == nil)
    }

    @Test func anEmptyCutChangesNothing() {
        let timeline = EditTimeline.whole(duration: tenSeconds)
        #expect(timeline.removing(sourceRange: 500..<500) == timeline)
    }

    /// A cut outside every clip removes nothing — and must not, for example, drop the clip it
    /// failed to overlap.
    @Test func aCutThatOverlapsNothingKeepsEveryClip() {
        let timeline = EditTimeline.whole(duration: ns(1_000)).removing(sourceRange: 400..<600)
        #expect(timeline.removing(sourceRange: 450..<550) == timeline)
    }

    // MARK: - trim

    @Test func aTrimShortensRatherThanSplits() {
        let timeline = EditTimeline.whole(duration: tenSeconds)
            .trimmed(toSource: 2_000_000_000..<8_000_000_000)
        #expect(timeline.clips.count == 1)
        #expect(timeline.outputDuration == ns(6_000_000_000))
        #expect(timeline.sourceTime(atOutput: ns(0)) == ns(2_000_000_000))
    }

    /// A trim applied to an already-cut timeline keeps only the parts inside it, and the
    /// clips it keeps stay in output order.
    @Test func aTrimComposesWithACut() {
        let timeline = EditTimeline.whole(duration: ns(1_000))
            .removing(sourceRange: 300..<400)
            .trimmed(toSource: 200..<600)
        #expect(timeline.clips.map(\.sourceStart.rawValue) == [200, 400])
        #expect(timeline.outputDuration == ns(300))
    }

    // MARK: - merge

    /// **Adjacent survivors are not merged by `removing`, deliberately.** Joining them would
    /// erase the record of a cut having been made there, which a reviewer reading the timeline
    /// needs. `merged()` is for a caller — an exporter — that genuinely wants one read.
    @Test func removingKeepsTheSeamAndMergedRemovesIt() {
        // Two cuts that leave abutting source ranges: 0–300 and 300–1000 after removing nothing
        // between them.
        let split = EditTimeline(clips: [
            EditClip(sourceStart: ns(0), duration: ns(300)),
            EditClip(sourceStart: ns(300), duration: ns(700)),
        ])
        #expect(split.clips.count == 2)
        #expect(split.merged().clips.count == 1)
        #expect(split.merged().outputDuration == split.outputDuration)
    }

    /// Merging must not join clips that only LOOK adjacent in the output. Two clips either
    /// side of a cut abut in output time and are far apart in the source.
    @Test func mergingDoesNotJoinAcrossACut() {
        let timeline = EditTimeline.whole(duration: ns(1_000)).removing(sourceRange: 200..<500)
        #expect(timeline.merged().clips.count == 2,
                "the two survivors abut in OUTPUT time but not in the source")
    }

    // MARK: - decoding

    /// D6 rule 8: the synthesised decoder bypasses the initialiser, so a corrupt project file
    /// has to be rejected explicitly rather than trapping.
    @Test func aClipWithNoDurationIsADecodingErrorAndNotACrash() {
        let json = Data(#"{"sourceStart":{"rawValue":0},"duration":{"rawValue":0}}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EditClip.self, from: json)
        }
    }

    @Test func anEditedTimelineSurvivesCoding() throws {
        let timeline = EditTimeline.whole(duration: tenSeconds)
            .removing(sourceRange: 2_000_000_000..<5_000_000_000)
        let data = try JSONEncoder().encode(timeline)
        #expect(try JSONDecoder().decode(EditTimeline.self, from: data) == timeline)
    }
}
