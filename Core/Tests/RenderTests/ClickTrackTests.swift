import Testing
import Foundation
import Geometry
import Timeline
import Project
@testable import Render

private let epoch = BootEpoch(id: UUID(uuidString: "9B1DE104-6C3E-4E2A-8B3C-2B6A6F1F9C07")!)
private func at(_ ns: Int64) -> HostInstant { HostInstant(epoch: epoch, hostTime: Nanoseconds(ns)) }
private func down(_ ns: Int64, x: Double = 0.5, y: Double = 0.5) -> ButtonEvent {
    ButtonEvent(instant: at(ns), position: NormalizedPoint(x: x, y: y),
               revision: GeometryRevision(id: 1), button: .left, phase: .down)
}
private func up(_ ns: Int64, x: Double = 0.5, y: Double = 0.5) -> ButtonEvent {
    ButtonEvent(instant: at(ns), position: NormalizedPoint(x: x, y: y),
               revision: GeometryRevision(id: 1), button: .left, phase: .up)
}

@Test func beforeAnyClickThereIsNoRipple() {
    let track = ClickTrack(events: [down(1_000_000_000)])
    #expect(track.ripplePhase(at: at(500_000_000)) == nil)
}

@Test func atTheClickInstantThePhaseIsZero() {
    let track = ClickTrack(events: [down(1_000_000_000)])
    #expect(track.ripplePhase(at: at(1_000_000_000)) == 0.0)
}

@Test func midRippleThePhaseIsBetweenZeroAndOne() {
    let track = ClickTrack(events: [down(0)])
    // rippleDuration is 400_000_000ns; 100_000_000ns in is a quarter of the way through.
    let phase = track.ripplePhase(at: at(100_000_000))
    #expect(phase != nil)
    #expect(abs(phase! - 0.25) < 0.0001)
}

@Test func afterTheRippleHasFinishedThereIsNoRipple() {
    let track = ClickTrack(events: [down(0)])
    #expect(track.ripplePhase(at: at(ClickTrack.rippleDuration.rawValue)) == nil)
    #expect(track.ripplePhase(at: at(ClickTrack.rippleDuration.rawValue + 1)) == nil)
    #expect(track.ripplePhase(at: at(10_000_000_000)) == nil)
}

/// On overlap the LATER click wins outright, computed from its own instant — not a
/// blend, and not the earlier ripple running longer.
@Test func twoClicksCloseTogetherOverlapAndTheLaterOneWins() {
    let earlier: Int64 = 0
    let later: Int64 = 100_000_000        // 100ms later — inside the earlier ripple's 400ms window
    let query: Int64 = 150_000_000        // 150ms after the earlier click, 50ms after the later one
    let track = ClickTrack(events: [down(earlier), down(later)])

    let phase = track.ripplePhase(at: at(query))
    #expect(phase != nil)
    // The LATER click's own elapsed time: 150ms - 100ms = 50ms of 400ms = 0.125.
    #expect(abs(phase! - 0.125) < 0.0001)
    // NOT the earlier click's elapsed time, 150ms of 400ms = 0.375.
    #expect(abs(phase! - 0.375) > 0.01)

    // Ordering in the input array must not matter — the track sorts internally.
    let reordered = ClickTrack(events: [down(later), down(earlier)])
    #expect(reordered.ripplePhase(at: at(query)) == phase)
}

/// `.up` events are not read at all: a ripple starts on contact, not on release.
@Test func onlyDownEventsStartARipple() {
    let track = ClickTrack(events: [up(0)])
    #expect(track.ripplePhase(at: at(0)) == nil)
    #expect(track.ripplePhase(at: at(100_000_000)) == nil)
}

@Test func aClickTrackWithNoEventsNeverProducesARipple() {
    let track = ClickTrack(events: [])
    #expect(track.ripplePhase(at: at(0)) == nil)
    #expect(track.ripplePhase(at: at(1_000_000_000)) == nil)
}

/// A click stamped in another boot session has no ripple in flight here — same skip
/// rule as `PointerTrack`, same reason: host times overlap across boots.
@Test func aClickFromAnotherEpochHasNoRipple() {
    let otherEpoch = BootEpoch(id: UUID(uuidString: "0BADC0DE-0000-4000-8000-000000000002")!)
    let foreignDown = ButtonEvent(
        instant: HostInstant(epoch: otherEpoch, hostTime: Nanoseconds(0)),
        position: NormalizedPoint(x: 0.5, y: 0.5),
        revision: GeometryRevision(id: 1), button: .left, phase: .down)
    let track = ClickTrack(events: [foreignDown])
    #expect(track.ripplePhase(at: at(100_000_000)) == nil)
}
