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
    #expect(track.position(at: Nanoseconds(400)) == .drawn(NormalizedPoint(x: 0.1, y: 0.1)))
}

@Test func aTimeInsideABlindIntervalReadsAsBlindAndCarriesTheCause() {
    let blind = BlindInterval(start: Nanoseconds(500), duration: Nanoseconds(300),
                              cause: .tapDisabled)
    let track = PointerTrack(samples: [sample(0, 0.1, 0.1), sample(1_000, 0.9, 0.9)],
                             blindIntervals: [blind], overrides: [])
    #expect(track.position(at: Nanoseconds(600)) == .blind(blind))
}

@Test func blindNeverDegradesToTheLastKnownPosition() {
    // `.blind` and `.drawn` are distinct cases so a gap cannot read as "the pointer
    // stayed there"; a hold-last-known implementation reddens this.
    let blind = BlindInterval(start: Nanoseconds(500), duration: Nanoseconds(300),
                              cause: .tapDisabled)
    let track = PointerTrack(samples: [sample(0, 0.1, 0.1)], blindIntervals: [blind], overrides: [])
    let reading = track.position(at: Nanoseconds(600))
    if case .drawn = reading { Issue.record("a blind interval produced a drawn position") }
}

@Test func anOverrideSuppressesTheCursorAndSaysSo() {
    let track = PointerTrack(samples: [sample(0, 0.1, 0.1)], blindIntervals: [],
                             overrides: [CursorOverride(epoch: epoch, start: Nanoseconds(0),
                                                        duration: Nanoseconds(1_000))])
    #expect(track.position(at: Nanoseconds(500)) == .suppressedByReviewer)
}

@Test func silenceBeforeTheFirstSampleIsNotBlindAndIsNotAPosition() {
    let track = PointerTrack(samples: [sample(1_000, 0.5, 0.5)], blindIntervals: [], overrides: [])
    #expect(track.position(at: Nanoseconds(0)) == .noObservationYet)
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
    let overlapping = Nanoseconds(600)
    let blind = BlindInterval(start: Nanoseconds(500), duration: Nanoseconds(300), cause: .tapDisabled)
    let override = CursorOverride(epoch: epoch, start: Nanoseconds(500), duration: Nanoseconds(300))
    // Sanity: the instant really does fall inside both intervals.
    #expect(blind.contains(overlapping))
    #expect(override.contains(overlapping))

    let track = PointerTrack(samples: [sample(0, 0.1, 0.1)], blindIntervals: [blind],
                             overrides: [override])
    #expect(track.position(at: overlapping) == .suppressedByReviewer)
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
