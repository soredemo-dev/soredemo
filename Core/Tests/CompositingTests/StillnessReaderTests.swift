import AVFoundation
import CoreVideo
import Foundation
import Testing
import Overlays
import Timeline
@testable import Compositing

/// The refusals — what a caller is told when a file cannot be measured.
///
/// The measurement itself is in the probe; see the note below and § 27 there.
@Suite("Stillness reader", .serialized)
struct StillnessReaderTests {
    static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "soredemo-still-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // **The end-to-end measurement lives in the probe, and that is a deadlock rather than a
    // preference.** Writing a twelve-second fixture and decoding it again, beside the audio and
    // codec suites already doing the same, stalled this target past ten minutes — ten unfinished
    // tests, only one of them this file's. The same failure Vision caused for § 22 and
    // CoreMediaIO for § 20. § 27 of `scripts/cross-boundary-digest-probe.swift` builds a
    // recording that is still, then moves, then is still, and checks the series separates.
    //
    // What stays here needs no media at all.

    // MARK: - Refusals

    @Test("a file that is not a movie is refused by name")
    func notAMovie() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "nope.mov")
        try Data(String(repeating: "not a movie. ", count: 200).utf8).write(to: url)
        #expect(await StillnessReader.changes(contentsOf: url)
                == .refused(.theFileWillNotOpen))
    }

    @Test("a recording with no picture is refused by name")
    func noVideoTrack() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "silent.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        guard let file = try? AVAudioFile(forWriting: url, settings: format.settings),
              let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else {
            Issue.record("the audio fixture was not written")
            return
        }
        silence.frameLength = 44_100
        try file.write(from: silence)
        #expect(await StillnessReader.changes(contentsOf: url)
                == .refused(.thereIsNoVideoTrack))
    }

    /// The three refusals are distinct reasons; a duplicate would be two causes reported as one.
    @Test("the refusals are distinct")
    func refusalsAreDistinct() {
        let all: [StillnessReader.Refusal] = [.theFileWillNotOpen, .thereIsNoVideoTrack,
                                              .theReaderWouldNotStart]
        #expect(Set(all.map(\.rawValue)).count == all.count)
    }

    // MARK: - walking a real recording

    /// `two-tone.mov` is 20 frames at 10 fps, red for the first second and blue for the second —
    /// known from how `generate-fixture.swift` writes it, not from this reader. At 0.25 s slices
    /// the frames read are 0.0, 0.3, 0.5, 0.8, 1.0, 1.3, 1.5 and 1.8, so of the seven changes only
    /// the fourth — 0.8 to 1.0, red to blue — is the whole frame, and the rest are nothing.
    private var twoTone: URL {
        repositoryRootFromTests.appending(path: "Tests/RenderParityFixtures/two-tone.mov")
    }

    @Test("the one cut from red to blue is the only change, and it is the whole frame")
    func theColourChangeIsFoundWhereItHappens() async throws {
        guard case .changes(let changes) = await StillnessReader.changes(contentsOf: twoTone) else {
            Issue.record("the fixture was refused"); return
        }
        try #require(changes.count == 7, "read \(changes.count) changes")
        #expect(changes[3] > 0.99)
        #expect(changes.enumerated().filter { $0.offset != 3 }.allSatisfy { $0.element == 0 })
    }

    /// Half-second slices read 0.0, 0.5, 1.0 and 1.5: three changes, the middle one the cut.
    @Test("the slice length decides which frames are compared")
    func aLongerSliceComparesFewerFrames() async throws {
        guard case .changes(let changes) = await StillnessReader.changes(contentsOf: twoTone,
                                                                         sliceSeconds: 0.5) else {
            Issue.record("the fixture was refused"); return
        }
        try #require(changes.count == 3, "read \(changes.count) changes")
        #expect(changes[1] > 0.99 && changes[0] == 0 && changes[2] == 0)
    }

    @Test("progress rises to the end and finishes at one")
    func progressRisesAndEndsAtOne() async {
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Double] = []
            func add(_ value: Double) { lock.withLock { values.append(value) } }
            var all: [Double] { lock.withLock { values } }
        }
        let seen = Seen()
        _ = await StillnessReader.changes(contentsOf: twoTone) { seen.add($0) }
        #expect(seen.all.last == 1)
        #expect(zip(seen.all, seen.all.dropFirst()).allSatisfy { $0 <= $1 })
    }

    /// A search stopped part-way is a refusal, not "nothing moved" — the empty list would switch
    /// every zoom off.
    @Test("a cancelled walk says it was cancelled")
    func aCancelledWalkIsARefusal() async {
        // Cancelled from INSIDE, before the walk begins: cancelling from outside races a
        // 20-frame fixture that can be read to the end before `cancel()` lands.
        let url = twoTone
        let outcome = await Task {
            // `unsafe`: the current task, cancelled inside the closure that lends it.
            unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
            return await StillnessReader.changes(contentsOf: url)
        }.value
        #expect(outcome == .refused(.theWorkWasCancelled))
    }
}

