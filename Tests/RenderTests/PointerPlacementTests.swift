import Testing
import Foundation
import Geometry
import Timeline
import Project
@testable import Render

// Placement maps a normalised source point onto the stage card.

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

/// `(1, 1)` must land at the card's TOP-RIGHT. The `(0.5, 0.5)` and `(0, 0)` cases above
/// are both blind to an axis flip; this one is not.
@Test func aPointerAtTheSourcesFarCornerLandsAtTheCardsTopRight() {
    let plan = StagePlanner.plan(outputWidth: 1000, outputHeight: 1000,
                                 sourceWidth: 1000, sourceHeight: 1000, style: .default)
    let placement = StagePlanner.placement(for: NormalizedPoint(x: 1, y: 1), in: plan)
    #expect(abs(placement.x - (plan.card.x + plan.card.width)) < 0.5)
    #expect(abs(placement.y - (plan.card.y + plan.card.height)) < 0.5)
}

/// `ripplePhase` passes straight through and stays `nil` when unsupplied;
/// `placement(for:in:)` never derives a phase of its own.
@Test func placementCarriesTheRipplePhaseItWasGivenAndOnlyThat() {
    let plan = StagePlanner.plan(outputWidth: 1000, outputHeight: 1000,
                                 sourceWidth: 1000, sourceHeight: 1000, style: .default)
    let noRipple = StagePlanner.placement(for: NormalizedPoint(x: 0.2, y: 0.2), in: plan)
    #expect(noRipple.ripplePhase == nil)

    let withRipple = StagePlanner.placement(for: NormalizedPoint(x: 0.2, y: 0.2), in: plan,
                                            ripplePhase: 0.4)
    #expect(withRipple.ripplePhase == 0.4)
}

/// A non-square, inset card, unlike the 1000×1000 fixtures above where the card fills the
/// output and the wrong origin would still look right.
@Test func placementUsesTheCardsOwnOriginAndExtentNotTheOutputCanvass() {
    let plan = StagePlanner.plan(outputWidth: 1920, outputHeight: 1080,
                                 sourceWidth: 1600, sourceHeight: 1000, style: .default)
    #expect(plan.card.width < 1920 && plan.card.height < 1080)
    #expect(plan.card.x > 0 && plan.card.y > 0)

    let placement = StagePlanner.placement(for: NormalizedPoint(x: 0.25, y: 0.75), in: plan)
    #expect(abs(placement.x - (plan.card.x + 0.25 * plan.card.width)) < 0.5)
    #expect(abs(placement.y - (plan.card.y + 0.75 * plan.card.height)) < 0.5)
}
