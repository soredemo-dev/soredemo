import Foundation
import Testing
import Timeline
@testable import Overlays

// Overlays placed on the recording, through an edit with a library clip in it
// (`docs/design/2026-11-13-clips-from-the-library.md`).

private let s: Int64 = 1_000_000_000
private func ns(_ seconds: Int64) -> Nanoseconds { Nanoseconds(seconds * s) }

@Suite struct LibraryClipRetimingTests {
    /// A caption at the recording's 1–2 s is where it was; one at 4–5 s plays two seconds later,
    /// after the picture; and a picture whose own span numbers overlap 4–5 s carries none of it.
    @Test func aCaptionMovesPastAnInsertedPictureAndIsNeverPutOnIt() throws {
        let edit = try #require(EditTimeline.whole(duration: ns(10))
            .inserting(.picture(item: 1), sourceStart: ns(4), duration: ns(2), atOutput: ns(3)))
        let track = CaptionTrack(cues: [CaptionCue(text: "early", start: ns(1), end: ns(2)),
                                        CaptionCue(text: "later", start: ns(4), end: ns(5))])
        let retimed = track.retimed(through: edit)
        #expect(retimed.cues.map(\.text) == ["early", "later"], "nothing doubled onto the picture")
        #expect(retimed.cues.map(\.start) == [ns(1), ns(6)])
    }

    @Test func aTitleIsNeverPlacedOnAPicture() throws {
        let edit = try #require(EditTimeline.whole(duration: ns(10))
            .inserting(.picture(item: 1), sourceStart: ns(4), duration: ns(2), atOutput: ns(3)))
        let titles = TextTrack().adding(text: "Hi", start: ns(4), end: ns(5)).retimed(through: edit)
        #expect(titles.items.map(\.start) == [ns(6)])
    }
}
