import Testing
import Foundation
import Geometry
import Timeline
import Project
@testable import Render

// `BootEpoch`'s only initialiser is `init(id: UUID)`, so fixtures use a fixed UUID.
private let epoch = BootEpoch(id: UUID(uuidString: "9B1DE104-6C3E-4E2A-8B3C-2B6A6F1F9C07")!)
private func at(_ ns: Int64) -> HostInstant { HostInstant(epoch: epoch, hostTime: Nanoseconds(ns)) }
private func sample(_ ns: Int64, _ x: Double, _ y: Double) -> PointerSample {
    PointerSample(instant: at(ns), position: NormalizedPoint(x: x, y: y),
                  revision: GeometryRevision(id: 1))
}

@Test func aPositionBetweenTwoSamplesComesFromTheEarlierOne() {
    let track = PointerTrack(samples: [sample(0, 0.1, 0.1), sample(1_000, 0.9, 0.9)],
                             blindIntervals: [], overrides: [])
    #expect(track.position(at: at(400)) == .drawn(NormalizedPoint(x: 0.1, y: 0.1), shape: nil))
}

@Test func aTimeInsideABlindIntervalReadsAsBlindAndCarriesTheCause() {
    let blind = BlindInterval(start: Nanoseconds(500), duration: Nanoseconds(300),
                              cause: .tapDisabled)
    let track = PointerTrack(samples: [sample(0, 0.1, 0.1), sample(1_000, 0.9, 0.9)],
                             blindIntervals: [blind], overrides: [])
    #expect(track.position(at: at(600)) == .blind(blind))
}

@Test func blindNeverDegradesToTheLastKnownPosition() {
    // `.blind` and `.drawn` are distinct cases so a gap cannot read as "the pointer
    // stayed there"; a hold-last-known implementation reddens this.
    let blind = BlindInterval(start: Nanoseconds(500), duration: Nanoseconds(300),
                              cause: .tapDisabled)
    let track = PointerTrack(samples: [sample(0, 0.1, 0.1)], blindIntervals: [blind], overrides: [])
    let reading = track.position(at: at(600))
    if case .drawn = reading { Issue.record("a blind interval produced a drawn position") }
}

@Test func anOverrideSuppressesTheCursorAndSaysSo() {
    let track = PointerTrack(samples: [sample(0, 0.1, 0.1)], blindIntervals: [],
                             overrides: [CursorOverride(epoch: epoch, start: Nanoseconds(0),
                                                        duration: Nanoseconds(1_000))])
    #expect(track.position(at: at(500)) == .suppressedByReviewer)
}

@Test func silenceBeforeTheFirstSampleIsNotBlindAndIsNotAPosition() {
    let track = PointerTrack(samples: [sample(1_000, 0.5, 0.5)], blindIntervals: [], overrides: [])
    #expect(track.position(at: at(0)) == .noObservationYet)
}

@Test func theBlindFractionIsOverTheSpanAskedAbout() {
    let track = PointerTrack(
        samples: [sample(0, 0.1, 0.1)],
        blindIntervals: [BlindInterval(start: Nanoseconds(200), duration: Nanoseconds(300),
                                       cause: .tapDisabled)],
        overrides: [])
    #expect(track.blindFraction(over: Nanoseconds(0) ..< Nanoseconds(1_000)) == 0.3)
}

/// Precedence at the overlap: one instant covered by BOTH a `CursorOverride` and a
/// `BlindInterval`. Checking the blind list first reddens only this test.
@Test func anOverrideOutranksAnOverlappingBlindInterval() {
    let overlapping = Nanoseconds(600)  // the raw instant, shared by both interval sanity checks
    let blind = BlindInterval(start: Nanoseconds(500), duration: Nanoseconds(300), cause: .tapDisabled)
    let override = CursorOverride(epoch: epoch, start: Nanoseconds(500), duration: Nanoseconds(300))
    // Sanity: the instant really does fall inside both intervals.
    #expect(blind.contains(overlapping))
    #expect(override.contains(overlapping))

    let track = PointerTrack(samples: [sample(0, 0.1, 0.1)], blindIntervals: [blind],
                             overrides: [override])
    #expect(track.position(at: at(overlapping.rawValue)) == .suppressedByReviewer)
}

/// `blindFraction(over:)`'s clamp path, which every test above leaves unexercised.
/// Two intervals each cross one edge of the 1000ns span, contributing 600 + 200 = 800ns
/// → 0.8; deleting the clamp sums their un-clamped widths and exceeds 1.0.
@Test func blindFractionClampsIntervalsThatCrossTheSpansEdges() {
    let startsBeforeTheSpan = BlindInterval(start: Nanoseconds(-400), duration: Nanoseconds(1_000),
                                            cause: .tapDisabled)
    let endsAfterTheSpan = BlindInterval(start: Nanoseconds(800), duration: Nanoseconds(700),
                                         cause: .secureInput)
    let track = PointerTrack(samples: [sample(0, 0.1, 0.1)],
                             blindIntervals: [startsBeforeTheSpan, endsAfterTheSpan], overrides: [])
    let fraction = track.blindFraction(over: Nanoseconds(0) ..< Nanoseconds(1_000))
    #expect(abs(fraction - 0.8) < 0.0001)
    #expect(fraction <= 1.0)
}

// MARK: - epoch mismatch: another boot session's data answers nothing here
//
// Two boots produce overlapping host times, so without these checks a number from
// another session matches by coincidence — `1a98402`'s failure surface, one domain
// over. Skip, not trap: a recording can legitimately span a reboot, so "another
// epoch" is a data condition (`HostRange.contains` draws the same line), and the
// reading cases keep the silence loud.

private let otherEpoch = BootEpoch(id: UUID(uuidString: "0BADC0DE-0000-4000-8000-000000000001")!)

/// The behaviour change `CursorOverride.epoch`'s own doc comment promised when it
/// was added "while zero files exist": an override recorded against another boot
/// session must not suppress this one's cursor.
@Test func anOverrideFromAnotherEpochDoesNotSuppress() {
    let track = PointerTrack(samples: [sample(0, 0.1, 0.1)], blindIntervals: [],
                             overrides: [CursorOverride(epoch: otherEpoch, start: Nanoseconds(0),
                                                        duration: Nanoseconds(1_000))])
    #expect(track.position(at: at(500)) == .drawn(NormalizedPoint(x: 0.1, y: 0.1), shape: nil))
}

/// A sample stamped in another boot session is not "the most recent sample" of this
/// one, even when its raw host time is smaller — overlapping host times across boots
/// is the whole reason `HostInstant` carries an epoch.
@Test func aSampleFromAnotherEpochIsNotDrawn() {
    let foreign = PointerSample(instant: HostInstant(epoch: otherEpoch, hostTime: Nanoseconds(100)),
                                position: NormalizedPoint(x: 0.9, y: 0.9),
                                revision: GeometryRevision(id: 1))
    let track = PointerTrack(samples: [foreign], blindIntervals: [], overrides: [])
    #expect(track.position(at: at(500)) == .noObservationYet)
}

// MARK: - decode validation
//
// Synthesised `Decodable` bypasses the validating memberwise `init`, so an
// out-of-invariant value read off disk would decode and only trap later. The JSON is
// hand-built because `init` traps before such a value could be encoded. `.dataCorrupted`
// specifically: a bare `precondition` would trap and synthesised `Codable` would not
// throw at all.

/// A `BlindInterval` with `duration` hand-edited negative.
@Test func decodingABlindIntervalWithNegativeDurationThrows() throws {
    let json = Data("""
    {"start":{"rawValue":0},"duration":{"rawValue":-1},"cause":"tapDisabled"}
    """.utf8)
    do {
        _ = try JSONDecoder().decode(BlindInterval.self, from: json)
        Issue.record("expected decoding a negative-duration BlindInterval to throw")
    } catch let error as DecodingError {
        guard case .dataCorrupted = error else {
            Issue.record("expected .dataCorrupted (BlindInterval's own validation), got \(error)")
            return
        }
    } catch {
        Issue.record("expected DecodingError, got \(error)")
    }
}

/// The same guard for `CursorOverride`, with `duration` hand-edited negative.
@Test func decodingACursorOverrideWithNegativeDurationThrows() throws {
    let json = Data("""
    {"epoch":{"id":"9B1DE104-6C3E-4E2A-8B3C-2B6A6F1F9C07"},\
    "start":{"rawValue":0},"duration":{"rawValue":-1}}
    """.utf8)
    do {
        _ = try JSONDecoder().decode(CursorOverride.self, from: json)
        Issue.record("expected decoding a negative-duration CursorOverride to throw")
    } catch let error as DecodingError {
        guard case .dataCorrupted = error else {
            Issue.record("expected .dataCorrupted (CursorOverride's own validation), got \(error)")
            return
        }
    } catch {
        Issue.record("expected DecodingError, got \(error)")
    }
}

/// Codable round trip for `BlindInterval`.
@Test func blindIntervalRoundTrips() throws {
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    let interval = BlindInterval(start: Nanoseconds(500), duration: Nanoseconds(300),
                                 cause: .secureInput)
    let back = try JSONDecoder().decode(BlindInterval.self, from: try enc.encode(interval))
    #expect(back == interval)
    #expect(back.start == interval.start)
    #expect(back.duration == interval.duration)
    #expect(back.cause == interval.cause)
}

/// Codable round trip for `CursorOverride`.
@Test func cursorOverrideRoundTrips() throws {
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    let override = CursorOverride(epoch: epoch, start: Nanoseconds(10), duration: Nanoseconds(20))
    let back = try JSONDecoder().decode(CursorOverride.self, from: try enc.encode(override))
    #expect(back == override)
    #expect(back.start == override.start)
    #expect(back.duration == override.duration)
}


/// A `CursorOverride` that omits its clock domain must be rejected, not read under
/// whatever the reader assumes. `.keyNotFound` is asserted specifically, distinct from
/// the `.dataCorrupted` above; changing `decode` to `decodeIfPresent` reddens this.
@Test func decodingACursorOverrideWithoutAnEpochThrows() throws {
    let json = Data("""
    {"start":{"rawValue":0},"duration":{"rawValue":1}}
    """.utf8)
    do {
        _ = try JSONDecoder().decode(CursorOverride.self, from: json)
        Issue.record("expected decoding an epoch-less CursorOverride to throw — an override with no clock domain is exactly the shape that reintroduces commit 1a98402")
    } catch let error as DecodingError {
        guard case .keyNotFound(let key, _) = error, key.stringValue == "epoch" else {
            Issue.record("expected .keyNotFound(\"epoch\"), got \(error)")
            return
        }
    } catch {
        Issue.record("expected DecodingError, got \(error)")
    }
}


// MARK: - the shape flows from the sample to the reading

/// The reading's shape is the MATCHED sample's, not the newest sample's or a constant —
/// two samples with different shapes, queried between and after, come back with each
/// sample's own. A track that hardcoded `.arrow` or always took the last sample's shape
/// reddens on one of the two instants.
@Test func theReadingCarriesTheMatchedSamplesOwnShape() {
    let iBeamThenHand = PointerTrack(samples: [
        PointerSample(instant: at(100), position: NormalizedPoint(x: 0.1, y: 0.1),
                      revision: GeometryRevision(id: 1), shape: PointerShape.iBeam),
        PointerSample(instant: at(1_000), position: NormalizedPoint(x: 0.9, y: 0.9),
                      revision: GeometryRevision(id: 1), shape: PointerShape.pointingHand),
    ], blindIntervals: [], overrides: [])
    #expect(iBeamThenHand.position(at: at(500))
            == .drawn(NormalizedPoint(x: 0.1, y: 0.1), shape: .iBeam))
    #expect(iBeamThenHand.position(at: at(2_000))
            == .drawn(NormalizedPoint(x: 0.9, y: 0.9), shape: .pointingHand))
}

// MARK: - smoothedPosition: the rendering path may be gentle; the review path may not

/// Halfway between two samples, the smoothed position is halfway between them — on both
/// axes, with different deltas so a lerp of x alone cannot pass. The STEPWISE reading at
/// the same instant is the earlier sample, and the test asserts both, because the split
/// into two queries is the design: `position(at:)` answering differently from
/// `smoothedPosition(at:)` between samples is the feature, not a discrepancy.
@Test func theSmoothedPositionIsTheLerpAndTheStepwiseReadingIsNot() {
    let track = PointerTrack(samples: [
        PointerSample(instant: at(0), position: NormalizedPoint(x: 0.0, y: 0.0),
                      revision: GeometryRevision(id: 1), shape: PointerShape.iBeam),
        PointerSample(instant: at(1_000), position: NormalizedPoint(x: 0.2, y: 0.4),
                      revision: GeometryRevision(id: 1), shape: PointerShape.arrow),
    ], blindIntervals: [], overrides: [])

    guard case .drawn(let smoothed, let shape) = track.smoothedPosition(at: at(500)) else {
        Issue.record("the smoothed reading between two samples was not drawn at all")
        return
    }
    #expect(abs(smoothed.x - 0.1) < 0.000001 && abs(smoothed.y - 0.2) < 0.000001,
            "expected the midpoint (0.1, 0.2), got (\(smoothed.x), \(smoothed.y))")
    // The shape is the EARLIER sample's — shapes are identities and do not blend.
    #expect(shape == .iBeam)
    // And the review path still steps.
    #expect(track.position(at: at(500)) == .drawn(NormalizedPoint(x: 0.0, y: 0.0), shape: .iBeam))
}

/// At a sample's own instant the lerp degenerates to that sample exactly — the endpoint
/// identity that keeps `RecordedPointerPositionTests`' searched instants meaningful.
@Test func theSmoothedPositionAtASampleInstantIsThatSample() {
    let track = PointerTrack(samples: [
        PointerSample(instant: at(0), position: NormalizedPoint(x: 0.0, y: 0.0),
                      revision: GeometryRevision(id: 1)),
        PointerSample(instant: at(1_000), position: NormalizedPoint(x: 0.2, y: 0.4),
                      revision: GeometryRevision(id: 1)),
    ], blindIntervals: [], overrides: [])
    #expect(track.smoothedPosition(at: at(1_000))
            == .drawn(NormalizedPoint(x: 0.2, y: 0.4), shape: nil))
}

/// A stationary pointer emits no samples, so a long gap between brackets means THE POINTER
/// WAS STILL — lerping across it would invent a slow drift the user never made. Past the
/// gap threshold the smoothed reading holds the earlier sample, exactly like the stepwise
/// one. The two instants differ only in which side of the threshold their gap falls.
@Test func aGapWiderThanTheThresholdIsHeldNotDrifted() {
    let justInside = PointerTrack.maxInterpolationGap.rawValue - 2
    let justOutside = PointerTrack.maxInterpolationGap.rawValue + 2
    func track(gap: Int64) -> PointerTrack {
        PointerTrack(samples: [
            PointerSample(instant: at(0), position: NormalizedPoint(x: 0.0, y: 0.0),
                          revision: GeometryRevision(id: 1)),
            PointerSample(instant: at(gap), position: NormalizedPoint(x: 0.2, y: 0.2),
                          revision: GeometryRevision(id: 1)),
        ], blindIntervals: [], overrides: [])
    }
    guard case .drawn(let lerped, _) = track(gap: justInside).smoothedPosition(at: at(justInside / 2))
    else { Issue.record("no reading inside the threshold"); return }
    #expect(lerped.x > 0.05, "inside the threshold the position should interpolate")

    guard case .drawn(let held, _) = track(gap: justOutside).smoothedPosition(at: at(justOutside / 2))
    else { Issue.record("no reading outside the threshold"); return }
    #expect(held == NormalizedPoint(x: 0.0, y: 0.0),
            "across a wider-than-threshold gap the pointer was STILL — holding is the truth")
}

/// A blind interval between the brackets refuses the lerp even when the queried instant
/// itself is sighted: motion invented across a span the tap could not see is exactly the
/// "looks fine" the review path's rule exists to refuse, and smoothing does not get to
/// reintroduce it from the other side.
@Test func theLerpRefusesToCrossABlindInterval() {
    let blind = BlindInterval(start: Nanoseconds(400), duration: Nanoseconds(200),
                              cause: .tapDisabled)
    let track = PointerTrack(samples: [
        PointerSample(instant: at(0), position: NormalizedPoint(x: 0.0, y: 0.0),
                      revision: GeometryRevision(id: 1)),
        PointerSample(instant: at(1_000), position: NormalizedPoint(x: 0.2, y: 0.2),
                      revision: GeometryRevision(id: 1)),
    ], blindIntervals: [blind], overrides: [])
    // 300 is sighted; the span 0…1000 crosses the blindness.
    #expect(track.smoothedPosition(at: at(300))
            == .drawn(NormalizedPoint(x: 0.0, y: 0.0), shape: nil))
    // And AT a blind instant the precedence is untouched.
    #expect(track.smoothedPosition(at: at(500)) == .blind(blind))
}

/// Past the last sample there is nothing to interpolate toward; the smoothed reading is
/// the stepwise one, and before the first there is nothing at all.
@Test func theSmoothedPositionDegradesToStepwiseAtTheTracksEdges() {
    let track = PointerTrack(samples: [
        PointerSample(instant: at(1_000), position: NormalizedPoint(x: 0.5, y: 0.5),
                      revision: GeometryRevision(id: 1)),
    ], blindIntervals: [], overrides: [])
    #expect(track.smoothedPosition(at: at(2_000))
            == .drawn(NormalizedPoint(x: 0.5, y: 0.5), shape: nil))
    #expect(track.smoothedPosition(at: at(0)) == .noObservationYet)
}
