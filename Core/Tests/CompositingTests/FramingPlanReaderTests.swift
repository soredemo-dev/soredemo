import Foundation
import Framing
import Geometry
import Project
import Testing
import Timeline
@testable import Compositing

private let epoch = BootEpoch(id: UUID(uuidString: "9B1DE104-6C3E-4E2A-8B3C-2B6A6F1F9C07")!)
private let revision = GeometryRevision(id: 1)

/// **The reasons are readable without building a composition.** Before this, the only path
/// from a log to a framing decision ran inside AVFoundation's compositor, so asking why a
/// click was refused meant standing up the machinery being explained.
@Suite struct FramingPlanReaderTests {
    private func writeLog(_ records: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "framing-plan-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "segment-00.jsonl")
        try (records.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// One chain with no element at all — `hitTestReturnedNothing`, the reason the reader
    /// exists to surface. Built through the record's own initialiser and encoder rather than
    /// hand-written JSON: the on-disk shape is `AXChainRecord`'s to define and is pinned by
    /// its own round-trip tests, so restating it here would only add a second place to
    /// update when it changes.
    private func emptyChainLine(atNanos nanos: Int64) throws -> String {
        let instant = HostInstant(epoch: epoch, hostTime: Nanoseconds(nanos))
        let record = AXChainRecord(
            instant: instant,
            clickPosition: NormalizedPoint(x: 0.5, y: 0.5),
            clickRevision: revision,
            hitTestGlobalX: 500, hitTestGlobalY: 250,
            hitTestInterval: HostRange(epoch: epoch, start: Nanoseconds(nanos),
                                       duration: Nanoseconds(100_000)),
            hit: nil, ancestors: [], children: nil,
            truncation: .hitTestReturnedNothing, axCalls: 1, depthCap: 12, walkBudgetNanos: 8_000_000)
        return String(decoding: try ObservationLog.encode(record), as: UTF8.self)
    }

    private func pointerLine(atNanos nanos: Int64) throws -> String {
        let sample = PointerSample(instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(nanos)),
                                   position: NormalizedPoint(x: 0.1, y: 0.1), revision: revision)
        return String(decoding: try ObservationLog.encode(sample), as: UTF8.self)
    }

    private func pointerLine(atNanos nanos: Int64, x: Double, y: Double) throws -> String {
        let sample = PointerSample(instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(nanos)),
                                   position: NormalizedPoint(x: x, y: y), revision: revision)
        return String(decoding: try ObservationLog.encode(sample), as: UTF8.self)
    }

    @Test func aLogWithNoChainsYieldsAnEmptyPlan() throws {
        let url = try writeLog([try pointerLine(atNanos: 1_000)])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let plan = try FramingPlanReader.plan(fromObservationLogAt: url)
        #expect(plan.entries.isEmpty,
                "an empty plan is a real answer — no clicks observed, not a failed read")
    }

    /// The point of the type: a refusal reaches the reviewer instead of being discarded.
    @Test func aRefusedChainReachesThePlanWithItsReason() throws {
        let url = try writeLog([try emptyChainLine(atNanos: 1_000)])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let plan = try FramingPlanReader.plan(fromObservationLogAt: url)
        #expect(plan.entries.count == 1)
        #expect(plan.entries.first?.decision.rejection == .hitTestReturnedNothing)
        #expect(plan.framedCount == 0)
        #expect(plan.rejectionCounts[.hitTestReturnedNothing] == 1)
    }

    /// A recording paused and resumed has one log per segment and one timeline.
    @Test func segmentLogsMergeIntoOneTimeline() throws {
        let first = try writeLog([try emptyChainLine(atNanos: 3_000)])
        let second = try writeLog([try emptyChainLine(atNanos: 1_000)])
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }

        let plan = try FramingPlanReader.plan(fromObservationLogsAt: [first, second])
        #expect(plan.entries.map { $0.instant.hostTime.rawValue } == [1_000, 3_000],
                "the merged plan is a timeline, so segment order must not decide it")
    }

    /// A read failure is not an empty plan. The two are different facts and a reviewer told
    /// "no clicks" about a log that could not be opened has been misinformed.
    @Test func aMissingLogThrowsRatherThanReturningNothing() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "no-such-log-\(UUID().uuidString).jsonl")
        #expect(throws: (any Error).self) {
            try FramingPlanReader.plan(fromObservationLogAt: missing)
        }
    }
    /// **The reader must carry the click's position AND its revision**, or the pointer
    /// fallback is disabled in exactly the case it exists for. A refused chain is one where
    /// accessibility could not say what was clicked — not one where nothing was clicked — and
    /// a plan that dropped the click would leave the camera nothing to aim at.
    @Test func aRefusedChainStillCarriesWhereTheClickWas() throws {
        let url = try writeLog([try emptyChainLine(atNanos: 1_000)])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let plan = try FramingPlanReader.plan(fromObservationLogAt: url)
        let entry = try #require(plan.entries.first)
        #expect(entry.decision.rejection == .hitTestReturnedNothing)
        #expect(entry.clickPosition == NormalizedPoint(x: 0.5, y: 0.5))
        #expect(entry.clickRevision == revision)
        // And the plan can therefore answer the question the camera asks it.
        #expect(plan.fallbackRevision == revision)
        #expect(plan.framedClicks(with: [], pointerFallbackRevision: plan.fallbackRevision).count == 1,
                "a log of nothing but refusals must still frame something")
    }

    // MARK: - placing a zoom where nobody clicked

    /// **Sorted on the way out, and a package is why.** The writer appends in observation
    /// order, but a recording paused and resumed has one log per segment and a caller that
    /// concatenates them gets two ascending runs, not one — and picking "the last sample at
    /// or before this instant" over that is a wrong answer rather than a slow one.
    @Test func pointerSamplesComeBackInTimeOrderWhateverOrderTheyWereWrittenIn() throws {
        let url = try writeLog([
            try pointerLine(atNanos: 3_000, x: 0.3, y: 0.3),
            try pointerLine(atNanos: 1_000, x: 0.1, y: 0.1),
            try emptyChainLine(atNanos: 2_500),
            try pointerLine(atNanos: 2_000, x: 0.2, y: 0.2),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let samples = try FramingPlanReader.pointerSamples(fromObservationLogAt: url)
        #expect(samples.map(\.instant.hostTime.rawValue) == [1_000, 2_000, 3_000])
        // The chain record between them is not a pointer sample and must not arrive as one.
        #expect(samples.count == 3)
        #expect(samples.map(\.position.x) == [0.1, 0.2, 0.3],
                "the positions did not travel with the instants they were sorted by")
    }

    /// A log with no pointer at all is a recording made without the input tap, and an empty
    /// array is the honest answer — the placement falls back to the middle of the frame,
    /// which is a decision the app makes and not one this reader should make for it.
    @Test func aLogWithNoPointerYieldsNoSamplesRatherThanFailing() throws {
        let url = try writeLog([try emptyChainLine(atNanos: 1_000)])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try FramingPlanReader.pointerSamples(fromObservationLogAt: url).isEmpty)
    }
}
