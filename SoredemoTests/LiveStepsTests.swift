import Testing
@testable import Soredemo

/// The expanded notch's list of what was just pressed — the checklist of the owner's Grok
/// reference, filled from the observation log's own steps while the take runs.
@Suite struct LiveStepsTests {
    /// The newest last, the oldest falling off past three.
    @Test func theLastThreePressesAreKeptNewestLast() {
        var steps: [String] = []
        for label in ["New Tab", "Search", "Sign in", "Continue"] {
            steps = LiveSteps.appending(label, to: steps)
        }
        #expect(steps == ["Search", "Sign in", "Continue"])
    }

    /// A button pressed twice running is one step — the rule `RecordedSteps` keeps for the
    /// recording's own list — and the same label after another is a new step.
    @Test func aRepeatedPressIsOneStep() {
        var steps = LiveSteps.appending("Next", to: [])
        steps = LiveSteps.appending("Next", to: steps)
        #expect(steps == ["Next"])
        steps = LiveSteps.appending("Back", to: steps)
        steps = LiveSteps.appending("Next", to: steps)
        #expect(steps == ["Next", "Back", "Next"])
    }
}
