import Testing
import Foundation
import Geometry
import Timeline
import Project
@testable import Render

// `PointerPath` is the presentation path: a spline through the samples, followed by a spring.
// Each test here would go red if one named property were lost — the spring being on, the
// corner being rounded, rest being still, a gap or a blind interval being held rather than
// crossed, the click stiffening, and the fallback to the lerp where the path has no answer.

private let epoch = BootEpoch(id: UUID(uuidString: "5A7E0F1E-2B3C-4D5E-8F90-A1B2C3D4E5F6")!)
private func at(seconds: Double) -> HostInstant {
    HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64(seconds * 1_000_000_000)))
}
private func sample(_ seconds: Double, _ x: Double, _ y: Double) -> PointerSample {
    PointerSample(instant: at(seconds: seconds), position: NormalizedPoint(x: x, y: y),
                  revision: GeometryRevision(id: 1))
}

/// Samples along a straight line at 120 Hz — the tap's cadence while a pointer moves.
private func line(from: (Double, Double), to: (Double, Double), start: Double, duration: Double,
                  hz: Double = 120) -> [PointerSample] {
    let count = Int(duration * hz)
    return (0...count).map { i in
        let f = Double(i) / Double(count)
        return sample(start + f * duration, from.0 + (to.0 - from.0) * f, from.1 + (to.1 - from.1) * f)
    }
}

private func presented(_ track: PointerTrack, at seconds: Double) -> NormalizedPoint? {
    if case .drawn(let point, _, _) = track.presentedPosition(at: at(seconds: seconds)) { return point }
    return nil
}
private func lerped(_ track: PointerTrack, at seconds: Double) -> NormalizedPoint? {
    if case .drawn(let point, _, _) = track.smoothedPosition(at: at(seconds: seconds)) { return point }
    return nil
}

// MARK: - the spring is on, and bounded

/// A target moving at constant speed is followed to within the tuning's own lag bound —
/// which is what `RecordedPointerPositionTests` relies on against the real recording. Not
/// "trailed": the phase lead samples the target ahead by the spring's steady-state lag, so
/// the presented cursor sits ON the true position of a steady move rather than behind it.
/// The spring's presence is proven by the corner and the rest below, which a lerp fails.
@Test func aMovingTargetIsFollowedWithinTheLagBound() throws {
    let speed = 1.0 // normalised units per second, a brisk sweep across the whole frame
    let track = PointerTrack(samples: line(from: (0.1, 0.5), to: (0.9, 0.5), start: 1, duration: 0.8),
                             blindIntervals: [], overrides: [])
    // Well into the move, past the spring's own settling from the start.
    let time = 1.5
    let followed = try #require(presented(track, at: time))
    let exact = try #require(lerped(track, at: time))
    let lag = PointerPath.Tuning.default.worstCaseLagSeconds
    #expect(abs(exact.x - followed.x) <= speed * lag * 2 + 0.002, """
        the spring was \(exact.x - followed.x) from the true position, past the \
        \(speed * lag * 2) bound
        """)
    // And the lead has done its job: closer than the raw steady-state trail would be.
    #expect(abs(exact.x - followed.x) < speed * lag,
            "the presented cursor trails by a full lag; the phase lead is not compensating")
    #expect(abs(followed.y - 0.5) < 0.001, "a horizontal move drifted vertically")
}

// MARK: - a corner is rounded

/// **The property the whole type exists for.** Two straight legs meeting at a right angle:
/// the lerp turns the corner exactly and the presented path cuts it — it never reaches the
/// corner point, and it is closer to the corner on the frame after the turn than the lerp is
/// far from it at the moment of the turn. A path that passed through the corner would be a
/// lerp with extra steps.
@Test func aRightAngleIsRoundedNotTraced() throws {
    let leg1 = line(from: (0.2, 0.2), to: (0.6, 0.2), start: 1, duration: 0.4)
    let leg2 = line(from: (0.6, 0.2), to: (0.6, 0.6), start: 1.4, duration: 0.4).dropFirst()
    let track = PointerTrack(samples: leg1 + leg2, blindIntervals: [], overrides: [])
    let corner = NormalizedPoint(x: 0.6, y: 0.2)

    // Sample densely across the turn; the closest approach must not touch the corner.
    var closest = Double.infinity
    for seconds in stride(from: 1.3, through: 1.5, by: 0.004) {
        let point = try #require(presented(track, at: seconds))
        closest = min(closest, hypot(point.x - corner.x, point.y - corner.y))
    }
    #expect(closest > 0.003, "the presented path passed through the corner at \(closest)")
    // And it is a genuine shortcut, inside the angle: x below the corner while y is above the
    // first leg, at the instant the lerp is exactly on the corner.
    let atTurn = try #require(presented(track, at: 1.4))
    #expect(atTurn.x < corner.x + 0.001 && atTurn.y > corner.y - 0.001,
            "the presented cursor at the turn (\(atTurn)) is outside the angle")
}

// MARK: - rest is still

/// `PointerSampler`'s 60 Hz floor emits a resting pointer as positions a fraction of a pixel
/// apart. The spring plus idle stabilisation must render that as still: the presented path's
/// spread across the rest is far below the samples' own.
@Test func aJitteringRestIsRenderedStill() throws {
    var samples: [PointerSample] = []
    // A quarter-pixel wobble on a 1080p frame, alternating, for a second at 60 Hz.
    let wobble = 0.25 / 1080
    for i in 0..<60 {
        let sign = i % 2 == 0 ? 1.0 : -1.0
        samples.append(sample(1 + Double(i) / 60, 0.5 + wobble * sign, 0.5 - wobble * sign))
    }
    let track = PointerTrack(samples: samples, blindIntervals: [], overrides: [])
    // Skip the first quarter second so the spring has settled onto the rest.
    let xs = try stride(from: 1.25, through: 1.95, by: 1.0 / 60).map {
        try #require(presented(track, at: $0)).x
    }
    let spread = (xs.max() ?? 0) - (xs.min() ?? 0)
    #expect(spread < wobble * 0.5, """
        the presented cursor wobbled by \(spread) against a sample wobble of \(wobble * 2) — \
        the rest was not stabilised
        """)
}

// MARK: - refusals, in the lerp's own terms

/// Across a gap wider than `maxInterpolationGap` the TARGET holds the earlier sample, so the
/// presented cursor stays at it until the later sample is observed — no motion is invented
/// across the unobserved span. Only afterwards does the spring glide to the new position.
@Test func aWideGapIsHeldThenGlidedAfterTheObservation() throws {
    let gap = 0.5 // ten times the threshold
    let before = line(from: (0.2, 0.2), to: (0.3, 0.2), start: 1, duration: 0.2)
    let after = line(from: (0.7, 0.7), to: (0.8, 0.7), start: 1.2 + gap, duration: 0.2)
    let track = PointerTrack(samples: before + after, blindIntervals: [], overrides: [])
    // In the middle of the gap: at the earlier sample, not on the way to the later one.
    let mid = try #require(presented(track, at: 1.2 + gap / 2))
    #expect(abs(mid.x - 0.3) < 0.002 && abs(mid.y - 0.2) < 0.002,
            "the cursor was at \(mid) mid-gap — motion was invented across the gap")
    // A tenth of a second after the later sample arrives, the spring has crossed.
    let landed = try #require(presented(track, at: 1.2 + gap + 0.15))
    #expect(landed.x > 0.65 && landed.y > 0.65, "the cursor never glided to the new position")
}

/// A blind interval between two samples is a span the tap could not see. The spline does not
/// cross it: the target holds the earlier sample, exactly as the lerp refuses.
@Test func aBlindIntervalBetweenSamplesIsNotCrossed() throws {
    let blind = BlindInterval(start: Nanoseconds(1_100_000_000), duration: Nanoseconds(50_000_000),
                              cause: .tapDisabled)
    let track = PointerTrack(samples: [sample(1.0, 0.2, 0.2), sample(1.03, 0.25, 0.2),
                                       sample(1.2, 0.8, 0.8), sample(1.23, 0.85, 0.8)],
                             blindIntervals: [blind], overrides: [])
    // 1.08 s is sighted (the blind window starts at 1.1) and lies between the brackets
    // 1.03 → 1.2, which the blindness sits inside.
    let held = try #require(presented(track, at: 1.08))
    #expect(abs(held.x - 0.25) < 0.005 && abs(held.y - 0.2) < 0.005,
            "the presented cursor at \(held) crossed a blind interval")
    // And AT a blind instant the precedence is untouched.
    #expect(track.presentedPosition(at: at(seconds: 1.12)) == .blind(blind))
}

/// Overrides and blindness at the instant keep `position(at:)`'s precedence — the spring is
/// consulted only after the stepwise reading is `.drawn`.
@Test func thePresentedReadingKeepsTheReviewPrecedence() {
    let override = CursorOverride(epoch: epoch, start: Nanoseconds(1_000_000_000),
                                  duration: Nanoseconds(500_000_000))
    let track = PointerTrack(samples: line(from: (0.1, 0.1), to: (0.9, 0.9), start: 0.5, duration: 1),
                             blindIntervals: [], overrides: [override])
    #expect(track.presentedPosition(at: at(seconds: 1.2)) == .suppressedByReviewer)
    #expect(track.presentedPosition(at: at(seconds: 0.1)) == .noObservationYet)
}

// MARK: - the fallback

/// A track too short to bake — two samples inside one integration step — has no path, and
/// the presented reading IS the lerp. This is what keeps every nanosecond-scale fixture in
/// `PointerTrackTests` meaningful, and what makes the presentation never less than the lerp.
@Test func aTrackTooShortToBakeFallsBackToTheLerp() {
    let track = PointerTrack(samples: [
        PointerSample(instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(0)),
                      position: NormalizedPoint(x: 0.0, y: 0.0), revision: GeometryRevision(id: 1)),
        PointerSample(instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(1_000)),
                      position: NormalizedPoint(x: 0.2, y: 0.4), revision: GeometryRevision(id: 1)),
    ], blindIntervals: [], overrides: [])
    let instant = HostInstant(epoch: epoch, hostTime: Nanoseconds(500))
    #expect(track.presentedPosition(at: instant) == track.smoothedPosition(at: instant))
    if case .drawn(let point, _, _) = track.presentedPosition(at: instant) {
        #expect(abs(point.x - 0.1) < 1e-9 && abs(point.y - 0.2) < 1e-9)
    } else {
        Issue.record("the fallback was not drawn")
    }
}

/// Past the last sample the path has no answer and the lerp holds the last sample; shapes
/// and hotspots ride with the stepwise sample, never with the path.
@Test func shapeAndHotspotComeFromTheStepwiseSample() throws {
    var samples = line(from: (0.1, 0.1), to: (0.5, 0.5), start: 1, duration: 0.5)
    samples[samples.count - 1] = PointerSample(
        instant: samples[samples.count - 1].instant, position: NormalizedPoint(x: 0.5, y: 0.5),
        revision: GeometryRevision(id: 1), shape: .iBeam, hotspot: NormalizedPoint(x: 0.5, y: 0.5))
    let track = PointerTrack(samples: samples, blindIntervals: [], overrides: [])
    guard case .drawn(let point, let shape, let hotspot) = track.presentedPosition(at: at(seconds: 2)) else {
        Issue.record("past the last sample the reading was not drawn"); return
    }
    #expect(point == NormalizedPoint(x: 0.5, y: 0.5))
    #expect(shape == .iBeam)
    #expect(hotspot == NormalizedPoint(x: 0.5, y: 0.5))
}

// MARK: - the click

/// **The spring stiffens into a click so the cursor has arrived when the ripple starts.**
/// The same move with and without a button-down at its end: at the click instant the
/// cursor with the click is closer to the target. Without this a ripple draws at a point
/// the cursor reaches a few frames later.
@Test func aClickPullsTheCursorOntoItsTargetInTime() throws {
    // A fast move that stops dead on the target, then rests there — the shape of a person
    // reaching a button and pressing it. The rest is what keeps the path covering the click.
    let move = line(from: (0.2, 0.2), to: (0.7, 0.7), start: 1, duration: 0.25)
        + line(from: (0.7, 0.7), to: (0.7, 0.7), start: 1.25, duration: 0.3, hz: 60).dropFirst()
    let clickAt = 1.25
    let plain = PointerTrack(samples: move, blindIntervals: [], overrides: [])
    let clicked = PointerTrack(samples: move, blindIntervals: [], overrides: [],
                               clickInstants: [at(seconds: clickAt)])
    let target = NormalizedPoint(x: 0.7, y: 0.7)
    let plainDistance = try hypot(#require(presented(plain, at: clickAt)).x - target.x,
                                  #require(presented(plain, at: clickAt)).y - target.y)
    let clickedDistance = try hypot(#require(presented(clicked, at: clickAt)).x - target.x,
                                    #require(presented(clicked, at: clickAt)).y - target.y)
    #expect(clickedDistance < plainDistance, """
        with a click the cursor was \(clickedDistance) from the target at the click instant, \
        against \(plainDistance) without one — the spring did not stiffen
        """)
    #expect(clickedDistance < 0.01, "even stiffened, the cursor was \(clickedDistance) short")
}

// MARK: - determinism

/// The same samples bake the same path — every entry, bit for bit. `render-parity` needs the
/// preview and the export to draw the same cursor, and both bake from the same log.
@Test func theSameSamplesBakeTheSamePath() {
    let samples = line(from: (0.1, 0.9), to: (0.9, 0.1), start: 2, duration: 1.3)
    let first = PointerPath(samples: samples, blindIntervals: [], clickInstants: [at(seconds: 3)])
    let second = PointerPath(samples: samples.reversed(), blindIntervals: [], clickInstants: [at(seconds: 3)])
    let a = first.entries(in: epoch), b = second.entries(in: epoch)
    #expect(!a.isEmpty, "nothing was baked; the comparison below is vacuous")
    #expect(a == b)
}

/// Samples from another boot session do not join this one's path: two boots overlap in host
/// time, so the epoch is the only thing that keeps them apart.
@Test func anotherEpochsSamplesDoNotJoinThePath() {
    let other = BootEpoch(id: UUID(uuidString: "0BADC0DE-0000-4000-8000-000000000002")!)
    let foreign = line(from: (0.9, 0.9), to: (0.1, 0.1), start: 1, duration: 0.5).map {
        PointerSample(instant: HostInstant(epoch: other, hostTime: $0.instant.hostTime),
                      position: $0.position, revision: $0.revision)
    }
    let path = PointerPath(samples: foreign, blindIntervals: [], clickInstants: [])
    #expect(path.position(at: at(seconds: 1.2)) == nil)
    #expect(!path.entries(in: other).isEmpty)
}
