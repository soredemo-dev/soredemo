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
    static func composition(for asset: AVAsset, outputWidth: Int, outputHeight: Int,
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
