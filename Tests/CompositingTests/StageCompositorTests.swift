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

    /// `CompositorError.notConfigured` exists and is distinguishable from another error — not
    /// that `startRequest`'s guard fires.
    @Test func theCompositorErrorIsDistinguishableFromAnotherError() {
        let error: any Error = StageCompositor.CompositorError.notConfigured
        #expect(error as? StageCompositor.CompositorError == .notConfigured)
        #expect((CancellationError() as any Error) as? StageCompositor.CompositorError == nil)
    }
}
