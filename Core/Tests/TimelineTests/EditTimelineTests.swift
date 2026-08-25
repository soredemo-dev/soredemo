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
            EditClip(id: ClipID(rawValue: 0), sourceStart: ns(0), duration: ns(300)),
            EditClip(id: ClipID(rawValue: 1), sourceStart: ns(300), duration: ns(700)),
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

    // MARK: - what a surface outside the timeline can still address

    /// **Three states rather than a `Bool`, and a half-cut span is why.** A transcript row that
    /// called a partly-cut sentence "removed" would disable the one control that could finish
    /// removing it; one that called it "present" would offer to delete footage already gone.
    @Test func aSpanReportsWhetherAllSomeOrNoneOfItSurvives() {
        let timeline = EditTimeline.whole(duration: tenSeconds)
        #expect(timeline.survival(ofSource: 2_000_000_000..<3_000_000_000) == .whole)

        // A cut through the middle of the span.
        let holed = timeline.removing(sourceRange: 2_400_000_000..<2_600_000_000)
        #expect(holed.survival(ofSource: 2_000_000_000..<3_000_000_000) == .partly)
        // …and the cut span itself is gone.
        #expect(holed.survival(ofSource: 2_400_000_000..<2_600_000_000) == .gone)
        // …while a span nowhere near it is untouched.
        #expect(holed.survival(ofSource: 5_000_000_000..<6_000_000_000) == .whole)
    }

    /// A cut that takes a span's leading edge but not its tail is `partly` from either side —
    /// the arithmetic must not depend on which end the survivor is at.
    @Test func aSpanCutFromEitherEndIsPartlyGone() {
        let timeline = EditTimeline.whole(duration: tenSeconds)
        let span: Range<Int64> = 4_000_000_000..<5_000_000_000
        #expect(timeline.removing(sourceRange: 3_500_000_000..<4_500_000_000)
                    .survival(ofSource: span) == .partly)
        #expect(timeline.removing(sourceRange: 4_500_000_000..<5_500_000_000)
                    .survival(ofSource: span) == .partly)
    }

    /// **Two clips CAN cover the same source range** — nothing in this type forbids it — and an
    /// uncapped sum of what survives would report a span that survives twice over as `partly`,
    /// which is the opposite of true.
    @Test func aSpanCoveredTwiceIsWholeAndNotPartly() {
        let span = ns(1_000_000_000)
        let doubled = EditTimeline(clips: [
            EditClip(id: ClipID(rawValue: 0), sourceStart: ns(0), duration: span),
            EditClip(id: ClipID(rawValue: 1), sourceStart: ns(0), duration: span),
        ])
        #expect(doubled.survival(ofSource: 0..<1_000_000_000) == .whole)
    }

    /// An empty range names nothing, so nothing of it survives. Returning `whole` for it would
    /// let a caller offer to delete a sentence with no duration.
    @Test func anEmptyRangeSurvivesNothing() {
        let timeline = EditTimeline.whole(duration: tenSeconds)
        #expect(timeline.survival(ofSource: 3_000_000_000..<3_000_000_000) == .gone)
    }
}

// MARK: - clips as objects

/// **A clip a person can point at has to survive edits to other clips.** Selection keyed on an
/// array index silently becomes a different clip the moment an earlier one is deleted; every
/// editor in `../opensource/Screen Record Opensource/` keys it on an identity instead.
@Suite struct ClipIdentityTests {
    private func whole(_ length: Int64) -> EditTimeline {
        EditTimeline.whole(duration: ns(length))
    }

    @Test func aClipCanBeFoundByTheOutputTimeAPersonClicked() {
        let timeline = whole(1_000).removing(sourceRange: 200..<500)
        // Output 0…200 is the first clip, 200…700 the second.
        #expect(timeline.clip(atOutput: ns(0))?.id == timeline.clips[0].id)
        #expect(timeline.clip(atOutput: ns(199))?.id == timeline.clips[0].id)
        #expect(timeline.clip(atOutput: ns(200))?.id == timeline.clips[1].id)
        #expect(timeline.clip(atOutput: ns(699))?.id == timeline.clips[1].id)
        #expect(timeline.clip(atOutput: ns(700)) == nil, "past the end there is no clip")
    }

    @Test func aClipsOutputStartIsTheSumOfWhatComesBefore() {
        let timeline = whole(1_000).removing(sourceRange: 200..<500)
        #expect(timeline.outputStart(of: timeline.clips[0].id) == ns(0))
        #expect(timeline.outputStart(of: timeline.clips[1].id) == ns(200))
        #expect(timeline.outputStart(of: ClipID(rawValue: 9_999)) == nil)
    }

    /// **The ripple is free, and that is a property of the model.** A clip's output position is
    /// the sum of the durations before it and never a stored value, so removing one cannot
    /// leave a gap. a native editor needs a `RippleEngine` because its clips carry `startFrame`.
    @Test func removingAClipPullsTheRestEarlierWithNoGap() {
        let timeline = whole(1_000).removing(sourceRange: 200..<500)
        let second = timeline.clips[1].id
        let after = timeline.removing(id: second)

        #expect(after.clips.count == 1)
        #expect(after.outputDuration == ns(200))
        #expect(after.sourceTime(atOutput: ns(0)) == ns(0))
        #expect(after.sourceTime(atOutput: ns(200)) == nil)
    }

    /// **Deleting an earlier clip must not move what a selection points at.** The whole reason
    /// for identity, stated as the case that would break with indices.
    @Test func deletingAnEarlierClipLeavesALaterOnesIdentityAlone() {
        let timeline = whole(1_000).removing(sourceRange: 200..<500)
        let selected = timeline.clips[1].id
        let after = timeline.removing(id: timeline.clips[0].id)

        #expect(after.clips.first?.id == selected,
                "the surviving clip changed identity — a selection would now point elsewhere")
        // …and by index it WOULD have: what was index 1 is index 0.
        #expect(after.clips.count == 1)
    }

    // MARK: - split

    /// A split changes nothing about the output: both halves play back to back. It is
    /// preparation for an edit, not an edit.
    @Test func aSplitLeavesTheOutputIdentical() {
        let timeline = whole(1_000)
        // `split(atOutput:)` returns a non-optional here, so a `#require` is redundant.
        let split = timeline.split(atOutput: ns(400))
        #expect(split?.clips.count == 2)
        #expect(split?.outputDuration == timeline.outputDuration)
        for probe: Int64 in [0, 399, 400, 999] {
            #expect(split?.sourceTime(atOutput: ns(probe)) == timeline.sourceTime(atOutput: ns(probe)),
                    "the split moved output \(probe)")
        }
    }

    /// The LEFT half keeps the id: a split is the selected clip becoming shorter with a new
    /// one after it, not a replacement of it.
    @Test func theLeftHalfOfASplitKeepsTheIdentity() throws {
        let timeline = whole(1_000)
        let original = timeline.clips[0].id
        let split = try #require(timeline.split(atOutput: ns(400)))
        #expect(split.clips[0].id == original)
        #expect(split.clips[1].id != original, "both halves took the same identity")
    }

    /// A cut on a boundary would make a zero-length piece. `nil` so the caller can tell a
    /// no-op from a split, rather than the model producing a clip with no duration.
    @Test func aSplitOnABoundaryIsRefused() {
        let timeline = whole(1_000)
        #expect(timeline.split(atOutput: ns(0)) == nil)
        #expect(timeline.split(atOutput: ns(1_000)) == nil)
        #expect(timeline.split(atOutput: ns(2_000)) == nil)
    }

    /// Splitting twice must not mint the same id twice — an id that came back would make a
    /// stale selection attach to a different clip, the fault identity exists to prevent.
    @Test func repeatedSplitsNeverReuseAnIdentity() throws {
        var timeline = whole(1_000)
        for cut: Int64 in [200, 400, 600, 800] {
            timeline = try #require(timeline.split(atOutput: ns(cut)))
        }
        let ids = timeline.clips.map(\.id)
        #expect(ids.count == 5)
        #expect(Set(ids).count == ids.count, "a split reused an identity: \(ids)")
    }

    // MARK: - trim and move

    @Test func trimmingAClipsFrontShortensItAndKeepsItsIdentity() throws {
        let timeline = whole(1_000)
        let id = timeline.clips[0].id
        let trimmed = try #require(timeline.trimming(id: id, startDelta: 100, endDelta: 0))
        #expect(trimmed.clips[0].id == id)
        #expect(trimmed.clips[0].sourceStart == ns(100))
        #expect(trimmed.outputDuration == ns(900))
    }

    /// A trim past the clip's own length is a gesture that has gone too far. `nil`, so the
    /// caller stops the handle rather than the model inventing a floor.
    @Test func aTrimThatWouldEmptyAClipIsRefused() {
        let timeline = whole(1_000)
        let id = timeline.clips[0].id
        #expect(timeline.trimming(id: id, startDelta: 1_000, endDelta: 0) == nil)
        #expect(timeline.trimming(id: id, startDelta: 0, endDelta: -1_000) == nil)
        // …and one that would start before the recording.
        #expect(timeline.trimming(id: id, startDelta: -1, endDelta: 0) == nil)
    }

    @Test func movingAClipChangesTheOrderAndNothingElse() throws {
        let timeline = whole(1_000).removing(sourceRange: 400..<600)
        let first = timeline.clips[0]
        let moved = try #require(timeline.moving(id: first.id, to: 1))

        #expect(moved.clips.map(\.id) == [timeline.clips[1].id, first.id])
        #expect(moved.outputDuration == timeline.outputDuration,
                "moving a clip changed how long the video is")
        // The moved clip now plays second, so the output reads the other span first.
        #expect(moved.sourceTime(atOutput: ns(0)) == ns(600))
    }

    /// `destination` indexes the timeline WITHOUT the moved clip, which is the only reading
    /// that makes "move it to the end" expressible.
    @Test func aClipCanBeMovedToTheEnd() throws {
        let timeline = whole(900).removing(sourceRange: 300..<400).removing(sourceRange: 600..<700)
        #expect(timeline.clips.count == 3)
        let first = timeline.clips[0].id
        let moved = try #require(timeline.moving(id: first, to: 2))
        #expect(moved.clips.last?.id == first)
        #expect(moved.moving(id: first, to: 3) == nil, "past the end is not a position")
    }

    @Test func movingAClipThatIsNotThereIsRefused() {
        #expect(whole(1_000).moving(id: ClipID(rawValue: 9_999), to: 0) == nil)
        #expect(whole(1_000).trimming(id: ClipID(rawValue: 9_999), startDelta: 1, endDelta: 0) == nil)
    }

    // MARK: - identity through the range edits

    /// A cut off the FRONT of a clip shortens it — there is no head to have taken the id — so
    /// the survivor keeps it.
    @Test func aCutOffTheFrontKeepsTheClipsIdentity() {
        let timeline = whole(1_000)
        let id = timeline.clips[0].id
        #expect(timeline.removing(sourceRange: 0..<200).clips[0].id == id)
    }

    /// A cut through the MIDDLE leaves the head with the id and the tail as a new clip.
    @Test func aCutThroughTheMiddleGivesTheHeadTheIdentity() {
        let timeline = whole(1_000)
        let id = timeline.clips[0].id
        let cut = timeline.removing(sourceRange: 400..<600)
        #expect(cut.clips.count == 2)
        #expect(cut.clips[0].id == id)
        #expect(cut.clips[1].id != id)
        #expect(Set(cut.clips.map(\.id)).count == 2)
    }

    /// Two cuts must not collide. `nextID` is carried through every edit precisely so the
    /// second cut mints past whatever the first one used.
    @Test func twoSuccessiveCutsMintDistinctIdentities() {
        let cut = whole(1_000).removing(sourceRange: 200..<300).removing(sourceRange: 600..<700)
        let ids = cut.clips.map(\.id)
        #expect(ids.count == 3)
        #expect(Set(ids).count == 3, "a second cut reused an identity: \(ids)")
    }

    /// A hand-built timeline cannot mint a duplicate: `nextID` is derived from the clips when
    /// it is not given. Every test fixture in this file relies on that.
    @Test func aHandBuiltTimelineDerivesItsNextIdentity() {
        let timeline = EditTimeline(clips: [
            EditClip(id: ClipID(rawValue: 7), sourceStart: ns(0), duration: ns(100)),
            EditClip(id: ClipID(rawValue: 3), sourceStart: ns(100), duration: ns(100)),
        ])
        #expect(timeline.nextID == ClipID(rawValue: 8))
        let split = timeline.split(atOutput: ns(50))
        #expect(split?.clips.map(\.id).contains(ClipID(rawValue: 8)) == true)
    }

    @Test func identitiesSurviveCoding() throws {
        let timeline = whole(1_000).removing(sourceRange: 200..<500)
        let data = try JSONEncoder().encode(timeline)
        let decoded = try JSONDecoder().decode(EditTimeline.self, from: data)
        #expect(decoded.clips.map(\.id) == timeline.clips.map(\.id))
        #expect(decoded.nextID == timeline.nextID)
    }

    @Test func aNegativeClipIdentityIsADecodingErrorAndNotACrash() {
        let json = Data(#"{"id":-1,"sourceStart":{"rawValue":0},"duration":{"rawValue":1}}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EditClip.self, from: json)
        }
    }
}

/// A clip that plays at a rate other than the recording's.
@Suite struct ClipSpeedTests {
    private func ns(_ seconds: Double) -> Nanoseconds {
        Nanoseconds(Int64(seconds * 1_000_000_000))
    }

    /// **Source duration and output duration stop being the same number.** That is the whole
    /// cost of the feature, and every conversion below is a consequence of it.
    @Test func aClipAtDoubleSpeedPlaysInHalfTheTime() {
        let clip = EditClip(id: ClipID(rawValue: 0), sourceStart: ns(0), duration: ns(10),
                            speed: 2)
        #expect(clip.duration == ns(10))
        #expect(clip.outputDuration == ns(5))
        #expect(clip.playing(at: 0.5).outputDuration == ns(20))
    }

    /// Bounded at a quarter and four: below a quarter the recording has no more frames to give,
    /// and above four the pointer moves faster than a viewer can follow.
    @Test func speedIsClampedRatherThanTrappedOn() {
        let clip = EditClip(id: ClipID(rawValue: 0), sourceStart: ns(0), duration: ns(1))
        #expect(clip.playing(at: 99).speed == 4)
        #expect(clip.playing(at: 0).speed == 0.25)
        #expect(clip.playing(at: .nan).speed == 1)
    }

    /// The timeline's own length is the sum of what PLAYS.
    @Test func theTimelinesLengthIsTheSumOfWhatPlays() {
        let timeline = EditTimeline(clips: [
            EditClip(id: ClipID(rawValue: 0), sourceStart: ns(0), duration: ns(10), speed: 2),
            EditClip(id: ClipID(rawValue: 1), sourceStart: ns(10), duration: ns(10)),
        ])
        #expect(timeline.outputDuration == ns(15))
        #expect(timeline.outputStarts == [ns(0), ns(5)])
    }

    /// **The mapping both ways, which is what the pointer, the camera and the captions all use.**
    /// Four seconds into a 2× clip is eight seconds into the recording.
    @Test func theMappingScalesInBothDirections() {
        let timeline = EditTimeline(clips: [
            EditClip(id: ClipID(rawValue: 0), sourceStart: ns(0), duration: ns(10), speed: 2),
        ])
        #expect(timeline.sourceTime(atOutput: ns(4)) == ns(8))
        #expect(timeline.outputTime(atSource: ns(8)) == ns(4))
        // Past the end of what plays is still nil, not the last frame.
        #expect(timeline.sourceTime(atOutput: ns(6)) == nil)
    }

    /// A cut lands in OUTPUT time, so the offset has to be converted back before it becomes a
    /// source duration — otherwise the split is at the wrong frame on every clip whose speed
    /// is not 1.
    @Test func aSplitOnAFastClipCutsAtTheFrameItLooksLike() throws {
        let timeline = EditTimeline(clips: [
            EditClip(id: ClipID(rawValue: 0), sourceStart: ns(0), duration: ns(10), speed: 2),
        ])
        let split = try #require(timeline.split(atOutput: ns(2)))
        #expect(split.clips.count == 2)
        // Two seconds of playback is four seconds of recording.
        #expect(split.clips[0].duration == ns(4))
        #expect(split.clips[1].sourceStart == ns(4))
        // Both halves keep the speed; a split is not a change of pace.
        #expect(split.clips.allSatisfy { $0.speed == 2 })
        #expect(split.outputDuration == timeline.outputDuration)
    }

    /// **Adjacent clips at different speeds are not merged.** Two spans played at different
    /// rates are two clips however contiguous their source is, and merging would silently give
    /// the whole run one of the two speeds.
    @Test func mergingLeavesClipsAtDifferentSpeedsAlone() {
        let timeline = EditTimeline(clips: [
            EditClip(id: ClipID(rawValue: 0), sourceStart: ns(0), duration: ns(5), speed: 2),
            EditClip(id: ClipID(rawValue: 1), sourceStart: ns(5), duration: ns(5)),
        ])
        #expect(timeline.merged().clips.count == 2)

        let sameSpeed = EditTimeline(clips: [
            EditClip(id: ClipID(rawValue: 0), sourceStart: ns(0), duration: ns(5), speed: 2),
            EditClip(id: ClipID(rawValue: 1), sourceStart: ns(5), duration: ns(5), speed: 2),
        ])
        #expect(sameSpeed.merged().clips.count == 1)
        #expect(sameSpeed.merged().clips[0].speed == 2)
    }

    /// A project written before speeds existed opens with its clips at the recording's own pace
    /// — which is what they did when it was saved.
    @Test func aClipWithNoSpeedKeyDecodesAtNormalPace() throws {
        let older = Data(#"{"id":0,"sourceStart":{"rawValue":0},"duration":{"rawValue":1000}}"#.utf8)
        let clip = try JSONDecoder().decode(EditClip.self, from: older)
        #expect(clip.speed == 1)
        #expect(clip.outputDuration == clip.duration)
    }

    @Test func aClipRoundTripsWithItsSpeed() throws {
        let clip = EditClip(id: ClipID(rawValue: 3), sourceStart: ns(1), duration: ns(2),
                            speed: 1.5)
        let data = try JSONEncoder().encode(clip)
        #expect(try JSONDecoder().decode(EditClip.self, from: data) == clip)
    }

    /// A trim keeps the speed, for `spanning`'s reason: a trim is an edit to a clip rather than
    /// a replacement of it.
    @Test func trimmingKeepsTheSpeed() throws {
        let timeline = EditTimeline(clips: [
            EditClip(id: ClipID(rawValue: 0), sourceStart: ns(0), duration: ns(10), speed: 2),
        ])
        let trimmed = try #require(timeline.trimming(id: ClipID(rawValue: 0),
                                                     startDelta: 0,
                                                     endDelta: -1_000_000_000))
        #expect(trimmed.clips[0].speed == 2)
    }
}
