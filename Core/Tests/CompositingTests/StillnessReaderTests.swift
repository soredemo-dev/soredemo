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
}
