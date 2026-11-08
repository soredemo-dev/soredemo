import Testing
import Foundation
import Timeline
@testable import Overlays

@Suite struct SilenceFinderTests {
    /// A slice every 100 ms, so the numbers in these fixtures read as tenths of a second.
    private let slice = 0.1

    private func peaks(_ pattern: String) -> [Float] {
        // `.` is silence, `x` is sound — one character per slice, which makes a fixture a
        // picture of the recording rather than an array to count through.
        pattern.map { $0 == "x" ? 1.0 : 0.0 }
    }

    @Test func aQuietStretchLongerThanTheMinimumIsFound() {
        // 10 slices of sound, 12 of silence, 10 of sound: a 1.2 s gap.
        let found = SilenceFinder.spans(
            peaks: peaks("xxxxxxxxxx............xxxxxxxxxx"), sliceSeconds: slice,
            settings: SilenceFinder.Settings(threshold: 0.04, minimumSeconds: 0.7,
                                             paddingSeconds: 0))
        #expect(found.count == 1)
        #expect(found[0].start == Nanoseconds(1_000_000_000))
        #expect(found[0].end == Nanoseconds(2_200_000_000))
    }

    /// **A pause under the minimum is speech**, not dead air — the gap between two words, the
    /// breath before a sentence. Removing it makes narration sound spliced.
    @Test func aShortPauseIsLeftAlone() {
        #expect(SilenceFinder.spans(peaks: peaks("xxxx....xxxx"), sliceSeconds: slice).isEmpty)
    }

    /// **Padding shrinks a span from both ends and can erase it**, which is right: a stretch
    /// only just over the minimum, once a tenth is given back at each end, is not worth cutting.
    @Test func paddingCanEraseASpanThatOnlyJustQualified() {
        let pattern = peaks("xxxx........xxxx")   // 0.8 s of silence
        let unpadded = SilenceFinder.spans(
            peaks: pattern, sliceSeconds: slice,
            settings: SilenceFinder.Settings(threshold: 0.04, minimumSeconds: 0.7,
                                             paddingSeconds: 0))
        #expect(unpadded.count == 1)

        let padded = SilenceFinder.spans(
            peaks: pattern, sliceSeconds: slice,
            settings: SilenceFinder.Settings(threshold: 0.04, minimumSeconds: 0.7,
                                             paddingSeconds: 0.45))
        #expect(padded.isEmpty)
    }

    /// **The commonest silence there is**: a person stops talking before they stop recording, so
    /// the run at the end is never closed by a loud slice.
    @Test func silenceAtTheEndIsFound() {
        let found = SilenceFinder.spans(
            peaks: peaks("xxxx............"), sliceSeconds: slice,
            settings: SilenceFinder.Settings(threshold: 0.04, minimumSeconds: 0.7,
                                             paddingSeconds: 0))
        #expect(found.count == 1)
        #expect(found[0].start == Nanoseconds(400_000_000))
    }

    /// A room has a noise floor and a microphone has a hiss, so the threshold is not zero — and
    /// a recording whose quiet parts sit just under it must still be found.
    @Test func theThresholdIsALevelRatherThanExactSilence() {
        let hiss = [Float](repeating: 0.02, count: 20)
        let found = SilenceFinder.spans(peaks: hiss, sliceSeconds: slice)
        #expect(found.count == 1)
        // The same recording with a threshold below the hiss finds nothing, which is what makes
        // the setting a setting.
        let strict = SilenceFinder.Settings(threshold: 0.01, minimumSeconds: 0.7,
                                            paddingSeconds: 0)
        #expect(SilenceFinder.spans(peaks: hiss, sliceSeconds: slice, settings: strict).isEmpty)
    }

    @Test func settingsAreClampedRatherThanTrappedOn() {
        let wild = SilenceFinder.Settings(threshold: 9, minimumSeconds: 0, paddingSeconds: -4)
        #expect(wild.threshold <= 0.5)
        #expect(wild.minimumSeconds >= 0.2)
        #expect(wild.paddingSeconds == 0)
    }

    @Test func anEmptyRecordingFindsNothing() {
        #expect(SilenceFinder.spans(peaks: [], sliceSeconds: slice).isEmpty)
        #expect(SilenceFinder.spans(peaks: peaks("xxxx"), sliceSeconds: 0).isEmpty)
    }

    /// Every span removed, and the timeline shortened by exactly their total.
    @Test func removingEverySpanShortensTheTimelineByTheirTotal() {
        let whole = EditTimeline.whole(duration: Nanoseconds(10_000_000_000))
        let spans = [
            SilenceFinder.Span(start: Nanoseconds(1_000_000_000),
                               end: Nanoseconds(2_000_000_000)),
            SilenceFinder.Span(start: Nanoseconds(5_000_000_000),
                               end: Nanoseconds(7_000_000_000)),
        ]
        let cut = SilenceFinder.removing(spans, from: whole)
        #expect(SilenceFinder.total(spans) == Nanoseconds(3_000_000_000))
        #expect(cut.outputDuration == Nanoseconds(7_000_000_000))
        #expect(cut.clips.count == 3)
    }

    /// **Removed back to front**, so the earlier clips keep the identities they had — a person's
    /// selection survives the operation. Front to back would renumber everything after each cut.
    @Test func removingLeavesTheEarliestClipsIdentityAlone() {
        let whole = EditTimeline.whole(duration: Nanoseconds(10_000_000_000))
        let firstID = whole.clips[0].id
        let cut = SilenceFinder.removing([
            SilenceFinder.Span(start: Nanoseconds(2_000_000_000),
                               end: Nanoseconds(3_000_000_000)),
            SilenceFinder.Span(start: Nanoseconds(6_000_000_000),
                               end: Nanoseconds(7_000_000_000)),
        ], from: whole)
        #expect(cut.clips.first?.id == firstID)
    }

    @Test func aSpanWithNoLengthRemovesNothing() {
        let whole = EditTimeline.whole(duration: Nanoseconds(5_000_000_000))
        let empty = SilenceFinder.Span(start: Nanoseconds(1_000_000_000),
                                       end: Nanoseconds(1_000_000_000))
        #expect(SilenceFinder.removing([empty], from: whole) == whole)
    }

    // MARK: - what could be heard

    private func span(_ from: Int64, _ to: Int64) -> SilenceFinder.Span {
        SilenceFinder.Span(start: Nanoseconds(from * 1_000_000_000), end: Nanoseconds(to * 1_000_000_000))
    }

    private func seconds(_ from: Int64, _ to: Int64) -> Range<Int64> {
        (from * 1_000_000_000)..<(to * 1_000_000_000)
    }

    @Test func soundIsTheRecordingOutsideEverySilence() {
        let sounding = SilenceFinder.sounding(outside: [span(6, 10), span(2, 4)],
                                              duration: Nanoseconds(10 * 1_000_000_000))
        #expect(sounding == [seconds(0, 2), seconds(4, 6)], "unsorted in, in time order out; silent to the end")
    }

    @Test func aRecordingWithNoSilenceSoundsThroughout() {
        #expect(SilenceFinder.sounding(outside: [], duration: Nanoseconds(10 * 1_000_000_000)) == [seconds(0, 10)])
    }

    @Test func overlappingSilencesLeaveNoSliverOfSoundBetweenThem() {
        // 2–3 sits inside 1–5 and 4–7 begins inside it too: a cursor moved BACK by the nested
        // one would find "sound" from 3 to 4.
        let sounding = SilenceFinder.sounding(outside: [span(1, 5), span(2, 3), span(4, 7)],
                                              duration: Nanoseconds(10 * 1_000_000_000))
        #expect(sounding == [seconds(0, 1), seconds(7, 10)])
    }

    @Test func aSilenceBeginningAfterTheEndAddsNoSoundPastIt() {
        let sounding = SilenceFinder.sounding(outside: [span(12, 15)], duration: Nanoseconds(10 * 1_000_000_000))
        #expect(sounding == [seconds(0, 10)])
    }

    @Test func aSilenceRunningPastTheEndIsClampedToIt() {
        let sounding = SilenceFinder.sounding(outside: [span(8, 30)], duration: Nanoseconds(10 * 1_000_000_000))
        #expect(sounding == [seconds(0, 8)])
    }
}
