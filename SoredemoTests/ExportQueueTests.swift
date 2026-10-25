import Foundation
import Testing
@testable import Soredemo

/// The queue's ending for a job: what it says, and what it teaches `ExportSpeedMemory`.
@MainActor @Suite struct ExportQueueTests {
    private func memory() -> ExportSpeedMemory {
        let name = "ExportQueueTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return ExportSpeedMemory(defaults: defaults)
    }

    private func settle(_ queue: ExportQueue) async {
        for _ in 0..<200 where queue.isBusy { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aFinishedJobTeachesTheRateForItsCodec() async {
        let speeds = memory()
        let queue = ExportQueue(speeds: speeds)
        queue.enqueue(destination: URL(fileURLWithPath: "/tmp/finished.mp4"),
                      measure: (frames: 600, width: 3024, height: 1964, codec: "hevc")) { _ in
            try? await Task.sleep(for: .milliseconds(30))
            return nil
        }
        await settle(queue)
        #expect(queue.jobs.first?.status == .finished)
        #expect(speeds.pixelsPerSecond(for: "hevc") != nil)
    }

    /// **Cancelled says cancelled, and teaches nothing.** The export swallows its own
    /// cancellation and returns no failure; read as a success, the job said "Done" and its
    /// half-written frames became this Mac's rate.
    @Test func aCancelledJobStaysCancelledAndTeachesNoRate() async {
        let speeds = memory()
        let queue = ExportQueue(speeds: speeds)
        let ended = Ended()
        let id = queue.enqueue(destination: URL(fileURLWithPath: "/tmp/cancelled.mp4"),
                               measure: (frames: 600, width: 3024, height: 1964, codec: "h264")) { _ in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            ended.value = true
            return nil
        }
        try? await Task.sleep(for: .milliseconds(30))
        queue.cancel(id!)
        // **Wait for the job itself, not for `isBusy`**: a cancelled job stops counting as busy
        // the moment it is cancelled, before the run has returned and the queue has written its
        // ending — waiting on `isBusy` read the status before the code under test ran.
        for _ in 0..<200 where !ended.value { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(ended.value, "the job never returned")
        #expect(queue.jobs.first?.status == .cancelled)
        #expect(speeds.pixelsPerSecond(for: "h264") == nil)
    }
}

@MainActor private final class Ended { var value = false }
