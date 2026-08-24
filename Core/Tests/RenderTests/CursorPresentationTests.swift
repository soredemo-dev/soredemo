import Testing
import Foundation
import Geometry
import Timeline
import Project
@testable import Render

// The three cursor-presentation rules that came with the 2026-08-25 design audit: the idle
// fade, the lean, and shake removal. Each is a pure function here; the pixels are checked in
// `CompositingTests`.

private let epoch = BootEpoch(id: UUID(uuidString: "1D1E0000-0000-4000-8000-0000000000AA")!)
private func at(_ seconds: Double) -> HostInstant {
    HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64(seconds * 1_000_000_000)))
}
private func sample(_ seconds: Double, _ x: Double, _ y: Double) -> PointerSample {
    PointerSample(instant: at(seconds), position: NormalizedPoint(x: x, y: y),
                  revision: GeometryRevision(id: 1))
}

// MARK: - the idle fade

/// A move, two seconds of rest, then a move: drawn while moving, drawn through the delay,
/// gone after the fade, and back BEFORE the next move — the look-ahead is what keeps a hidden
/// cursor from appearing already in motion.
@Test func theIdleFadeHidesAStillCursorAndReturnsItBeforeItMoves() {
    var samples = (0...30).map { sample(Double($0) / 60, 0.2 + Double($0) * 0.01, 0.5) }
    // A resting stream at 60 Hz — `PointerSampler`'s floor — for 3 s, sub-pixel wobble and all.
    let restStart = 0.5, restEnd = 3.5
    for i in 0..<180 {
        let wobble = (i % 2 == 0 ? 1.0 : -1.0) * 0.1 / 2160
        samples.append(sample(restStart + Double(i) / 60, 0.5 + wobble, 0.5))
    }
    samples += (0...30).map { sample(restEnd + Double($0) / 60, 0.5 + Double($0) * 0.01, 0.5) }
    let track = PointerTrack(samples: samples, blindIntervals: [], overrides: [])
    let delay = 1.0

    #expect(track.idleOpacity(at: at(0.25), hideAfter: delay) == 1, "moving, but faded")
    #expect(track.idleOpacity(at: at(restStart + 0.9), hideAfter: delay) == 1,
            "inside the delay, but faded")
    #expect(track.idleOpacity(at: at(restStart + delay + PointerTrack.idleFadeSeconds + 0.1),
                              hideAfter: delay) == 0, "past the fade, but drawn")
    let midFade = track.idleOpacity(at: at(restStart + delay + PointerTrack.idleFadeSeconds / 2),
                                    hideAfter: delay)
    #expect(midFade > 0.3 && midFade < 0.7, "halfway through the fade the opacity is \(midFade)")
    // The look-ahead: a tenth of a second before motion resumes, most of the way back.
    let beforeResume = track.idleOpacity(at: at(restEnd + 1.0 / 60 - 0.1), hideAfter: delay)
    #expect(beforeResume > 0.5, "just before the next move the cursor is still at \(beforeResume)")
    #expect(track.idleOpacity(at: at(restEnd + 0.2), hideAfter: delay) == 1, "moving again, but faded")
}

/// A pointer that never moved is not idle: it is where it is, and it is drawn.
@Test func aPointerThatNeverMovedIsNotHidden() {
    let track = PointerTrack(samples: (0..<300).map { sample(Double($0) / 60, 0.4, 0.4) },
                             blindIntervals: [], overrides: [])
    #expect(track.idleOpacity(at: at(4.5), hideAfter: 1) == 1)
}

// MARK: - the lean

/// Zero at rest and with the amount off; full at the reference speed; clamped past it;
/// signed by direction; scaled by the amount.
@Test func theLeanFollowsSpeedDirectionAndAmount() {
    #expect(CursorTilt.degrees(velocityXPixelsPerSecond: 0, amount: 1) == 0)
    #expect(CursorTilt.degrees(velocityXPixelsPerSecond: 3000, amount: 0) == 0)
    let reference = CursorTilt.speedReferencePixelsPerSecond
    #expect(CursorTilt.degrees(velocityXPixelsPerSecond: reference, amount: 1) == CursorTilt.maximumDegrees)
    #expect(CursorTilt.degrees(velocityXPixelsPerSecond: reference * 5, amount: 1) == CursorTilt.maximumDegrees)
    #expect(CursorTilt.degrees(velocityXPixelsPerSecond: -reference, amount: 1) == -CursorTilt.maximumDegrees)
    #expect(abs(CursorTilt.degrees(velocityXPixelsPerSecond: reference / 2, amount: 0.5)
                - CursorTilt.maximumDegrees / 4) < 1e-9)
}

/// The presented velocity is what the lean reads: a steady sweep to the right reports a
/// positive x velocity close to the sweep's own speed.
@Test func thePresentedVelocityReportsTheSweep() throws {
    let samples = (0...120).map { sample(1 + Double($0) / 120, 0.1 + Double($0) * 0.005, 0.5) }
    let track = PointerTrack(samples: samples, blindIntervals: [], overrides: [])
    let velocity = try #require(track.presentedVelocity(at: at(1.6)))
    // 0.005 per 1/120 s = 0.6 units/s.
    #expect(abs(velocity.x - 0.6) < 0.1, "reported \(velocity.x) for a 0.6 units/s sweep")
    #expect(abs(velocity.y) < 0.01)
}

// MARK: - shake removal

/// A one-sample reversal inside the window and under the threshold is dropped; the same
/// reversal wider than the window, or larger than the threshold, is kept. The dropped case
/// is proven by the path: with the tremor removed the spline runs straight through, and
/// with it kept the spline dips toward the tremor.
@Test func aSmallReversalInsideTheWindowIsDroppedAndALargeOneIsKept() {
    func samples(jog: Double, spacing: Double) -> [PointerSample] {
        [sample(1.0, 0.30, 0.5), sample(1.0 + spacing, 0.30 + jog, 0.5),
         sample(1.0 + 2 * spacing, 0.30, 0.5), sample(1.0 + 3 * spacing, 0.30, 0.5)]
    }
    let window = PointerPath.Tuning.default.shakeWindow.rawValue
    let threshold = PointerPath.Tuning.default.shakeThreshold
    // Inside: 30 ms apart (60 ms window), a 0.005 jog — a tremor.
    let tremor = PointerPath.withoutShakes(samples(jog: 0.005, spacing: 0.03),
                                           window: window, threshold: threshold)
    #expect(tremor.count == 3, "the tremor sample survived")
    // A deliberate flick of 0.05 — past the threshold — is a move, and stays.
    let flick = PointerPath.withoutShakes(samples(jog: 0.05, spacing: 0.03),
                                          window: window, threshold: threshold)
    #expect(flick.count == 4, "a real flick was dropped as a shake")
    // The same tremor spread over 150 ms is outside the window: two slow moves, kept.
    let slow = PointerPath.withoutShakes(samples(jog: 0.005, spacing: 0.075),
                                         window: window, threshold: threshold)
    #expect(slow.count == 4, "a slow reversal outside the window was dropped")
    // First and last always survive, whatever they are.
    #expect(tremor.first == samples(jog: 0.005, spacing: 0.03).first)
    #expect(tremor.last == samples(jog: 0.005, spacing: 0.03).last)
}

/// With shakes removed the spring's path across a tremor is straighter than with them kept —
/// the observable difference, not just the sample count.
@Test func removingShakesStraightensThePresentedPath() throws {
    var samples: [PointerSample] = []
    // A slow drift with a tremor superimposed: every third sample jogs up by 0.004 and the
    // next comes back down. The drift is 0.001 per sample, SMALLER than the jog, so the two
    // legs genuinely reverse (their dot product is negative) — a first draft advanced x by
    // as much as the jog, which made the legs perpendicular, not reversed, and the filter
    // rightly kept every sample while the test blamed it.
    for i in 0...120 {
        let x = 0.2 + Double(i) * 0.001
        let jog = i % 3 == 1 ? 0.004 : 0.0
        samples.append(sample(1 + Double(i) / 120, x, 0.5 + jog))
    }
    var kept = PointerPath.Tuning.default
    kept.removesShakes = false
    let clean = PointerPath(samples: samples, blindIntervals: [], clickInstants: [])
    let shaky = PointerPath(samples: samples, blindIntervals: [], clickInstants: [], tuning: kept)
    func deviation(_ path: PointerPath) -> Double {
        path.entries(in: epoch).map { abs($0.position.y - 0.5) }.max() ?? 0
    }
    let cleanDeviation = deviation(clean), shakyDeviation = deviation(shaky)
    #expect(shakyDeviation > 0, "the tremor never reached the path; the comparison is vacuous")
    #expect(cleanDeviation < shakyDeviation * 0.6, """
        with shakes removed the path still deviates \(cleanDeviation) against \(shakyDeviation)
        """)
}
