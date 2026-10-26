import Render
import SwiftUI
import Testing
import Timeline
@testable import Soredemo

/// The countdown panel's ring round the record eye: drawn from the time each second began, so it
/// is empty when the second ends — the owner saw it stop short in the last fraction of a second,
/// because it was set a tenth at a time to the tenth's start and eased by the face's spring.
@MainActor @Suite struct CountdownRingTests {
    private func second(_ s: Double) -> Nanoseconds { Nanoseconds(Int64(s * 1_000_000_000)) }

    @Test func theRingDrainsWithTheSecondAndIsEmptyWhenItEnds() {
        let state = CountdownState(total: 3, subject: "Keynote")
        state.secondBegan = second(5)
        #expect(state.panelRing(at: second(5)) == 1)
        #expect(abs(state.panelRing(at: second(5.25)) - 0.75) < 1e-9)
        #expect(state.panelRing(at: second(6)) == 0, "the second's end is an empty ring")
        #expect(state.panelRing(at: second(6.2)) == 0, "a late wake does not refill it")
    }

    /// When the count is over the ring is spent, whatever the clock says — the frame drawn before
    /// the panel goes is a closed ring.
    @Test func aFinishedCountHasNoRingLeft() {
        let state = CountdownState(total: 3, subject: "Keynote")
        state.secondBegan = second(5)
        state.isFinished = true
        #expect(state.panelRing(at: second(5.4)) == 0)
    }

    /// The ring does not ride the face's spring: interpolating the view's animatable data moves
    /// the gaze and the eyes, and leaves the ring where the clock put it.
    @Test func theRingIsNotEasedWithTheFace() {
        var view = DarumaView(pose: .counting(remaining: 2, ringRemaining: 0.3))
        var data = view.animatableData
        data.first = .init(0.5, 0.2)
        view.animatableData = data
        #expect(view.pose.countRing == 0.3)
        #expect(view.pose.yaw == 0.5)
    }
}
