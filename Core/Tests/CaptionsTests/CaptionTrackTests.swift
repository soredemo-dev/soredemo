import Testing
import Foundation
import Timeline
@testable import Captions

private func ns(_ seconds: Double) -> Nanoseconds {
    Nanoseconds(Int64((seconds * 1000).rounded()) * 1_000_000)
}

private func cue(_ text: String, _ start: Double, _ end: Double,
                 words: [TranscribedWord] = []) -> CaptionCue {
    CaptionCue(text: text, start: ns(start), end: ns(end), words: words)
}

@Suite struct CaptionTrackTests {
    @Test func aTrackIsHeldInStartOrderHoweverItWasBuilt() {
        let track = CaptionTrack(cues: [cue("second", 5, 6), cue("first", 1, 2)])
        #expect(track.cues.map(\.text) == ["first", "second"])
    }

    @Test func theCueAtATimeIsTheOneOnScreenAndTheEndIsExclusive() {
        let track = CaptionTrack(cues: [cue("a", 0, 1), cue("b", 1, 2)])
        #expect(track.cue(at: ns(0.5))?.text == "a")
        // Exactly at the boundary belongs to the SECOND cue: an inclusive end would show two
        // lines on the frame where one replaces the other.
        #expect(track.cue(at: ns(1))?.text == "b")
        #expect(track.cue(at: ns(9)) == nil)
    }

    /// A cut removes 2…4 s. The cue that lived inside it is gone; the one after it moves back.
    @Test func retimingDropsCuesInsideACutAndMovesTheOnesAfterIt() {
        let timeline = EditTimeline.whole(duration: ns(10))
            .removing(sourceRange: ns(2).rawValue..<ns(4).rawValue)
        let track = CaptionTrack(cues: [cue("before", 0, 1),
                                        cue("inside the cut", 2.2, 3.5),
                                        cue("after", 5, 6)])
        let retimed = track.retimed(through: timeline)
        #expect(retimed.cues.map(\.text) == ["before", "after"])
        #expect(retimed.cues[0].start == ns(0))
        // 5 s in the source is 3 s in the output, because 2 s were removed before it.
        #expect(retimed.cues[1].start == ns(3))
        #expect(retimed.cues[1].end == ns(4))
    }

    /// A cue straddling a cut becomes two, rather than being dropped or left whole across a jump.
    @Test func aCueSpanningACutIsSplitAtIt() {
        let timeline = EditTimeline.whole(duration: ns(10))
            .removing(sourceRange: ns(3).rawValue..<ns(5).rawValue)
        let track = CaptionTrack(cues: [cue("one long sentence", 2, 6)])
        let retimed = track.retimed(through: timeline)
        #expect(retimed.cues.count == 2)
        // The first piece keeps its own second; the second piece lands where the cut left it.
        #expect(retimed.cues[0].start == ns(2))
        #expect(retimed.cues[0].end == ns(3))
        #expect(retimed.cues[1].start == ns(3))
        #expect(retimed.cues[1].end == ns(4))
        #expect(retimed.cues.allSatisfy { $0.text == "one long sentence" })
    }

    /// A highlight must not point at a word the cut removed.
    @Test func retimingClipsAWordsSpanToWhatSurvived() {
        let timeline = EditTimeline.whole(duration: ns(10))
            .removing(sourceRange: ns(3).rawValue..<ns(5).rawValue)
        let words = [TranscribedWord(text: "kept", start: ns(2), end: ns(2.5)),
                     TranscribedWord(text: "cut", start: ns(3.2), end: ns(4.5)),
                     TranscribedWord(text: "later", start: ns(5.2), end: ns(5.8))]
        let track = CaptionTrack(cues: [cue("kept cut later", 2, 6, words: words)])
        let retimed = track.retimed(through: timeline)
        #expect(retimed.cues.count == 2)
        #expect(retimed.cues[0].words.map(\.text) == ["kept"])
        #expect(retimed.cues[1].words.map(\.text) == ["later"])
        // Every surviving word sits inside its own cue.
        for line in retimed.cues {
            for word in line.words {
                #expect(word.start.rawValue >= line.start.rawValue)
                #expect(word.end.rawValue <= line.end.rawValue)
            }
        }
    }

    @Test func retimingThroughAnUncutTimelineChangesNothing() {
        let timeline = EditTimeline.whole(duration: ns(10))
        let track = CaptionTrack(cues: [cue("a", 0, 1), cue("b", 4, 5)])
        #expect(track.retimed(through: timeline) == track)
    }

    /// A recogniser gets a name wrong far more often than it gets the timing wrong.
    @Test func correctingACuesTextLeavesItsTimingAlone() {
        let track = CaptionTrack(cues: [cue("sorry demo", 1, 2)])
        let fixed = track.replacingText(at: 0, with: "Soredemo")
        #expect(fixed.cues[0].text == "Soredemo")
        #expect(fixed.cues[0].start == ns(1))
        #expect(fixed.cues[0].end == ns(2))
        // An index nobody has is a no-op, not a crash — rule 8: never trap on an input.
        #expect(track.replacingText(at: 9, with: "x") == track)
        #expect(track.removing(at: 9) == track)
    }

    @Test func removingACueLeavesTheRest() {
        let track = CaptionTrack(cues: [cue("a", 0, 1), cue("b", 1, 2), cue("c", 2, 3)])
        #expect(track.removing(at: 1).cues.map(\.text) == ["a", "c"])
    }

    @Test func anEmptyTrackKnowsItIsEmpty() {
        #expect(CaptionTrack().isEmpty)
        #expect(!CaptionTrack(cues: [cue("a", 0, 1)]).isEmpty)
    }

    @Test func aTrackRoundTripsThroughItsOwnEncoding() throws {
        let track = CaptionTrack(cues: [
            cue("hello", 0, 1, words: [TranscribedWord(text: "hello", start: ns(0), end: ns(0.5))]),
        ])
        let data = try JSONEncoder().encode(track)
        #expect(try JSONDecoder().decode(CaptionTrack.self, from: data) == track)
    }
}

@Suite struct SubtitleFileTests {
    /// Both formats are millisecond-precise, and the only difference between their timestamps is
    /// the separator before the milliseconds.
    @Test func aTimestampIsZeroPaddedToHoursAndMilliseconds() {
        #expect(SubtitleFile.timestamp(ns(0), separator: ",") == "00:00:00,000")
        #expect(SubtitleFile.timestamp(ns(1.5), separator: ",") == "00:00:01,500")
        #expect(SubtitleFile.timestamp(ns(61.25), separator: ".") == "00:01:01.250")
        #expect(SubtitleFile.timestamp(ns(3661.007), separator: ",") == "01:01:01,007")
    }

    /// A track retimed through an edit is exactly the kind of thing that can produce one, and no
    /// player accepts it.
    @Test func aNegativeTimeIsClampedRatherThanWrittenWithAMinusSign() {
        #expect(SubtitleFile.timestamp(Nanoseconds(-5_000_000_000), separator: ",")
                == "00:00:00,000")
    }

    @Test func subRipNumbersItsCuesFromOneAndUsesACommaBeforeTheMilliseconds() {
        let track = CaptionTrack(cues: [cue("first line", 0, 1.5), cue("second line", 2, 3)])
        let text = SubtitleFile.text(for: track, format: .subRip)
        #expect(text.hasPrefix("1\n00:00:00,000 --> 00:00:01,500\nfirst line\n"))
        #expect(text.contains("2\n00:00:02,000 --> 00:00:03,000\nsecond line\n"))
        #expect(!text.contains("0\n00:00:00"))
    }

    /// Browsers reject a WebVTT file without the header outright.
    @Test func webVTTStartsWithItsHeaderAndUsesADotBeforeTheMilliseconds() {
        let track = CaptionTrack(cues: [cue("hello", 0, 1)])
        let text = SubtitleFile.text(for: track, format: .webVTT)
        #expect(text.hasPrefix("WEBVTT\n\n"))
        #expect(text.contains("00:00:00.000 --> 00:00:01.000"))
        #expect(!text.contains(","))
    }

    @Test func anEmptyTrackStillProducesAValidWebVTTFileAndAnEmptySubRipOne() {
        #expect(SubtitleFile.text(for: CaptionTrack(), format: .webVTT) == "WEBVTT\n\n")
        #expect(SubtitleFile.text(for: CaptionTrack(), format: .subRip).isEmpty)
    }

    @Test func bothFormatsNameTheirOwnExtensionAndSayWhatTheyAre() {
        for format in SubtitleFile.Format.allCases {
            #expect(!format.fileExtension.isEmpty)
            #expect(format.displayName.contains(format.fileExtension))
        }
    }
}
