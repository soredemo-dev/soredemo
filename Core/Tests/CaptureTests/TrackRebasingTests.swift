import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Capture

// The fourth defect a real window recording showed: stuttering, jerky playback.
//
// ScreenCaptureKit hands VIDEO timestamps from one clock and AUDIO timestamps from another —
// video from a synthetic clock near zero, audio from the system media clock, which counts
// from boot. Written into one file without rebasing, the two tracks disagree by the
// machine's uptime, and a player honouring timestamps shows exactly that symptom.
//
// `TrackRebase` is the arithmetic, extracted so it can be tested without a stream: the
// session holds one per track and asks it to map every buffer's PTS.

/// The rebase maps a track's FIRST sample to zero, whatever its clock started at. Uptime is
/// the number that made this a bug — a machine up for eleven hours hands audio timestamps
/// around 40,000 s while video starts near 0.
@Test func aTracksFirstSampleRebasesToZeroWhateverItsClockReads() {
    var rebase = TrackRebase()
    let uptime = CMTime(seconds: 39_600, preferredTimescale: 600)   // 11 hours
    #expect(rebase.rebased(uptime) == .zero)
}

/// And subsequent samples keep their spacing: a rebase that mapped everything to zero would
/// pass the test above and produce a track with no duration.
@Test func laterSamplesKeepTheirSpacingAfterRebasing() {
    var rebase = TrackRebase()
    let base = CMTime(seconds: 39_600, preferredTimescale: 600)
    _ = rebase.rebased(base)
    let quarterSecondLater = CMTimeAdd(base, CMTime(seconds: 0.25, preferredTimescale: 600))
    let rebased = rebase.rebased(quarterSecondLater)
    #expect(abs(rebased.seconds - 0.25) < 1e-6, "spacing became \(rebased.seconds)")
}

/// **The defect, stated as a comparison.** Two tracks whose clocks differ by an entire
/// uptime rebase onto ONE timeline: a video sample and an audio sample that happened
/// together land together. Without rebasing they differ by eleven hours, which is the
/// stutter — the player honours the timestamps it is given.
@Test func twoTracksOnDifferentClocksLandOnOneTimeline() {
    var video = TrackRebase()
    var audio = TrackRebase()
    // The same instant, reported by two clocks: video's synthetic one near zero, audio's
    // system media clock counting from boot.
    let videoStart = CMTime(seconds: 0.05, preferredTimescale: 600)
    let audioStart = CMTime(seconds: 39_600.05, preferredTimescale: 600)
    _ = video.rebased(videoStart)
    _ = audio.rebased(audioStart)

    let halfASecond = CMTime(seconds: 0.5, preferredTimescale: 600)
    let videoLater = video.rebased(CMTimeAdd(videoStart, halfASecond))
    let audioLater = audio.rebased(CMTimeAdd(audioStart, halfASecond))
    #expect(abs(videoLater.seconds - audioLater.seconds) < 1e-6, """
        half a second into the recording the two tracks are \(videoLater.seconds) and \
        \(audioLater.seconds) apart — they are not on one timeline
        """)

    // And the unrebased values genuinely differ, or this test proves nothing.
    #expect(abs(audioStart.seconds - videoStart.seconds) > 1000)
}

/// An invalid PTS cannot establish a base — a track whose first buffer arrives invalid would
/// otherwise anchor every later sample to nonsense. It passes through unchanged and the next
/// valid sample sets the base.
@Test func anInvalidTimestampDoesNotBecomeTheBase() {
    var rebase = TrackRebase()
    #expect(rebase.rebased(.invalid) == .invalid)
    let real = CMTime(seconds: 100, preferredTimescale: 600)
    #expect(rebase.rebased(real) == .zero, "an invalid first sample anchored the track")
}

/// **One base for the whole recording, which is the reverse of what this test used to
/// assert.**
///
/// It read: "Rebasing is per TRACK, not shared: video and audio have their own bases
/// because they have their own clocks, and one shared base would reintroduce the offset it
/// removes." Measured on macOS 26 with a live stream carrying video, system audio and
/// microphone at once, that premise is false — all three arrive on the same clock, and the
/// per-track base was not removing an offset between clocks but destroying one between
/// tracks:
///
///     first video   pts   1092810.2436
///     first system  pts   1092810.2554     +11.8 ms after the video
///     first mic     pts   1092810.3569    +101.5 ms after the system audio
///
/// A tenth of a second is audible. A demo with music playing captures it twice — once
/// through the system tap, once through the microphone — and forced to a common zero the
/// two copies flange against each other, which is what was reported.
@Test func oneBaseSpansEveryTrackSoTheOffsetsBetweenThemSurvive() {
    var rebase = TrackRebase()
    // The numbers are the measured ones, on the clock they were measured on.
    let video = CMTime(value: 1_092_810_243_617_375, timescale: 1_000_000_000)
    let system = CMTime(value: 1_092_810_255_370_250, timescale: 1_000_000_000)
    let microphone = CMTime(value: 1_092_810_356_916_099, timescale: 1_000_000_000)

    #expect(rebase.rebased(video) == .zero, "the first sample is composition time zero")
    let systemOffset = rebase.rebased(system).seconds
    let microphoneOffset = rebase.rebased(microphone).seconds

    // Both land where they actually were, not at a zero of their own.
    #expect(abs(systemOffset - 0.0118) < 0.0005,
            "system audio came out at \(systemOffset)s, not 11.8 ms after the video")
    #expect(abs(microphoneOffset - 0.1133) < 0.0005,
            "the microphone came out at \(microphoneOffset)s, not 113.3 ms after the video")
    // And the distance BETWEEN the two audio tracks — the one a person hears — survives.
    #expect(abs((microphoneOffset - systemOffset) - 0.1015) < 0.0005,
            "the 101.5 ms between the two audio tracks was not preserved")
}

/// A different timescale is not a different clock, and the microphone reports one: 44100
/// against the other two tracks' 1e9. `CMTimeSubtract` reconciles them, and this pins that
/// the reconciliation is exact rather than merely close — a rounding here is a drift that
/// accumulates over a long recording.
@Test func aTrackReportingItsOwnTimescaleIsStillOnTheSameClock() {
    var rebase = TrackRebase()
    let base = CMTime(value: 1_092_810_243_617_375, timescale: 1_000_000_000)
    #expect(rebase.rebased(base) == .zero)
    // Exactly one second later, expressed at the microphone's own timescale.
    let oneSecondLater = CMTime(value: 1_092_811 * 44_100 + 10_738, timescale: 44_100)
    let offset = rebase.rebased(oneSecondLater).seconds
    #expect(abs(offset - (oneSecondLater.seconds - base.seconds)) < 1e-9,
            "subtracting across timescales lost precision")
}
