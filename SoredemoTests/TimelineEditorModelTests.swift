import Testing
import Timeline
@testable import Soredemo

/// The first executable test the app target has ever had.
///
/// **13,761 lines and nothing ran against them.** The models here are `@Observable` classes with
/// no view in them — they were testable the whole time, and the only thing missing was somewhere
/// to put the tests. See docs/TESTING.md § 5.4.
@Test @MainActor func aFreshTimelineHasNoDurationAndNoExportRange() {
    let model = TimelineEditorModel()
    #expect(model.duration == nil)
    #expect(model.exportRange == nil)
    #expect(model.playhead == Nanoseconds(0))
}
