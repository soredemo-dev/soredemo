import Testing
import Foundation
import CoreMedia
import Render
import Timeline
@testable import Compositing

/// `.serialized`, because `StageCompositor`'s configuration (`observationLogURL`, `overrides`,
/// `renderer`, the `diagnostics` counters) is process-global mutable state and Swift Testing
/// parallelises `@Test` functions by default. Extensions of this suite already rely on it.
@Suite(.serialized)
struct StageCompositorTests {
    /// `resetDiagnostics()` returns the drop count to zero. The explicit `Diagnostics` type
    /// annotation is deliberate: it names the type for the entry-rule scanner, which the
    /// lowercase `diagnostics` property alone would not.
    @Test func resettingDiagnosticsReturnsTheDropCountToZero() {
        StageCompositor.resetDiagnostics()
        let diagnostics: StageCompositor.Diagnostics = StageCompositor.diagnostics
        #expect(diagnostics.framesDropped == 0)
    }

    /// With no observation log configured, no pointer is placed — so a positive-log result
    /// cannot be produced by a default. This returns at `pointerPlacement`'s leading guard;
    /// everything below it is covered by `RecordedPointerPositionTests.swift`, not here.
    @Test func noConfiguredLogPlacesNoPointer() {
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.overrides = []
        let compositor = StageCompositor()
        let base = StagePlanner.plan(outputWidth: 640, outputHeight: 360,
                                     sourceWidth: 640, sourceHeight: 360, style: .default)
        let plan = RenderPlan(outputWidth: base.outputWidth, outputHeight: base.outputHeight,
                              card: base.card, cornerRadius: base.cornerRadius,
                              style: base.style, pointer: nil)
        #expect(compositor.pointerPlacement(at: CMTime(value: 0, timescale: 600), in: plan) == nil)
    }

    /// `CompositorError` exists and is distinguishable from another error — not that
    /// `startRequest`'s guards fire.
    @Test func theCompositorErrorIsDistinguishableFromAnotherError() {
        let error: any Error = StageCompositor.CompositorError.notConfigured
        #expect(error as? StageCompositor.CompositorError == .notConfigured)
        #expect((CancellationError() as any Error) as? StageCompositor.CompositorError == nil)
    }

    // MARK: - which refusal it was

    // **These were one case and one counter until 2026-09-16, and that cost a diagnosis.** A
    // console carrying `<<<< CustomVideoCompositor >>>> signalled err=-12784` says this
    // compositor refused a frame and nothing more; five different faults reach that line and
    // they have five different owners. What is asserted here is that they stay distinct.

    /// **Every refusal maps to its own counter.** A `switch` that collapsed two cases onto one
    /// bucket would compile and would quietly merge two defects back together.
    @Test func everyRefusalHasItsOwnCounter() {
        let errors: [StageCompositor.CompositorError] =
            [.noScreenTrack, .noSourceBuffer, .noRenderContext, .noDestinationBuffer, .noRenderer]
        let counters = errors.map(\.refusal)
        #expect(Set(counters).count == errors.count,
                "two refusals share a counter: \(counters)")
    }

    /// The `catch` around `render` has a counter of its own that no guard uses — a render that
    /// threw is a different thing from a render that was never attempted.
    @Test func aRenderThatThrewIsNotAMissingInput() {
        let fromGuards = Set(StageCompositor.CompositorError.allRefusals.map(\.refusal))
        #expect(!fromGuards.contains(.renderThrew))
        // The other direction: every counter is either reachable from a guard or is
        // `renderThrew`. A seventh case added with no way to reach it would be a counter that
        // can only ever read zero, which is worse than not having it.
        let unreachable = Set(StageCompositor.Diagnostics.Refusal.allCases)
            .subtracting(fromGuards).subtracting([.renderThrew])
        #expect(unreachable.isEmpty, "counters nothing can increment: \(unreachable)")
    }

    /// **`notConfigured` still means something.** It was every one of the five; code comparing
    /// against it was coarse rather than wrong, and silently changing what it matches would
    /// turn those comparisons into assertions about a case nobody chose.
    @Test func theOldSpellingStillNamesARealCase() {
        #expect(StageCompositor.CompositorError.notConfigured == .noRenderer)
    }

    /// The summary is what a status line can carry, and it must be empty — not "none", not a
    /// stray comma — when nothing was refused.
    @Test func nothingRefusedReadsAsNothing() {
        #expect(StageCompositor.Diagnostics().refusalSummary.isEmpty)
        #expect(StageCompositor.Diagnostics().framesDropped == 0)
    }

    /// Worst first, so a summary truncated by a narrow status line still names the one that
    /// happened most.
    @Test func theSummaryLeadsWithTheCommonestRefusal() {
        var diagnostics = StageCompositor.Diagnostics()
        diagnostics.refusals = [.noSourceBuffer: 2, .noRenderer: 97]
        #expect(diagnostics.refusalSummary.hasPrefix("noRenderer x97"),
                "got \(diagnostics.refusalSummary)")
    }
}
