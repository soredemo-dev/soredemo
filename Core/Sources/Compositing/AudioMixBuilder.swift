import AVFoundation
import Foundation
import Overlays
import Project

/// Turns an `AudioMix` into the `AVAudioMix` both the export and the PREVIEW apply.
///
/// **One builder, because a preview that mixed differently from the export would be a lie.** The
/// whole point of hearing a change while the video plays is to decide whether to keep it, and a
/// decision made against a different mix than the file will have is worse than no preview.
///
/// **Track order is the master's order and nothing else identifies them.** The recorder writes
/// system audio first and the microphone second — see `MasterWriting` — and an `AVAssetTrack`
/// carries no name a caller can match on. A recording whose tracks were ever written in the
/// other order would have its two sources swapped, silently, which is why the order lives here
/// as a named constant rather than as an index at a call site.
public enum AudioMixBuilder {
    /// The order the master writer lays the audio tracks down in.
    public static let trackOrder: [AudioMix.Source] = [.systemAudio, .microphone]

    /// `measured` is each track's `Loudness.Reading`, by index — its own level AND how close it
    /// already is to full scale, which is a derived value and so is passed in rather than
    /// stored. Empty means "not measured", which levelling treats as "leave it alone".
    ///
    /// **Levelling multiplies the person's gain rather than replacing it.** Someone who levels
    /// and then pulls the microphone down means both: the target is what the source is brought
    /// to, and the slider is where they want it relative to that. A muted source stays silent
    /// whatever it measures — `effectiveGain` has already applied that, and multiplying zero
    /// keeps it zero.
    public nonisolated static func mix(_ settings: AudioMix, over tracks: [AVAssetTrack],
                                       measured: [Int: Loudness.Reading] = [:],
                                       musicTrackID: CMPersistentTrackID? = nil,
                                       musicRamps: [MusicDucking.Ramp] = []) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.enumerated().map { index, track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            // **The music bed is found by track ID, never by index.** It is appended last, so
            // an index would work today and stop working the moment a recording has no system
            // audio — the tracks would shift under `trackOrder` and the microphone would be
            // levelled as though it were the bed. The ID is the composition's own answer.
            if let musicTrackID, track.trackID == musicTrackID {
                applyRamps(musicRamps, to: parameters)
                return parameters
            }
            let source = index < trackOrder.count ? trackOrder[index] : nil
            parameters.setVolume(Float(volume(for: source, in: settings,
                                              measured: measured[index])), at: .zero)
            return parameters
        }
        return mix
    }

    /// **The ducking envelope, as the volume automation `AVAudioMix` reads.** Ramps arrive
    /// ordered and abutting from `MusicDucking.ramps` — which is where that is asserted — so
    /// this only has to convert the times. An empty envelope silences the bed rather than
    /// leaving it at whatever `AVAudioMix` defaults to: no envelope means nothing asked for
    /// music, and unity on a music track under narration is the worst available outcome.
    nonisolated static func applyRamps(_ ramps: [MusicDucking.Ramp],
                                       to parameters: AVMutableAudioMixInputParameters) {
        guard !ramps.isEmpty else {
            parameters.setVolume(0, at: .zero)
            return
        }
        for ramp in ramps {
            let start = CMTime(value: ramp.start.rawValue, timescale: 1_000_000_000)
            let end = CMTime(value: ramp.end.rawValue, timescale: 1_000_000_000)
            parameters.setVolumeRamp(fromStartVolume: Float(ramp.from), toEndVolume: Float(ramp.to),
                                     timeRange: CMTimeRange(start: start, end: end))
        }
    }

    /// **The one volume rule, as a function, so it can be tested.** A track beyond the two this
    /// recorder writes has no source and is left at unity — an asset with three audio tracks did
    /// not come from here, and silencing something because it was unexpected is worse than
    /// passing it through.
    ///
    /// Levelling MULTIPLIES the person's gain rather than replacing it: the target is what the
    /// source is brought to, the slider is where they want it relative to that, and a muted
    /// source stays silent because `effectiveGain` has already made it zero.
    ///
    /// **The levelling is capped at the peak ceiling and the person's gain is not.** Levelling
    /// is this app's arithmetic and may be overruled by arithmetic; a slider somebody moved is
    /// an authored value. So a track that measures quiet but already peaks near full scale is
    /// brought up only as far as it can go without clipping, and somebody who deliberately
    /// drives a track into the red still can. See `Loudness.levellingGain`.
    public nonisolated static func volume(for source: AudioMix.Source?, in settings: AudioMix,
                                          measured: Loudness.Reading?) -> Double {
        guard let source else { return 1 }
        let gain = settings.effectiveGain(for: source)
        let levelling = settings.targetLoudness.flatMap { target in
            measured.map { Loudness.levellingGain(for: $0, to: target) }
        } ?? 1
        return gain * levelling
    }

    /// Applies `settings` to a player item that is already playing.
    ///
    /// **Set on the item rather than rebuilt into a new one**, which is what makes it audible
    /// immediately: replacing the item would reload the asset, drop the position and stop the
    /// sound for as long as that takes. `AVPlayerItem.audioMix` is honoured mid-playback.
    ///
    /// The item's own asset is used, not the caller's: a `AVPlayerItem` may hold a composition
    /// built from an edit, and mixing over the uncut asset's tracks would address tracks that
    /// item does not have.
    /// `asset` is taken as a parameter rather than read off the item, because `AVAsset` is not
    /// `Sendable` and reading it here would carry it across the isolation boundary the `await`
    /// creates. The caller already holds the asset it built the item from — and that is the one
    /// to use anyway: an item may hold a composition built from an edit, and mixing over the
    /// UNCUT asset's tracks would address tracks the item does not have.
    @MainActor
    public static func apply(_ settings: AudioMix, to item: AVPlayerItem,
                             of asset: sending AVAsset, measured: [Int: Loudness.Reading] = [:],
                             musicTrackID: CMPersistentTrackID? = nil,
                             musicRamps: [MusicDucking.Ramp] = []) async {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              !tracks.isEmpty else { return }
        item.audioMix = mix(settings, over: tracks, measured: measured,
                            musicTrackID: musicTrackID, musicRamps: musicRamps)
    }
}
