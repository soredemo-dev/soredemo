import Foundation
import Framing
import Geometry
import Testing
import Timeline
@testable import Soredemo

private let epoch = BootEpoch(id: UUID(uuidString: "7C2D3E4F-5061-4728-9ABC-DE0F1A2B3C4D")!)
private let second: Int64 = 1_000_000_000
/// The recording starts 500 s after boot.
private let anchor = EpochAnchor(epoch: epoch, hostTime: Nanoseconds(500 * second), wallClockUnixNanos: 0)

private func step(_ number: Int, at seconds: Double, _ label: String) -> RecordedStep {
    let origin = HostInstant(epoch: epoch, hostTime: Nanoseconds(500 * second + Int64(seconds * 1e9)))
    // The element's frame carries its step's time in x, so a highlight placed from the wrong
    // step's frame is visible.
    return RecordedStep(origin: origin, end: origin, number: number, label: label, role: "AXButton",
                        application: "Keynote",
                        frame: NormalizedFrame(origin: NormalizedPoint(x: seconds / 100, y: 0.5),
                                               size: NormalizedSize(width: 0.1, height: 0.05),
                                               revision: GeometryRevision(id: 1)))
}

private func ns(_ seconds: Double) -> Nanoseconds { Nanoseconds(Int64((seconds * 1e9).rounded())) }

@MainActor @Suite struct GuideExportTests {
    /// **A 20 s recording with 2–5 s cut out**, so source and output time differ after the cut —
    /// a picture time taken without the conversion would show a frame three seconds late.
    private func cut() -> EditTimeline {
        let model = TimelineEditorModel(scrubbingThrough: { _ in })
        model.load(duration: 20)
        model.selection = ns(2).rawValue..<ns(5).rawValue
        model.removeSelection()
        return model.edit
    }

    @Test func stepsCutFromTheVideoAreLeftOutAndTheRestRenumbered() {
        let pictures = GuideExport.pictures(for: [step(1, at: 1, "Open"), step(2, at: 3, "Gone"),
                                                  step(3, at: 8, "Export")],
                                            anchor: anchor, edit: cut())
        #expect(pictures.map(\.step.label) == ["Open", "Export"])
    }

    /// The frame is taken just before the press, in OUTPUT time.
    @Test func eachPictureIsTakenJustBeforeItsPressInTheEditedVideo() {
        let pictures = GuideExport.pictures(for: [step(1, at: 1, "Open"), step(2, at: 8, "Export")],
                                            anchor: anchor, edit: cut())
        #expect(pictures.map(\.outputTime) == [ns(0.85), ns(4.85)])
    }

    /// A press right at the start has nothing before it to show; it shows the press itself.
    @Test func aPressAtTheVeryStartIsPicturedAtItsOwnMoment() {
        let pictures = GuideExport.pictures(for: [step(1, at: 0.05, "Open")], anchor: anchor, edit: cut())
        #expect(pictures.map(\.outputTime) == [ns(0.05)])
    }

    @Test func withoutAnAnchorThereIsNoGuide() {
        #expect(GuideExport.pictures(for: [step(1, at: 1, "Open")], anchor: nil, edit: cut()).isEmpty)
    }

    /// Each picture's box is placed from its OWN step's element, at its OWN picture's time.
    @Test func eachBoxIsPlacedFromItsStepsElementAtItsPicturesTime() {
        var asked: [(x: Double, time: Nanoseconds)] = []
        let pictures = GuideExport.pictures(
            for: [step(1, at: 1, "Open"), step(2, at: 8, "Export")], anchor: anchor, edit: cut(),
            highlight: { frame, time in
                asked.append((frame.minX, time))
                return GuideHighlight(x: frame.minX, y: 0, width: 0.1, height: 0.1)
            })
        #expect(asked.map(\.x) == [0.01, 0.08])
        #expect(asked.map(\.time) == [ns(0.85), ns(4.85)])
        #expect(pictures.map { $0.step.highlight?.x } == [0.01, 0.08])
    }
}
