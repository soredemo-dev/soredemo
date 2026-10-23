import Testing
import Timeline
@testable import Soredemo

private func ns(_ seconds: Int64) -> Nanoseconds { Nanoseconds(seconds * 1_000_000_000) }

/// The two rules a pair of marks keeps on its own, before any clock is involved.
@Suite struct ExportMarksTests {
    @Test func markingTheSamePlaceAgainCancelsThatMark() {
        var marks = ExportMarks()
        marks.markIn(at: ns(6))
        marks.markOut(at: ns(9))
        marks.markIn(at: ns(6))
        #expect(marks.inPoint == nil)
        #expect(marks.outPoint == ns(9), "the other mark is not touched")
    }

    @Test func anInPointAtOrAfterTheOutPointClearsTheOutPoint() {
        var marks = ExportMarks()
        marks.markOut(at: ns(6))
        marks.markIn(at: ns(6))
        #expect(marks.inPoint == ns(6) && marks.outPoint == nil)
    }

    @Test func anOutPointAtOrBeforeTheInPointClearsTheInPoint() {
        var marks = ExportMarks()
        marks.markIn(at: ns(9))
        marks.markOut(at: ns(4))
        #expect(marks.outPoint == ns(4) && marks.inPoint == nil)
    }

    @Test func oneEndIsARangeAndTheWholeVideoIsNot() {
        var marks = ExportMarks()
        #expect(marks.range(outputDuration: ns(17)) == nil)
        marks.markIn(at: ns(7))
        #expect(marks.range(outputDuration: ns(17)) == ns(7).rawValue..<ns(17).rawValue)
        marks.markOut(at: ns(17))
        #expect(marks.range(outputDuration: ns(17)) == ns(7).rawValue..<ns(17).rawValue)
        marks.clear()
        marks.markIn(at: ns(0))
        #expect(marks.range(outputDuration: ns(17)) == nil)
    }

    /// An edit shortened under a mark: the mark is past the end, so nothing is selected.
    @Test func aMarkPastTheEndSelectsNothing() {
        var marks = ExportMarks()
        marks.markIn(at: ns(15))
        #expect(marks.range(outputDuration: ns(12)) == nil)
    }
}
