import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Framing

// Steps, derived from the observation log's clicks. `docs/design/2026-10-25-a-recording-knows-its-steps.md`.
//
// **The recording starts at 100 s and no step at its start**, so a span measured from zero rather
// than from the click, or a step that took the recording's first instant, would show.

private let epoch = BootEpoch(id: UUID(uuidString: "5A7E9C11-2B3D-4E5F-8A9B-0C1D2E3F4A5B")!)
private let revision = GeometryRevision(id: 3)

private func at(_ seconds: Double) -> HostInstant {
    HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64(seconds * 1_000_000_000)))
}

private func element(_ role: String, _ title: String?, x: Double = 0.4) -> AXElementRecord {
    AXElementRecord(role: role, title: title,
                    frame: NormalizedFrame(origin: NormalizedPoint(x: x, y: 0.4),
                                           size: NormalizedSize(width: 0.1, height: 0.05),
                                           revision: revision),
                    readInterval: HostRange(epoch: epoch, start: Nanoseconds(1_000), duration: Nanoseconds(500)))
}

private func press(_ seconds: Double, hit: AXElementRecord?,
                   ancestors: [AXElementRecord] = [element("AXWindow", nil), element("AXApplication", "Finder")],
                   truncation: ChainTruncation = .reachedRoot) -> AXChainRecord {
    AXChainRecord(instant: at(seconds), clickPosition: NormalizedPoint(x: 0.45, y: 0.42),
                  clickRevision: revision, hitTestGlobalX: 100, hitTestGlobalY: 200,
                  hitTestInterval: HostRange(epoch: epoch, start: at(seconds).hostTime, duration: Nanoseconds(2_000_000)),
                  hit: hit, ancestors: ancestors, children: [],
                  truncation: truncation, axCalls: 5, depthCap: 30, walkBudgetNanos: 35_000_000)
}

@Suite struct RecordedStepsTests {
    @Test func aStepPerPressNamedByItsElementAndItsApplication() throws {
        let steps = RecordedSteps.steps(from: [press(104, hit: element("AXButton", "Export")),
                                               press(109, hit: element("AXMenuItem", "Movie…"))],
                                        recordingEnd: at(120))
        try #require(steps.count == 2)
        #expect(steps.map(\.label) == ["Export", "Movie…"])
        #expect(steps.map(\.application) == ["Finder", "Finder"])
        #expect(steps[0].origin == at(104) && steps[0].end == at(109), "a step lasts until the next")
        #expect(steps[1].end == at(120), "the last lasts until the recording ends")
        #expect(steps.map(\.number) == [1, 2])
    }

    /// The text inside a button is an `AXStaticText` with no title; the button has one.
    @Test func untitledTextInsideATitledButtonIsNamedByTheButton() throws {
        let steps = RecordedSteps.steps(from: [press(104, hit: element("AXStaticText", nil),
                                                     ancestors: [element("AXButton", "Share"),
                                                                 element("AXWindow", nil),
                                                                 element("AXApplication", "Keynote")])],
                                        recordingEnd: at(120))
        #expect(steps.first?.label == "Share")
        #expect(steps.first?.role == "AXButton", "the role of the element that gave the name")
    }

    @Test func aDoublePressIsOneStepAndTwoPressesApartAreTwo() {
        let twice = RecordedSteps.steps(from: [press(104, hit: element("AXCell", "Report.pdf")),
                                               press(104.3, hit: element("AXCell", "Report.pdf"))],
                                        recordingEnd: at(120))
        #expect(twice.count == 1)
        let apart = RecordedSteps.steps(from: [press(104, hit: element("AXCell", "Report.pdf")),
                                               press(104.6, hit: element("AXCell", "Report.pdf"))],
                                        recordingEnd: at(120))
        #expect(apart.count == 2)
    }

    /// "Click here" over a point nobody can name is the blank step guides are criticised for.
    @Test func aPressWithNoElementOrOnThisAppIsNotAStep() {
        let steps = RecordedSteps.steps(from: [press(102, hit: nil, ancestors: [], truncation: .hitTestReturnedNothing),
                                               press(103, hit: nil, ancestors: [], truncation: .overOwnWindow),
                                               press(104, hit: element("AXGroup", nil),
                                                     ancestors: [element("AXWindow", nil), element("AXApplication", "Finder")]),
                                               press(106, hit: element("AXButton", "Done"))],
                                        recordingEnd: at(120))
        #expect(steps.map(\.label) == ["Done"], "an untitled element up to the window names nothing")
        #expect(steps.first?.number == 1)
    }

    /// An old log may carry a window's title (`2026-10-25-a-window-title-is-content.md`); a step
    /// must not use it as a label.
    @Test func noWindowTitleNamesAStep() {
        let steps = RecordedSteps.steps(from: [press(104, hit: element("AXGroup", nil),
                                                     ancestors: [element("AXWindow", "Invoice — A. Customer.pdf"),
                                                                 element("AXApplication", "Preview")])],
                                        recordingEnd: at(120))
        #expect(steps.isEmpty)
    }

    @Test func pressesAreOrderedByTimeWhateverOrderTheyArrive() {
        let steps = RecordedSteps.steps(from: [press(109, hit: element("AXButton", "Second")),
                                               press(104, hit: element("AXButton", "First"))],
                                        recordingEnd: at(120))
        #expect(steps.map(\.label) == ["First", "Second"])
    }
}
