import AppKit
import Foundation
import Observation

/// What watches a take while it runs: the display kept awake, the Mac about to sleep, the disk
/// filling, and the microphone — its meter, and whether it hears anything at all.
///
/// **Extracted from `RecordingCoordinator`** — step 3 of
/// `docs/design/2026-10-23-splitting-the-recording-coordinator.md`. The coordinator starts and
/// ends it with the take, feeds it the clock, and acts on what it raises (`onSleep`,
/// `onDiskNearlyFull`). The notification centre and the free-space reading are passed in, so
/// each guard is tested without a real take.
@Observable
final class TakeGuards {
    /// 0…1, the microphone's level right now, smoothed. `nil` when no microphone is being
    /// recorded, which is what lets the bar draw a struck-through mic rather than a dead meter.
    private(set) var microphoneLevel: Double?
    /// True once the microphone has heard NOTHING for `MicrophoneSilenceWatch.patience` — no
    /// buffers, or buffers of digital silence. Not a person being quiet; see the watch.
    private(set) var microphoneHearsNothing = false

    /// Raised when the Mac is about to sleep during a take — see `SleepPause`.
    var onSleep: () -> Void = {}
    /// Raised once per take when the disk can hold the take's copy and about one more minute and
    /// no more — see `DiskWatch`. The owner stops and saves.
    var onDiskNearlyFull: () -> Void = {}

    /// How often the free space is read during a take. Five seconds at 85 Mbps is about 55 MB —
    /// far inside the minute of margin `DiskWatch` keeps.
    static let diskCheckSeconds = 5.0

    private let notificationCentre: NotificationCenter
    private let freeSpace: () -> Int64?
    private let wakeLock = TakeWakeLock()
    private var sleepPause: SleepPause?
    private var diskWatch = DiskWatch()
    private var secondsSinceDiskCheck = 0.0
    private var diskAlarmRaised = false
    private var silenceWatch = MicrophoneSilenceWatch()

    /// `notificationCentre` is `NSWorkspace.shared.notificationCenter` in the app — sleep is
    /// posted there — and `freeSpace` reads the scratch volume (`DiskHeadroom.availableBytes`).
    init(notificationCentre: NotificationCenter = NSWorkspace.shared.notificationCenter,
         freeSpace: @escaping () -> Int64? = DiskHeadroom.availableBytes) {
        self.notificationCentre = notificationCentre
        self.freeSpace = freeSpace
    }

    /// **The display is held awake by this and nothing else**, so every way a take starts —
    /// a screen, a phone — takes it. Listening for sleep, and counting the disk, for exactly the
    /// life of a take.
    func takeStarted() {
        wakeLock.hold()
        sleepPause = SleepPause(centre: notificationCentre) { [weak self] in self?.onSleep() }
        diskWatch = DiskWatch()
        secondsSinceDiskCheck = 0
        diskAlarmRaised = false
        silenceWatch.reset()
        microphoneHearsNothing = false
    }

    /// Every way a take ends — a stop, a failure — gives it all back.
    func takeEnded() {
        wakeLock.release()
        sleepPause = nil
        microphoneLevel = nil
        microphoneHearsNothing = false
    }

    /// A pause closed the segment and its copy is made: the disk count starts again. The clock
    /// did not tick while paused, and a pause is not silence.
    func segmentResumed() {
        diskWatch.segmentBegan()
        silenceWatch.reset()
        microphoneHearsNothing = false
    }

    /// One tick of a running, unpaused take. `microphone` is the session's own accounting for
    /// its microphone track — buffers delivered and the latest one's RMS — or `nil` when there
    /// is no session to ask.
    func tick(interval: Double, microphoneOff: Bool,
              microphone: (delivered: Int, latestRMS: Double?)?) {
        secondsSinceDiskCheck += interval
        if secondsSinceDiskCheck >= Self.diskCheckSeconds {
            let verdict = diskWatch.observe(free: freeSpace(), after: secondsSinceDiskCheck)
            secondsSinceDiskCheck = 0
            // **Raised once**: the readings after the alarm stay low, and a second stop would
            // race the first.
            if verdict == .stopNow, !diskAlarmRaised {
                diskAlarmRaised = true
                onDiskNearlyFull()
            }
        }
        // Smoothed toward the instantaneous value: `latestRMS` is the RMS of one buffer, and a
        // meter drawn straight from it flickers at the buffer rate. Rising fast and falling slow
        // is what every level meter does, because a peak a person missed is worse than a decay
        // they can see.
        // `.off` reads as no meter rather than as a silent one: a full-height empty track is
        // what "not hearing you" looks like, and that is not what a person who turned the
        // microphone off should be shown.
        guard !microphoneOff else {
            microphoneLevel = nil
            microphoneHearsNothing = false
            return
        }
        // **Before the level's guard, not after it.** A microphone that never delivered has no
        // reading at all, and that is the loudest case of hearing nothing.
        if let microphone {
            microphoneHearsNothing = silenceWatch.observe(delivered: microphone.delivered,
                                                          latestRMS: microphone.latestRMS,
                                                          over: interval)
        }
        guard let reading = microphone?.latestRMS else { microphoneLevel = nil; return }
        let scaled = min(1, sqrt(reading) * 1.6)
        let previous = microphoneLevel ?? 0
        microphoneLevel = scaled > previous ? scaled : previous + (scaled - previous) * 0.25
    }
}
