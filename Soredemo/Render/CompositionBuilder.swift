import AVFoundation
import Foundation
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
enum CompositionBuilder {
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
    nonisolated static func composition(for asset: AVAsset, outputWidth: Int, outputHeight: Int,
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
        // `CGGeometryBridge.renderSize`, not a literal `CGSize(...)` here: rule 5
        // (`AppSourceAllowListTests.coreGraphicsGeometryTypesAppearOnlyInTheBridge`) confines
        // `CGSize` to that one file — see the bridge's own doc comment on `renderSize(width:
        // height:)` for why this is a correction to the task brief, the same correction Task 3
        // made for `CoreImageFrameRenderer`'s crop rectangle.
        configuration.renderSize = CGGeometryBridge.renderSize(width: outputWidth, height: outputHeight)
        configuration.frameDuration = frameDuration
        return AVVideoComposition(configuration: configuration)
    }

    enum BuilderError: Error { case noVideoTrack }
}
