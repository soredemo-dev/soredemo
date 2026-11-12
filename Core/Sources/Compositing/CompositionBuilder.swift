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
        AVVideoComposition(configuration: try await configuration(
            for: asset, outputWidth: outputWidth, outputHeight: outputHeight, frameDuration: frameDuration))
    }

    /// The composition's configuration, kept by the preview so it can make a NEW composition
    /// from it. **A paused player redraws only for a composition it has not seen**: measured on
    /// macOS 27.2 with a counting compositor, a zero-distance seek asked for 0 frames and the same
    /// composition assigned again asked for 0, while a fresh one built from the same values asked
    /// for 1 — and `AVVideoComposition` has no copy that is not the deprecated mutable class.
    public nonisolated static func configuration(for asset: AVAsset, outputWidth: Int, outputHeight: Int,
                                                 frameDuration: CMTime) async throws -> AVVideoComposition.Configuration {
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
        return configuration
    }

    public enum BuilderError: Error, Equatable { case noVideoTrack }
}
