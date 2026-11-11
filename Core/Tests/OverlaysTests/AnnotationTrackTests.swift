import Foundation
import Render
import Testing
import Timeline
@testable import Overlays

/// The annotation track: identity, the on-screen window, what a cut does to it, and what a
/// decoder cannot smuggle past it.
@Suite struct AnnotationTrackTests {
    private let second = 1_000_000_000

    private func track() -> AnnotationTrack {
        AnnotationTrack()
            .adding(shape: .arrow, startX: 0.2, startY: 0.2, endX: 0.6, endY: 0.7,
                    start: Nanoseconds(Int64(second)), end: Nanoseconds(Int64(3 * second)))
            .adding(shape: .rectangle, startX: 0.1, startY: 0.1, endX: 0.3, endY: 0.4,
                    start: Nanoseconds(Int64(4 * second)), end: Nanoseconds(Int64(6 * second)))
    }

    // MARK: - identity

    /// **A deleted id is never handed out again.** Deriving the next id from `items.count` would
    /// do exactly that, and the consequence is not a crash: an inspector bound to the deleted
    /// arrow silently starts editing the new one.
    @Test func deletingAnItemDoesNotFreeItsIdForReuse() {
        let two = track()
        #expect(two.items.map(\.id) == [0, 1])
        let afterDelete = two.removing(0)
        let afterAdd = afterDelete.adding(shape: .line, startX: 0, startY: 0, endX: 1, endY: 1,
                                          start: Nanoseconds(0), end: Nanoseconds(Int64(second)))
        #expect(afterAdd.items.map(\.id).sorted() == [1, 2],
                "the new annotation reused a dead id")
    }

    /// Replacing something nobody has is a no-op, not a trap — rule 8: never trap on an input
    /// that came from outside, and an id from a stale selection is exactly that.
    @Test func replacingAnUnknownIdChangesNothing() {
        let before = track()
        let stranger = AnnotationItem(id: 99, shape: .ellipse, startX: 0, startY: 0,
                                      endX: 1, endY: 1, start: Nanoseconds(0),
                                      end: Nanoseconds(Int64(second)))
        #expect(before.replacing(stranger) == before)
    }

    // MARK: - the on-screen window

    /// Half-open, `[start, end)`. Two annotations that abut must not both be on for one frame —
    /// the closed form draws them together for exactly one frame, which reads as a flicker and
    /// is the sort of thing nobody reports because it is over before it registers.
    @Test func theWindowIsHalfOpenSoAbuttingAnnotationsNeverOverlap() {
        let abutting = AnnotationTrack()
            .adding(shape: .line, startX: 0, startY: 0, endX: 1, endY: 1,
                    start: Nanoseconds(0), end: Nanoseconds(Int64(second)))
            .adding(shape: .line, startX: 0, startY: 1, endX: 1, endY: 0,
                    start: Nanoseconds(Int64(second)), end: Nanoseconds(Int64(2 * second)))
        #expect(abutting.items(at: Nanoseconds(Int64(second) - 1)).map(\.id) == [0])
        #expect(abutting.items(at: Nanoseconds(Int64(second))).map(\.id) == [1])
    }

    /// Overlaps are a layout, not a bug — three arrows converging on one control is a diagram.
    /// This is the difference from `CaptionTrack`, where two at once IS a bug.
    @Test func overlappingAnnotationsAreAllReturned() {
        let overlapping = AnnotationTrack()
            .adding(shape: .arrow, startX: 0, startY: 0, endX: 0.5, endY: 0.5,
                    start: Nanoseconds(0), end: Nanoseconds(Int64(4 * second)))
            .adding(shape: .arrow, startX: 1, startY: 0, endX: 0.5, endY: 0.5,
                    start: Nanoseconds(Int64(second)), end: Nanoseconds(Int64(3 * second)))
        #expect(overlapping.items(at: Nanoseconds(Int64(2 * second))).count == 2)
    }

    // MARK: - what a cut does

    /// An annotation inside a removed span goes with it. Keeping it would put an arrow on screen
    /// pointing at footage the viewer never sees.
    @Test func anAnnotationInsideACutDisappearsWithIt() {
        let whole = EditTimeline.whole(duration: Nanoseconds(Int64(10 * second)))
        let cut = whole.removing(sourceRange: Int64(3 * second)..<Int64(7 * second))
        let annotations = AnnotationTrack()
            .adding(shape: .arrow, startX: 0.2, startY: 0.2, endX: 0.6, endY: 0.7,
                    start: Nanoseconds(Int64(4 * second)), end: Nanoseconds(Int64(6 * second)))
        #expect(annotations.retimed(through: cut).items.isEmpty)
    }

    /// Everything after a cut moves back by exactly what the cut removed. The alternative is an
    /// arrow that appears four seconds after the thing it points at.
    @Test func anAnnotationAfterACutMovesBackByWhatWasRemoved() {
        let whole = EditTimeline.whole(duration: Nanoseconds(Int64(10 * second)))
        let cut = whole.removing(sourceRange: Int64(2 * second)..<Int64(5 * second))
        let annotations = AnnotationTrack()
            .adding(shape: .line, startX: 0, startY: 0, endX: 1, endY: 1,
                    start: Nanoseconds(Int64(8 * second)), end: Nanoseconds(Int64(9 * second)))
        let retimed = try! #require(annotations.retimed(through: cut).items.first)
        #expect(retimed.start.rawValue == Int64(5 * second),
                "8 s minus the 3 s that was cut is 5 s, got \(retimed.start.rawValue)")
        #expect(retimed.end.rawValue == Int64(6 * second))
    }

    /// **On a sped-up clip an annotation plays for the time its span takes to play.** The start
    /// went through `outputTime(atSource:)`, which divides by the speed; the end added the SOURCE
    /// length, which does not — the defect the caption track had and fixed. On a 2× clip an arrow
    /// at 2–4 s drew for two seconds of video instead of one, over whatever followed it.
    @Test func anAnnotationOnASpedUpClipPlaysForTheTimeItTakesToPlay() {
        let clip = EditClip(id: ClipID(rawValue: 1), sourceStart: Nanoseconds(0),
                            duration: Nanoseconds(Int64(10 * second)), speed: 2)
        let annotations = AnnotationTrack()
            .adding(shape: .line, startX: 0, startY: 0, endX: 1, endY: 1,
                    start: Nanoseconds(Int64(2 * second)), end: Nanoseconds(Int64(4 * second)))
        let retimed = try! #require(annotations.retimed(through: EditTimeline(clips: [clip])).items.first)
        #expect(retimed.start.rawValue == Int64(1 * second))
        #expect(retimed.end.rawValue == Int64(2 * second), "got \(retimed.end.rawValue)")
    }

    /// **A split keeps the id AND the geometry.** Both halves are the same arrow pointing at the
    /// same thing; an inspector showing "this one" should show both, and a half that moved would
    /// be pointing somewhere nobody aimed.
    @Test func anAnnotationSpanningACutIsSplitAndBothHalvesAreStillTheSameOne() {
        let whole = EditTimeline.whole(duration: Nanoseconds(Int64(10 * second)))
        let cut = whole.removing(sourceRange: Int64(4 * second)..<Int64(6 * second))
        let annotations = AnnotationTrack()
            .adding(shape: .arrow, startX: 0.25, startY: 0.75, endX: 0.5, endY: 0.5,
                    start: Nanoseconds(Int64(2 * second)), end: Nanoseconds(Int64(8 * second)))
        let halves = annotations.retimed(through: cut).items
        #expect(halves.count == 2, "expected two halves, got \(halves.count)")
        #expect(Set(halves.map(\.id)) == [0], "the halves are not the same annotation any more")
        for half in halves {
            #expect(half.startX == 0.25 && half.startY == 0.75)
            #expect(half.endX == 0.5 && half.endY == 0.5)
        }
    }

    // MARK: - what a decoder cannot smuggle past

    /// The custom `init(from:)` routes through the validating initialiser. Without it a
    /// hand-edited project file puts an arrow off the edge of every export, silently.
    @Test func aDecodedCoordinateOutsideTheFrameIsClamped() throws {
        let json = """
        {"id": 0, "shape": "arrow", "startX": 5, "startY": -5, "endX": 0.5, "endY": 0.5,
         "style": {"strokeWidthFraction": 0.006, "red": 1, "green": 0, "blue": 0, "alpha": 1,
                   "fillOpacity": 0, "shadowOpacity": 0.4, "shadowBlurFraction": 0.004},
         "start": {"rawValue": 0}, "end": {"rawValue": 1000000000}}
        """
        let item = try JSONDecoder().decode(AnnotationItem.self, from: Data(json.utf8))
        #expect(item.startX == 1 && item.startY == 0)
    }

    /// An annotation written before `animation` existed opens rather than failing. Those were
    /// drawn with a fade, so that is what they get.
    @Test func anAnnotationSavedBeforeAnimationsExistedStillOpens() throws {
        let json = """
        {"id": 3, "shape": "line", "startX": 0.1, "startY": 0.1, "endX": 0.2, "endY": 0.2,
         "style": {"strokeWidthFraction": 0.006, "red": 1, "green": 0, "blue": 0, "alpha": 1,
                   "fillOpacity": 0, "shadowOpacity": 0.4, "shadowBlurFraction": 0.004},
         "start": {"rawValue": 0}, "end": {"rawValue": 1000000000}}
        """
        let item = try JSONDecoder().decode(AnnotationItem.self, from: Data(json.utf8))
        #expect(item.animation == .fade)
    }

    /// A track written before `nextID` existed recovers one from its items — and recovers one
    /// PAST the highest, or the next annotation added would collide with an existing id.
    @Test func aTrackSavedBeforeNextIDExistedRecoversOnePastItsHighest() throws {
        let encoded = try JSONEncoder().encode(track())
        var object = try #require(try JSONSerialization.jsonObject(with: encoded)
                                  as? [String: Any])
        object.removeValue(forKey: "nextID")
        let without = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AnnotationTrack.self, from: without)
        #expect(decoded.nextID == 2)
        // `.max()`, not `.last`: `items` is kept sorted by start time, so an annotation added at
        // zero sorts to the FRONT. Reading it off the end of the array passed on this track and
        // would have passed on any track whose newest item happened to be its latest — which is
        // most of them, and none of them by design.
        let grown = decoded.adding(shape: .line, startX: 0, startY: 0, endX: 1, endY: 1,
                                   start: Nanoseconds(0), end: Nanoseconds(1))
        #expect(grown.items.map(\.id).max() == 2)
    }

    /// **`min(max(NaN, 0), 1)` is `NaN`.** The clamp expression every other style field uses does
    /// not catch it, which is why `AnnotationItem`'s is written out by hand — and 0.5 rather than
    /// 0, so a corrupt annotation is visible in the middle of the frame instead of parked in a
    /// corner where nobody looks for it.
    @Test func aNonFiniteCoordinateLandsInTheMiddleRatherThanPropagating() {
        let corrupt = AnnotationItem(id: 0, shape: .arrow,
                                     startX: .nan, startY: .infinity,
                                     endX: 0.5, endY: 0.5,
                                     start: Nanoseconds(0), end: Nanoseconds(Int64(second)))
        #expect(corrupt.startX == 0.5)
        // `.infinity` IS finite-checked too: the guard is `isFinite`, not `isNaN`.
        #expect(corrupt.startY == 0.5)
    }

    // MARK: - arriving and leaving

    /// Fully on in the middle, and the exit mirrors the entrance — a title that left differently
    /// from how it arrived would need a second animation nobody chose, and the same is true here.
    @Test func anAnnotationIsFullyOnInTheMiddleAndSymmetricAtItsEnds() {
        let item = AnnotationItem(id: 0, shape: .arrow, startX: 0, startY: 0, endX: 1, endY: 1,
                                  start: Nanoseconds(0), end: Nanoseconds(Int64(2 * second)),
                                  animation: .fade)
        #expect(item.animationState(at: Nanoseconds(Int64(second))).opacity == 1)
        let entering = item.animationState(at: Nanoseconds(Int64(0.1 * Double(second))))
        let leaving = item.animationState(at: Nanoseconds(Int64(1.9 * Double(second))))
        #expect(entering.opacity < 1 && entering.opacity > 0)
        #expect(abs(entering.opacity - leaving.opacity) < 0.001,
                "the exit is not the entrance run backwards")
    }

    /// A zero-length annotation has no animation to be part-way through, and dividing by its
    /// duration would produce a `NaN` opacity — which reads as fully transparent and would make
    /// the annotation silently absent rather than obviously wrong.
    @Test func aZeroDurationAnnotationIsSimplyOn() {
        let instant = AnnotationItem(id: 0, shape: .line, startX: 0, startY: 0, endX: 1, endY: 1,
                                     start: Nanoseconds(Int64(second)),
                                     end: Nanoseconds(Int64(second)))
        let state = instant.animationState(at: Nanoseconds(Int64(second)))
        #expect(state.opacity == 1 && state.scale == 1)
    }
}

// MARK: - a callout's words, on disk

/// Every annotation saved before callouts existed has no `text` key, and must still open.
@Test func anAnnotationSavedBeforeCalloutsExistedStillOpens() throws {
    let old = Data(#"""
        {"id":1,"shape":"arrow","startX":0.2,"startY":0.3,"endX":0.6,"endY":0.7,
         "style":{"strokeWidthFraction":0.006,"red":1,"green":0,"blue":0,"alpha":1,
                  "fillOpacity":0,"shadowOpacity":0,"shadowBlurFraction":0},
         "start":{"rawValue":0},"end":{"rawValue":1000000000}}
        """#.utf8)
    let decoded = try JSONDecoder().decode(AnnotationItem.self, from: old)
    #expect(decoded.text == "")
    #expect(decoded.shape == .arrow)
}

/// What somebody typed survives a save and an open — the round trip the encoder and decoder
/// are hand-written to keep.
@Test func aCalloutsWordsSurviveASave() throws {
    let callout = AnnotationItem(id: 3, shape: .callout, startX: 0.2, startY: 0.3,
                                 endX: 0.6, endY: 0.7, start: Nanoseconds(0),
                                 end: Nanoseconds(1_000_000_000), text: "按這裡 → Save")
    let reopened = try JSONDecoder().decode(AnnotationItem.self,
                                            from: try JSONEncoder().encode(callout))
    #expect(reopened.text == "按這裡 → Save")
    #expect(reopened.shape == .callout)
}

/// A picture's file name survives a save, and a project saved before pictures existed opens with
/// none — the `text` field's two rules, for the field added beside it.
@Test func anImageAnnotationKeepsItsPictureAcrossASaveAndOldProjectsOpenWithNone() throws {
    let item = AnnotationItem(id: 3, shape: .image, startX: 0.2, startY: 0.2, endX: 0.4, endY: 0.5,
                              start: Nanoseconds(0), end: Nanoseconds(1_000_000_000),
                              imageName: "logo.png")
    let decoded = try JSONDecoder().decode(AnnotationItem.self, from: try JSONEncoder().encode(item))
    #expect(decoded.imageName == "logo.png" && decoded.shape == .image)

    var legacy = try #require(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(item)) as? [String: Any])
    legacy["imageName"] = nil
    legacy["shape"] = "rectangle"
    let old = try JSONDecoder().decode(AnnotationItem.self, from: try JSONSerialization.data(withJSONObject: legacy))
    #expect(old.imageName == "")
}

// MARK: - step numbers

/// **Numbered by when they appear, not by when they were made.** The fixture adds the steps out of
/// time order, so "by id" and "by time" give different answers and only one of them passes.
/// `docs/design/2026-09-30-steps-and-highlights.md`.
@Suite struct StepNumberTests {
    private func at(_ seconds: Int64) -> Nanoseconds { Nanoseconds(seconds * 1_000_000_000) }

    private func track() -> AnnotationTrack {
        AnnotationTrack()
            .adding(shape: .step, startX: 0.1, startY: 0.1, endX: 0.2, endY: 0.2,
                    start: at(30), end: at(35))                                  // id 0
            .adding(shape: .arrow, startX: 0.1, startY: 0.1, endX: 0.4, endY: 0.4,
                    start: at(5), end: at(8))                                    // id 1
            .adding(shape: .step, startX: 0.3, startY: 0.3, endX: 0.4, endY: 0.4,
                    start: at(10), end: at(15))                                  // id 2
            .adding(shape: .step, startX: 0.5, startY: 0.5, endX: 0.6, endY: 0.6,
                    start: at(50), end: at(55))                                  // id 3
    }

    @Test func stepsAreNumberedInTheOrderTheyAppear() {
        let steps = track()
        #expect(steps.stepNumber(of: 2) == 1)
        #expect(steps.stepNumber(of: 0) == 2)
        #expect(steps.stepNumber(of: 3) == 3)
        // Not a step, so not counted and not numbered.
        #expect(steps.stepNumber(of: 1) == nil)
        #expect(steps.stepNumber(of: 99) == nil)
    }

    @Test func removingAStepRenumbersTheOnesAfterIt() {
        let steps = track().removing(2)
        #expect(steps.stepNumber(of: 0) == 1)
        #expect(steps.stepNumber(of: 3) == 2)
    }

    /// Two steps at one instant are still ordered, by id, so neither is ever "step 1" twice.
    @Test func twoStepsAtOneMomentAreStillTwoNumbers() {
        let steps = AnnotationTrack()
            .adding(shape: .step, startX: 0.1, startY: 0.1, endX: 0.2, endY: 0.2, start: at(7), end: at(9))
            .adding(shape: .step, startX: 0.3, startY: 0.3, endX: 0.4, endY: 0.4, start: at(7), end: at(9))
        #expect([steps.stepNumber(of: 0), steps.stepNumber(of: 1)] == [1, 2])
    }

    /// What the renderer is handed: a step's number, anything else its own words.
    @Test func whatIsDrawnInAStepIsItsNumber() throws {
        let steps = track()
        let step = try #require(steps.items.first { $0.id == 3 })
        let arrow = try #require(steps.items.first { $0.id == 1 })
        #expect(steps.drawnText(for: step) == "3")
        #expect(steps.drawnText(for: arrow) == arrow.text)
    }
}
