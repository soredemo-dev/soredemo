import CoreMedia
import Foundation

/// Maps a recording's presentation timestamps onto a timeline starting at zero.
///
/// **Why a recording stuttered.** Written into one file unrebased, the timestamps
/// count from boot — on a machine up eleven hours, from forty thousand seconds —
/// and a player honouring what it is given produces exactly the jerky playback
/// that was reported. The frame rate was never the problem.
///
/// **ONE base for the whole recording, and the correction is measured.** This
/// used to be one instance per track, on the reading that ScreenCaptureKit hands
/// video from "a synthetic clock starting near zero" and audio from the system
/// media clock. Measured on macOS 26, with a live stream carrying all three:
///
///     host clock at startCapture()   1092810.1749
///     first video   pts              1092810.2436   timescale 1e9
///     first system-audio pts         1092810.2554   timescale 1e9
///     first microphone   pts         1092810.3569   timescale 44100
///
/// All three are the SAME clock, and the timescales differ without the clock
/// differing. What a per-track base did, then, was force each track's own first
/// sample to zero and throw away the offsets BETWEEN them: 11.8 ms of video-to-
/// system-audio, and **101.5 ms of system-audio-to-microphone**.
///
/// That second number is audible and was reported as such — a demo with music
/// playing has the music twice, once through the system tap and once through the
/// microphone, and a tenth of a second apart they flange against each other. The
/// same misalignment was measured independently at about 91 ms in an exported
/// recording, from the correlation between the mixed track's mid and side
/// channels.
///
/// So the base is taken once, from the first sample the recording writes, and
/// every track subtracts it. The uptime offset is removed just as completely — it
/// is one subtraction either way — and the real offsets survive, which is the
/// whole point of putting three tracks in one file.
///
/// A `struct` rather than a class, and mutating rather than pure, because the
/// base is genuinely state: it is "whatever the first sample said", which cannot
/// be a parameter without every caller having to remember it.
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
