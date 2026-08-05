import AVFoundation
import Foundation
// `HeadlessGeometryBridge` (Phase 3A-1 Task 2) and `StageCompositor` (Task 4, this move) no
// longer need an import: this file now lives IN the `Headless` module that declares them. A
// module does not import itself — the `import Headless` this file carried while it still lived
// in the app target is gone, not merely redundant.
import Render

/// Builds ONE composition, handed to both the preview and the export.
///
/// `AVVideoComposition.Configuration` and not `AVMutableVideoComposition`: the mutable class is
/// deprecated at macOS **26.0**, this project's own floor, so it was never available here. The
/// value type is also what makes D8's "one render path" a fact about a type rather than a rule two
/// call sites must remember.
///
/// **`async throws`, corrected from the brief.** The brief's literal text for
/// `AVVideoComposition.Configuration(for:prototypeInstruction:)` omits both `async` and `throws`;
/// the initialiser is both — confirmed by typechecking this exact function body at
/// `-target arm64-apple-macos26.0` before writing this file. Everything else below typechecked as
/// the brief specified.
public enum CompositionBuilder {
    /// `nonisolated`, added for Phase 2B Task 7 and beyond that task's own file list — a
    /// correction of the same shape `CGGeometryBridge.swift`'s own functions record for Task 8:
    /// nothing here reads AppKit or UI state, it is `AVAsset`/`AVVideoComposition` construction,
    /// so there is no reason for this to inherit the app target's `@MainActor` default. Without
    /// it, `MP4Exporter.export` — itself `nonisolated`, for the reason its own header gives
    /// (`AVAssetWriter.finishWriting(_:)`'s completion handler runs off an AVFoundation-owned
    /// queue) — cannot call this function at all: passing the non-`Sendable` `AVAsset` from a
    /// `nonisolated` context to a `@MainActor`-isolated one is exactly
    /// `#RegionIsolation::SendingRisksDataRace`, measured directly (`xcrun swiftc` rejected it
    /// before this was added). `StageWindow.load()`, the preview's own call site, stays
    /// `@MainActor` by the app's default and calls this exactly as before — a `nonisolated async`
    /// function is callable from any isolation, so this is a widening, not a move.
    ///
    /// **Cross-module concurrency mismatch found in Task 4, and the fix's own history — corrected
    /// in code review, fix round 1.** Moving this function into the `Headless` module (from the
    /// app target, where it lived through Task 3) made `xcodebuild -project Soredemo.xcodeproj`
    /// fail at `MP4Exporter.swift`'s call site with the SAME diagnostic tag the paragraph above
    /// already names — `#RegionIsolation::SendingRisksDataRace` — even though `MP4Exporter.export`
    /// and this function were both already `nonisolated` before the move. `swift build`/`swift
    /// test` never saw it: at the time, neither compiled `MP4Exporter.swift`, which was still an
    /// app-target file (`Soredemo/Export/MP4Exporter.swift`) through Task 6 — **corrected here in
    /// Task 7, which moved that file into this same `Headless` module** (`Sources/Headless
    /// /MP4Exporter.swift`), so `swift build`/`swift test` compile it now; this paragraph
    /// describes why the mismatch was invisible to them AT THE TIME it was found, not a fact that
    /// still holds today. Root cause:
    /// the app target builds with `SWIFT_APPROACHABLE_CONCURRENCY = YES`
    /// (`Soredemo.xcodeproj`'s own setting), which enables the `NonisolatedNonsendingByDefault`
    /// upcoming feature for code the APP TARGET declares — but the calling convention of a
    /// `nonisolated async` function is a property of the module that DECLARES it, not of its
    /// caller, and `Package.swift` enabled no such feature for `Headless`. Without it, this
    /// function hopped to the global concurrent executor on every call, so the non-`Sendable`
    /// `AVAsset` `MP4Exporter.export` passes in genuinely crossed an isolation domain the app
    /// target's own build no longer crosses for functions declared inside the app target itself.
    ///
    /// The first attempt fixed this with `nonisolated(nonsending)` on this one declaration
    /// (SE-0461's per-declaration spelling of the same calling convention) rather than the
    /// module-wide `Package.swift` flag, because the module-wide flag APPEARED to crash `swift
    /// test` with `EXC_BAD_ACCESS` inside `objc_msgSend`, called from this function's own
    /// `asset.loadTracks(withMediaType:)`. Fix round 1 re-measured that claim from a clean
    /// `.build` and could not reproduce it — `swift test`, `swift test --parallel`, and
    /// `xcodebuild` all passed repeatedly with the module-wide flag in place and no per-
    /// declaration annotation. The likeliest explanation is a stale, mixed-ABI `.build` directory
    /// from an incremental rebuild during the first attempt's own investigation, not a real
    /// defect in this toolchain or in the flag — a `Package.swift`-level setting change was
    /// tested incrementally rather than from `rm -rf .build`, and the crash never reproduced
    /// again once verified clean. The actual, shipped fix is `.enableUpcomingFeature
    /// ("NonisolatedNonsendingByDefault")` on the `Headless` target in `Package.swift` — narrower
    /// than the app target's own setting (scoped to the one package target the app and the probe
    /// both compile this file's kin against), and consistent with the principle
    /// `scripts/run-cross-boundary-probe.sh` already states for its own compile of these same
    /// two files (commit `ab941a9`): the probe, the app target and `Headless` must compile this
    /// code under the SAME language semantics, or a change can pass one and fail another. This
    /// function carries no isolation annotation of its own beyond the plain `nonisolated` above;
    /// the calling convention comes from the target's build setting, as it should.
    public nonisolated static func composition(for asset: AVAsset, outputWidth: Int, outputHeight: Int,
                            frameDuration: CMTime) async throws -> AVVideoComposition {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw BuilderError.noVideoTrack }
        let duration = try await asset.load(.duration)

        let layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        let instruction = AVVideoCompositionInstruction.Configuration(
            backgroundColor: nil, enablePostProcessing: false,
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            requiredSourceSampleDataTrackIDs: [],
            timeRange: CMTimeRange(start: .zero, duration: duration))

        var configuration = try await AVVideoComposition.Configuration(
            for: asset,
            prototypeInstruction: AVVideoCompositionInstruction(configuration: instruction))
        configuration.customVideoCompositorClass = StageCompositor.self
        // `HeadlessGeometryBridge.renderSize`, not a literal `CGSize(...)` here: rule 5
        // (`AppSourceAllowListTests.coreGraphicsGeometryTypesAppearOnlyInTheBridge`) confines
        // `CGSize` to one file per tier — see the bridge's own doc comment on `renderSize(width:
        // height:)` for why this is a correction to the task brief, the same correction Task 3
        // made for `CoreImageFrameRenderer`'s crop rectangle. It moved to
        // `Sources/Headless/HeadlessGeometryBridge.swift` in Phase 3A-1 Task 2.
        configuration.renderSize = HeadlessGeometryBridge.renderSize(width: outputWidth, height: outputHeight)
        configuration.frameDuration = frameDuration
        return AVVideoComposition(configuration: configuration)
    }

    public enum BuilderError: Error, Equatable { case noVideoTrack }
}
