import AVFoundation
import Foundation
import Overlays
import Timeline

/// **Runs the room-removal pass over a recording's audio and hands back a file.**
///
/// The division of labour here is the point. `NoiseReduction` (pure tier) knows the arithmetic
/// and nothing about files; `AudioSamples` knows how to move PCM in and out of one and nothing
/// about noise; this knows the ORDER — find the quiet, measure it, subtract it, write the result —
/// and owns none of the three. Each of them has one reason to change, and the two that can be
/// tested on synthetic input are the two that do not touch the disk.
///
/// **The master recording is never modified.** A cleaned copy is written beside it and the
/// composition reads that instead. Undoing noise removal is deleting a file; the evidence the
/// recording is, is still the recording.
public enum NoiseReducedAudio {
    /// Why a recording came back unprocessed. **Every one of these is a named value rather than a
    /// `nil` that a caller could read as success**, because "we cleaned it" and "there was nothing
    /// we could do" look identical in the output otherwise.
    public enum Refusal: Hashable, Sendable, CustomStringConvertible {
        case noAudioTrack
        case tooShort(seconds: Double)
        case noMeasurableSilence

        public var description: String {
            switch self {
            case .noAudioTrack:
                "there is no audio in this recording"
            case .tooShort(let seconds):
                // Two decimals without `String(format:)`, which is C varargs and therefore an
                // unsafe construct this package would have to justify at every call site.
                "the recording is \((seconds * 100).rounded() / 100) s long, too short to measure a room in"
            case .noMeasurableSilence:
                """
                there is no measurable silence in this recording, so the room could not be \
                measured. Noise removal needs a moment where nobody is talking
                """
            }
        }
    }

    public enum Outcome: Sendable {
        case reduced(URL)
        case refused(Refusal)
    }

    /// How the recording is sliced when looking for quiet. Matches `WaveformEnvelope` so that the
    /// silences found here are the same silences the timeline draws and the dead-air cut removes —
    /// three features disagreeing about where the quiet is would be worse than any of them being
    /// slightly wrong.
    static var slicesPerSecond: Double { WaveformEnvelope.slicesPerSecond }

    /// The shortest recording worth processing. Below this there is not enough of anything —
    /// speech or silence — for a profile to mean something.
    public static let minimumSeconds: Double = 1.0

    /// **Which track the microphone is, by the one named constant that answers that.**
    ///
    /// `AudioMixBuilder.trackOrder` is where the master writer's layout is written down, and
    /// every part of the app that has to tell the two audio tracks apart reads it rather than
    /// writing `1`. Noise removal must not touch system audio: a game's soundtrack is not a room
    /// to be subtracted, and the hiss "removed" from it would be the music.
    public static var microphoneTrackIndex: Int? {
        AudioMixBuilder.trackOrder.firstIndex(of: .microphone)
    }

    /// Cleans one of `asset`'s audio tracks and writes it to `destination`.
    ///
    /// **One track, not the mix.** A Soredemo recording has system audio and a microphone as
    /// separate tracks, and a person mixes them separately; reading them as one signal and
    /// writing one back would collapse that and make both gain sliders meaningless. The default
    /// is the microphone, because that is the only one a room is in.
    ///
    /// **The silence is found from the samples already in memory**, not by re-reading the file
    /// through `WaveformEnvelope`. Same arithmetic, same slice rate, one read.
    public nonisolated static func write(from asset: AVAsset, to destination: URL,
                                         trackIndex: Int? = microphoneTrackIndex,
                                         settings: NoiseReduction.Settings = .default,
                                         silence: SilenceFinder.Settings = .default)
    async throws -> Outcome {
        guard let track = try await AudioSamples.read(from: asset, trackIndex: trackIndex) else {
            return .refused(.noAudioTrack)
        }
        guard track.seconds >= minimumSeconds else {
            return .refused(.tooShort(seconds: track.seconds))
        }

        let quiet = quietSampleRanges(in: track, settings: silence)
        guard let profile = NoiseReduction.profile(samples: track.samples, quiet: quiet) else {
            return .refused(.noMeasurableSilence)
        }
        let cleaned = NoiseReduction.reduced(samples: track.samples, profile: profile,
                                             settings: settings)
        try AudioSamples.write(AudioSamples.Track(samples: cleaned, sampleRate: track.sampleRate),
                               to: destination)
        return .reduced(destination)
    }

    /// The half-open sample ranges `SilenceFinder` considers quiet.
    ///
    /// **Internal rather than private, because it is the joint between two things that must
    /// agree**, and a test that cannot see it can only check the pair through a whole file.
    static func quietSampleRanges(in track: AudioSamples.Track,
                                  settings: SilenceFinder.Settings = .default) -> [Range<Int>] {
        guard track.sampleRate > 0, !track.samples.isEmpty else { return [] }
        let samplesPerSlice = Swift.max(Int(track.sampleRate / slicesPerSecond), 1)
        var peaks: [Float] = []
        peaks.reserveCapacity(track.samples.count / samplesPerSlice + 1)
        var index = 0
        while index < track.samples.count {
            let end = Swift.min(index + samplesPerSlice, track.samples.count)
            var peak: Float = 0
            for i in index..<end { peak = Swift.max(peak, abs(track.samples[i])) }
            peaks.append(peak)
            index = end
        }
        let sliceSeconds = Double(samplesPerSlice) / track.sampleRate
        return SilenceFinder.spans(peaks: peaks, sliceSeconds: sliceSeconds, settings: settings)
            .map { span in
                // **Nanoseconds back to samples, rounded inward and clamped into the array.**
                //
                // Inward is a sub-sample courtesy and nothing more, which is worth saying because
                // the first version of this comment claimed it was what kept speech out of the
                // profile. It is not: a mutation that rounded outward left every test green.
                // `SilenceFinder.Settings.paddingSeconds` is what actually holds the edge — it
                // pulls each span in by tens of milliseconds before this ever sees it — and
                // `NoiseReduction.profile` then takes only windows lying ENTIRELY inside. One
                // sample either way is noise against both of those.
                let lower = Int((Double(span.start.rawValue) / 1e9 * track.sampleRate).rounded(.up))
                let upper = Int((Double(span.end.rawValue) / 1e9 * track.sampleRate).rounded(.down))
                return Swift.max(lower, 0)..<Swift.min(Swift.max(upper, 0), track.samples.count)
            }
            .filter { !$0.isEmpty }
    }

    /// Where a cleaned copy of `source` belongs.
    ///
    /// **Keyed by the settings as well as the file.** Changing the strength and getting the
    /// previous result back is the cache bug this shape prevents; the alternative — deleting on
    /// every settings change — throws away a result somebody may switch back to within seconds.
    public static func destination(for source: URL, settings: NoiseReduction.Settings,
                                   in directory: URL) -> URL {
        let key = "\(Int((settings.strength * 1000).rounded()))-\(Int((settings.floor * 1000).rounded()))"
        return directory.appending(path: "\(source.deletingPathExtension().lastPathComponent)-quiet-\(key).caf")
    }
}
