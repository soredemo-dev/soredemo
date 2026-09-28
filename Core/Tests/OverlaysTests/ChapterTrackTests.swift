import Testing
import Foundation
import Geometry
import Project
import Timeline
@testable import Overlays

private func ns(_ seconds: Double) -> Nanoseconds {
    Nanoseconds(Int64((seconds * 1000).rounded()) * 1_000_000)
}

private func clip(_ id: Int, from start: Double, seconds: Double, speed: Double = 1) -> EditClip {
    EditClip(id: ClipID(rawValue: id), sourceStart: ns(start), duration: ns(seconds), speed: speed)
}

@Suite struct ChapterTrackTests {
    @Test func chaptersAreKeptInTheOrderTheyHappen() {
        let track = ChapterTrack()
            .adding(title: "Export", start: ns(40))
            .adding(title: "Install", start: ns(0))
        #expect(track.chapters.map(\.title) == ["Install", "Export"])
        #expect(Set(track.chapters.map(\.id)).count == 2)
    }

    /// The producer-value rule: a chapter no suggestion could have produced survives a second
    /// round of suggestions, and editing a suggested title makes it the person's.
    @Test func editingASuggestedTitleMakesItAuthored() throws {
        let track = ChapterTrack()
            .adding(title: "Record", start: ns(12), origin: .suggested(sentence: 3, text: "Now we record."))
        let id = try #require(track.chapters.first?.id)
        let edited = track.retitled(id, to: "Recording the screen")
        #expect(edited.chapters.first?.title == "Recording the screen")
        #expect(edited.chapters.first?.origin == .authored)
        // An unchanged title is not an edit, and must not erase where the chapter came from.
        #expect(track.retitled(id, to: "Record").chapters.first?.origin
                == .suggested(sentence: 3, text: "Now we record."))
    }

    @Test func aChapterMovesWithTheContentAroundItThroughCutsAndSpeed() {
        // Source 0–10 at 1×, source 20–40 at 2× (10 s of output). A chapter at source 30 plays
        // at output 10 + (30 − 20) / 2 = 15.
        let timeline = EditTimeline(clips: [clip(1, from: 0, seconds: 10),
                                            clip(2, from: 20, seconds: 20, speed: 2)])
        let track = ChapterTrack()
            .adding(title: "Intro", start: ns(0))
            .adding(title: "Later", start: ns(30))
        let placement = track.outputChapters(through: timeline, outputDuration: ns(20))
        #expect(placement.placed.map(\.start) == [ns(0), ns(15)])
        #expect(placement.placed.map(\.duration) == [ns(15), ns(5)])
        #expect(placement.placed.allSatisfy { placement.fates[$0.id] == .placed })
    }

    @Test func aChapterWhoseMomentWasCutMovesToWhereItsContentResumes() throws {
        // Source 5–8 is cut. A chapter at 6 has lost its first two seconds, not its content.
        let timeline = EditTimeline(clips: [clip(1, from: 0, seconds: 5), clip(2, from: 8, seconds: 12)])
        let track = ChapterTrack()
            .adding(title: "Intro", start: ns(0))
            .adding(title: "Second", start: ns(6))
        let placement = track.outputChapters(through: timeline, outputDuration: ns(17))
        let second = try #require(track.chapters.last)
        #expect(placement.placed.last?.start == ns(5))
        #expect(placement.fates[second.id] == .movedPastACut)
    }

    @Test func aChapterWithNothingLeftAfterItIsDroppedAndSaysSo() throws {
        let timeline = EditTimeline(clips: [clip(1, from: 0, seconds: 10)])
        let track = ChapterTrack()
            .adding(title: "Intro", start: ns(0))
            .adding(title: "Outro", start: ns(15))
        let placement = track.outputChapters(through: timeline, outputDuration: ns(10))
        let outro = try #require(track.chapters.last)
        #expect(placement.placed.map(\.name) == ["Intro"])
        #expect(placement.fates[outro.id] == .droppedNothingAfter)
    }

    /// Two chapters landing on one moment is two derivations disagreeing, so it is reported.
    /// The one whose own moment survived keeps the spot.
    @Test func twoChaptersLandingTogetherAreReportedNotSilentlyMerged() throws {
        let timeline = EditTimeline(clips: [clip(1, from: 0, seconds: 5), clip(2, from: 8, seconds: 12)])
        let track = ChapterTrack()
            .adding(title: "Cut away", start: ns(6))
            .adding(title: "Kept", start: ns(8))
        let placement = track.outputChapters(through: timeline, outputDuration: ns(17))
        let cutAway = try #require(track.chapters.first)
        let kept = try #require(track.chapters.last)
        #expect(placement.placed.map(\.name) == ["Kept"])
        #expect(placement.fates[cutAway.id] == .collided(with: kept.id))
    }

    @Test func reorderedClipsPutChaptersInPlayingOrder() {
        // Source 10–20 plays first, then 0–10.
        let timeline = EditTimeline(clips: [clip(2, from: 10, seconds: 10), clip(1, from: 0, seconds: 10)])
        let track = ChapterTrack()
            .adding(title: "A", start: ns(0))
            .adding(title: "B", start: ns(10))
        let placement = track.outputChapters(through: timeline, outputDuration: ns(20))
        #expect(placement.placed.map(\.name) == ["B", "A"])
        #expect(placement.placed.map(\.start) == [ns(0), ns(10)])
    }

    /// The fixture where "nearest after it in the recording" and "earliest-playing clip after
    /// it" disagree: source 20–30 plays first, source 8–12 second, and a chapter at 6 was cut.
    @Test func aCutChapterFollowsTheNearestContentInTheRecordingNotTheEarliestToPlay() {
        let timeline = EditTimeline(clips: [clip(2, from: 20, seconds: 10), clip(1, from: 8, seconds: 4)])
        let track = ChapterTrack().adding(title: "Cut", start: ns(6))
        #expect(track.outputChapters(through: timeline, outputDuration: ns(14)).placed.map(\.start) == [ns(10)])
    }

    @Test func withNoEditChaptersPlayWhereTheyWereRecorded() {
        let track = ChapterTrack().adding(title: "A", start: ns(0)).adding(title: "B", start: ns(4))
        let placement = track.outputChapters(through: nil, outputDuration: ns(9))
        #expect(placement.placed.map(\.start) == [ns(0), ns(4)])
        #expect(placement.placed.map(\.duration) == [ns(4), ns(5)])
    }

    @Test func withNoEditAChapterPastTheEndIsDropped() throws {
        let track = ChapterTrack().adding(title: "A", start: ns(0)).adding(title: "Late", start: ns(12))
        let late = try #require(track.chapters.last)
        let placement = track.outputChapters(through: nil, outputDuration: ns(9))
        #expect(placement.placed.map(\.name) == ["A"])
        #expect(placement.fates[late.id] == .droppedNothingAfter)
    }

    /// Removing takes that chapter and no other, and its id is not handed out again — a later
    /// chapter with a recycled id would answer to an old chapter's edits.
    @Test func removingTakesOnlyThatChapterAndRetiresItsId() throws {
        let track = ChapterTrack().adding(title: "A", start: ns(0)).adding(title: "B", start: ns(9))
        let first = try #require(track.chapters.first)
        let removed = track.removing(first.id)
        #expect(removed.chapters.map(\.title) == ["B"])
        #expect(removed.adding(title: "C", start: ns(20)).chapters.last?.id != first.id)
        #expect(ChapterTrack().isEmpty && !track.isEmpty)
    }

    @Test func aDecodedTrackIsSortedAndItsIdsCannotCollide() throws {
        let json = #"{"chapters":[{"id":4,"title":"B","start":{"rawValue":9000000000},"origin":{"authored":{}}},{"id":1,"title":"A","start":{"rawValue":0},"origin":{"authored":{}}}],"nextID":2}"#
        let track = try JSONDecoder().decode(ChapterTrack.self, from: Data(json.utf8))
        #expect(track.chapters.map(\.title) == ["A", "B"])
        #expect(track.adding(title: "C", start: ns(20)).chapters.last?.id == 5)
    }

    @Test func aDecodedChapterBeforeTheRecordingIsRefused() {
        let json = #"{"chapters":[{"id":1,"title":"A","start":{"rawValue":-5},"origin":{"authored":{}}}],"nextID":2}"#
        // Caught as the SPECIFIC refusal: a malformed fixture throws a `DecodingError` too, and
        // the first version of this test passed on exactly that.
        do {
            _ = try JSONDecoder().decode(ChapterTrack.self, from: Data(json.utf8))
            Issue.record("a chapter at -5 ns decoded")
        } catch DecodingError.dataCorrupted(let context) {
            #expect(context.debugDescription.contains("before the recording"))
        } catch {
            Issue.record("refused for the wrong reason: \(error)")
        }
    }

    @Test func aTrackRoundTrips() throws {
        let track = ChapterTrack()
            .adding(title: "A", start: ns(0))
            .adding(title: "B", start: ns(9), origin: .suggested(sentence: 2, text: "Then B."))
        let data = try JSONEncoder().encode(track)
        #expect(try JSONDecoder().decode(ChapterTrack.self, from: data) == track)
    }
}

@Suite struct ChapterListTests {
    private func placed(_ starts: [Double], total: Double) -> [PlacedChapter] {
        starts.enumerated().map { index, start in
            let end = index + 1 < starts.count ? starts[index + 1] : total
            return PlacedChapter(id: index, name: "Part \(index + 1)", start: ns(start),
                                 duration: ns(end - start))
        }
    }

    @Test func aListUsesMinutesAndSecondsUnderAnHour() {
        let text = ChapterList.text(placed([0, 75, 610], total: 900), outputDuration: ns(900))
        #expect(text == "0:00 Part 1\n1:15 Part 2\n10:10 Part 3")
    }

    @Test func aListOverAnHourUsesHoursOnEveryLine() {
        let text = ChapterList.text(placed([0, 3725], total: 4000), outputDuration: ns(4000))
        #expect(text == "0:00:00 Part 1\n1:02:05 Part 2")
    }

    /// Seconds are truncated, not rounded: a chapter at 74.6 s has not reached 1:15 yet, and a
    /// viewer clicking 1:15 would land after its first words.
    @Test func secondsAreTruncatedNotRounded() {
        let text = ChapterList.text(placed([0, 74.6], total: 100), outputDuration: ns(100))
        #expect(text == "0:00 Part 1\n1:14 Part 2")
    }

    @Test func aListThatVideoHostsWouldRejectSaysWhy() {
        #expect(ChapterList.problems(placed([0, 60, 120], total: 200)).isEmpty)
        #expect(ChapterList.problems(placed([3, 60, 120], total: 200)) == [.firstIsNotAtTheStart])
        #expect(ChapterList.problems(placed([0, 60], total: 200)) == [.fewerThanThree(2)])
        // The first runs 0–5; the last runs 120–125. Both short; the middle one is not.
        #expect(ChapterList.problems(placed([0, 5, 120], total: 125))
                == [.tooShort(id: 0), .tooShort(id: 2)])
    }
}

// MARK: - marks placed while recording

private let markEpoch = BootEpoch(id: UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!)
private let second: Int64 = 1_000_000_000

/// Two segments at a non-zero host origin, with a ten-second pause between them: 1000–1060 s and
/// 1070–1100 s of host time, which is 0–60 s and 60–90 s of the recording.
private func pausedTable() throws -> SegmentTable {
    try SegmentTable(segments: [
        MasterSegment(index: 0, mediaFilename: "a.mov",
                      hostRange: HostRange(epoch: markEpoch, start: Nanoseconds(1_000 * second),
                                           duration: Nanoseconds(60 * second)),
                      revision: GeometryRevision(id: 1), endedBy: .paused),
        MasterSegment(index: 1, mediaFilename: "b.mov",
                      hostRange: HostRange(epoch: markEpoch, start: Nanoseconds(1_070 * second),
                                           duration: Nanoseconds(30 * second)),
                      revision: GeometryRevision(id: 1), endedBy: .stopped),
    ])
}

private func mark(_ seconds: Int64) -> HostInstant {
    HostInstant(epoch: markEpoch, hostTime: Nanoseconds(seconds * second))
}

@Suite struct ChapterMarkSeedingTests {
    /// **Placed against the segment table, not as an offset from the first frame.** A mark at host
    /// 1075 s is 60 + 5 = 65 s into the recording; measured from the first frame it would be 75 s
    /// — the pause's length late.
    @Test func aMarkLandsWhereItsMomentIsInTheRecordingAcrossAPause() throws {
        let seeded = ChapterTrack.fromMarks([mark(1_075), mark(1_010)], in: try pausedTable()) {
            "Chapter \($0)"
        }
        #expect(seeded.track.chapters.map(\.start) == [Nanoseconds(10 * second), Nanoseconds(65 * second)])
        // Numbered in the order they happen, not the order they were handed over.
        #expect(seeded.track.chapters.map(\.title) == ["Chapter 1", "Chapter 2"])
        #expect(seeded.track.chapters.allSatisfy { $0.origin == .marked })
        #expect(seeded.refused == 0)
    }

    /// A mark in the pause or before the first frame has no moment in the video. **Refused and
    /// counted, never moved to the nearest edge** — that would be a chapter at a moment nobody
    /// chose.
    @Test func aMarkThatLandsInNoSegmentIsRefusedAndCounted() throws {
        let seeded = ChapterTrack.fromMarks([mark(1_065), mark(999), mark(1_030)],
                                            in: try pausedTable()) { "Chapter \($0)" }
        #expect(seeded.track.chapters.map(\.start) == [Nanoseconds(30 * second)])
        #expect(seeded.track.chapters.map(\.title) == ["Chapter 1"])
        #expect(seeded.refused == 2)
    }

    @Test func retitlingAMarkedChapterMakesItAuthored() throws {
        let seeded = ChapterTrack.fromMarks([mark(1_010)], in: try pausedTable()) { "Chapter \($0)" }
        let id = try #require(seeded.track.chapters.first?.id)
        #expect(seeded.track.retitled(id, to: "Chapter 1").chapters.first?.origin == .marked)
        #expect(seeded.track.retitled(id, to: "Installing").chapters.first?.origin == .authored)
    }

    @Test func aMarkedChapterSurvivesSavingAndOpening() throws {
        let seeded = ChapterTrack.fromMarks([mark(1_010), mark(1_080)], in: try pausedTable()) {
            "Chapter \($0)"
        }
        let decoded = try JSONDecoder().decode(ChapterTrack.self,
                                               from: try JSONEncoder().encode(seeded.track))
        #expect(decoded == seeded.track)
    }
}
