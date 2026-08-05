import Testing
import Foundation
import CoreMedia
import Render
import Timeline
@testable import Headless

/// `Diagnostics` starts at zero and `resetDiagnostics()` returns it there. A counter
/// nobody can read is indistinguishable from an event that never happened, which is
/// why this type exists; a counter nothing tests is the same thing one step later.
@Test func resettingDiagnosticsReturnsTheDropCountToZero() {
    StageCompositor.resetDiagnostics()
    #expect(StageCompositor.diagnostics.framesDropped == 0)
}

/// **With no observation log configured, no pointer is placed** — and that is not a
/// fifth `PointerReading` case smuggled in through a side door, it is nothing having
/// been configured to read from. Pinning it here means Task 6's positive result
/// cannot be produced by a default.
@Test func noConfiguredLogPlacesNoPointer() {
    // `observationLogURL`/`overrides` are `nonisolated(unsafe)` for the reason their own
    // declarations give (published before playback starts, read by any `StageCompositor`
    // instance) — `unsafe` here states that shape at this call site, the same way it does inside
    // `StageCompositor` itself; this is not the first caller to set them (`StageWindow.load()`
    // already does, unmarked, because the app target carries no `StrictMemorySafety` setting).
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

/// `Diagnostics` is a public type whose whole content is a count, so what is pinned is
/// that the count is readable and resettable — nothing here claims the drop path RAN.
/// `startRequest` takes an `AVAsynchronousVideoCompositionRequest`, which only
/// AVFoundation constructs, so no `swift test` test reaches the two increment sites.
/// That limit is stated rather than left for a reader to discover, because a
/// `framesDropped == 0` in a report means "the compositor was not asked" here and
/// "the compositor dropped nothing" in the app, and those are different sentences.
@Test func theDropCounterIsReadableAndResettable() {
    StageCompositor.resetDiagnostics()
    // Typed explicitly as `StageCompositor.Diagnostics`, not left to inference — this is the
    // entry rule's own scanner (`everyPublicTypeInHeadlessIsNamedByATestThatLinksTheProduct`)
    // finding a real code mention of the type name, not only of the lowercase `diagnostics`
    // property above. `Diagnostics` has no public initialiser of its own (see its declaration),
    // so naming the type at its one reachable read site — this one — is the cheapest honest
    // discharge, exactly the ceremony this task's own brief names rather than hides.
    let diagnostics: StageCompositor.Diagnostics = StageCompositor.diagnostics
    #expect(diagnostics.framesDropped == 0)
}

/// `CompositorError` is public and thrown from `startRequest`'s leading guard. Same
/// limit as above: what is pinned is that the case exists and is distinguishable from
/// another error, not that the guard fires.
@Test func theCompositorErrorIsDistinguishableFromAnotherError() {
    let error: any Error = StageCompositor.CompositorError.notConfigured
    #expect(error as? StageCompositor.CompositorError == .notConfigured)
    #expect((CancellationError() as any Error) as? StageCompositor.CompositorError == nil)
}
