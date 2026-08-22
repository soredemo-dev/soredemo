import AVFoundation
import Foundation
// `HeadlessGeometryBridge` and `StageCompositor` are same-module names and need no import.

/// Builds one composition, handed to both the preview and the export.
/// `AVVideoComposition.Configuration` rather than `AVMutableVideoComposition`, which is deprecated
/// at macOS 26.0, this project's floor.
public enum CompositionBuilder {
    /// `nonisolated` so `MP4Exporter.export` can call it: passing the non-`Sendable` `AVAsset` into
    /// a `@MainActor` function is a region-isolation error. The `Headless` target must also enable
    /// `NonisolatedNonsendingByDefault`, since a `nonisolated async` function's calling convention
    /// belongs to the declaring module.
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
        // Rule 5 confines `CGSize` to one file per tier, so no literal here.
        configuration.renderSize = HeadlessGeometryBridge.renderSize(width: outputWidth, height: outputHeight)
        configuration.frameDuration = frameDuration
        return AVVideoComposition(configuration: configuration)
    }

    public enum BuilderError: Error, Equatable { case noVideoTrack }
}
