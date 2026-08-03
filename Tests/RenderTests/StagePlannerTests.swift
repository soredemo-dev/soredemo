import Testing
import Geometry
import Timeline
import Project
@testable import Render

@Test func theCardIsInsetAndCentredInsideTheOutput() {
    let plan = StagePlanner.plan(outputWidth: 1920, outputHeight: 1080,
                                 sourceWidth: 1600, sourceHeight: 1000,
                                 style: .default)
    // The card keeps the SOURCE aspect ratio, is centred, and never touches the edge.
    #expect(plan.card.width / plan.card.height == 1.6)
    #expect(plan.card.x > 0 && plan.card.y > 0)
    #expect(plan.card.x + plan.card.width < 1920)
    #expect(plan.card.y + plan.card.height < 1080)
    #expect(abs((plan.card.x + plan.card.width / 2) - 960) < 0.5)
    #expect(abs((plan.card.y + plan.card.height / 2) - 540) < 0.5)
}

@Test func aTallerSourceIsFittedByHeightNotStretched() {
    let wide = StagePlanner.plan(outputWidth: 1920, outputHeight: 1080,
                                 sourceWidth: 1000, sourceHeight: 1600, style: .default)
    #expect(abs(wide.card.width / wide.card.height - 0.625) < 0.001)
    #expect(wide.card.height <= 1080)
}

@Test func theCornerRadiusIsClampedToHalfTheShorterSide() {
    let style = StageStyle(insetFraction: 0.04, cornerRadius: 10_000,
                           shadowRadius: 24, shadowOpacity: 0.35,
                           background: .solid(red: 0.1, green: 0.1, blue: 0.12))
    let plan = StagePlanner.plan(outputWidth: 400, outputHeight: 400,
                                 sourceWidth: 400, sourceHeight: 400, style: style)
    #expect(plan.cornerRadius == min(plan.card.width, plan.card.height) / 2)
}
