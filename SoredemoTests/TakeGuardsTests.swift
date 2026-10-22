import Testing
import AppKit
import IOKit.pwr_mgt
@testable import Soredemo

/// **What watches a take while it runs** — step 3 of
/// `docs/design/2026-10-23-splitting-the-recording-coordinator.md`. The free space and the
/// notification centre are passed in, so the disk alarm and the sleep pause are tested here,
/// where before they could only be reached through a real take.
@MainActor @Suite(.serialized) struct TakeGuardsTests {
    final class Count { var value = 0 }
    private let megabyte: Int64 = 1_000_000

    private func guards(free: @escaping () -> Int64?, centre: NotificationCenter = NotificationCenter())
    -> (TakeGuards, sleeps: Count, alarms: Count) {
        let sleeps = Count(), alarms = Count()
        let guards = TakeGuards(notificationCentre: centre, freeSpace: free)
        guards.onSleep = { sleeps.value += 1 }
        guards.onDiskNearlyFull = { alarms.value += 1 }
        return (guards, sleeps, alarms)
    }

    /// The disk is read every five seconds of take, and the alarm is raised ONCE however many
    /// readings stay low after it — a second stop would race the first.
    @Test func aFillingDiskRaisesTheAlarmOnce() {
        var free: Int64 = 9_000 * megabyte
        let (guards, _, alarms) = self.guards(free: { free })
        guards.takeStarted()
        for _ in 0..<(20 * 60) {               // a minute of 50 ms ticks
            guards.tick(interval: 0.05, microphoneOff: true, microphone: nil)
            free -= 5 * megabyte               // 100 MB a second
        }
        #expect(alarms.value == 1)
        guards.takeEnded()
    }

    @Test func aDiskWithRoomRaisesNothing() {
        let (guards, _, alarms) = self.guards(free: { 500_000 * self.megabyte })
        guards.takeStarted()
        for _ in 0..<(20 * 60) { guards.tick(interval: 0.05, microphoneOff: true, microphone: nil) }
        #expect(alarms.value == 0)
        guards.takeEnded()
    }

    @Test func sleepIsHeardOnlyDuringATake() {
        let centre = NotificationCenter()
        let (guards, sleeps, _) = self.guards(free: { nil }, centre: centre)
        centre.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(sleeps.value == 0, "a sleep before any take paused something")
        guards.takeStarted()
        centre.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(sleeps.value == 1)
        guards.takeEnded()
        centre.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(sleeps.value == 1, "a sleep after the take paused something")
    }

    /// The meter rises at once and falls slowly; a microphone switched off shows no meter rather
    /// than an empty one.
    @Test func theMeterRisesFastFallsSlowlyAndVanishesWhenOff() {
        let (guards, _, _) = self.guards(free: { nil })
        guards.takeStarted()
        guards.tick(interval: 0.05, microphoneOff: false, microphone: (delivered: 1, latestRMS: 0.25))
        let loud = guards.microphoneLevel ?? 0
        #expect(abs(loud - 0.8) < 0.0001)        // sqrt(0.25) × 1.6
        guards.tick(interval: 0.05, microphoneOff: false, microphone: (delivered: 2, latestRMS: 0))
        let after = guards.microphoneLevel ?? 0
        #expect(after > 0.5 && after < loud, "the meter dropped at once: \(after)")
        guards.tick(interval: 0.05, microphoneOff: true, microphone: nil)
        #expect(guards.microphoneLevel == nil)
        guards.takeEnded()
    }

    /// A take that ends clears what the next one would otherwise inherit.
    @Test func endingATakeClearsTheMeterAndTheWarning() {
        let (guards, _, _) = self.guards(free: { nil })
        guards.takeStarted()
        for i in 0..<120 {                      // six seconds, nothing delivered after the first
            guards.tick(interval: 0.05, microphoneOff: false, microphone: (delivered: 1, latestRMS: i == 0 ? 0.2 : 0.2))
        }
        #expect(guards.microphoneHearsNothing, "five seconds with no new buffer was not called silence")
        guards.takeEnded()
        #expect(!guards.microphoneHearsNothing)
        #expect(guards.microphoneLevel == nil)
    }
}
