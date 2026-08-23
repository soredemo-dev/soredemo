import AVFoundation
import Foundation
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

    public nonisolated static func mix(_ settings: AudioMix,
                                       over tracks: [AVAssetTrack]) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.enumerated().map { index, track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            let gain = index < trackOrder.count
                ? settings.effectiveGain(for: trackOrder[index]) : 1
            parameters.setVolume(Float(gain), at: .zero)
            return parameters
        }
        return mix
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
                             of asset: sending AVAsset) async {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              !tracks.isEmpty else { return }
        item.audioMix = mix(settings, over: tracks)
    }
}
