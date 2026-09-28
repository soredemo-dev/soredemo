import Testing
import Foundation
@testable import Soredemo

/// **The recording's clock belongs to nothing on screen.** It was advanced by the floating bar's
/// own timer, and when the notch took over the take's controls the bar was never shown — so the
/// time in the notch read 0:00 for the whole recording (reported 2026-09-28).
@MainActor @Suite(.serialized) struct RecordingClockTests {
    final class Ticks: @unchecked Sendable {
        private let lock = NSLock()
        private var intervals: [Double] = []
        func add(_ interval: Double) { lock.withLock { intervals.append(interval) } }
        var all: [Double] { lock.withLock { intervals } }
    }

    /// Runs with no view anywhere: nothing here is on screen, and it still ticks.
    @Test func itTicksWithNothingOnScreen() async throws {
        let clock = RecordingClock(interval: 0.01)
        let ticks = Ticks()
        clock.start { ticks.add($0) }
        #expect(clock.isRunning)
        try await Task.sleep(for: .milliseconds(200))
        clock.stop()
        #expect(ticks.all.count >= 3, "\(ticks.all.count) ticks in 200 ms at a 10 ms interval")
        #expect(ticks.all.allSatisfy { $0 == 0.01 }, "each tick reports the interval it stands for")
    }

    @Test func stoppingStopsIt() async throws {
        let clock = RecordingClock(interval: 0.01)
        let ticks = Ticks()
        clock.start { ticks.add($0) }
        try await Task.sleep(for: .milliseconds(60))
        clock.stop()
        #expect(!clock.isRunning)
        let atStop = ticks.all.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(ticks.all.count == atStop, "ticked \(ticks.all.count - atStop) times after stopping")
    }

    /// Starting twice is one clock, not two — two would run the time at double speed.
    @Test func startingAgainReplacesTheClockRatherThanAddingOne() async throws {
        let clock = RecordingClock(interval: 0.02)
        let first = Ticks(), second = Ticks()
        clock.start { first.add($0) }
        clock.start { second.add($0) }
        try await Task.sleep(for: .milliseconds(150))
        clock.stop()
        #expect(first.all.isEmpty, "the replaced clock kept ticking \(first.all.count) times")
        #expect(!second.all.isEmpty)
    }
}
