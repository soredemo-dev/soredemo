import Foundation
import Testing
import Timeline
@testable import Overlays

private func ns(_ seconds: Double) -> Nanoseconds { Nanoseconds(Int64(seconds * 1_000_000_000)) }

// MARK: - reading a sidecar back

/// **The round trip is the point.** A writer with no reader is a one-way door, and the way to
/// know a reader works is that what this project wrote comes back as what it wrote.
@Test func whatThisProjectWritesItCanReadBack() throws {
    let original = CaptionTrack(cues: [
        CaptionCue(text: "Welcome to this walkthrough.", start: ns(0), end: ns(1.5)),
        CaptionCue(text: "Today I'll show you", start: ns(1.56), end: ns(2.58)),
        CaptionCue(text: "how to record your screen.", start: ns(2.58), end: ns(3.96)),
    ])
    for format in SubtitleFile.Format.allCases {
        let reading = try SubtitleFile.read(SubtitleFile.text(for: original, format: format))
        #expect(reading.format == format, "the format was detected as \(reading.format)")
        #expect(reading.refused.isEmpty)
        #expect(reading.overlapsTrimmed == 0)
        #expect(reading.track.cues.map(\.text) == original.cues.map(\.text))
        // Millisecond precision both ways: the writer rounds to milliseconds, so the reader
        // must land on the same millisecond rather than near it.
        for (read, wrote) in zip(reading.track.cues, original.cues) {
            #expect(read.start == wrote.start && read.end == wrote.end,
                    "\(format) moved a cue: \(read.start) – \(read.end)")
        }
    }
}

/// The format is read from the CONTENT, because a file that has been through a converter or a
/// rename is exactly the file somebody is importing.
@Test func theFormatComesFromTheFileRatherThanItsName() throws {
    let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhello\n"
    #expect(try SubtitleFile.read(vtt).format == .webVTT)
    let srt = "1\n00:00:01,000 --> 00:00:02,000\nhello\n"
    #expect(try SubtitleFile.read(srt).format == .subRip)

    // And a WebVTT file carrying SubRip commas — what a converter writes — still reads.
    let mixed = "WEBVTT\n\n00:00:01,000 --> 00:00:02,000\nhello\n"
    #expect(try SubtitleFile.read(mixed).track.cues.first?.start == ns(1))
}

/// What real files carry: a byte-order mark, CRLF, a NOTE block, a cue identifier on its own
/// line, cue settings after the timestamps, and several lines of text.
@Test func theShapesRealFilesArriveInAreAccepted() throws {
    let messy = "\u{FEFF}WEBVTT\r\n\r\n"
        + "NOTE this file came from somewhere else\r\n\r\n"
        + "intro-1\r\n"
        + "00:00:01.000 --> 00:00:03.000 align:start position:10%\r\n"
        + "first line\r\nsecond line\r\n\r\n"
        + "00:04.500 --> 00:06.000\r\n"
        + "a two-field timestamp"
    let reading = try SubtitleFile.read(messy)

    #expect(reading.refused.isEmpty, "a readable file was refused: \(reading.refused)")
    #expect(reading.track.cues.count == 2)
    #expect(reading.track.cues[0].text == "first line\nsecond line",
            "the second line of a cue was lost")
    #expect(reading.track.cues[1].start == ns(4.5),
            "WebVTT's two-field MM:SS.mmm was read as something else")
    // A missing final newline is not a missing cue.
    #expect(reading.track.cues[1].text == "a two-field timestamp")
}

/// **A bad cue is named and counted, never dropped quietly.** A file that silently loses three
/// lines is worse than one that refuses: the three are the ones somebody spent the most time on.
@Test func everyCueThisCannotUseIsReportedWithItsLine() throws {
    let file = """
        1
        00:00:01,000 --> 00:00:02,000
        fine

        2
        00:00:05,000 --> 00:00:04,000
        backwards

        3
        not a timestamp at all --> nonsense
        orphaned

        4
        00:00:08,000 --> 00:00:09,000

        5
        00:00:10,000 --> 00:00:11,000
        also fine
        """
    let reading = try SubtitleFile.read(file)
    #expect(reading.track.cues.map(\.text) == ["fine", "also fine"])
    #expect(reading.refused.count == 3, "refused \(reading.refused)")
    #expect(reading.refused.contains { if case .endsBeforeItStarts = $0 { true } else { false } })
    #expect(reading.refused.contains { if case .unreadableTimestamp = $0 { true } else { false } })
    #expect(reading.refused.contains { if case .noText = $0 { true } else { false } })
    // Every refusal names a line, so the panel can say where to look.
    #expect(reading.refused.allSatisfy { $0.line > 0 })
}

/// A file with nothing cue-shaped in it is a different answer from a file of bad cues: the
/// second had cues and they were wrong, the first is a text file somebody picked by mistake.
@Test func aFileWithNoCuesAtAllThrowsRatherThanReturningNothing() {
    #expect(throws: SubtitleFile.ReadError.noCues) {
        try SubtitleFile.read("This is just a paragraph of prose.\n\nAnd another.\n")
    }
}

/// Sidecars from elsewhere may legitimately show two cues at once; this project's own invariant
/// is that they never overlap. The trim is reported rather than done silently.
@Test func overlappingCuesAreTrimmedAndTheTrimIsCounted() throws {
    let file = """
        1
        00:00:01,000 --> 00:00:05,000
        long one

        2
        00:00:03,000 --> 00:00:06,000
        starts during it
        """
    let reading = try SubtitleFile.read(file)
    #expect(reading.overlapsTrimmed == 1)
    #expect(reading.track.cues[0].end == reading.track.cues[1].start)
    for (earlier, later) in zip(reading.track.cues, reading.track.cues.dropFirst()) {
        #expect(earlier.end.rawValue <= later.start.rawValue)
    }
}

/// Fractions of a second come in two and four digits as well as three, and scaling is what
/// makes each mean what it says.
@Test func aFractionIsScaledByHowManyDigitsItHas() {
    #expect(SubtitleFile.nanoseconds("00:00:01.5") == ns(1.5))
    #expect(SubtitleFile.nanoseconds("00:00:01.50") == ns(1.5))
    #expect(SubtitleFile.nanoseconds("00:00:01.500") == ns(1.5))
    #expect(SubtitleFile.nanoseconds("00:00:01.5000") == ns(1.5))
    #expect(SubtitleFile.nanoseconds("01:02:03.004")
            == Nanoseconds((((1 * 60 + 2) * 60 + 3) * 1000 + 4) * 1_000_000))

    // And what is not a timestamp says so rather than becoming zero.
    #expect(SubtitleFile.nanoseconds("banana") == nil)
    #expect(SubtitleFile.nanoseconds("00:00:0a.000") == nil)
    #expect(SubtitleFile.nanoseconds("1") == nil)
    #expect(SubtitleFile.nanoseconds("") == nil)
}
