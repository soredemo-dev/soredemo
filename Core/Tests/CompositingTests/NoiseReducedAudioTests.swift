import AVFoundation
import Foundation
import Overlays
import Testing
@testable import Compositing

/// The joint between finding silence and measuring a room, and one pass over a real file.
///
/// `NoiseReductionTests` pins the arithmetic on synthetic signals. This pins the wiring: that the
/// spans `SilenceFinder` reports become sample ranges that contain no speech, that every refusal
/// is a named value, and that a file written by this comes back quieter than it went in.
@Suite struct NoiseReducedAudioTests {
    private let rate = 48_000.0

    private func tone(_ hz: Double, seconds: Double, amplitude: Double) -> [Float] {
        (0..<Int(seconds * rate)).map {
            Float(amplitude * sin(2 * .pi * hz * Double($0) / rate))
        }
    }

    private func track(_ samples: [Float]) -> AudioSamples.Track {
        AudioSamples.Track(samples: samples, sampleRate: rate)
    }

    private func scratch() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "soredemo-noise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - finding the quiet

    @Test func aSilenceInTheMiddleBecomesASampleRangeOverIt() throws {
        let loud = tone(1000, seconds: 1.0, amplitude: 0.6)
        let quiet = [Float](repeating: 0, count: Int(1.5 * rate))
        let ranges = NoiseReducedAudio.quietSampleRanges(in: track(loud + quiet + loud))

        let found = try #require(ranges.first, "no silence was found in 1.5 s of digital zero")
        #expect(ranges.count == 1, "\(ranges.count) silences found where there is one")
        // Inside the quiet stretch, both ends.
        #expect(found.lowerBound >= loud.count)
        #expect(found.upperBound <= loud.count + quiet.count)
    }

    /// **Not one sample of speech may be inside a range this returns.** Every sample in it is
    /// averaged into the room's profile and then subtracted from the whole recording, so a
    /// fragment of a vowel in here becomes a notch in every word.
    @Test func aQuietRangeNeverReachesIntoTheSpeechEitherSideOfIt() throws {
        let loud = tone(1000, seconds: 0.8, amplitude: 0.7)
        let quiet = [Float](repeating: 0, count: Int(1.5 * rate))
        let samples = loud + quiet + loud
        let ranges = NoiseReducedAudio.quietSampleRanges(in: track(samples))
        for range in ranges {
            let peak = samples[range].map { abs($0) }.max() ?? 0
            #expect(peak < 0.05, """
                a quiet range peaks at \(peak) — it reaches into the tone either side, and that \
                energy would be subtracted from every window of the recording
                """)
        }
    }

    @Test func aRecordingWithNoQuietYieldsNoRanges() {
        let unbroken = tone(440, seconds: 3, amplitude: 0.6)
        #expect(NoiseReducedAudio.quietSampleRanges(in: track(unbroken)).isEmpty)
    }

    @Test func anEmptyTrackIsNotAnError() {
        #expect(NoiseReducedAudio.quietSampleRanges(in: track([])).isEmpty)
        #expect(NoiseReducedAudio.quietSampleRanges(
            in: AudioSamples.Track(samples: [0, 0, 0], sampleRate: 0)).isEmpty)
    }

    // MARK: - the refusals

    /// **Each refusal says which one it is.** A caller that got `nil` for all three could only
    /// tell somebody "it did not work", and the three have completely different remedies:
    /// record with a microphone, record for longer, stop talking for a second.
    @Test func everyRefusalIsANamedValueThatSaysWhatToDoAboutIt() {
        let cases: [NoiseReducedAudio.Refusal] = [
            .noAudioTrack, .tooShort(seconds: 0.4), .noMeasurableSilence,
        ]
        for refusal in cases {
            #expect(!refusal.description.isEmpty)
            #expect(refusal.description.count > 20, "\(refusal) explains nothing")
        }
        #expect(NoiseReducedAudio.Refusal.tooShort(seconds: 0.4).description.contains("0.4"))
        // Distinct, so a caller can switch on them.
        #expect(NoiseReducedAudio.Refusal.noAudioTrack != .noMeasurableSilence)
        #expect(NoiseReducedAudio.Refusal.tooShort(seconds: 1) != .tooShort(seconds: 2))
    }

    /// **An `Outcome` is one of two things and a caller must be made to handle both.**
    ///
    /// The alternative shape — an optional `URL` — collapses "cleaned" and "could not clean"
    /// into a value and a `nil`, and the `nil` carries no reason. Every refusal in this app is a
    /// named value; this is that rule at the boundary where the work either happened or did not.
    @Test func anOutcomeCarriesEitherAFileOrTheReasonThereIsNone() {
        let cleaned: NoiseReducedAudio.Outcome = .reduced(URL(filePath: "/tmp/quiet.caf"))
        let refused: NoiseReducedAudio.Outcome = .refused(.noMeasurableSilence)

        var cleanedURL: URL?
        switch cleaned {
        case .reduced(let url): cleanedURL = url
        case .refused: Issue.record("a .reduced outcome matched .refused")
        }
        #expect(cleanedURL?.lastPathComponent == "quiet.caf")

        switch refused {
        case .reduced: Issue.record("a .refused outcome matched .reduced")
        case .refused(let reason):
            #expect(reason == .noMeasurableSilence)
            #expect(reason.description.contains("silence"))
        }
    }

    // MARK: - the cache key

    /// **Changing the strength must not return the previous result.** The alternative — one
    /// filename per source — hands back a differently-processed file and looks like the setting
    /// does nothing.
    @Test func twoSettingsCannotShareOneCachedFile() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = URL(filePath: "/tmp/master-00.mov")
        let gentle = NoiseReducedAudio.destination(
            for: source, settings: .init(strength: 1.0, floor: 0.06), in: directory)
        let strong = NoiseReducedAudio.destination(
            for: source, settings: .init(strength: 3.0, floor: 0.06), in: directory)
        let differentFloor = NoiseReducedAudio.destination(
            for: source, settings: .init(strength: 1.0, floor: 0.2), in: directory)
        #expect(gentle != strong)
        #expect(gentle != differentFloor)
        // And the same settings do share one, or the cache never hits.
        #expect(gentle == NoiseReducedAudio.destination(
            for: source, settings: .init(strength: 1.0, floor: 0.06), in: directory))
    }

    // MARK: - a real file, end to end

    /// **Written, read back through AVFoundation, processed, and measured.** Everything above is
    /// arrays; this is the only check that the reader, the writer and the pass agree about what a
    /// file contains.
    @Test func aFileWithHumComesBackWithLessOfIt() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Two seconds of hum alone, then two seconds of hum under a tone.
        //
        // **The hum is at 0.02, and that number is the realistic one rather than a convenient
        // one.** A first draft used 0.25 and the pass refused the file: `SilenceFinder`'s
        // threshold is a peak of 0.04, so a 0.25 hum is not silence — it is a loud continuous
        // tone, and there was no quiet anywhere in the file to measure. That is the pass behaving
        // correctly on an unrealistic input. Room noise IS quiet; that is why it survives being
        // ignored while recording and only becomes obvious on playback.
        let humLevel = 0.02
        let hum = tone(60, seconds: 2.0, amplitude: humLevel)
        let both = zip(tone(60, seconds: 2.0, amplitude: humLevel),
                       tone(1000, seconds: 2.0, amplitude: 0.55)).map { $0 + $1 }
        let sourceURL = directory.appending(path: "noisy.caf")
        try AudioSamples.write(track(hum + both), to: sourceURL)

        let outputURL = directory.appending(path: "quiet.caf")
        let outcome = try await NoiseReducedAudio.write(from: AVURLAsset(url: sourceURL),
                                                        to: outputURL)
        guard case .reduced(let written) = outcome else {
            Issue.record("the pass refused a file built to be processable: \(outcome)")
            return
        }
        #expect(written == outputURL)

        let cleaned = try #require(try await AudioSamples.read(from: AVURLAsset(url: written)))
        // Length is preserved to within one buffer — the video track is lined up against this.
        #expect(abs(cleaned.samples.count - (hum.count + both.count)) < 4096, """
            the cleaned file is \(cleaned.samples.count) samples against \
            \(hum.count + both.count) — anything lined up against this would drift
            """)

        func energy(_ samples: ArraySlice<Float>, at hz: Double) -> Double {
            var real = 0.0, imaginary = 0.0
            for (offset, sample) in samples.enumerated() {
                let angle = 2 * Double.pi * hz * Double(offset) / rate
                real += Double(sample) * cos(angle)
                imaginary += Double(sample) * sin(angle)
            }
            return (real * real + imaginary * imaginary).squareRoot() / Double(samples.count)
        }
        let region = hum.count..<Swift.min(hum.count + both.count, cleaned.samples.count)
        let humBefore = energy((hum + both)[region], at: 60)
        let humAfter = energy(cleaned.samples[region], at: 60)
        let voiceBefore = energy((hum + both)[region], at: 1000)
        let voiceAfter = energy(cleaned.samples[region], at: 1000)

        #expect(humAfter < humBefore * 0.4,
                "the hum went from \(humBefore) to \(humAfter) through a real file")
        #expect(voiceAfter > voiceBefore * 0.7,
                "the tone went from \(voiceBefore) to \(voiceAfter) — the voice is going too")
    }

    /// A recording with no silence anywhere is refused by name rather than returned unchanged,
    /// so the app can say why instead of appearing to have done nothing.
    @Test func aFileWithNoSilenceIsRefusedByName() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "talky.caf")
        try AudioSamples.write(track(tone(440, seconds: 3, amplitude: 0.6)), to: sourceURL)

        let outcome = try await NoiseReducedAudio.write(
            from: AVURLAsset(url: sourceURL),
            to: directory.appending(path: "out.caf"))
        guard case .refused(let refusal) = outcome else {
            Issue.record("an unbroken tone was processed: \(outcome)")
            return
        }
        #expect(refusal == .noMeasurableSilence)
    }

    @Test func aRecordingTooShortToMeasureIsRefusedByName() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "blip.caf")
        try AudioSamples.write(track(tone(440, seconds: 0.4, amplitude: 0.4)), to: sourceURL)

        let outcome = try await NoiseReducedAudio.write(
            from: AVURLAsset(url: sourceURL),
            to: directory.appending(path: "out.caf"))
        guard case .refused(let refusal) = outcome else {
            Issue.record("a 0.4 s file was processed: \(outcome)")
            return
        }
        guard case .tooShort = refusal else {
            Issue.record("refused as \(refusal) rather than as too short")
            return
        }
    }
}
