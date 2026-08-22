import Testing
import Foundation
import AVFoundation
import CoreMedia
import Render
@testable import Compositing

/// …/Tests/CaptureTests/CompositionBuilderTests.swift → the repository root. Three components,
/// because this file sits at `Tests/<Target>/<File>.swift`. Duplicated per target on purpose:
/// test targets cannot share a declaration.
let repositoryRootFromTests = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The builder produces a non-degenerate render size and installs `StageCompositor`, against a
/// REAL asset — `Tests/RenderParityFixtures/two-tone.mov`, the file the cross-boundary probe
/// already composes — rather than an input shape nothing else in this repository uses.
@Test func aCompositionIsBuiltFromARealAssetAndInstallsTheStageCompositor() async throws {
    let asset = AVURLAsset(url: repositoryRootFromTests
        .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
    let composition = try await CompositionBuilder.composition(
        for: asset, outputWidth: 640, outputHeight: 360,
        frameDuration: CMTime(value: 1, timescale: 60))

    #expect(composition.renderSize.width > 0 && composition.renderSize.height > 0)
    #expect(composition.customVideoCompositorClass == StageCompositor.self,
            "the composition does not install StageCompositor; nothing this phase tests would run")
}

/// An asset with no video track is rejected by name. `AVMutableComposition()`, NOT a zero-byte
/// `.mov`: an unparseable file makes `loadTracks` itself throw, so the builder's own
/// `noVideoTrack` guard is never reached and the test would measure AVFoundation instead.
@Test func anAssetWithNoVideoTrackIsRejected() async throws {
    let empty = AVMutableComposition()

    await #expect(throws: CompositionBuilder.BuilderError.noVideoTrack) {
        _ = try await CompositionBuilder.composition(
            for: empty, outputWidth: 640, outputHeight: 360,
            frameDuration: CMTime(value: 1, timescale: 60))
    }
}
