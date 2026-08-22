import CoreMedia
import Foundation

/// Maps one track's presentation timestamps onto a timeline starting at zero.
///
/// **Why a recording stuttered.** ScreenCaptureKit hands VIDEO timestamps from a synthetic
/// clock starting near zero and AUDIO timestamps from the system media clock, which counts
/// from boot. Written into one file unrebased, the tracks disagree by the machine's uptime —
/// on a machine up eleven hours, by forty thousand seconds — and a player honouring the
/// timestamps it is given produces exactly the jerky, out-of-step playback that was
/// reported. The frame rate was never the problem.
///
/// **One per TRACK, never shared.** Each clock gets its own base; a single shared base would
/// reintroduce the very offset this removes, and `eachTrackHoldsItsOwnBase` is that
/// assertion.
///
/// A `struct` rather than a class, and mutating rather than pure, because the base is
/// genuinely state: it is "whatever the first sample said", which cannot be a parameter
/// without every caller having to remember it.
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
