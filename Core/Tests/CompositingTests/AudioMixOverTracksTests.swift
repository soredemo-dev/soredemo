import AVFoundation
import Foundation
import Overlays
import Project
import Testing
import Timeline
@testable import Compositing

/// **The mix applied to real tracks** — `AudioMixBuilder.mix` is what the preview plays through,
/// and its tests stopped at the track-order constant and an empty input. These read back the
/// volume AVFoundation was actually given for each track of `two-track-audio.mov` (system audio
/// first, microphone second, as the master writes them).

private func tracks() async throws -> [AVAssetTrack] {
    let url = repositoryRootFromTests.appending(path: "Tests/RenderParityFixtures/two-track-audio.mov")
    let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
    try #require(tracks.count == 2, "the fixture has \(tracks.count) audio tracks, not two")
    return tracks
}

/// The volume a parameter set holds at `time`, or `nil` when it holds none.
private func volume(of parameters: AVAudioMixInputParameters, at time: CMTime)
-> (start: Float, end: Float, range: CMTimeRange)? {
    var start: Float = -1, end: Float = -1, range = CMTimeRange.invalid
    guard unsafe parameters.getVolumeRamp(for: time, startVolume: &start, endVolume: &end,
                                          timeRange: &range) else { return nil }
    return (start, end, range)
}

@Suite struct AudioMixOverTracksTests {
    /// A gain is set on its own source's track and nowhere else — 0.4 on the microphone, which is
    /// second, and the system audio left at one. A mix that numbered the sources the other way
    /// round would turn the wrong voice down.
    @Test func eachSourcesGainReachesItsOwnTrack() async throws {
        let mix = AudioMixBuilder.mix(AudioMix().setting(.microphone, gain: 0.4), over: try await tracks())
        try #require(mix.inputParameters.count == 2)
        #expect(volume(of: mix.inputParameters[0], at: .zero)?.start == 1)
        #expect(abs((volume(of: mix.inputParameters[1], at: .zero)?.start ?? -1) - 0.4) < 1e-6)
    }

    /// Levelling multiplies the gain by what brings the MEASURED track to the target — computed
    /// here from the loudness module's own rule, not from the mix.
    @Test func levellingIsTheGainTimesWhatReachesTheTarget() async throws {
        let reading = Loudness.Reading(integrated: -30, peak: 0.05)
        let settings = AudioMix().setting(.microphone, gain: 0.5).settingTargetLoudness(-16)
        let expected = 0.5 * Loudness.levellingGain(for: reading, to: -16)
        let mix = AudioMixBuilder.mix(settings, over: try await tracks(), measured: [1: reading])
        #expect(abs(Double(volume(of: mix.inputParameters[1], at: .zero)?.start ?? -1) - expected) < 1e-4)
        #expect(expected > 0.5, "the fixture's reading is quieter than the target, so levelling lifts it")
    }

    /// The music bed follows its ducking ramps and nothing else — no source gain applies to it.
    @Test func theMusicTrackFollowsItsRamps() async throws {
        let all = try await tracks()
        let ramp = MusicDucking.Ramp(start: Nanoseconds(1_000_000_000), end: Nanoseconds(1_500_000_000),
                                     from: 0.8, to: 0.3)
        let mix = AudioMixBuilder.mix(AudioMix().setting(.systemAudio, gain: 0.1), over: all,
                                      musicTrackID: all[0].trackID, musicRamps: [ramp])
        let during = try #require(volume(of: mix.inputParameters[0], at: CMTime(value: 1_200, timescale: 1_000)))
        #expect(abs(during.start - 0.8) < 1e-6 && abs(during.end - 0.3) < 1e-6)
        #expect(abs(during.range.start.seconds - 1.0) < 1e-6 && abs(during.range.duration.seconds - 0.5) < 1e-6)
    }

    /// A bed with no ramps is silent rather than at full level: no ramps means there was no speech
    /// analysis to duck against, and a bed at unity over an unmeasured voice is the loud mistake.
    @Test func aMusicTrackWithNoRampsIsSilent() async throws {
        let all = try await tracks()
        let mix = AudioMixBuilder.mix(.unchanged, over: all, musicTrackID: all[1].trackID, musicRamps: [])
        #expect(volume(of: mix.inputParameters[1], at: .zero)?.start == 0)
    }
}
