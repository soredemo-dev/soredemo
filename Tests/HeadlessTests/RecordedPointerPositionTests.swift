import Testing
import Foundation
import CoreMedia
import CoreVideo
// `NormalizedPoint`: the expected position is re-derived from the fixture's bytes here, not taken
// from the code under test.
import Geometry
import Project
import Render
import Timeline
import Headless

/// Positive-log pointer tests: a pointer is drawn, at the position a real recording's observation
/// log gives (the frame composed onto is synthesised — this asserts geometry, not depiction).
/// Must EXTEND `StageCompositorTests`: `.serialized` does not serialise sibling top-level suites,
/// so a new suite here would race `noConfiguredLogPlacesNoPointer` on the same statics.
extension StageCompositorTests {

    /// Layer 1: a pointer placement actually changes the composed pixels. Reddened by deleting
    /// `CoreImageFrameRenderer.render`'s `if let pointer = plan.pointer` block. The pointerless
    /// frame is composed twice first: without determinism the difference proves nothing.
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

    /// Layer 2: the pointer is drawn where the recording says. Two references, because either
    /// alone has a hole: the drawn tip against the returned placement, and the placement against
    /// the position re-read from the fixture's bytes — an offset inside `StagePlanner.placement`
    /// moves drawing and expectation together, and only the second assertion catches it.
    @Test func aPointerIsDrawnAtTheRecordedPosition() throws {
        let instants = try drawnInstants()
        let samples = try recordedPointerSamples()
        let card = stagePlan(pointer: nil).card
        // Composed once: the reference every tip below is measured against.
        let withoutPointer = try composedFrame(pointer: nil)

        for instant in instants {
            // The recording's own answer, re-derived from the fixture's bytes: the latest sample
            // at or before `anchor + offset`. A non-`nil` placement already excludes blindness
            // and overrides, so that is the whole rule that applies here.
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

            // Tolerance 3 px: the 1.5 px stroke, antialiasing, and integer pixel coordinates
            // against a fractional placement — together still far below any real misplacement.
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

/// 640×360; the source is the same size, so the card is the whole recording inset by 6 %.
let frameWidth = 640, frameHeight = 360

/// The plan both tests compose against: a 640×360 stage at `StageStyle.default`.
func stagePlan(pointer: NormalizedPointerPlacement?) -> RenderPlan {
    StagePlanner.plan(outputWidth: frameWidth, outputHeight: frameHeight,
                      sourceWidth: frameWidth, sourceHeight: frameHeight,
                      style: .default, pointer: pointer)
}

/// One composed frame from a `sourceFill` source through the production renderer. Needs a GPU:
/// with no Metal device this throws `FrameRenderingError.noRenderDevice` as a real failure.
func composedFrame(pointer: NormalizedPointerPlacement?) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
    let source = try makePixelBuffer(width: frameWidth, height: frameHeight, fill: sourceFill)
    let destination = try makePixelBuffer(width: frameWidth, height: frameHeight, fill: (0, 0, 0))
    try CoreImageFrameRenderer().render(stagePlan(pointer: pointer), source: source, into: destination)
    return try pixels(of: destination)
}

/// The TIP of whatever the pointer added to `frame`, in the plan's space, or `nil` if nothing.
/// The arrow extends toward +x and -y from its tip, so min-x/max-y IS the tip, not a centroid —
/// true only at rippleless instants, which is why the search requires `ripplePhase == nil`.
func drawnTip(of frame: [(r: UInt8, g: UInt8, b: UInt8)],
              against reference: [(r: UInt8, g: UInt8, b: UInt8)]) -> (x: Double, y: Double)? {
    // Buffer indices are row-major from the TOP; `RenderPlan` is bottom-left origin.
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

/// 4, not 1: with one candidate sample every selection rule agrees, so nothing is discriminated.
/// With four behind the instant and one ahead, `samples.first` and `samples.last` are both wrong.
let minimumPriorSamples = 4

/// Three, spread over start/middle/end of the qualifying set — three CONSECUTIVE frames would
/// usually resolve to the same sample and assert one thing three times.
let assertedInstantCount = 3

/// Instants where this recording really has a rippleless drawn pointer with enough history for
/// the selection rule to be under test. Searched for, never hardcoded: most of the timeline sits
/// inside tap-disabled windows, and `ripplePhase == nil` is required because a ripple is a ring
/// centred on the tip, so min-x/max-y inside one would be the ring's edge, not the arrow.
func drawnInstants() throws -> [DrawnInstant] {
    // `StageCompositor.style` is deliberately NOT set: only `startRequest` reads it and it is
    // `internal`, so setting it would force `@testable import Headless` here.
    unsafe StageCompositor.observationLogURL = try recordedObservationLog()
    unsafe StageCompositor.overrides = []
    let compositor = StageCompositor()

    let plan = stagePlan(pointer: nil)
    let anchor = try recordedAnchor()
    let samples = try recordedPointerSamples()

    var qualifying: [DrawnInstant] = []
    // 1/60 s steps across the first 10 s, using the same `CMTime` the render path is handed.
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
        // Counts measured at failure time: a regenerated, smaller fixture must not be
        // misreported as a broken conversion.
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

/// The redacted recording, declared as a resource of this test target in `Package.swift`.
func recordedObservationLog() throws -> URL {
    try #require(Bundle.module.url(forResource: "segment-00-redacted", withExtension: "jsonl"),
                 "the redacted fixture is not in the test bundle — check Package.swift's resources")
}

/// The header's `EpochAnchor.hostTime` — the origin `pointerPlacement` adds a composition offset
/// to. Read directly here, so the expectation does not borrow it from the code under test.
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

/// What the LOG says the pointer's position was at an absolute host time, plus the candidate
/// count — an independent restatement of `PointerTrack.position(at:)`'s rule once blindness and
/// overrides are excluded. `priorCount` is what the search filters on.
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
