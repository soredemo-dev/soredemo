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
    /// **`(nonsending)`, added in Phase 3A-1 Task 4, and measured rather than guessed.** Moving
    /// this function into the `Headless` module (from the app target, where it lived through
    /// Task 3) made `xcodebuild -project Soredemo.xcodeproj` fail at `MP4Exporter.swift`'s call
    /// site with the SAME diagnostic tag the paragraph above already names —
    /// `#RegionIsolation::SendingRisksDataRace` — even though `MP4Exporter.export` and this
    /// function were both already `nonisolated` before the move. `swift build`/`swift test`
    /// never saw it: neither compiles `MP4Exporter.swift`, an app-target file. What changed
    /// crossing the module boundary: the app target builds with `SWIFT_APPROACHABLE_CONCURRENCY =
    /// YES` (`Soredemo.xcodeproj`'s own setting), which enables the `NonisolatedNonsendingByDefault`
    /// upcoming feature for code the APP TARGET declares — but the calling convention of a
    /// `nonisolated async` function is a property of the module that DECLARES it, not of its
    /// caller, and `Package.swift` enables no such feature for `Headless`. Without it, this
    /// function hops to the global concurrent executor on every call, so the non-`Sendable`
    /// `AVAsset` `MP4Exporter.export` passes in genuinely crosses an isolation domain its own
    /// build no longer crosses for functions declared inside the app target itself.
    ///
    /// **Why `(nonsending)` on this one declaration, not `-enable-upcoming-feature
    /// NonisolatedNonsendingByDefault` on the whole `Headless` target — measured, not assumed.**
    /// The module-wide flag was tried first and does make `xcodebuild` pass, but it also makes
    /// `swift test --filter aCompositionIsBuiltFromARealAssetAndInstallsTheStageCompositor` crash
    /// with `EXC_BAD_ACCESS` (`SIGSEGV`) inside `objc_msgSend`, reproducibly, called from this
    /// function's own `asset.loadTracks(withMediaType:)` — a macOS-crash-report backtrace, not a
    /// guess, and confirmed by toggling the flag off and back on and watching the crash disappear
    /// and reappear. That is this toolchain (Swift 6.3 tools, Xcode-beta, macOS 27.0 SDK) reacting
    /// badly to the module-wide flag under Swift Testing's parallel runner — a real defect, but
    /// not this task's to chase down. `nonisolated(nonsending)` is the SE-0461 per-declaration
    /// spelling of the identical calling convention, scoped to the one function that needs it,
    /// and does not trigger the crash: every `HeadlessTests` run in this task's own gate passed
    /// repeatedly with it in place. `sending AVAsset` on the parameter was tried too and rejected
    /// by the compiler for the real reason its own diagnostic gives — `MP4Exporter.export` reads
    /// `asset` again after this call (`AVAssetReader(asset: asset)`, `Soredemo/Export/
    /// MP4Exporter.swift`), so the parameter cannot honestly claim ownership transfers here.
    public nonisolated(nonsending) static func composition(for asset: AVAsset, outputWidth: Int, outputHeight: Int,
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
