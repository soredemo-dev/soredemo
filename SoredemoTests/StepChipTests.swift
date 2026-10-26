import Testing
import Timeline
@testable import Soredemo

/// The Steps lane's chips. **The labels overlapped** (owner, 2026-10-25: the steps were unclear):
/// each ran to the lane's end, so every label lay under the next one's.
@MainActor @Suite struct StepChipTests {
    /// Each chip ends where the next step starts — a gap of 2 points between — and the last at the
    /// lane's end. On an 800-point lane, not a round 1000, so a width computed in fractions alone
    /// cannot pass.
    @Test func eachChipEndsWhereTheNextStepBegins() {
        let chips = StepChip.layout([(1, 0.1), (2, 0.4), (3, 0.43), (4, 0.9)], width: 800)
        #expect(chips.map(\.number) == [1, 2, 3, 4])
        #expect(chips.map(\.x) == [80, 320, 344, 720])
        #expect(chips.map(\.width) == [238, 22, 374, 78])
        // Too narrow for a label: the number alone, the label in the tooltip.
        #expect(chips.map(\.showsLabel) == [true, false, true, true])
    }

    /// A step outside the visible window is not drawn, and does not cut the chip before it short.
    @Test func aStepOutsideTheWindowIsNotDrawn() {
        let chips = StepChip.layout([(1, -0.2), (2, 0.5), (3, 1.4)], width: 600)
        #expect(chips.map(\.number) == [2])
        #expect(chips.first?.width == 298)
    }

    /// The step the playhead is in: the last one that has begun. None before the first.
    @Test func theCurrentStepIsTheLastOneBegun() {
        let steps = [StepMark(start: Nanoseconds(1_000_000_000), number: 1, label: "Open"),
                     StepMark(start: Nanoseconds(3_500_000_000), number: 2, label: "Save")]
        #expect(StepChip.current(steps, playhead: Nanoseconds(500_000_000)) == nil)
        #expect(StepChip.current(steps, playhead: Nanoseconds(2_000_000_000)) == 1)
        #expect(StepChip.current(steps, playhead: Nanoseconds(3_500_000_000)) == 2)
        #expect(StepChip.current(steps, playhead: Nanoseconds(9_000_000_000)) == 2)
    }
}
