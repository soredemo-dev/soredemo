import Testing
import Foundation
import CoreMedia
import CoreVideo
// `NormalizedPoint` — the log's own coordinate space, named directly here because the expected
// position is re-derived from the fixture's bytes rather than taken from the code under test.
import Geometry
import Project
import Render
import Timeline
import Headless

/// **The instrument that reaches the code only a person reached.**
///
/// `1a98402` lived in `StageCompositor.pointerPlacement` for a whole phase: a COMPOSITION
/// time (0 at the first frame) was compared against samples stamped in the ABSOLUTE host
/// clock (~5.2 × 10¹⁴), so `sample.instant.hostTime <= time` was false for every sample of
/// every recording, `.noObservationYet` came back on every frame, and no build of this app
/// had ever drawn a pointer — through 450 tests, 350 probe checks, eight task reviews and
/// fifteen fix rounds. It was found by a person recording four seconds and looking.
///
/// **Observations recorded, source frame constructed.** The input is the REAL recording's
/// observation log, redacted by schema: 411 lines, 251 pointer samples, 149 tap-disabled
/// windows, 6 button events, an authorisation flip mid-session. Every timestamp and every
/// coordinate this test consumes was written by the real `ObservationWriter` through the
/// real capture path, before this test existed — only `AXElementRecord.title` was replaced,
/// and nothing the compositor reads was touched. The fixture carries no media (the 29 MB
/// `.mov` is correctly excluded from the repository), so the frame those observations are
/// composed ONTO is synthesised here, filled with `sourceFill`. That is deliberate: the
/// assertion is about GEOMETRY, not about what the frame depicts.
///
/// **What the re-read below is independent OF, stated narrowly — code review, item 5.** The
/// expected position is re-derived from the fixture's bytes rather than taken from the code
/// that produces the drawn one, and what that buys is calibrated: it catches a defect in the
/// SAMPLE-SELECTION rule and in the normalised→output-pixel CARD MAPPING (mutation B′ in this
/// task's report reddens exactly there). It does NOT make the two paths disjoint. Both go
/// through `JSONLReader.linesOfFile`, `ObservationLog.kind`/`decode`, the same read of the
/// header's `EpochAnchor`, and `Nanoseconds(rationalSeconds:timescale:)` — each unit-tested in
/// its own target, none of them re-implemented here. What is NOT shared is the CALL: this file
/// converts the frame index through its own `Nanoseconds(rationalSeconds:timescale:)`
/// invocation and adds the anchor itself, so a wrong conversion at `pointerPlacement`'s own
/// call site diverges from the expectation rather than moving with it. That is what stops this
/// repeating probe § 12, whose fixture and code under test shared one wrong frame of reference
/// and cancelled each other out.
///
/// **These tests live in an extension of `StageCompositorTests`, and that is load-bearing.**
/// `StageCompositor`'s configuration (`observationLogURL`, `overrides`) is process-global
/// mutable state; `noConfiguredLogPlacesNoPointer` sets `observationLogURL = nil` and the
/// tests below set it to the fixture. `.serialized` on a suite serialises that suite's own
/// tests — it does NOT serialise two sibling top-level suites against each other, and Swift
/// Testing runs those in parallel. A second `@Suite(.serialized)` struct in this file would
/// therefore still race `noConfiguredLogPlacesNoPointer` on the same static, and the failure
/// would be nondeterministic. Joining the existing serialized suite is what actually removes
/// the race; the file name says what these tests are, the suite says who they must not
/// overlap with.
extension StageCompositorTests {

    /// **Layer 1: something got drawn.** This is what a person already catches — the pointer
    /// being absent is exactly how `1a98402` was found — so it is asserted separately from
    /// position and never allowed to stand in for it.
    ///
    /// **Its own red has been observed, and NOT through the search — code review, item 1.**
    /// The `1a98402` revert reddens this test inside `drawnInstants()` (no instant yields a
    /// placement at all), so that mutation calibrates the SEARCH and leaves the
    /// pixel-difference expectation below unevaluated. The mutation that calibrates *this
    /// expectation* is deleting `CoreImageFrameRenderer.render`'s `if let pointer =
    /// plan.pointer { … }` block: the placement still exists, the search still succeeds, the
    /// composition still succeeds, and the two frames come back byte-identical. Observed, on
    /// this line; recorded in this task's report.
    ///
    /// **The determinism control is the first assertion, not a nicety.** "The pointer changed
    /// the frame" only follows from two differing frames if composing the SAME plan twice gives
    /// the same bytes. Under a nondeterministic renderer the expectation below would pass while
    /// measuring nothing — a green that means nothing is this branch's own signature failure —
    /// so the pointerless frame is composed twice and required to be identical first.
    @Test func aPointerIsDrawnAtAll() throws {
        let instant = try drawnInstants()[0]

        let withoutPointer = try composedFrame(pointer: nil)
        let withoutPointerAgain = try composedFrame(pointer: nil)
        try #require(withoutPointer.elementsEqual(withoutPointerAgain, by: ==), """
            composing the SAME pointerless plan twice produced two different frames. The \
            renderer is not deterministic here, so a difference between two frames cannot be \
            attributed to the pointer and the expectation below would pass while measuring \
            nothing.
            """)

        let withPointer = try composedFrame(pointer: instant.placement)
        let differing = zip(withPointer, withoutPointer).filter { $0 != $1 }
        #expect(!differing.isEmpty, """
            composing with a pointer placement produced a frame identical to composing without \
            one. Nothing was drawn. This is the shape of 1a98402: the placement existed and the \
            pixels did not change.
            """)
    }

    /// **Layer 2: it got drawn where the recording says.** The capability this test claims.
    ///
    /// Its calibrating mutation is NOT the `let time = offset` revert — that one makes the
    /// compositor draw nothing at all, which layer 1 already covers — but a mutation that can
    /// only misplace. Both are recorded in this task's report.
    ///
    /// **Two references, because one of them alone has a hole.** The drawn tip is checked
    /// against the placement the compositor returned AND the placement is checked against the
    /// position re-read from the fixture's own bytes. Without the second, a defect that moved
    /// the placement itself — a constant offset inside `StagePlanner.placement`, say — would
    /// move the expectation and the drawing by the same amount and this test would stay green.
    /// Measured: it does exactly that, and only the second assertion catches it.
    ///
    /// **Several instants, because one instant was the degenerate one — code review, item 2.**
    /// The first drawn frame of this recording (frame 4) has exactly ONE pointer sample at or
    /// before it, so "latest sample at or before" is a rule every other selection rule agrees
    /// with there: a `PointerTrack` that returned `samples.first` would have stayed green. The
    /// instants below are required to have at least `minimumPriorSamples` samples behind them
    /// and at least one ahead, so `samples.first` and `samples.last` are both wrong answers at
    /// every one of them, and they are drawn from the two ends and the middle of the qualifying
    /// span rather than from three consecutive frames sharing one sample.
    @Test func aPointerIsDrawnAtTheRecordedPosition() throws {
        let instants = try drawnInstants()
        let samples = try recordedPointerSamples()
        let card = stagePlan(pointer: nil).card
        // Composed once: the pointerless frame is the same for every instant, and it is the
        // reference every tip below is measured against.
        let withoutPointer = try composedFrame(pointer: nil)

        for instant in instants {
            // The recording's own answer for this instant, re-derived from the fixture's bytes:
            // the latest pointer sample at or before `anchor + offset`. No blind-interval logic
            // is repeated — `pointerPlacement` returned non-`nil`, which by
            // `PointerTrack.position(at:)`'s own four-case contract means this instant is
            // neither blind nor suppressed, so "latest sample at or before" is the whole rule
            // that applies.
            let reading = try #require(
                recordedReading(in: samples, atHostTime: instant.hostTime),
                "frame \(instant.frame): the log has no sample at or before this instant")
            let expectedX = card.x + reading.position.x * card.width
            let expectedY = card.y + reading.position.y * card.height
            #expect(abs(instant.placement.x - expectedX) < 0.001
                    && abs(instant.placement.y - expectedY) < 0.001, """
                frame \(instant.frame) (\(reading.priorCount) of \(samples.count) samples lie at \
                or before it): the compositor placed the pointer at (\(instant.placement.x), \
                \(instant.placement.y)); the sample the log selects at this instant places it at \
                (\(expectedX), \(expectedY))
                """)

            let withPointer = try composedFrame(pointer: instant.placement)
            let tip = try #require(
                drawnTip(of: withPointer, against: withoutPointer),
                "frame \(instant.frame): nothing was drawn; aPointerIsDrawnAtAll covers that case")

            // Tolerance: 3 px. Three effects, each under a pixel and a half: the arrow is
            // stroked (1.5 px wide, so half a stroke lies outside the filled outline) as well
            // as filled, antialiasing changes a pixel that the outline only partly covers, and
            // a differing pixel is reported at its integer column/row while the placement is
            // fractional. 3 px covers all three together and is far smaller than any
            // misplacement worth catching — a swapped x/y at 640×360 moves the tip by hundreds
            // of pixels.
            #expect(abs(tip.x - instant.placement.x) < 3, """
                frame \(instant.frame): the drawn pointer's tip is at x = \(tip.x); the \
                recording places it at \(instant.placement.x)
                """)
            #expect(abs(tip.y - instant.placement.y) < 3, """
                frame \(instant.frame): the drawn pointer's tip is at y = \(tip.y); the \
                recording places it at \(instant.placement.y)
                """)
        }
    }
}

// MARK: - the frame both tests compose

/// The output frame both tests compose. 640×360, and the source is the same size so the card
/// is the whole recording letterboxed by `StageStyle.default`'s 6 % inset.
let frameWidth = 640, frameHeight = 360

/// The plan both tests compose against: a 640×360 stage at `StageStyle.default`.
func stagePlan(pointer: NormalizedPointerPlacement?) -> RenderPlan {
    StagePlanner.plan(outputWidth: frameWidth, outputHeight: frameHeight,
                      sourceWidth: frameWidth, sourceHeight: frameHeight,
                      style: .default, pointer: pointer)
}

/// One composed frame, from a source filled with `sourceFill` (dark saturated blue — see
/// `PixelBufferSupport.swift` for why it must contrast with the white-filled, black-stroked
/// arrow), through the production renderer.
///
/// **This test needs a GPU**, which is why `HeadlessTests` is a separate population. On a
/// machine with no Metal device `CoreImageFrameRenderer.init` throws
/// `FrameRenderingError.noRenderDevice`, and that propagates out of here as a real failure
/// rather than a silent skip.
func composedFrame(pointer: NormalizedPointerPlacement?) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
    let source = try makePixelBuffer(width: frameWidth, height: frameHeight, fill: sourceFill)
    let destination = try makePixelBuffer(width: frameWidth, height: frameHeight, fill: (0, 0, 0))
    try CoreImageFrameRenderer().render(stagePlan(pointer: pointer), source: source, into: destination)
    return try pixels(of: destination)
}

/// The TIP of whatever the pointer added to `frame`, in the plan's own coordinate space, or
/// `nil` if it added nothing at all.
///
/// **The tip, not the centroid.** `CursorArt`'s outline puts the tip at the origin and extends
/// toward positive x and negative y, so the drawn mass sits below and right of the recorded
/// point: minimum x and maximum y ARE the tip. A centroid would be offset by half the arrow and
/// the tolerance would have to absorb it, which is a tolerance hiding a systematic error. The
/// search's `ripplePhase == nil` requirement is what keeps this true — a ripple is a ring
/// centred on the tip, and min-x/max-y inside one belong to the ring, not the arrow.
func drawnTip(of frame: [(r: UInt8, g: UInt8, b: UInt8)],
              against reference: [(r: UInt8, g: UInt8, b: UInt8)]) -> (x: Double, y: Double)? {
    // The changed pixels' indices, converted back to the plan's own coordinate space: the
    // buffer is row-major from the TOP, `RenderPlan` is bottom-left origin.
    var minX: Double?, maxY: Double?
    for (index, pair) in zip(frame, reference).enumerated() where pair.0 != pair.1 {
        let x = Double(index % frameWidth)
        let y = Double(frameHeight - 1 - index / frameWidth)
        if minX == nil || x < minX! { minX = x }
        if maxY == nil || y > maxY! { maxY = y }
    }
    guard let minX, let maxY else { return nil }
    return (x: minX, y: maxY)
}

// MARK: - the instants this test composes, found by reading the log

/// A composition time at which the recording really does have a drawn pointer, and the
/// placement the compositor produces there.
struct DrawnInstant {
    let frame: Int
    let time: CMTime
    let hostTime: Nanoseconds
    let placement: NormalizedPointerPlacement
}

/// How many pointer samples must lie at or before an instant before it is worth asserting at.
///
/// **1 is the degenerate case, and that is why this number is not 1 — code review, item 2.** At
/// this recording's first drawn frame exactly one sample is a candidate, so `PointerTrack`'s
/// "latest at or before" rule and every other selection rule (`samples.first`, nearest,
/// anything) return the same answer there, and the re-read below can discriminate none of them.
/// With four samples behind the instant and at least one ahead of it, `samples.first` and
/// `samples.last` are both wrong answers, and the assertion measures the rule instead of
/// agreeing with it.
let minimumPriorSamples = 4

/// How many instants the position test asserts at. Three, taken from the start, the middle and
/// the end of the qualifying set — three CONSECUTIVE frames would usually resolve to the same
/// sample and assert one thing three times.
let assertedInstantCount = 3

/// Instants at which this recording really does have a rippleless drawn pointer with enough
/// history behind it for the selection rule to be under test.
///
/// **Found by reading the log, never by a hardcoded index.** 149 of the fixture's 411 lines are
/// tap-disabled windows, and they are not a minority of the timeline: measured over the first
/// 600 frames of this recording, 504 are blind, 4 precede the first sample and only 92 yield a
/// placement. A hardcoded offset would land in a blind window five times out of six,
/// `position(at:)` would return `.blind`, and this test would then pass or fail for a reason
/// with nothing to do with the clock conversion it exists to check. So the instants are
/// searched for, and the search reports what it found before anything else runs.
///
/// **`ripplePhase == nil` is part of what is searched for, and it is not a convenience.** A
/// click's ripple is a ring CENTRED on the tip that grows to a 28 px radius, so at an instant
/// inside one the minimum-x and maximum-y of the changed pixels are the ring's edge, not the
/// arrow's tip — the quantity layer 2 measures would silently stop being the quantity it names.
/// Choosing instants where the measurement is well defined is not a weaker assertion; asserting
/// a tip against a ring would be a wrong one.
func drawnInstants() throws -> [DrawnInstant] {
    // `observationLogURL`/`overrides` are `nonisolated(unsafe)` for the reason their own
    // declarations give (published before playback starts, read by any `StageCompositor`
    // instance). `unsafe` here states that shape at this call site, exactly as
    // `noConfiguredLogPlacesNoPointer` already does for the same two statics; this suite is
    // `.serialized`, which is what makes "published before it is read" true between tests.
    // `StageCompositor.style` is deliberately NOT set: it is read only by `startRequest`, which
    // no test can call, and it is `internal` — setting it would force `@testable import
    // Headless` and cost this file the plain `import Headless` the phase's completion condition
    // is written in terms of.
    unsafe StageCompositor.observationLogURL = try recordedObservationLog()
    unsafe StageCompositor.overrides = []
    let compositor = StageCompositor()

    let plan = stagePlan(pointer: nil)
    let anchor = try recordedAnchor()
    let samples = try recordedPointerSamples()

    var qualifying: [DrawnInstant] = []
    // Walk forward in 1/60 s steps across the first 10 s of the recording. `CMTime(value:
    // timescale:)` is what `AVAsynchronousVideoCompositionRequest.compositionTime` carries, and
    // `pointerPlacement` converts it through `Nanoseconds(rationalSeconds:timescale:)` — the
    // same arithmetic on the same types the render path uses, not a stand-in for it.
    for frame in 0..<600 {
        let time = CMTime(value: CMTimeValue(frame), timescale: 60)
        guard let placement = compositor.pointerPlacement(at: time, in: plan),
              placement.ripplePhase == nil else { continue }
        let offset = try #require(Nanoseconds(rationalSeconds: time.value, timescale: time.timescale),
                                  "frame \(frame) at timescale 60 has no nanosecond form")
        let hostTime = anchor + offset
        guard let reading = recordedReading(in: samples, atHostTime: hostTime),
              reading.priorCount >= minimumPriorSamples,
              reading.priorCount < samples.count else { continue }
        qualifying.append(DrawnInstant(frame: frame, time: time, hostTime: hostTime,
                                       placement: placement))
    }

    guard qualifying.count >= assertedInstantCount else {
        // The counts are MEASURED at failure time, not asserted in prose — code review, item 4.
        // A hardcoded "the fixture carries 251 pointer samples" would confidently misattribute a
        // regenerated, smaller fixture's genuine silence to a broken conversion, which is the
        // exact confusion this message exists to prevent.
        Issue.record("""
            the first 10 s of the fixture yielded \(qualifying.count) instants with a rippleless \
            drawn pointer and at least \(minimumPriorSamples) samples behind it; \
            \(assertedInstantCount) are needed. The fixture carries \(samples.count) pointer \
            records in total — if that number is large, this is the conversion failing; if it is \
            small, the recording is too short or too sparse for this test and the FIXTURE is what \
            needs revisiting.
            """)
        throw CancellationError()
    }
    // The start, the middle and the end of the qualifying span.
    return [qualifying[0], qualifying[qualifying.count / 2], qualifying[qualifying.count - 1]]
}

// MARK: - the recording's own answer, re-read from its bytes

/// The redacted recording, as `Bundle.module` resolves it — declared as a resource of this test
/// target in `Package.swift` (Task 5).
func recordedObservationLog() throws -> URL {
    try #require(Bundle.module.url(forResource: "segment-00-redacted", withExtension: "jsonl"),
                 "the redacted fixture is not in the test bundle — check Package.swift's resources")
}

/// The observation log header's `EpochAnchor.hostTime` — the origin `pointerPlacement` adds a
/// composition offset to. Read here directly, so the expected position below does not borrow the
/// value from the code under test.
func recordedAnchor() throws -> Nanoseconds {
    let lines = try JSONLReader.linesOfFile(at: try recordedObservationLog()).lines
    for line in lines {
        guard try ObservationLog.kind(of: line) == "logHeader" else { continue }
        return (try ObservationLog.decode(line) as ObservationLogHeader).anchor.hostTime
    }
    Issue.record("the fixture has no logHeader line, so it carries no anchor to convert against")
    throw CancellationError()
}

/// Every `pointer` record in the fixture, in file order.
func recordedPointerSamples() throws -> [PointerSample] {
    let lines = try JSONLReader.linesOfFile(at: try recordedObservationLog()).lines
    var samples: [PointerSample] = []
    for line in lines {
        guard try ObservationLog.kind(of: line) == "pointer" else { continue }
        samples.append(try ObservationLog.decode(line) as PointerSample)
    }
    return samples
}

/// The position the LOG says the pointer was at, at an absolute host time, and how many samples
/// were candidates for it. An independent restatement of the one rule
/// `PointerTrack.position(at:)` applies once blindness and reviewer overrides are excluded — and
/// they are excluded by construction at every call site here, because the instant has already
/// produced a placement rather than `nil`.
///
/// `priorCount` is what makes the restatement worth having: at an instant with one candidate
/// every selection rule agrees, so the count is what the search filters on.
func recordedReading(in samples: [PointerSample],
                     atHostTime time: Nanoseconds) -> (position: NormalizedPoint, priorCount: Int)? {
    var latest: PointerSample?
    var priorCount = 0
    for sample in samples {
        guard sample.instant.hostTime.rawValue <= time.rawValue else { continue }
        priorCount += 1
        if let current = latest, current.instant.hostTime.rawValue > sample.instant.hostTime.rawValue {
            continue
        }
        latest = sample
    }
    guard let latest else { return nil }
    return (position: latest.position, priorCount: priorCount)
}
