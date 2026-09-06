import AVFoundation
import CoreVideo
import Foundation
import Testing
import Timeline
@testable import Capture

/// **Every failure here is built rather than described.**
///
/// A check that says "a file with a broken container is refused" and never makes one is a claim
/// about a code path nobody has walked. So each test writes the actual broken thing: an empty
/// file, a file of text with a video extension, a real recording truncated to a third of its
/// bytes, an asset with sound and no picture. The point of this type is to catch the worst
/// failure this app can have — eleven minutes of somebody's voice in a file that will not open —
/// and a test suite that only checked the healthy path would be describing the failure it was
/// written to prevent.
///
/// **`.serialized`, because every test writes real media.** Five concurrent `AVAssetWriter`s
/// stalled thirty-one tests in this repository once; two suites doing it at once is how that
/// starts.
@Suite("Recording health", .serialized)
struct RecordingHealthTests {
    static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "soredemo-health-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A real, playable movie of `seconds`.
    static func movie(at url: URL, seconds: Double, frameRate: Int = 30) async -> Bool {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160, AVVideoHeightKey: 120,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        var created: CVPixelBuffer?
        _ = unsafe CVPixelBufferCreate(nil, 160, 120, kCVPixelFormatType_32BGRA,
                                       [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                       &created)
        guard let buffer = created else { return false }
        for frame in 0..<Int(seconds * Double(frameRate)) {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(1)) }
            adaptor.append(buffer, withPresentationTime:
                            CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(frameRate)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }

    // MARK: - The five ways a file is not a recording

    @Test("a path with nothing at it is named, not treated as an empty recording")
    func nothingThere() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let health = await RecordingCheck.health(of: directory.appending(path: "gone.mov"),
                                                 session: Nanoseconds(5_000_000_000))
        #expect(health == .damaged(.theFileIsNotThere))
    }

    /// A writer killed before its first flush leaves exactly this.
    @Test("a file with no bytes is named")
    func emptyFile() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "empty.mov")
        try Data().write(to: url)
        let health = await RecordingCheck.health(of: url, session: Nanoseconds(5_000_000_000))
        #expect(health == .damaged(.theFileIsEmpty))
    }

    /// **A file that is not a movie at all.** Distinct from empty: the size check passes and the
    /// container check is what has to catch it.
    @Test("bytes that are not a movie are named as a container that will not open")
    func notAMovie() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "notreally.mov")
        try Data(String(repeating: "this is not a movie. ", count: 200).utf8).write(to: url)
        let health = await RecordingCheck.health(of: url, session: Nanoseconds(5_000_000_000))
        #expect(health == .damaged(.theContainerWillNotOpen))
    }

    /// **The one that actually happens.** A `.mov` writes its index at the end; a process killed
    /// mid-recording leaves the samples on disk and no index. Built by truncating a real file.
    @Test("a recording truncated mid-write is caught")
    func truncatedFile() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cut-off.mov")
        guard await Self.movie(at: url, seconds: 2) else {
            Issue.record("the fixture movie was not written")
            return
        }
        let whole = try Data(contentsOf: url)
        try whole.prefix(whole.count / 3).write(to: url)

        let health = await RecordingCheck.health(of: url, session: Nanoseconds(2_000_000_000))
        // Which damage it is depends on where the truncation landed — the container may refuse
        // to open, or open and fail to decode. Both are damage and both are named; asserting one
        // of them would be asserting a property of the byte count rather than of the check.
        #expect(health != .sound(duration: Nanoseconds(2_000_000_000)))
        guard case .damaged(let damage) = health else {
            Issue.record("a truncated recording was reported sound")
            return
        }
        #expect([.theContainerWillNotOpen, .theVideoWillNotDecode,
                 .itIsShorterThanTheSession].contains(damage),
                "a truncated file was called \(damage.rawValue)")
    }

    /// **A capture that never received a frame.** The container opens and there is no picture.
    @Test("an asset with sound and no picture is named")
    func audioOnly() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "silent.caf")
        // **Real audio samples, not an empty writer.** The first version of this test made an
        // asset with an audio input and appended nothing, so the file had no bytes and the check
        // correctly answered `.theFileIsEmpty` — a fixture that tested the check before the one
        // it meant to. A second of silence written through `AVAudioFile` is a real audio-only
        // asset with a real duration and no picture in it.
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        guard let file = try? AVAudioFile(forWriting: url, settings: format.settings) else {
            Issue.record("no audio file"); return
        }
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else {
            Issue.record("no buffer"); return
        }
        silence.frameLength = 44_100
        try file.write(from: silence)

        let health = await RecordingCheck.health(of: url, session: Nanoseconds(5_000_000_000))
        #expect(health == .damaged(.thereIsNoVideoTrack))
    }

    // MARK: - Length

    /// **The failure this whole type exists for**: a file that opens, decodes, looks fine, and is
    /// a fraction of the session it was supposed to record.
    @Test("a recording far shorter than the session that made it is caught")
    func shorterThanTheSession() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cut-short.mov")
        guard await Self.movie(at: url, seconds: 1) else {
            Issue.record("the fixture movie was not written")
            return
        }
        let health = await RecordingCheck.health(of: url, session: Nanoseconds(60_000_000_000))
        #expect(health == .damaged(.itIsShorterThanTheSession))
    }

    /// **Loose on purpose, and this is the check that says why.** A healthy file is legitimately
    /// a little shorter than the session — the last partial frame is not written. An alarm that
    /// fired on that would be wrong nearly every time, and an alarm people learn to dismiss is
    /// worse than none on the day it is right.
    @Test("a recording slightly shorter than the session is sound, not damaged")
    func slightlyShortIsFine() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "normal.mov")
        guard await Self.movie(at: url, seconds: 2) else {
            Issue.record("the fixture movie was not written")
            return
        }
        // A session a tenth longer than the file: what every healthy recording looks like.
        let health = await RecordingCheck.health(of: url, session: Nanoseconds(2_200_000_000))
        guard case .sound(let duration) = health else {
            Issue.record("a healthy recording was called \(health)")
            return
        }
        #expect(duration.rawValue > 1_500_000_000)
    }

    /// **A session length nobody supplied skips the length check rather than comparing against
    /// zero.** Comparing a real duration against a zero session is a division nobody asked for,
    /// and it would call every recording damaged.
    @Test("with no session length the file is still checked, just not for length")
    func noSessionLengthStillChecks() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "unknown-session.mov")
        guard await Self.movie(at: url, seconds: 1) else {
            Issue.record("the fixture movie was not written")
            return
        }
        guard case .sound = await RecordingCheck.health(of: url, session: Nanoseconds(0)) else {
            Issue.record("a healthy recording with no session length was called damaged")
            return
        }
        // And the checks before the length one still ran: an empty file is still refused.
        let empty = directory.appending(path: "empty2.mov")
        try Data().write(to: empty)
        #expect(await RecordingCheck.health(of: empty, session: Nanoseconds(0))
                == .damaged(.theFileIsEmpty))
    }

    // MARK: - The verdict itself

    @Test("damage is worth interrupting somebody for and health is not")
    func onlyDamageNeedsSaying() {
        #expect(RecordingHealth.damaged(.theFileIsEmpty).needsSaying)
        #expect(!RecordingHealth.sound(duration: Nanoseconds(1)).needsSaying)
    }

    /// Distinct reasons, not one reason spelled several ways. A duplicate would be two different
    /// causes reported as one, and they have different fixes.
    ///
    /// **Built from `allCases` rather than a hand-written list**, because a list here is a thing
    /// that goes stale: a case added without a line added would be a damage nothing checked, and
    /// the previous version of this test had a hand-written six that its own comment called five.
    @Test("the damages are distinct reasons rather than one reason spelled several ways")
    func theDamagesAreDistinct() {
        let all = RecordingHealth.Damage.allCases
        #expect(all.count >= 6)
        #expect(Set(all.map(\.rawValue)).count == all.count)
    }

    /// **A size that cannot be READ is not a file that is EMPTY.** The check used to fold a
    /// failed `attributesOfItem` into zero and report an empty file — a fact about the read
    /// stated as a fact about the recording, which sends somebody looking for a writer bug that
    /// is not there. The compiler had been saying so all along, in a warning about a `??` whose
    /// left side could not be nil.
    @Test func anUnreadableSizeIsItsOwnDamage() {
        #expect(RecordingHealth.Damage.theSizeCannotBeRead != .theFileIsEmpty)
        #expect(RecordingHealth.damaged(.theSizeCannotBeRead).needsSaying,
                "a file this app cannot measure is worth interrupting somebody for")
    }
}
