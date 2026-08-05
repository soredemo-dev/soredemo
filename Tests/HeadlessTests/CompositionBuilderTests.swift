import Testing
import Foundation
import AVFoundation
import CoreMedia
import Render
@testable import Headless

/// …/Tests/HeadlessTests/CompositionBuilderTests.swift → the repository root.
///
/// A per-target duplicate of the same `#filePath` walk `Tests/GeometryTests/ArchitectureCheckTests.swift:5`
/// already declares — test targets cannot share a declaration across targets, so this is the
/// second copy of that walk, not a divergent one: same three `deletingLastPathComponent()` calls,
/// because this file sits at the same depth (`Tests/<Target>/<File>.swift`) that one does.
let repositoryRootFromTests = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// `CompositionBuilder`'s entry-rule discharge, against a REAL asset —
/// `Tests/RenderParityFixtures/two-tone.mov`, the file the cross-boundary probe
/// already composes. A synthesised asset would test the builder against an input
/// shape nothing else in this repository uses.
///
/// **`composition(for:outputWidth:outputHeight:frameDuration:)`, not `build(from:style:)`.** The
/// task brief's listing named a `build(from:style:)` entry point; the real one — read off
/// `Sources/Headless/CompositionBuilder.swift` after the move, and unchanged by the move itself —
/// is `composition(for:outputWidth:outputHeight:frameDuration:)`, with no `style` parameter at
/// all (the style `StagePlanner` needs lives on `StageCompositor.style`, read inside
/// `startRequest`, not passed through this builder). This test calls the real signature.
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

/// The failure the builder names. An asset with no video track is a real condition —
/// an audio-only recording, or a file that failed to write its video track — and the
/// builder must say so rather than build an empty composition.
///
/// **`AVMutableComposition()`, not a zero-byte file on disk — corrected from the brief's
/// listing, measured.** The brief's original shape wrote `Data()` to a `.mov` path and opened
/// that as an `AVURLAsset`. Run as written, `asset.loadTracks(withMediaType: .video)` itself
/// throws — an empty file is not a parseable QuickTime container, so AVFoundation reports
/// `AVFoundationErrorDomain Code=-11829 "Cannot Open"` ("This media may be damaged") before
/// `CompositionBuilder`'s own `guard let track = tracks.first else { throw .noVideoTrack }` is
/// ever reached. That tests "AVFoundation refuses a corrupt file", not "the builder rejects an
/// asset with no video track" — a different failure this test is not named for. `AVComposition`
/// is itself an `AVAsset` subclass; an empty `AVMutableComposition()` has zero tracks of any
/// kind, loads instantly with no file I/O, and reaches the builder's own `guard` reliably —
/// which is the condition this test is actually named for.
@Test func anAssetWithNoVideoTrackIsRejected() async throws {
    let empty = AVMutableComposition()

    await #expect(throws: CompositionBuilder.BuilderError.noVideoTrack) {
        _ = try await CompositionBuilder.composition(
            for: empty, outputWidth: 640, outputHeight: 360,
            frameDuration: CMTime(value: 1, timescale: 60))
    }
}
