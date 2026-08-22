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

/// Rebasing is per TRACK, not shared: video and audio have their own bases because they
/// have their own clocks, and one shared base would reintroduce the offset it removes.
@Test func eachTrackHoldsItsOwnBase() {
    var video = TrackRebase()
    var audio = TrackRebase()
    _ = video.rebased(CMTime(seconds: 1, preferredTimescale: 600))
    #expect(audio.hasBase == false, "one track's first sample set another's base")
    _ = audio.rebased(CMTime(seconds: 39_600, preferredTimescale: 600))
    #expect(video.hasBase && audio.hasBase)
}
