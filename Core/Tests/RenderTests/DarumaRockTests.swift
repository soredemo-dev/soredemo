import Testing
@testable import Render

/// Poked, the daruma tips away and rocks back upright — `docs/design/2026-10-27-the-daruma-tips-flies-and-paints.md`.
@Suite struct DarumaRockTests {
    let pushedRight = DarumaRock(direction: 1), pushedLeft = DarumaRock(direction: -1)

    @Test func itStartsUprightAndTipsThePushedWayFirst() {
        #expect(pushedRight.angle(at: 0) == 0)
        #expect(abs(pushedRight.angle(at: 0.01)) < 3, "from upright, not a jump to its lean")
        #expect(pushedRight.angle(at: 0.08) > 2, "tipping right, degrees clockwise")
        #expect(pushedLeft.angle(at: 0.08) < -2)
    }

    /// Touched on its left it tips right, away from the finger; on its right, left.
    @Test func itTipsAwayFromWhereItWasTouched() {
        #expect(DarumaRock(touchedAt: 20, width: 100).direction == 1)
        #expect(DarumaRock(touchedAt: 80, width: 100).direction == -1)
    }

    /// It swings back past upright before it settles — a rock, not a lean that eases home.
    @Test func itSwingsBackPastUprightAndSettles() {
        let samples = stride(from: 0.0, through: 2.5, by: 0.01).map { pushedRight.angle(at: $0) }
        #expect(samples.contains { $0 < -1 }, "it overshoots the other way")
        #expect(samples.allSatisfy { abs($0) <= 18 }, "it never falls over")
        #expect(stride(from: 2.2, through: 4, by: 0.05).allSatisfy { abs(pushedRight.angle(at: $0)) < 0.3 })
        #expect(pushedRight.isSettled(at: 2.3) && !pushedRight.isSettled(at: 0.5))
    }

    /// It squeezes its eyes shut as it is pushed, and opens them while it is still rocking.
    @Test func itSqueezesItsEyesOnlyAtFirst() {
        #expect(pushedRight.isSqueezing(at: 0.05))
        #expect(!pushedRight.isSqueezing(at: 0.5))
        #expect(!pushedRight.isSqueezing(at: -0.1), "before the push it does nothing")
        #expect(pushedRight.angle(at: -0.1) == 0)
    }
}
