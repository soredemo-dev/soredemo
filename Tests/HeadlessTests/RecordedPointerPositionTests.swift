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
/// assertion is about GEOMETRY, not about what the frame depicts. What stops this repeating
/// probe § 12 — whose fixture and code under test shared one wrong frame of reference and
/// cancelled each other out — is that the timestamps come from a recording made before the
/// conversion under test was written, and that the expected position below is re-derived
/// from those bytes independently of the code that produces the drawn one.
///
/// **These tests live in an extension of `StageCompositorTests`, and that is load-bearing.**
/// `StageCompositor`'s configuration (`observationLogURL`, `overrides`) is process-global
/// mutable state; `noConfiguredLogPlacesNoPointer` sets `observationLogURL = nil` and the
/// two tests below set it to the fixture. `.serialized` on a suite serialises that suite's
/// own tests — it does NOT serialise two sibling top-level suites against each other, and
/// Swift Testing runs those in parallel. A second `@Suite(.serialized)` struct in this file
/// would therefore still race `noConfiguredLogPlacesNoPointer` on the same static, and the
/// failure would be nondeterministic. Joining the existing serialized suite is what actually
/// removes the race; the file name says what these tests are, the suite says who they must
/// not overlap with.
extension StageCompositorTests {

    /// **Layer 1: something got drawn.** This is what a person already catches — the pointer
    /// being absent is exactly how `1a98402` was found — so it is asserted separately from
    /// position and never allowed to stand in for it.
    @Test func aPointerIsDrawnAtAll() throws {
        let found = try aCompositionTimeWithADrawnPointer()

        let withPointer = try composedFrame(pointer: found.placement)
        let withoutPointer = try composedFrame(pointer: nil)

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
    /// **Two assertions, against two independent references, because one of them alone has a
    /// hole.** The drawn tip is checked against the placement the compositor returned AND the
    /// placement is checked against the position re-read from the fixture's own bytes. Without
    /// the second, a defect that moved the placement itself — a swapped `x`/`y` inside
    /// `StagePlanner.placement`, say — would move the expectation and the drawing by the same
    /// amount and this test would stay green. That is the "fixture and code under test share
    /// one wrong frame of reference" shape, one layer up, and it is closed by deriving the
    /// expected point from the log rather than from the code that reads it.
    @Test func aPointerIsDrawnAtTheRecordedPosition() throws {
        let found = try aCompositionTimeWithADrawnPointer()
        let placement = found.placement

        // The recording's own answer for this instant, re-derived here from the fixture's
        // bytes: the latest pointer sample at or before `anchor + offset`. No blind-interval
        // logic is repeated — `pointerPlacement` returned non-`nil`, which by
        // `PointerTrack.position(at:)`'s own four-case contract means this instant is neither
        // blind nor suppressed, so "latest sample at or before" is the whole rule that applies.
        let recorded = try recordedPointerPosition(atHostTime: found.hostTime)
        let card = stagePlan(pointer: nil).card
        let expectedX = card.x + recorded.x * card.width
        let expectedY = card.y + recorded.y * card.height
        #expect(abs(placement.x - expectedX) < 0.001 && abs(placement.y - expectedY) < 0.001, """
            the compositor placed the pointer at (\(placement.x), \(placement.y)); the recorded \
            sample at this instant, read straight from the fixture, places it at \
            (\(expectedX), \(expectedY))
            """)

        let withPointer = try composedFrame(pointer: placement)
        let withoutPointer = try composedFrame(pointer: nil)

        // Indices of the changed pixels, converted back to the plan's own coordinate space:
        // the buffer is row-major from the TOP, `RenderPlan` is bottom-left origin.
        let width = frameWidth, height = frameHeight
        var xs: [Double] = [], ys: [Double] = []
        for (index, pair) in zip(withPointer, withoutPointer).enumerated() where pair.0 != pair.1 {
            xs.append(Double(index % width))
            ys.append(Double(height - 1 - index / width))
        }
        try #require(!xs.isEmpty, "nothing was drawn; aPointerIsDrawnAtAll covers that case")

        // The TIP, not the centroid. `CursorArt`'s outline puts the tip at the origin and
        // extends toward positive x and negative y, so the drawn mass sits below and right of
        // the recorded point — a centroid would be offset by half the arrow and the tolerance
        // would have to absorb it, which is a tolerance hiding a systematic error. The search
        // below guarantees `ripplePhase == nil` at this instant, which is what makes min-x /
        // max-y the ARROW's tip rather than the edge of a ring centred on it.
        let tipX = xs.min()!
        let tipY = ys.max()!

        // Tolerance: 3 px. Three effects, each under a pixel and a half: the arrow is stroked
        // (1.5 px wide, so half a stroke lies outside the filled outline) as well as filled,
        // antialiasing changes a pixel that the outline only partly covers, and a differing
        // pixel is reported at its integer column/row while the placement is fractional. 3 px
        // covers all three together and is far smaller than any misplacement worth catching —
        // a swapped x/y at 640×360 moves the tip by hundreds of pixels.
        #expect(abs(tipX - placement.x) < 3, """
            the drawn pointer's tip is at x = \(tipX); the recording places it at \(placement.x)
            """)
        #expect(abs(tipY - placement.y) < 3, """
            the drawn pointer's tip is at y = \(tipY); the recording places it at \(placement.y)
            """)
    }
}

// MARK: - the fixture, and the instant this test composes

/// The output frame both tests compose. 640×360, and the source is the same size so the card
/// is the whole recording letterboxed by `StageStyle.default`'s 6 % inset.
let frameWidth = 640, frameHeight = 360

/// The plan both tests compose against: a 640×360 stage at `StageStyle.default`.
func stagePlan(pointer: NormalizedPointerPlacement?) -> RenderPlan {
    StagePlanner.plan(outputWidth: frameWidth, outputHeight: frameHeight,
                      sourceWidth: frameWidth, sourceHeight: frameHeight,
                      style: .default, pointer: pointer)
}

/// The redacted recording, as `Bundle.module` resolves it — declared as a resource of this
/// test target in `Package.swift` (Task 5).
func recordedObservationLog() throws -> URL {
    try #require(Bundle.module.url(forResource: "segment-00-redacted", withExtension: "jsonl"),
                 "the redacted fixture is not in the test bundle — check Package.swift's resources")
}

/// A composition time at which the recording really does have a drawn pointer, the placement
/// the compositor produces there, and the absolute host time that instant maps to.
///
/// **Found by reading the log, never by a hardcoded index.** 149 of the fixture's 411 lines
/// are tap-disabled windows, and they are not a minority of the timeline: measured over the
/// first 600 frames of this recording, 504 are blind, 4 precede the first sample and only 92
/// yield a placement. A hardcoded offset would land in a blind window five times out of six,
/// `position(at:)` would return `.blind`, and this test would then pass or fail for a reason
/// with nothing to do with the clock conversion it exists to check. So the instant is searched
/// for, and the search reports what it found before anything else runs.
///
/// **`ripplePhase == nil` is part of what is searched for, and it is not a convenience.** A
/// click's ripple is a ring CENTRED on the tip that grows to a 28 px radius, so at an instant
/// inside one the minimum-x and maximum-y of the changed pixels are the ring's edge, not the
/// arrow's tip — the quantity layer 2 measures would silently stop being the quantity it
/// names. Choosing an instant where the measurement is well defined is not a weaker assertion;
/// asserting a tip against a ring would be a wrong one.
func aCompositionTimeWithADrawnPointer() throws
    -> (time: CMTime, hostTime: Nanoseconds, placement: NormalizedPointerPlacement) {
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
        return (time: time, hostTime: anchor + offset, placement: placement)
    }
    Issue.record("""
        no composition time in the first 10 s of the fixture produced a rippleless pointer \
        placement. The fixture carries 251 pointer samples, so this is the conversion failing, \
        not the recording being silent.
        """)
    throw CancellationError()
}

// MARK: - the recording's own answer, re-read from its bytes

/// The observation log header's `EpochAnchor.hostTime` — the origin `pointerPlacement` adds a
/// composition offset to. Read here directly, so the expected position below does not borrow
/// the value from the code under test.
func recordedAnchor() throws -> Nanoseconds {
    let lines = try JSONLReader.linesOfFile(at: try recordedObservationLog()).lines
    for line in lines {
        guard try ObservationLog.kind(of: line) == "logHeader" else { continue }
        return (try ObservationLog.decode(line) as ObservationLogHeader).anchor.hostTime
    }
    Issue.record("the fixture has no logHeader line, so it carries no anchor to convert against")
    throw CancellationError()
}

/// The position the LOG says the pointer was at, at an absolute host time: the latest
/// `pointer` record at or before it. An independent restatement of the one rule
/// `PointerTrack.position(at:)` applies once blindness and reviewer overrides are excluded —
/// and they are excluded here by construction, because the caller only reaches this after
/// `pointerPlacement` has already returned a placement rather than `nil`.
func recordedPointerPosition(atHostTime time: Nanoseconds) throws -> NormalizedPoint {
    let lines = try JSONLReader.linesOfFile(at: try recordedObservationLog()).lines
    var latest: PointerSample?
    for line in lines {
        guard try ObservationLog.kind(of: line) == "pointer" else { continue }
        let sample = try ObservationLog.decode(line) as PointerSample
        guard sample.instant.hostTime.rawValue <= time.rawValue else { continue }
        if let current = latest, current.instant.hostTime.rawValue > sample.instant.hostTime.rawValue {
            continue
        }
        latest = sample
    }
    let sample = try #require(latest, """
        no pointer record in the fixture is at or before the instant the compositor drew at. \
        The compositor placed a pointer where the log has nothing to place one from.
        """)
    return sample.position
}

// MARK: - the composed frame

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
