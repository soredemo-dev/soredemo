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
    ///
    /// **Waits for the ticks rather than timing them.** This asked for three ticks in a fixed
    /// 200 ms and failed under a busy main actor — once in a mutation run on 2026-09-30, once in
    /// gate 5 on 2026-10-22 with ONE tick counted — because the clock runs on the main actor and
    /// the suite runs other main-actor tests beside it. The claim is that it ticks with nothing
    /// on screen, not how fast; up to two seconds for three ticks says that without a race.
    /// (That a busy main actor slows the clock is a real property, and the audit records it.)
    @Test func itTicksWithNothingOnScreen() async throws {
        let clock = RecordingClock(interval: 0.01)
        let ticks = Ticks()
        clock.start { ticks.add($0) }
        #expect(clock.isRunning)
        for _ in 0..<100 where ticks.all.count < 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        clock.stop()
        #expect(ticks.all.count >= 3, "\(ticks.all.count) ticks in up to 2 s at a 10 ms interval")
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
