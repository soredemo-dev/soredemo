import Foundation
import Testing
@testable import Timeline

private let second: Int64 = 1_000_000_000

private func clip(_ id: Int, start: Int64, seconds: Int64, speed: Double = 1,
                  fadeIn: Double = 0, fadeOut: Double = 0) -> EditClip {
    EditClip(id: ClipID(rawValue: id), sourceStart: Nanoseconds(start),
             duration: Nanoseconds(seconds * second), speed: speed,
             fadeInSeconds: fadeIn, fadeOutSeconds: fadeOut)
}

/// A fade is a straight ramp measured from each end: nothing at the very start, full at the end
/// of the fade-in, and the mirror on the way out.
@Test func aFadeRampsFromNothingToFullAndBack() {
    let one = clip(1, start: 0, seconds: 10, fadeIn: 2, fadeOut: 2)
    #expect(one.visibility(atPlayOffsetSeconds: 0) == 0)
    #expect(abs(one.visibility(atPlayOffsetSeconds: 1) - 0.5) < 1e-9)
    #expect(one.visibility(atPlayOffsetSeconds: 2) == 1)
    #expect(one.visibility(atPlayOffsetSeconds: 5) == 1)
    #expect(abs(one.visibility(atPlayOffsetSeconds: 9) - 0.5) < 1e-9)
    #expect(one.visibility(atPlayOffsetSeconds: 10) == 0)
}

/// A clip nobody faded is fully visible everywhere, including at its very edges — the feature is
/// opt-in and `0` has to mean no fade rather than an instant one.
@Test func aClipWithNoFadeIsVisibleAtItsOwnEdges() {
    let plain = clip(1, start: 0, seconds: 5)
    #expect(plain.visibility(atPlayOffsetSeconds: 0) == 1)
    #expect(plain.visibility(atPlayOffsetSeconds: 5) == 1)
}

/// **Two fades that overlap are scaled down together, keeping the ratio asked for.** Clamping
/// each separately would let them meet in the middle, and the clip would dim and brighten
/// without ever simply being visible.
@Test func fadesThatWouldOverlapAreShrunkInProportion() {
    // Four seconds of play time, asked for three in and one out — four in total, which fits
    // exactly, so nothing is scaled.
    let exact = clip(1, start: 0, seconds: 4, fadeIn: 3, fadeOut: 1)
    #expect(abs(exact.fadeInSeconds - 3) < 1e-9)
    #expect(abs(exact.fadeOutSeconds - 1) < 1e-9)

    // Six asked for in four: halved, and 3:1 stays 3:1.
    let over = clip(2, start: 0, seconds: 4, fadeIn: 4.5, fadeOut: 1.5)
    #expect(abs(over.fadeInSeconds + over.fadeOutSeconds - 4) < 1e-9)
    #expect(abs(over.fadeInSeconds / over.fadeOutSeconds - 3) < 1e-9)
}

/// **Fades are in OUTPUT seconds.** A clip at double speed plays for half as long, so the same
/// fade takes the same time on screen — and the halving above measures against play time, not
/// against the source it was cut from.
@Test func aFadeIsMeasuredInWhatAViewerWatches() {
    // Ten source seconds at 2× plays for five. A four-second fade-in fits.
    let quick = clip(1, start: 0, seconds: 10, speed: 2, fadeIn: 4)
    #expect(abs(quick.fadeInSeconds - 4) < 1e-9)
    #expect(quick.visibility(atPlayOffsetSeconds: 2) == 0.5)

    // Six would not fit in five, and is scaled to it.
    let tooLong = clip(2, start: 0, seconds: 10, speed: 2, fadeIn: 6)
    #expect(abs(tooLong.fadeInSeconds - 5) < 1e-9)
}

/// A seam is where one clip's fade-out meets the next one's fade-in, which is what makes this
/// model cover a dip without a transition list. The timeline reads them as one curve.
@Test func aSeamBetweenTwoFadesReadsAsOneDip() {
    let timeline = EditTimeline(clips: [
        clip(1, start: 0, seconds: 5, fadeOut: 1),
        clip(2, start: 10 * second, seconds: 5, fadeIn: 1),
    ])
    // Full through the middle of the first clip.
    #expect(timeline.visibility(atOutput: Nanoseconds(2 * second)) == 1)
    // Down to nothing at the seam, from both sides.
    #expect(abs(timeline.visibility(atOutput: Nanoseconds(4 * second + second / 2)) - 0.5) < 1e-6)
    #expect(timeline.visibility(atOutput: Nanoseconds(5 * second)) == 0)
    #expect(abs(timeline.visibility(atOutput: Nanoseconds(5 * second + second / 2)) - 0.5) < 1e-6)
    // And full again once the second clip has arrived.
    #expect(timeline.visibility(atOutput: Nanoseconds(7 * second)) == 1)
}

/// Past the end is `1`, not `nil` and not `0`: a frame nobody can see has nothing to be wrong
/// about, and an optional would put the same `?? 1` at every call site.
@Test func pastTheEndIsFullyVisibleRatherThanAbsent() {
    let timeline = EditTimeline(clips: [clip(1, start: 0, seconds: 2, fadeOut: 1)])
    #expect(timeline.visibility(atOutput: Nanoseconds(99 * second)) == 1)
    #expect(timeline.visibility(atOutput: Nanoseconds(-1)) == 1)
}

/// `hasAnyFade` is what keeps a timeline nobody faded from paying anything per frame.
@Test func aTimelineWithNoFadesSaysSo() {
    #expect(EditTimeline(clips: [clip(1, start: 0, seconds: 5)]).hasAnyFade == false)
    #expect(EditTimeline(clips: [clip(1, start: 0, seconds: 5, fadeIn: 0.5)]).hasAnyFade)
    #expect(EditTimeline(clips: [clip(1, start: 0, seconds: 5, fadeOut: 0.5)]).hasAnyFade)
}

/// A project saved before fades existed decodes with none, and a corrupt one cannot carry a
/// fade longer than the clip it is on.
@Test func fadesDecodeAbsenceTolerantlyAndAreClampedOnTheWayIn() throws {
    // Built by encoding a real clip and taking the keys out, rather than by writing JSON from
    // memory: `ClipID` and `Nanoseconds` encode through single-value containers, and a fixture
    // guessing at their shape tests the guess.
    let encoded = try JSONEncoder().encode(clip(1, start: 0, seconds: 5))
    var object = try #require(
        try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "fadeInSeconds")
    object.removeValue(forKey: "fadeOutSeconds")
    let older = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(EditClip.self, from: older)
    #expect(decoded.fadeInSeconds == 0)
    #expect(decoded.fadeOutSeconds == 0)

    // Nine hundred seconds of fade on a two-second clip is a corrupt file, not a decision.
    var absurd = try #require(try JSONSerialization.jsonObject(
        with: try JSONEncoder().encode(clip(2, start: 0, seconds: 2))) as? [String: Any])
    absurd["fadeInSeconds"] = 900
    absurd["fadeOutSeconds"] = 100
    let clamped = try JSONDecoder().decode(
        EditClip.self, from: try JSONSerialization.data(withJSONObject: absurd))
    #expect(clamped.fadeInSeconds + clamped.fadeOutSeconds <= 2.0000001)
    #expect(clamped.fadeInSeconds > clamped.fadeOutSeconds, "the ratio asked for was lost")

    // And a clip that WAS faded keeps what it was given.
    let faded = clip(3, start: 0, seconds: 10, fadeIn: 1.5, fadeOut: 0.5)
    let round = try JSONDecoder().decode(EditClip.self, from: try JSONEncoder().encode(faded))
    #expect(abs(round.fadeInSeconds - 1.5) < 1e-9)
    #expect(abs(round.fadeOutSeconds - 0.5) < 1e-9)
}

// MARK: - what survives an edit

/// **A cut through a sped-up clip used to reset its tail to 1×.** The head went through
/// `spanning`, which carries the clip's own attributes; the tail was built from the
/// initialiser, which takes the defaults. The fourth time this project has reconstructed a
/// value and lost a field — a `StageStyle` without its blur, a `CameraOverlayStyle` without its
/// shape, a `StageStylePicker` that did not apply one — and the first three were all found the
/// same way: by adding a field and asking what else drops it.
@Test func cuttingASpedUpClipKeepsTheSpeedOnBothSides() {
    let timeline = EditTimeline(clips: [clip(1, start: 0, seconds: 10, speed: 2)])
    let cut = timeline.removing(sourceRange: (4 * second)..<(6 * second))
    #expect(cut.clips.count == 2, "the cut did not leave two clips")
    for piece in cut.clips {
        #expect(piece.speed == 2, "a piece came back at \(piece.speed)× instead of 2×")
    }
}

/// A cut keeps the fades at the edges that still exist and drops the ones at the edge it
/// removed: the head's start and the tail's end are unchanged, and the two new edges are cuts.
@Test func aCutKeepsTheFadesAtTheEdgesItDidNotTouch() {
    let timeline = EditTimeline(clips: [
        clip(1, start: 0, seconds: 10, fadeIn: 1, fadeOut: 1),
    ])
    let cut = timeline.removing(sourceRange: (4 * second)..<(6 * second))
    let head = try! #require(cut.clips.first)
    let tail = try! #require(cut.clips.last)
    #expect(head.fadeInSeconds == 1, "the head lost the fade in at a start it still has")
    #expect(head.fadeOutSeconds == 0, "the head kept a fade out at an edge that is now a cut")
    #expect(tail.fadeInSeconds == 0, "the tail kept a fade in at an edge that is now a cut")
    #expect(tail.fadeOutSeconds == 1, "the tail lost the fade out at an end it still has")
}

/// Changing the speed keeps the fades, and the fades stay in output seconds — so the same fade
/// covers half as much of the recording once the clip plays twice as fast.
@Test func changingSpeedKeepsTheFades() {
    let slow = clip(1, start: 0, seconds: 10, speed: 1, fadeIn: 2, fadeOut: 1)
    let fast = slow.playing(at: 2)
    #expect(fast.fadeInSeconds == 2)
    #expect(fast.fadeOutSeconds == 1)
    // Ten source seconds at 2× plays for five, and three seconds of fade still fits in it.
    #expect(fast.visibility(atPlayOffsetSeconds: 1) == 0.5)
}

/// Trimming keeps them too — `spanning` is a trim rather than a replacement, which is what the
/// id surviving is already supposed to mean.
@Test func trimmingKeepsEverythingButTheSpan() {
    let original = clip(1, start: 0, seconds: 10, speed: 1.5, fadeIn: 0.5, fadeOut: 0.25)
    let trimmed = original.spanning(sourceStart: Nanoseconds(second),
                                    duration: Nanoseconds(8 * second))
    #expect(trimmed.id == original.id)
    #expect(trimmed.speed == 1.5)
    #expect(trimmed.fadeInSeconds == 0.5)
    #expect(trimmed.fadeOutSeconds == 0.25)
}
