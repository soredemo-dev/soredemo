import Testing
import Foundation
import Geometry
import Timeline
import Project
@testable import Render

// The brief (task-2-brief.md Step 1) writes `BootEpoch(rawValue: 7)`, but `BootEpoch`'s only
// initialiser is `init(id: UUID)` (Sources/Timeline/BootEpoch.swift:19) — there is no
// `rawValue` member. Every other test in the tree constructs one from a fixed UUID
// (e.g. Tests/TimelineTests/EpochTests.swift), so this file follows that convention instead.
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
    // The whole point of the policy: `.blind` and `.drawn` are different cases, so a caller
    // cannot accidentally treat a gap as "the pointer stayed there". A test that only checked
    // "some position came back" would pass under hold-last-known, which is the rejected option.
    let blind = BlindInterval(start: Nanoseconds(500), duration: Nanoseconds(300),
                              cause: .tapDisabled)
    let track = PointerTrack(samples: [sample(0, 0.1, 0.1)], blindIntervals: [blind], overrides: [])
    let reading = track.position(at: Nanoseconds(600))
    if case .drawn = reading { Issue.record("a blind interval produced a drawn position") }
}

@Test func anOverrideSuppressesTheCursorAndSaysSo() {
    let track = PointerTrack(samples: [sample(0, 0.1, 0.1)], blindIntervals: [],
                             overrides: [CursorOverride(start: Nanoseconds(0),
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

/// **Precedence, tested at the overlap: a reviewer's decision outranks a measured gap.**
///
/// `position(at:)` checks `overrides` before `blindIntervals` (`PointerTrack.swift`'s own doc
/// comment on the method), but until now every test exercised the two lists separately — an
/// instant either fell inside an override or inside a blind interval, never both. This is the
/// instant Task 2's reviewer asked for: one moment covered by BOTH a `CursorOverride` and a
/// `BlindInterval`, so the precedence itself is what is under test, not merely that either case
/// works in isolation. A `position(at:)` that checked the blind list first would return
/// `.blind(...)` here and this is the only test that would notice.
@Test func anOverrideOutranksAnOverlappingBlindInterval() {
    let overlapping = Nanoseconds(600)
    let blind = BlindInterval(start: Nanoseconds(500), duration: Nanoseconds(300), cause: .tapDisabled)
    let override = CursorOverride(start: Nanoseconds(500), duration: Nanoseconds(300))
    // Sanity: the chosen instant really does fall inside both intervals — otherwise this test
    // would pass by construction rather than by exercising the precedence.
    #expect(blind.contains(overlapping))
    #expect(override.contains(overlapping))

    let track = PointerTrack(samples: [sample(0, 0.1, 0.1)], blindIntervals: [blind],
                             overrides: [override])
    #expect(track.position(at: overlapping) == .suppressedByReviewer)
}

/// **`blindFraction(over:)`'s clamp path.** Every test above this one keeps the blind interval
/// entirely inside the queried span, so `max(interval.start, span.lowerBound)` and
/// `min(interval.end, span.upperBound)` never actually move either bound — the clamp could be
/// deleted and these tests would not notice. Two intervals here are each clamped on exactly one
/// side: one starts 400ns before the 1000ns span and should count only the 600ns that falls
/// inside it; the other ends 500ns after the span and should count only the 200ns that falls
/// inside it. Total blind time inside the span is 600 + 200 = 800ns of 1000ns → 0.8. A fraction
/// above 1.0 (summing the intervals' own, un-clamped widths: 1000 + 700 = 1700ns) is exactly the
/// bug this test exists to catch.
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

// MARK: - decode validation (rule 8)
//
// Same reasoning and same shape as `StagePlannerTests`'s `StageRect`/`StageStyle` decode-guard
// tests: the synthesised `Decodable` for a type whose memberwise `init` carries a `precondition`
// would assign stored properties directly and never call that `init`, so an out-of-invariant
// value read off disk would decode successfully and only trap later, far from where it was
// read. These decode a hand-built JSON literal carrying a negative duration — not a value
// encoded and re-decoded, because that route is closed: the memberwise `init` traps before such
// a value could ever be constructed to encode in the first place. Asserts `.dataCorrupted`
// specifically, for the same reason: only that is proof the hand-written validation ran and
// rejected the value, rather than the type falling back to a bare `precondition` (which would
// trap the process, not throw) or to fully-synthesised `Codable` (which would decode
// successfully and never throw at all).

/// `BlindInterval`'s own `encode(to:)` output for
/// `BlindInterval(start: Nanoseconds(0), duration: Nanoseconds(1), cause: .tapDisabled)`
/// (`Nanoseconds` has no custom `Codable`, so it nests as `{"rawValue":N}` — see
/// `HostRange`'s `decodingANegativeDurationHostRangeThrows` for the same shape), confirmed
/// against a scratch build of the type, with `duration` then hand-edited negative.
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

/// `CursorOverride`'s own `encode(to:)` output for
/// `CursorOverride(start: Nanoseconds(0), duration: Nanoseconds(1))` (`Nanoseconds` nests as
/// `{"rawValue":N}`, as above), confirmed against a scratch build of the type, with `duration`
/// then hand-edited negative.
@Test func decodingACursorOverrideWithNegativeDurationThrows() throws {
    let json = Data("""
    {"start":{"rawValue":0},"duration":{"rawValue":-1}}
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

/// Codable round trip for `BlindInterval`, because everything that carries one is expected to
/// travel intact through the same encoder every persisted document uses.
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
    let override = CursorOverride(start: Nanoseconds(10), duration: Nanoseconds(20))
    let back = try JSONDecoder().decode(CursorOverride.self, from: try enc.encode(override))
    #expect(back == override)
    #expect(back.start == override.start)
    #expect(back.duration == override.duration)
}
