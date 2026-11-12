import Foundation
import Testing
@testable import Timeline

// A clip that is not the recording (`docs/design/2026-11-13-clips-from-the-library.md`). The
// recording is 10 s; a picture is held for 2 s inserted 3 s in — so the recording's seconds and
// the output's disagree after the insert, and a mapping that ignored the picture would be off
// by exactly 2 s.

private let s: Int64 = 1_000_000_000
private func ns(_ seconds: Int64) -> Nanoseconds { Nanoseconds(seconds * s) }

@Suite struct LibraryClipTests {
    private func withPicture() throws -> EditTimeline {
        try #require(EditTimeline.whole(duration: ns(10))
            .inserting(.picture(item: 4), sourceStart: ns(0), duration: ns(2), atOutput: ns(3)))
    }

    @Test func aPictureInsertedSplitsTheClipItLandsInAndLengthensTheEdit() throws {
        let edit = try withPicture()
        #expect(edit.clips.map(\.source) == [.recording, .picture(item: 4), .recording])
        #expect(edit.clips.map(\.duration) == [ns(3), ns(2), ns(7)])
        #expect(edit.outputDuration == ns(12))
        #expect(Set(edit.clips.map(\.id)).count == 3, "every clip its own id")
    }

    /// Only the recording has a source time: inside the picture there is no cursor, no zoom and
    /// no recording caption to place, and after it the recording is two seconds later.
    @Test func onlyTheRecordingHasASourceTime() throws {
        let edit = try withPicture()
        #expect(edit.sourceTime(atOutput: OutputTime(nanos: 4 * s)) == nil, "inside the picture")
        #expect(edit.sourceTime(atOutput: OutputTime(nanos: 6 * s)) == SourceTime(nanos: 4 * s))
        #expect(edit.outputTime(atSource: SourceTime(nanos: 4 * s)) == OutputTime(nanos: 6 * s))
        #expect(edit.outputTime(atSource: SourceTime(nanos: 1 * s)) == OutputTime(nanos: 1 * s))
        #expect(edit.clip(atSource: ns(1))?.source == .recording)
    }

    /// A library VIDEO's own span is not the recording's, though its numbers look like one.
    @Test func aLibraryVideosSpanIsNeverTakenForTheRecordings() throws {
        let edit = try #require(EditTimeline.whole(duration: ns(10))
            .inserting(.video(item: 2), sourceStart: ns(1), duration: ns(3), atOutput: ns(10)))
        #expect(edit.clip(atSource: ns(2))?.source == .recording, "the recording's 2 s, not the video's")
        #expect(edit.outputTime(atSource: SourceTime(nanos: 2 * s)) == OutputTime(nanos: 2 * s))
        #expect(edit.survival(ofSource: (10 * s)..<(11 * s)) == .gone, "the video does not make the recording's end survive")
    }

    /// Cuts by a span of the recording leave a library clip where it is; merging never joins
    /// across one; trimming the recording keeps it.
    @Test func cutsOfTheRecordingLeaveALibraryClipAlone() throws {
        let edit = try withPicture()
        let cut = edit.removing(sourceRange: (1 * s)..<(5 * s))
        #expect(cut.clips.map(\.source) == [.recording, .picture(item: 4), .recording])
        #expect(cut.clips.map(\.duration) == [ns(1), ns(2), ns(5)])
        // A picture whose own span starts exactly where the clip before it ends: the numbers say
        // "contiguous", and only the source says they are not one clip.
        let abutting = try #require(EditTimeline.whole(duration: ns(10))
            .inserting(.picture(item: 4), sourceStart: ns(3), duration: ns(2), atOutput: ns(3)))
        #expect(abutting.merged().clips.map(\.source) == [.recording, .picture(item: 4), .recording],
                "merging never joins a recording clip and a library clip")
        // Trimming the recording to 5–8 s keeps the picture, whose own 0–2 s is outside that span.
        #expect(edit.trimmed(toSource: (5 * s)..<(8 * s)).clips.contains { $0.source == .picture(item: 4) })
        #expect(edit.survival(ofSource: (0 * s)..<(10 * s)) == .whole)
    }

    /// A project written before library clips has no `source`, and a recording clip is written
    /// exactly as it was — so every saved project and every digest is unchanged by this.
    @Test func aRecordingClipIsWrittenAsBeforeAndALibraryClipRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let recording = EditClip(id: ClipID(rawValue: 0), sourceStart: ns(0), duration: ns(3))
        let written = try encoder.encode(recording)
        #expect(!String(decoding: written, as: UTF8.self).contains("\"source\""), "no new key on a recording clip")
        // What a project saved before the library holds is exactly that: no `source`.
        #expect(try JSONDecoder().decode(EditClip.self, from: written).source == .recording)
        let edit = try withPicture()
        #expect(try JSONDecoder().decode(EditTimeline.self, from: encoder.encode(edit)) == edit)
    }

    /// Inserting at the very end, and refusing what is not a place or a length.
    @Test func anInsertAtTheEndAppendsAndANonsenseInsertIsRefused() {
        let end = EditTimeline.whole(duration: ns(10)).inserting(.picture(item: 1), sourceStart: ns(0), duration: ns(2), atOutput: ns(10))
        #expect(end?.clips.map(\.source) == [.recording, .picture(item: 1)])
        #expect(EditTimeline.whole(duration: ns(10)).inserting(.picture(item: 1), sourceStart: ns(0), duration: ns(2), atOutput: ns(11)) == nil)
        #expect(EditTimeline.whole(duration: ns(10)).inserting(.recording, sourceStart: ns(0), duration: ns(2), atOutput: ns(1)) == nil,
                "the recording is not inserted from the library")
    }
}

/// The snap targets are the recording's clip edges, never a library file's own times.
@Test func snapTargetsAreTheRecordingsEdgesOnly() throws {
    let edit = try #require(EditTimeline.whole(duration: ns(10))
        .inserting(.video(item: 2), sourceStart: ns(4), duration: ns(3), atOutput: ns(10)))
    let edges = SnapEngine.targets(in: edit).filter { $0.kind == .clipEdge }.map(\.time)
    #expect(Set(edges) == [ns(0), ns(10)], "the video's 4 s and 7 s are not the recording's")
}
