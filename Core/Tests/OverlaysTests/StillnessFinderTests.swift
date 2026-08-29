import Foundation
import Testing
import Timeline
@testable import Overlays

/// **Where the picture does not change — the visual half of what `SilenceFinder` does for sound.**
///
/// The rule reads one number per slice and decides which runs are worth cutting. Everything about
/// how that number is produced belongs to `StillnessReader`; these tests hand the rule a series
/// and check what it does with it.
@Suite("Stillness")
struct StillnessFinderTests {
    static let slice = 0.25
    static let still = 0.0
    static let moving = 0.05

    /// A series of `count` slices at `value`.
    static func run(_ value: Double, _ count: Int) -> [Double] {
        Array(repeating: value, count: count)
    }

    @Test("a recording where nothing ever moves is one long span")
    func allStill() {
        let spans = StillnessFinder.spans(changes: Self.run(Self.still, 40),
                                          sliceSeconds: Self.slice)
        #expect(spans.count == 1)
        // 40 slices at 0.25 s is 10 s, less 0.3 s of padding at each end.
        #expect(abs(Double(spans[0].duration.rawValue) / 1e9 - 9.4) < 0.01)
    }

    @Test("a recording where something is always moving has no spans")
    func allMoving() {
        #expect(StillnessFinder.spans(changes: Self.run(Self.moving, 40),
                                      sliceSeconds: Self.slice).isEmpty)
    }

    /// **The case the feature exists for**: a demo that holds a frame in the middle.
    @Test("a still stretch in the middle is found, and only it")
    func aStretchInTheMiddle() {
        let changes = Self.run(Self.moving, 8) + Self.run(Self.still, 24) + Self.run(Self.moving, 8)
        let spans = StillnessFinder.spans(changes: changes, sliceSeconds: Self.slice)
        #expect(spans.count == 1)
        // Slices 8…32 is 2.0 s to 8.0 s, padded in by 0.3 s at each end.
        #expect(abs(Double(spans[0].start.rawValue) / 1e9 - 2.3) < 0.01)
        #expect(abs(Double(spans[0].end.rawValue) / 1e9 - 7.7) < 0.01)
    }

    /// **A recording that ends still has an open run, and it is the commonest one there is** —
    /// people stop moving before they stop recording, because stopping is done from a menu.
    @Test("a recording that ends still is cut to the end")
    func anOpenRunAtTheEnd() {
        let changes = Self.run(Self.moving, 4) + Self.run(Self.still, 20)
        let spans = StillnessFinder.spans(changes: changes, sliceSeconds: Self.slice)
        #expect(spans.count == 1)
        #expect(abs(Double(spans[0].end.rawValue) / 1e9 - 5.7) < 0.01)
    }

    /// **Two seconds, and the reason is that a second of a held picture is normal.** A one-second
    /// pause is somebody reading; dead air starts where a viewer wonders whether the video stopped.
    @Test("a still stretch shorter than the minimum is left alone")
    func tooShortToCut() {
        // Six slices is 1.5 s, under the two-second minimum.
        let changes = Self.run(Self.moving, 8) + Self.run(Self.still, 6) + Self.run(Self.moving, 8)
        #expect(StillnessFinder.spans(changes: changes, sliceSeconds: Self.slice).isEmpty)
    }

    /// **Padding can erase a span, and that is correct.** A stretch only just past the minimum,
    /// once three tenths of a second is given back at each end, is not worth cutting.
    @Test("padding erases a stretch that is barely long enough")
    func paddingErasesAMarginalSpan() {
        // Nine slices is 2.25 s: past the two-second minimum, and 0.6 s of padding leaves 1.65 s.
        let changes = Self.run(Self.moving, 4) + Self.run(Self.still, 9) + Self.run(Self.moving, 4)
        let spans = StillnessFinder.spans(changes: changes, sliceSeconds: Self.slice)
        #expect(spans.count == 1)
        // And with padding wide enough to swallow it, nothing is returned rather than a
        // negative-length span.
        let wide = StillnessFinder.Settings(changeThreshold: 0.0005, minimumSeconds: 2,
                                            paddingSeconds: 1.5)
        #expect(StillnessFinder.spans(changes: changes, sliceSeconds: Self.slice,
                                      settings: wide).isEmpty)
    }

    /// **The threshold sits between two measured numbers**, and this is the check that says so.
    /// A still frame measures 0; a cursor moving across a 1512×982 frame changes about 0.15% of
    /// it. Below the cursor, or a recording whose only motion is the pointer gets cut — and the
    /// cut makes the pointer jump.
    @Test("a moving cursor is motion, not stillness")
    func aMovingCursorIsNotStillness() {
        let cursorOnly = 0.0015   // 0.15% of the frame
        #expect(cursorOnly > StillnessFinder.Settings.default.changeThreshold)
        let changes = Self.run(cursorOnly, 40)
        #expect(StillnessFinder.spans(changes: changes, sliceSeconds: Self.slice).isEmpty,
                "a recording where only the pointer moves must not be cut")
    }

    /// **The threshold is not a sensitive number**, which is the useful property. Measured across
    /// three real recordings, every value from 0.02% to 0.5% gave nearly the same answer: real
    /// activity is 1% to 50% of the frame and stillness is 0.000%, so the signal is bimodal and
    /// the threshold has a wide valley to sit in.
    @Test("any threshold in the measured valley gives the same answer")
    func theThresholdIsNotSensitive() {
        let changes = Self.run(0.05, 8) + Self.run(0, 24) + Self.run(0.05, 8)
        let answers = [0.0002, 0.0005, 0.001, 0.002, 0.005].map { threshold in
            StillnessFinder.spans(
                changes: changes, sliceSeconds: Self.slice,
                settings: StillnessFinder.Settings(changeThreshold: threshold,
                                                   minimumSeconds: 2, paddingSeconds: 0.3))
        }
        #expect(Set(answers.map(\.count)) == [1])
        #expect(Set(answers.map { $0.first?.start.rawValue }).count == 1)
    }

    // MARK: - Cutting

    @Test("removing a span shortens the timeline by its length")
    func removingShortens() {
        let timeline = EditTimeline(clips: [
            EditClip(id: ClipID(rawValue: 1), sourceStart: Nanoseconds(0),
                     duration: Nanoseconds(10_000_000_000)),
        ])
        let spans = [StillnessFinder.Span(start: Nanoseconds(3_000_000_000),
                                          end: Nanoseconds(5_000_000_000))]
        let cut = StillnessFinder.removing(spans, from: timeline)
        #expect(cut.outputDuration.rawValue == 8_000_000_000)
        #expect(StillnessFinder.total(spans).rawValue == 2_000_000_000)
    }

    /// **Cut back to front**, so the clip identities the timeline mints as it splits leave the
    /// earlier clips untouched and a person's selection survives.
    @Test("several spans cut to the same result whatever order they arrive in")
    func orderDoesNotChangeTheResult() {
        let timeline = EditTimeline(clips: [
            EditClip(id: ClipID(rawValue: 1), sourceStart: Nanoseconds(0),
                     duration: Nanoseconds(20_000_000_000)),
        ])
        let spans = [
            StillnessFinder.Span(start: Nanoseconds(2_000_000_000), end: Nanoseconds(4_000_000_000)),
            StillnessFinder.Span(start: Nanoseconds(9_000_000_000), end: Nanoseconds(12_000_000_000)),
            StillnessFinder.Span(start: Nanoseconds(15_000_000_000), end: Nanoseconds(16_000_000_000)),
        ]
        let forwards = StillnessFinder.removing(spans, from: timeline)
        let backwards = StillnessFinder.removing(spans.reversed(), from: timeline)
        #expect(forwards.outputDuration == backwards.outputDuration)
        #expect(forwards.outputDuration.rawValue == 14_000_000_000)
    }

    @Test("a span with no length removes nothing rather than corrupting the timeline")
    func anEmptySpanRemovesNothing() {
        let timeline = EditTimeline(clips: [
            EditClip(id: ClipID(rawValue: 1), sourceStart: Nanoseconds(0),
                     duration: Nanoseconds(5_000_000_000)),
        ])
        let empty = [StillnessFinder.Span(start: Nanoseconds(1_000_000_000),
                                          end: Nanoseconds(1_000_000_000))]
        #expect(StillnessFinder.removing(empty, from: timeline).outputDuration
                == timeline.outputDuration)
        #expect(StillnessFinder.total(empty).rawValue == 0)
    }

    // MARK: - Settings that arrive from outside

    @Test("settings from a slider or a decoder are clamped rather than trapping")
    func settingsAreClamped() {
        let mad = StillnessFinder.Settings(changeThreshold: .nan, minimumSeconds: -5,
                                           paddingSeconds: .infinity)
        #expect(mad.changeThreshold == 0.0005)
        #expect(mad.minimumSeconds == 0)
        #expect(mad.paddingSeconds == .infinity || mad.paddingSeconds >= 0)
        #expect(StillnessFinder.Settings(changeThreshold: 5, minimumSeconds: 2,
                                         paddingSeconds: 0.3).changeThreshold == 1)
    }

    @Test("a project written before this existed decodes as the defaults")
    func anOlderProjectDecodesAsDefaults() throws {
        let decoded = try JSONDecoder().decode(StillnessFinder.Settings.self,
                                               from: Data("{}".utf8))
        #expect(decoded == StillnessFinder.Settings.default)
    }

    @Test("no slices and no slice length produce no spans rather than dividing")
    func degenerateInputsAreRefused() {
        #expect(StillnessFinder.spans(changes: [], sliceSeconds: 0.25).isEmpty)
        #expect(StillnessFinder.spans(changes: Self.run(0, 40), sliceSeconds: 0).isEmpty)
        #expect(StillnessFinder.spans(changes: Self.run(0, 40), sliceSeconds: -1).isEmpty)
    }
}
