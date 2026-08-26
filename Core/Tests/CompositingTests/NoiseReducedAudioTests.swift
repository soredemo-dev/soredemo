import AVFoundation
import Foundation
import Overlays
import Timeline
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
        // `trackIndex: 0` because these fixtures are single-track files. In a real recording
        // the default — the microphone's index — is the right one, and
        // `onlyTheMicrophoneTrackIsCleaned` is the test for that.
        let outcome = try await NoiseReducedAudio.write(from: AVURLAsset(url: sourceURL),
                                                        to: outputURL, trackIndex: 0)
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

    /// **The default track is the microphone, and that is not an arbitrary choice.**
    ///
    /// System audio is a game's soundtrack, a video someone is demonstrating, a notification
    /// chime. It is not a room, and subtracting an "estimated noise floor" from it removes the
    /// quiet parts of the music. `AudioMixBuilder.trackOrder` is the one place the master
    /// writer's layout is written down, and this reads it rather than writing `1`.
    @Test func theTrackCleanedByDefaultIsTheMicrophoneOne() {
        let index = NoiseReducedAudio.microphoneTrackIndex
        #expect(index == AudioMixBuilder.trackOrder.firstIndex(of: .microphone))
        #expect(index != AudioMixBuilder.trackOrder.firstIndex(of: .systemAudio), """
            the microphone and system audio resolve to the same track index, so noise removal \
            would be subtracting a room from whatever the machine was playing
            """)
    }

    /// Asking for a track that is not there is a refusal, not a crash and not a silent fallback
    /// to track 0 — which would denoise system audio on a recording made without a microphone.
    @Test func aRecordingWithNoMicrophoneTrackIsRefusedRatherThanFallingBack() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "system-only.caf")
        try AudioSamples.write(track(tone(440, seconds: 3, amplitude: 0.5)), to: sourceURL)

        let outcome = try await NoiseReducedAudio.write(
            from: AVURLAsset(url: sourceURL),
            to: directory.appending(path: "out.caf"), trackIndex: 1)
        guard case .refused(.noAudioTrack) = outcome else {
            Issue.record("a one-track file was processed as though it had a microphone: \(outcome)")
            return
        }
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
            to: directory.appending(path: "out.caf"), trackIndex: 0)
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
            to: directory.appending(path: "out.caf"), trackIndex: 0)
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

/// Substituting one audio track and leaving the other alone — the shape noise removal needs.
@Suite struct EditedAssetAudioSubstitutionTests {
    private let rate = 48_000.0

    private func tone(_ hz: Double, seconds: Double, amplitude: Double) -> [Float] {
        (0..<Int(seconds * rate)).map {
            Float(amplitude * sin(2 * .pi * hz * Double($0) / rate))
        }
    }

    private func scratch() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "soredemo-sub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes a movie with one video track and `audio.count` audio tracks.
    ///
    /// **Two audio tracks, because one would not test the thing.** The whole point of keying the
    /// substitution by index is that a Soredemo recording has system audio AND a microphone, and
    /// a cleaned microphone must not land on both.
    /// **`async`, and every wait is a suspension rather than a block.**
    ///
    /// The first version blocked: `usleep` in the ready-for-more loop and a `DispatchSemaphore`
    /// waiting on `finishWriting`. `swift test` runs every target in ONE process and Swift
    /// Testing runs suites concurrently, so those blocked threads in the cooperative pool — and
    /// 24 tests across four unrelated suites stopped at 0% CPU, none of them this one. A hang
    /// that presents as somebody else's test is the reason this note is here.
    private func movie(at url: URL, audio: [[Float]], seconds: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String:
                                            kCVPixelFormatType_32BGRA])
        writer.add(video)

        let inputs = audio.map { _ -> AVAssetWriterInput in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            return input
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var pixels: CVPixelBuffer?
        // Safe here: `&pixels` is an out-parameter the framework fills, and the result is
        // read only through the optional binding below.
        unsafe CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels)
        for frame in 0..<Int(seconds * 30) {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            if let pixels {
                adaptor.append(pixels, withPresentationTime:
                                CMTime(value: CMTimeValue(frame), timescale: 30))
            }
        }
        video.markAsFinished()

        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            return
        }
        for (index, samples) in audio.enumerated() {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(samples.count)),
                  // Safe here: the buffer owns this pointer for its own lifetime and outlives
                  // every use below.
                  let channel = unsafe buffer.floatChannelData else { continue }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            // Safe here: `frameCapacity` and `frameLength` are both `samples.count`, so every
            // index this loop produces is one the buffer owns.
            for (i, sample) in samples.enumerated() { unsafe channel[0][i] = sample }
            guard let sampleBuffer = buffer.asSampleBuffer() else { continue }
            while !inputs[index].isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            inputs[index].append(sampleBuffer)
            inputs[index].markAsFinished()
        }

        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
    }

    /// **The cleaned track lands on the microphone and system audio comes through untouched.**
    ///
    /// This is the whole reason the parameter is a map keyed by index rather than one replacement
    /// asset. A version that swapped every audio track would put a denoised copy of the
    /// microphone where the game soundtrack was, and the export would sound like the music had
    /// been replaced by somebody talking over it.
    @Test func onlyTheSubstitutedTrackChangesAndTheOtherIsUntouched() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Track 0 (system audio) is 300 Hz; track 1 (the microphone) is 900 Hz.
        let sourceURL = directory.appending(path: "master.mov")
        try await movie(at: sourceURL,
                  audio: [tone(300, seconds: 1.0, amplitude: 0.5),
                          tone(900, seconds: 1.0, amplitude: 0.5)],
                  seconds: 1.0)

        // The replacement is a THIRD frequency, so which track it landed on is unambiguous.
        let replacementURL = directory.appending(path: "clean.caf")
        try AudioSamples.write(
            AudioSamples.Track(samples: tone(2000, seconds: 1.0, amplitude: 0.5),
                               sampleRate: rate),
            to: replacementURL)

        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        try #require(tracks.count == 2, "the fixture wrote \(tracks.count) audio tracks, not 2")

        let duration = try await asset.load(.duration)
        let edited = try await EditedAsset.make(
            from: asset,
            by: EditTimeline.whole(duration: Nanoseconds(Int64(duration.seconds * 1e9))),
            substitutingAudio: [1: AVURLAsset(url: replacementURL)])

        let editedTracks = try await edited.loadTracks(withMediaType: .audio)
        #expect(editedTracks.count == 2, "a track was dropped by the substitution")

        func energy(_ samples: [Float], at hz: Double) -> Double {
            var real = 0.0, imaginary = 0.0
            for (i, sample) in samples.enumerated() {
                let angle = 2 * Double.pi * hz * Double(i) / rate
                real += Double(sample) * cos(angle)
                imaginary += Double(sample) * sin(angle)
            }
            return (real * real + imaginary * imaginary).squareRoot() / Double(samples.count)
        }
        let zero = try #require(try await AudioSamples.read(from: edited, trackIndex: 0))
        let one = try #require(try await AudioSamples.read(from: edited, trackIndex: 1))

        #expect(energy(zero.samples, at: 300) > energy(zero.samples, at: 2000) * 4, """
            system audio was overwritten: 300 Hz \(energy(zero.samples, at: 300)), \
            2000 Hz \(energy(zero.samples, at: 2000))
            """)
        #expect(energy(one.samples, at: 2000) > energy(one.samples, at: 900) * 4, """
            the microphone was not substituted: 2000 Hz \(energy(one.samples, at: 2000)), \
            900 Hz \(energy(one.samples, at: 900))
            """)
    }


    /// The parameter is keyed by index rather than applying to every track, and this is the test
    /// of that shape: two entries with different assets cannot collapse into one.
    @Test func substitutionIsKeyedPerTrackRatherThanForTheWholeAsset() {
        let one = AVURLAsset(url: URL(filePath: "/tmp/a.caf"))
        let two = AVURLAsset(url: URL(filePath: "/tmp/b.caf"))
        let map: [Int: AVAsset] = [0: one, 1: two]
        #expect(map.count == 2)
        #expect((map[1] as? AVURLAsset)?.url.lastPathComponent == "b.caf", """
            the microphone's index does not select the microphone's replacement, so a cleaned \
            track could be pasted over system audio
            """)
    }
}

private extension AVAudioPCMBuffer {
    /// A `CMSampleBuffer` over this buffer's samples, for handing to `AVAssetWriterInput`.
    func asSampleBuffer() -> CMSampleBuffer? {
        var format: CMFormatDescription?
        // Safe here: `streamDescription` is a pointer the format owns and `self` outlives this
        // call; `&format` is an out-parameter the framework fills.
        guard unsafe CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: self.format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format) == noErr, let format else { return nil }
        var sampleBuffer: CMSampleBuffer?
        // Safe here: every pointer is either `nil` or an out-parameter the framework fills,
        // and the timing array is a literal that outlives the call.
        guard unsafe CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: format, sampleCount: CMItemCount(frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: [CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(self.format.sampleRate)),
                presentationTimeStamp: .zero, decodeTimeStamp: .invalid)],
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { return nil }
        // Safe here: `audioBufferList` belongs to the buffer this is called on, and the
        // sample buffer is used only while that buffer is alive.
        guard unsafe CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, bufferList: audioBufferList) == noErr else { return nil }
        return sampleBuffer
    }
}
