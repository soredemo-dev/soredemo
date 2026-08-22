import Testing
import Foundation
import AVFoundation
import Timeline
@testable import Compositing

extension StageCompositorTests {
    @Test func tempAudioRepro() async throws {
        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.style = .default
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.overrides = []
        let asset = AVURLAsset(url: URL(fileURLWithPath: "/private/tmp/claude-501/-Users-jesse-Documents-Soredemo-soredemo-main/9e447ec5-d597-46b2-b6b4-6a5add4a4146/scratchpad/short-audio.mov"))
        let nanos = Int64(try await asset.load(.duration).seconds * 1_000_000_000)
        let edit = EditTimeline.whole(duration: Nanoseconds(nanos))
        unsafe StageCompositor.editTimeline = edit
        defer { unsafe StageCompositor.editTimeline = nil }
        let cut = try await EditedAsset.make(from: asset, by: edit)
        let cutAudio = try await cut.loadTracks(withMediaType: .audio)
        var durations: [Double] = []
        for track in cutAudio { durations.append(try await track.load(.timeRange).duration.seconds) }
        let out = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-jesse-Documents-Soredemo-soredemo-main/9e447ec5-d597-46b2-b6b4-6a5add4a4146/scratchpad/audio-repro.mp4")
        try? FileManager.default.removeItem(at: out)
        let r = try await MP4Exporter.export(asset: asset, to: out, outputWidth: 160, outputHeight: 90, edit: edit)
        let exported = AVURLAsset(url: out)
        var outDur: [Double] = []
        for track in try await exported.loadTracks(withMediaType: .audio) {
            outDur.append(try await track.load(.timeRange).duration.seconds)
        }
        print("AUDIOREPRO editedTracks=\(durations) written=\(r.audioSamplesWritten) exportedAudioDur=\(outDur) exportedTotal=\(try await exported.load(.duration).seconds)")
    }
}
