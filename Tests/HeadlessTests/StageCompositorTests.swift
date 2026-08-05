import Testing
import Foundation
import CoreMedia
import Render
import Timeline
@testable import Headless

/// `.serialized` — code review, fix round 1. `StageCompositor`'s configuration
/// (`observationLogURL`, `overrides`, `renderer`, the `diagnostics` counters) is process-global
/// mutable state, and Swift Testing parallelises `@Test` functions by default. Benign today:
/// `noConfiguredLogPlacesNoPointer` below is the only test that writes `observationLogURL`/
/// `overrides`, so nothing else in this suite reads a value it could have raced on. It stops
/// being benign the moment a positive-log test is added (Task 6) — two tests setting
/// `observationLogURL` to different files in the same process, unserialised, race on the same
/// static, and the failure is nondeterministic and load-bearing rather than a compile error.
/// `.serialized` costs nothing while this suite is this small and removes the need to re-derive
/// that reasoning under time pressure later.
@Suite(.serialized)
struct StageCompositorTests {
    /// Merges what were two separate tests through Task 4's first commit — code review, fix
    /// round 1: `resettingDiagnosticsReturnsTheDropCountToZero` and
    /// `theDropCounterIsReadableAndResettable` asserted the identical thing
    /// (`resetDiagnostics()` then `diagnostics.framesDropped == 0`), the second existing only to
    /// give the entry-rule scanner a real code mention of `StageCompositor.Diagnostics` as a
    /// type name, not only of the lowercase `diagnostics` property. One test, with the
    /// annotation, does both jobs. `Diagnostics` has no public initialiser of its own — naming
    /// the type at its one reachable read site is the cheapest honest discharge of the entry
    /// rule for it, exactly the ceremony this task's own brief names rather than hides. A
    /// counter nobody can read is indistinguishable from an event that never happened, which is
    /// why the type exists; a counter nothing tests is the same thing one step later.
    @Test func resettingDiagnosticsReturnsTheDropCountToZero() {
        StageCompositor.resetDiagnostics()
        let diagnostics: StageCompositor.Diagnostics = StageCompositor.diagnostics
        #expect(diagnostics.framesDropped == 0)
    }

    /// **With no observation log configured, no pointer is placed** — and that is not a
    /// fifth `PointerReading` case smuggled in through a side door, it is nothing having
    /// been configured to read from. Pinning it here means Task 6's positive result
    /// cannot be produced by a default.
    ///
    /// **What this does NOT cover — code review, fix round 1.** This test returns at
    /// `pointerPlacement(at:in:)`'s own `guard let pointer, let anchor else { return nil }`,
    /// because `noConfiguredLogPlacesNoPointer` is exactly the state where `loadedTracks()`
    /// yields neither. Every line below that guard in the real function — the offset-plus-anchor
    /// composition-time-to-host-clock conversion, and the four-case `switch` over
    /// `PointerReading` — is executed by NO test `swift test` runs today. `pointerPlacement`
    /// being `public` makes that code reachable from a test; it does not mean a test reaches it
    /// yet. Commit `1a98402`'s own defect lived in exactly the lines this test does not execute.
    /// That gap is Task 6's, not a claim this commit already closes it.
    @Test func noConfiguredLogPlacesNoPointer() {
        // `observationLogURL`/`overrides` are `nonisolated(unsafe)` for the reason their own
        // declarations give (published before playback starts, read by any `StageCompositor`
        // instance) — `unsafe` here states that shape at this call site, the same way it does
        // inside `StageCompositor` itself; this is not the first caller to set them
        // (`StageWindow.load()` already does, unmarked, because the app target carries no
        // `StrictMemorySafety` setting).
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

    /// `CompositorError` is public and thrown from `startRequest`'s leading guard. Same
    /// limit as above: what is pinned is that the case exists and is distinguishable from
    /// another error, not that the guard fires.
    @Test func theCompositorErrorIsDistinguishableFromAnotherError() {
        let error: any Error = StageCompositor.CompositorError.notConfigured
        #expect(error as? StageCompositor.CompositorError == .notConfigured)
        #expect((CancellationError() as any Error) as? StageCompositor.CompositorError == nil)
    }
}
