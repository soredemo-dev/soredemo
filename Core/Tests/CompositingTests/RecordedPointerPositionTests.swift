import Testing
import Foundation
import CoreMedia
import CoreVideo
// `NormalizedPoint`: the expected position is re-derived from the fixture's bytes here, not taken
// from the code under test.
import Geometry
import Framing
import Project
import Render
import Timeline
import Compositing

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
    ///
    /// **The placement is BOUNDED by the recording, not equal to it, since the presentation
    /// path became a spring** (`PointerPath`). A spring following a target moving at speed
    /// `s` trails it by at most `s × worstCaseLag`; that is the bound, with the speed
    /// re-derived from the fixture's own bracket samples. The bound is `s`-shaped on purpose:
    /// a resting pointer has `s = 0` and the assertion collapses back to equality within a
    /// pixel, so a wrong offset cannot hide behind the spring's tolerance at a still instant
    /// — and `aRestingPointerIsDrawnExactlyWhereItRests` below pins that case on its own.
    @Test func aPointerIsDrawnAtTheRecordedPosition() throws {
        let instants = try drawnInstants()
        let samples = try recordedPointerSamples()
        let card = stagePlan(pointer: nil).card
        // Composed once: the reference every tip below is measured against.
        let withoutPointer = try composedFrame(pointer: nil)
        // **Counted across the whole set, not required of each instant** — the first draft
        // asserted every one of the three smeared, and two of them do not: the search picks
        // instants for sample history, not for speed, and at this fixture's 640-wide stage a
        // cursor has to cross 0.32 of the recording per second to reach the smear threshold
        // at all. One that does is enough to keep the case below covered; none would mean the
        // smear had stopped being computed.
        var smearedInstants = 0

        for instant in instants {
            // The recording's own answer, re-derived from the fixture's bytes: the latest sample
            // at or before `anchor + offset`. A non-`nil` placement already excludes blindness
            // and overrides, so that is the whole rule that applies here.
            let reading = try #require(
                recordedReading(in: samples, atHostTime: instant.hostTime),
                "frame \(instant.frame): the log has no sample at or before this instant")
            let expectedX = card.x + reading.position.x * card.width
            let expectedY = card.y + reading.position.y * card.height
            // **Inside the box the pointer actually occupied recently, not within a
            // speed-derived tolerance.** Two earlier drafts bounded this by the spring's
            // steady-state trail, `speed × lag` — first from the instant's own bracket,
            // then from the peak over a settling window. Both are formulas for a target
            // already moving at a constant speed, and a spring is also still catching up
            // from whatever came before: measured on this fixture at frame 559, the
            // second draft allowed 8.08 px and the real displacement was 8.66. Widening
            // the multiplier until it fits is how a bound stops meaning anything.
            //
            // A spring's output is a weighted average of the targets it has chased, so it
            // cannot leave the region the target occupied except by its overshoot — which
            // at ζ = 0.9 is a couple of percent. So the invariant is: the drawn position
            // lies inside the box the RECORDING's own samples covered over the settling
            // window. That is speed-independent, collapses to a point when the cursor has
            // been still, and is exactly what a wrong mapping in `StagePlanner.placement`
            // — the thing this assertion exists to catch — would violate.
            let lag = PointerPath.Tuning.default.worstCaseLagSeconds
            let settling = Nanoseconds(Int64(lag * 4 * 1e9))
            let box = try #require(
                recordedBox(in: samples, endingAt: instant.hostTime, window: settling),
                "frame \(instant.frame): no samples in the settling window before it")
            // The overshoot allowance, plus two pixels for the stroke and the rounding.
            let slackX = (box.maxX - box.minX) * card.width * 0.05 + 2
            let slackY = (box.maxY - box.minY) * card.height * 0.05 + 2
            let lowX = card.x + box.minX * card.width - slackX
            let highX = card.x + box.maxX * card.width + slackX
            let lowY = card.y + box.minY * card.height - slackY
            let highY = card.y + box.maxY * card.height + slackY
            #expect(instant.placement.x >= lowX && instant.placement.x <= highX
                    && instant.placement.y >= lowY && instant.placement.y <= highY, """
                frame \(instant.frame) (\(reading.priorCount) of \(samples.count) samples lie at \
                or before it): the compositor placed the pointer at (\(instant.placement.x), \
                \(instant.placement.y)), outside the box its own samples covered over the \
                preceding \(lag * 4) s — x \(lowX)…\(highX), y \(lowY)…\(highY). The sample \
                the log selects at this instant is at (\(expectedX), \(expectedY)).
                """)

            // **Composed WITHOUT the smear, since 2026-08-25, and removing the confound is
            // the fix rather than budgeting for it.** `drawnTip` reads the min-x/max-y of
            // everything the pointer changed, which is the arrow's tip only while the arrow is
            // the whole of what was drawn. A moving cursor now trails (`cursorSmear`), and
            // `CIMotionBlur` spreads the drawing past the tip by more than its nominal radius
            // — measured here at 8.2 px against a 3.1 px projected radius, so a tolerance
            // derived from the radius does not bound it and one large enough to would stop
            // discriminating a misplaced cursor.
            //
            // This test is about GEOMETRY: that the renderer draws at the placement the
            // compositor returned. The smear is presentation, it is symmetric about that same
            // placement, and it has its own test (`theCursorSmearIsDrawnAndIsDirectional`
            // asserts it is drawn, and is directional). Taking it off the placement here
            // isolates the question this test asks; it does not weaken it, because a cursor
            // drawn in the wrong place is still wrong with the smear at zero.
            let unsmeared = NormalizedPointerPlacement(
                x: instant.placement.x, y: instant.placement.y,
                ripplePhase: instant.placement.ripplePhase, shape: instant.placement.shape,
                hotspot: instant.placement.hotspot, opacity: instant.placement.opacity,
                tiltDegrees: instant.placement.tiltDegrees)
            if instant.placement.smearRadius > 0 { smearedInstants += 1 }
            let withPointer = try composedFrame(pointer: unsmeared)
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
        #expect(smearedInstants > 0, """
            none of the \(instants.count) asserted instants smeared, so taking the smear off \
            the placement changed nothing and this test no longer covers the case it was \
            rewritten for. Either the threshold moved or cursorSmear stopped being computed.
            """)
    }
}

extension StageCompositorTests {
    /// **Where the recording's pointer has been still, the drawn pointer is exactly there.**
    /// The bound in `aPointerIsDrawnAtTheRecordedPosition` is zero at rest, but the three
    /// instants it asserts are chosen for sample history, not for stillness; this one is
    /// chosen for stillness, so the spring's equality case is pinned by a test that would
    /// go red on a constant offset however small the tolerance elsewhere.
    ///
    /// Still means one of two things, because the log's two eras record stillness
    /// differently. Before `PointerSampler`, the tap emitted only on motion, so a resting
    /// pointer is a SILENCE: the latest sample is at least `settleSeconds` old and the next
    /// one has not happened yet. Since the sampler, a resting pointer is a STREAM of
    /// positions within a tenth of a pixel of one another for the whole window. Either way
    /// the spring has had `settleSeconds` — long enough to converge from anywhere it could
    /// have been — and the drawn position must be the recorded one.
    @Test func aRestingPointerIsDrawnExactlyWhereItRests() throws {
        unsafe StageCompositor.observationLogURL = try recordedObservationLog()
        unsafe StageCompositor.overrides = []
        let compositor = StageCompositor()
        let plan = stagePlan(pointer: nil)
        let anchor = try recordedAnchor()
        let samples = try recordedPointerSamples()
            .sorted { $0.instant.hostTime.rawValue < $1.instant.hostTime.rawValue }
        let settleSeconds = 0.4
        let stillTolerance = 0.1 / min(plan.card.width, plan.card.height)

        var asserted = 0
        for frame in 0..<1800 {
            let time = CMTime(value: CMTimeValue(frame), timescale: 60)
            guard let offset = Nanoseconds(rationalSeconds: time.value, timescale: time.timescale)
            else { continue }
            let hostTime = anchor + offset
            guard let latest = samples.last(where: { $0.instant.hostTime.rawValue <= hostTime.rawValue })
            else { continue }
            let latestAge = Double(hostTime.rawValue - latest.instant.hostTime.rawValue) / 1e9
            // Every sample inside the settle window before the instant.
            let window = samples.filter {
                $0.instant.hostTime.rawValue <= hostTime.rawValue
                    && Double(hostTime.rawValue - $0.instant.hostTime.rawValue) / 1e9 <= settleSeconds
            }
            let silent = latestAge >= settleSeconds
            let streamed = window.count >= 3 && window.allSatisfy {
                abs($0.position.x - latest.position.x) < stillTolerance
                    && abs($0.position.y - latest.position.y) < stillTolerance
            }
            guard silent || streamed,
                  let placement = compositor.pointerPlacement(at: time, in: plan) else { continue }
            let expectedX = plan.card.x + latest.position.x * plan.card.width
            let expectedY = plan.card.y + latest.position.y * plan.card.height
            #expect(abs(placement.x - expectedX) < 1 && abs(placement.y - expectedY) < 1, """
                frame \(frame): the pointer had rested for \(settleSeconds) s at (\(expectedX), \
                \(expectedY)) and was drawn at (\(placement.x), \(placement.y))
                """)
            asserted += 1
            if asserted >= 5 { break }
        }
        #expect(asserted > 0, """
            the first 30 s of the fixture had no instant where the pointer rested for \
            \(settleSeconds) s with a sighted placement — the test asserted nothing
            """)
    }
}

/// The box the recording's own pointer samples covered over `window` ending at `time`, in
/// normalised coordinates — the region a spring chasing them cannot leave except by its
/// own small overshoot. `nil` when no sample falls in the window.
func recordedBox(in samples: [PointerSample], endingAt time: Nanoseconds,
                 window: Nanoseconds) -> (minX: Double, maxX: Double,
                                          minY: Double, maxY: Double)? {
    let start = time.rawValue - window.rawValue
    var inWindow = samples.filter {
        $0.instant.hostTime.rawValue >= start && $0.instant.hostTime.rawValue <= time.rawValue
    }
    // **Plus the sample being HELD when the window opened, which is the target's value
    // at that instant and not merely an older reading.** This fixture carries 149
    // tap-disabled windows: across one the target holds its last sample, and a spring
    // that set off when the gap closed is travelling from there. A box built only from
    // samples INSIDE the window excludes where the cursor legitimately came from, which
    // is how the first draft of this bound reported a placement 62 px outside a box it
    // had drawn around the destination alone.
    if let held = samples.last(where: { $0.instant.hostTime.rawValue <= start }) {
        inWindow.append(held)
    }
    guard let first = inWindow.first else { return nil }
    var box = (minX: first.position.x, maxX: first.position.x,
               minY: first.position.y, maxY: first.position.y)
    for sample in inWindow.dropFirst() {
        box.minX = min(box.minX, sample.position.x); box.maxX = max(box.maxX, sample.position.x)
        box.minY = min(box.minY, sample.position.y); box.maxY = max(box.maxY, sample.position.y)
    }
    return box
}

/// The recorded pointer's speed across the bracket at `time`, in normalised units per
/// second per axis — zero when held, exactly as `recordedReading` holds.
func recordedSpeed(in samples: [PointerSample],
                   atHostTime time: Nanoseconds) -> (x: Double, y: Double) {
    var latest: PointerSample?
    var next: PointerSample?
    for sample in samples {
        if sample.instant.hostTime.rawValue <= time.rawValue {
            if let current = latest,
               current.instant.hostTime.rawValue > sample.instant.hostTime.rawValue { continue }
            latest = sample
        } else if next == nil || sample.instant.hostTime.rawValue < next!.instant.hostTime.rawValue {
            next = sample
        }
    }
    guard let latest, let next else { return (0, 0) }
    let span = next.instant.hostTime.rawValue - latest.instant.hostTime.rawValue
    guard span > 0, span <= PointerTrack.maxInterpolationGap.rawValue else { return (0, 0) }
    let seconds = Double(span) / 1e9
    return (abs(next.position.x - latest.position.x) / seconds,
            abs(next.position.y - latest.position.y) / seconds)
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
    try CoreImageFrameRenderer().render(stagePlan(pointer: pointer), source: source, camera: nil, into: destination)
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
    // `internal`, so setting it would force `@testable import Compositing` here.
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
/// **Re-derives the RENDERING rule from the fixture's bytes, independently of
/// `PointerTrack`** — the same interpolate-or-hold the compositor uses since it switched to
/// `smoothedPosition(at:)` (recorder-parity, 2026-08-19). Independence is the point: this
/// function shares only the PUBLIC threshold constant with the implementation, so agreeing
/// on the threshold is what lets any other disagreement mean something. The fixture's 149
/// tap-disabled windows are already excluded by the search (a drawn placement excludes
/// blindness), so the blind-refusal branch needs no twin here.
func recordedReading(in samples: [PointerSample],
                     atHostTime time: Nanoseconds) -> (position: NormalizedPoint, priorCount: Int)? {
    var latest: PointerSample?
    var next: PointerSample?
    var priorCount = 0
    for sample in samples {
        if sample.instant.hostTime.rawValue <= time.rawValue {
            priorCount += 1
            if let current = latest,
               current.instant.hostTime.rawValue > sample.instant.hostTime.rawValue { continue }
            latest = sample
        } else if next == nil || sample.instant.hostTime.rawValue < next!.instant.hostTime.rawValue {
            next = sample
        }
    }
    guard let latest else { return nil }
    guard let next else { return (position: latest.position, priorCount: priorCount) }
    let span = next.instant.hostTime.rawValue - latest.instant.hostTime.rawValue
    guard span > 0, span <= PointerTrack.maxInterpolationGap.rawValue else {
        return (position: latest.position, priorCount: priorCount)
    }
    let fraction = Double(time.rawValue - latest.instant.hostTime.rawValue) / Double(span)
    let position = NormalizedPoint(
        x: latest.position.x + (next.position.x - latest.position.x) * fraction,
        y: latest.position.y + (next.position.y - latest.position.y) * fraction)
    return (position: position, priorCount: priorCount)
}

// MARK: - the zoom pipeline, against the same real recording

/// **End to end on the row-14 recording**: the log's own `axChain` lines through
/// `FramingGate`, `ZoomBlock` and `CameraMotion` to a `RenderPlan` the compositor would
/// draw. Until this landed, `axChain` was a line the writer had always written and nothing
/// had ever read — it fell through `buildTracks`' `default: break`.
///
/// The recording's three chains exercise three different outcomes, and the second one
/// corrected this test's own premise:
///
/// * 36.6 ms hit-test, `truncation == .hitTestReturnedNothing` — gate 1;
/// * 6.8 ms hit-test on an `AXGroup` covering 0.92 × 0.87 — **gate 3, `staleObservation`**.
///   This test first asserted `tooLarge`, reasoning from the area (0.80, past the 0.5
///   threshold). The area gate never runs: staleness is gate 3 and fires first, because the
///   read took 6.8 ms against a 4 ms budget. **The ordering claim from
///   `theEarliestApplicableGateIsTheReportedReason` turns out to matter on the very first
///   real recording it met**, and it is the more useful answer of the two — "the frame may
///   describe a window that has since moved" explains the refusal, where "it was big"
///   describes a rectangle that might not have been where AX said it was.
/// * 3.1 ms hit-test, `AXGroup` at area 0.27 — inside both budgets, accepted.
///
/// So exactly one click survives the gates, and the camera zooms once. Two uncalibrated
/// constants are doing real work here on real data, which is the first evidence either has
/// ever had.
@Test func theRecordingsAXChainsProduceExactlyOneZoom() throws {
    let decisions = try recordedAXChains().map { FramingGate.decide(for: $0) }
    #expect(decisions.count == 3, "the fixture's chain count changed — re-read this test's premise")

    let accepted = decisions.compactMap { decision -> FramingTarget? in
        if case .framed(let target) = decision { return target }
        return nil
    }
    #expect(accepted.count == 1, """
        expected one of the recording's three chains to pass the gates, got \(accepted.count). \
        Reasons: \(decisions.map { $0.rejection.map(\.rawValue) ?? "framed" }.joined(separator: ", "))
        """)
    #expect(decisions.contains { $0.rejection == .hitTestReturnedNothing })
    #expect(decisions.contains { $0.rejection == .staleObservation })
}

/// **The recording produces NO zoom, and that is the pipeline working.** This test first
/// asserted the camera zoomed past 1.2 somewhere; it does not, and the code is right.
///
/// The one chain that survives the gates frames an `AXGroup` 0.60 wide. `FramingDepth`'s
/// curve gives it 0.89, its own fit cap gives 1.0, and quantisation lands on **1.0 — no
/// zoom**. A 60%-wide group is not a control worth magnifying, which is the same judgement
/// `FramingGate.tooLarge` makes one threshold up. So the honest end-to-end assertion for
/// THIS recording is that the camera stays at rest while remaining well-defined — and that
/// a recording of someone clicking around a window chrome yields no zoom is a result about
/// the data, not a gap in the code.
///
/// **What this test therefore cannot show**, stated rather than left for a reader to
/// assume: that a zoom renders correctly end to end. Nothing committed here contains a
/// click on a small control. `zoomingTheContentMagnifiesWhatTheCameraIsCentredOn` covers
/// the rendering with a synthetic plan, and the missing piece is a recording — a person
/// clicking a button — which is a human step, not a fixture that can be written.
@Test func theRecordingsOneAcceptedClickIsTooBroadToZoomInto() throws {
    let chains = try recordedAXChains()
    let clicks = chains.compactMap { record -> FramedClick? in
        guard case .framed(let target) = FramingGate.decide(for: record) else { return nil }
        return FramedClick(instant: record.instant, target: target)
    }
    let blocks = ZoomBlock.blocks(for: clicks, coverage: 1)
    let block = try #require(blocks.first, "the pipeline produced no block at all")
    #expect(block.zoom == 1.0, """
        the accepted target is \(block.target.frame.size.width) wide and got depth \
        \(block.zoom) — this test's premise is that a group that broad is not worth \
        magnifying, so a change here is a change to FramingDepth's curve
        """)

    // Well-defined at rest is not the same as absent: sample across the block's own span
    // and the camera must be finite, at rest, and centred.
    let camera = CameraMotion(blocks: blocks)
    let anchorTime = try recordedAnchor()
    let epoch = try #require(chains.first?.instant.epoch)
    let from = Double(block.start.hostTime.rawValue - anchorTime.rawValue) / 1e9 - 1.0
    let to = Double(block.end.hostTime.rawValue - anchorTime.rawValue) / 1e9 + 4.0
    for seconds in stride(from: from, through: to, by: 1.0 / 30) {
        let instant = HostInstant(epoch: epoch,
                                  hostTime: Nanoseconds(anchorTime.rawValue
                                                        + Int64(seconds * 1_000_000_000)))
        let state = camera.state(at: instant)
        #expect(state.zoom.isFinite && state.zoom >= 1.0 && state.zoom < 1.01)
        #expect(state.centre.x.isFinite && state.centre.y.isFinite)
    }
}

/// Every `axChain` line in the fixture, decoded through the production reader.
func recordedAXChains() throws -> [AXChainRecord] {
    let url = try #require(Bundle.module.url(forResource: "segment-00-redacted",
                                             withExtension: "jsonl"))
    return try JSONLReader.linesOfFile(at: url).lines.compactMap { line in
        guard try ObservationLog.kind(of: line) == "axChain" else { return nil }
        return try ObservationLog.decode(line) as AXChainRecord
    }
}
