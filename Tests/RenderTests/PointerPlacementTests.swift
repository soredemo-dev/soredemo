import Testing
import Foundation
import Geometry
import Timeline
import Project
@testable import Render

// task-5-brief.md Step 1, verbatim.

@Test func aNormalisedPointBecomesOutputPixelsInsideTheCard() {
    let plan = StagePlanner.plan(outputWidth: 1000, outputHeight: 1000,
                                 sourceWidth: 1000, sourceHeight: 1000, style: .default)
    let placement = StagePlanner.placement(for: NormalizedPoint(x: 0.5, y: 0.5), in: plan)
    #expect(abs(placement.x - 500) < 0.5)
    #expect(abs(placement.y - 500) < 0.5)
}

@Test func aPointerAtTheSourceOriginLandsAtTheCardsBottomLeft() {
    let plan = StagePlanner.plan(outputWidth: 1000, outputHeight: 1000,
                                 sourceWidth: 1000, sourceHeight: 1000, style: .default)
    let placement = StagePlanner.placement(for: NormalizedPoint(x: 0, y: 0), in: plan)
    #expect(abs(placement.x - plan.card.x) < 0.5)
    #expect(abs(placement.y - plan.card.y) < 0.5)
}

/// The opposite corner from the origin case above: `(1, 1)` must land at the card's TOP-RIGHT —
/// `card.x + card.width`, `card.y + card.height` — not merely "somewhere positive". Between this
/// and the two brief tests, all four placement extremes (both axes, both ends) are pinned; a sign
/// error on either axis would pass the brief's own two tests (both touch `x` and `y` together at
/// values where a flip is invisible: `(0.5, 0.5)` is symmetric, and `(0, 0)` maps to `(card.x,
/// card.y)` regardless of which axis a flip happened on) but fail here.
@Test func aPointerAtTheSourcesFarCornerLandsAtTheCardsTopRight() {
    let plan = StagePlanner.plan(outputWidth: 1000, outputHeight: 1000,
                                 sourceWidth: 1000, sourceHeight: 1000, style: .default)
    let placement = StagePlanner.placement(for: NormalizedPoint(x: 1, y: 1), in: plan)
    #expect(abs(placement.x - (plan.card.x + plan.card.width)) < 0.5)
    #expect(abs(placement.y - (plan.card.y + plan.card.height)) < 0.5)
}

/// `ripplePhase` passes straight through when the caller supplies one, and stays `nil` — not
/// substituted for a default click phase — when it does not. `placement(for:in:)` does not derive a
/// phase from anything of its own; it only carries the one it was handed.
@Test func placementCarriesTheRipplePhaseItWasGivenAndOnlyThat() {
    let plan = StagePlanner.plan(outputWidth: 1000, outputHeight: 1000,
                                 sourceWidth: 1000, sourceHeight: 1000, style: .default)
    let noRipple = StagePlanner.placement(for: NormalizedPoint(x: 0.2, y: 0.2), in: plan)
    #expect(noRipple.ripplePhase == nil)

    let withRipple = StagePlanner.placement(for: NormalizedPoint(x: 0.2, y: 0.2), in: plan,
                                            ripplePhase: 0.4)
    #expect(withRipple.ripplePhase == 0.4)
}

/// A non-square, inset card (the shape `StagePlanner.plan` actually produces for a realistic
/// output/source pair) rather than the brief's identity-sized 1000×1000 fixture, where the card
/// fills the whole output and `x * width` could coincidentally look right even with the wrong
/// origin. The card here is measurably smaller than and offset from the output canvas, so a
/// placement computed from the wrong rectangle (the output's instead of the card's) would miss by
/// more than this test's tolerance.
@Test func placementUsesTheCardsOwnOriginAndExtentNotTheOutputCanvass() {
    let plan = StagePlanner.plan(outputWidth: 1920, outputHeight: 1080,
                                 sourceWidth: 1600, sourceHeight: 1000, style: .default)
    #expect(plan.card.width < 1920 && plan.card.height < 1080)
    #expect(plan.card.x > 0 && plan.card.y > 0)

    let placement = StagePlanner.placement(for: NormalizedPoint(x: 0.25, y: 0.75), in: plan)
    #expect(abs(placement.x - (plan.card.x + 0.25 * plan.card.width)) < 0.5)
    #expect(abs(placement.y - (plan.card.y + 0.75 * plan.card.height)) < 0.5)
}
