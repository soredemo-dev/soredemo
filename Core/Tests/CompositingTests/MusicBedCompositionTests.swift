import AVFoundation
import Foundation
import Testing
@testable import Compositing

/// **A music bed with no camera** — `CameraComposition.combine`'s other path, which nothing ran.
///
/// The piece is 0.75 s under a 2 s recording, so it must be LOOPED to cover it. A piece as long
/// as the recording would pass whether or not the loop works — the identity case for looping.

private func musicFile(seconds: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("music-\(UUID().uuidString).caf")
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                            channels: 1, interleaved: false))
    let file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * 48_000)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    // `unsafe`: the buffer's channel pointer, read while `buffer` is alive in this scope.
    let channel = try unsafe #require(unsafe buffer.floatChannelData)[0]
    for index in 0..<Int(frames) { unsafe channel[index] = Float(0.1 * sin(Double(index) * 0.05)) }
    try file.write(from: buffer)
    return url
}

private var screenURL: URL {
    repositoryRootFromTests.appending(path: "Tests/RenderParityFixtures/two-tone.mov")
}

@MainActor @Suite struct MusicBedCompositionTests {
    @Test func aShortPieceIsLoopedToCoverTheWholeRecording() async throws {
        let music = try musicFile(seconds: 0.75)
        defer { try? FileManager.default.removeItem(at: music) }
        let screen = AVURLAsset(url: screenURL)
        let combined = try await CameraComposition.combine(screen: screen, cameraURL: nil,
                                                           musicURL: music)
        let trackID = try #require(combined.musicTrackID)
        #expect(combined.cameraTrackID == nil)
        let track = try #require(try await combined.asset.loadTrack(withTrackID: trackID))
        let covered = try await track.load(.timeRange)
        #expect(covered.start == .zero)
        #expect(abs(covered.duration.seconds - 2.0) < 0.001, "music covers \(covered.duration.seconds) s of 2")
        #expect(try await combined.asset.loadTracks(withMediaType: .video).count == 1)
    }

    /// A chosen file that has gone missing is not an error, and not silence stitched in: the
    /// recording plays as it was.
    ///
    /// **Held in two places, and this reddens only when both go** — measured by mutation: the
    /// existence check in `combine`, and the `try?` around `insertMusic`, which turns an
    /// unreadable file into "no music" rather than an error. Either alone keeps it green.
    @Test func aMissingPieceLeavesTheRecordingAsItIs() async throws {
        let screen = AVURLAsset(url: screenURL)
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString).caf")
        let combined = try await CameraComposition.combine(screen: screen, cameraURL: nil, musicURL: gone)
        #expect(combined.asset === screen)
        #expect(combined.musicTrackID == nil)
    }

    /// A file with no sound in it — somebody picked a video — gives no music track, and the
    /// recording plays as it was rather than as a composition with an empty track.
    @Test func aPieceWithNoSoundGivesNoMusicTrack() async throws {
        let screen = AVURLAsset(url: screenURL)
        let combined = try await CameraComposition.combine(screen: screen, cameraURL: nil,
                                                           musicURL: screenURL)
        #expect(combined.musicTrackID == nil)
        #expect(combined.asset === screen)
    }
}
