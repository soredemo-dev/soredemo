import CoreMedia
import Foundation

/// Maps a recording's presentation timestamps onto a timeline starting at zero.
///
/// **ONE base for the whole recording, not one per track.** All three tracks arrive on the same
/// clock — measured, and the microphone's different timescale is not a different clock — so a
/// per-track base did not reconcile anything. It forced each track's own first sample to zero
/// and deleted the 11.8 ms between the picture and the machine's sound, and the 101.5 ms between
/// that and the microphone, which is the tenth of a second a person hears as music flanging
/// against itself. The measurements are in `docs/design/three-tracks-one-clock.md`.
///
/// A `struct` rather than a class, and mutating rather than pure, because the base is genuinely
/// state: it is "whatever the first sample said", which cannot be a parameter without every
/// caller having to remember it.
struct TrackRebase {
    private var base: CMTime?

    /// Whether a first sample has established this track's base yet.
    var hasBase: Bool { base != nil }

    init() {}

    /// `time` on a timeline where this track's first sample is zero.
    ///
    /// An INVALID time passes through unchanged and does not establish the base: a track
    /// whose first buffer arrives invalid would otherwise anchor every later sample to
    /// nonsense, and the honest behaviour is to let the next valid sample set it.
    mutating func rebased(_ time: CMTime) -> CMTime {
        guard time.isValid else { return time }
        guard let base else {
            self.base = time
            return .zero
        }
        return CMTimeSubtract(time, base)
    }
}
