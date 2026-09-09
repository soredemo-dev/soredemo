import Foundation
import Render
import Overlays
import Testing
import Timeline
@testable import Soredemo

/// The caption model, which nothing has ever run against.
///
/// **These are app-tier tests, which this project had none of** — 13,761 lines with no
/// executable test, and `CaptionsModel` is an `@Observable` class with no view in it. See
/// docs/TESTING.md § 5.4. The rules under test are the ones the editing keys depend on: a
/// split that loses a word, or a merge that keeps the wrong end, is silent until somebody
/// reads their own captions back.
@MainActor private func track(_ cues: [(String, Int64, Int64)]) -> CaptionTrack {
    CaptionTrack(cues: cues.map {
        CaptionCue(text: $0.0, start: Nanoseconds($0.1), end: Nanoseconds($0.2))
    })
}

@Test @MainActor func settingTextLeavesTheTimingAlone() {
    let model = CaptionsModel()
    model.restore(track: track([("hello there", 0, 2_000_000_000)]),
                  style: CaptionStyle.presets[0].style, burnsIn: false)
    model.setText("hello world", at: 0)
    #expect(model.track.cues[0].text == "hello world")
    #expect(model.track.cues[0].start == Nanoseconds(0))
    #expect(model.track.cues[0].end == Nanoseconds(2_000_000_000))
}

/// **A split keeps every character.** The failure this guards is the one nobody notices: a
/// split at the wrong offset drops or duplicates a word, and the line still looks like a line.
@Test @MainActor func splittingKeepsTheWholeSentence() {
    let model = CaptionsModel()
    model.restore(track: track([("one two three", 0, 3_000_000_000)]),
                  style: CaptionStyle.presets[0].style, burnsIn: false)
    model.split(at: 0, atCharacter: 7)
    #expect(model.track.cues.count == 2)
    let rejoined = model.track.cues.map(\.text).joined(separator: " ")
    #expect(rejoined.replacingOccurrences(of: "  ", with: " ") == "one two three")
}

/// **A merge takes the first cue's start and the second's end.** Either other combination
/// leaves a hole in the timeline or an overlap, and both play as a caption that flickers.
@Test @MainActor func mergingSpansBothCues() {
    let model = CaptionsModel()
    model.restore(track: track([("first", 0, 1_000_000_000),
                                ("second", 1_100_000_000, 2_000_000_000)]),
                  style: CaptionStyle.presets[0].style, burnsIn: false)
    model.merge(at: 0)
    #expect(model.track.cues.count == 1)
    #expect(model.track.cues[0].start == Nanoseconds(0))
    #expect(model.track.cues[0].end == Nanoseconds(2_000_000_000))
}

/// **A retime cannot cross its neighbour.** `CaptionTrack.retiming` clamps rather than
/// refusing, which is what makes holding a nudge button safe — the test is that it clamps and
/// not that it accepts.
@Test @MainActor func retimingClampsAgainstTheNextCue() {
    let model = CaptionsModel()
    model.restore(track: track([("first", 0, 1_000_000_000),
                                ("second", 1_100_000_000, 2_000_000_000)]),
                  style: CaptionStyle.presets[0].style, burnsIn: false)
    model.retime(at: 0, start: Nanoseconds(0), end: Nanoseconds(1_900_000_000))
    #expect(model.track.cues[0].end <= model.track.cues[1].start)
}

/// **Removing a cue removes exactly one.** An off-by-one here deletes the line after the one
/// somebody clicked, which is the kind of thing an undo stack hides rather than fixes.
@Test @MainActor func removingTakesOnlyThatCue() {
    let model = CaptionsModel()
    model.restore(track: track([("a", 0, 1_000_000_000), ("b", 1_000_000_000, 2_000_000_000),
                                ("c", 2_000_000_000, 3_000_000_000)]),
                  style: CaptionStyle.presets[0].style, burnsIn: false)
    model.remove(at: 1)
    #expect(model.track.cues.map(\.text) == ["a", "c"])
}
