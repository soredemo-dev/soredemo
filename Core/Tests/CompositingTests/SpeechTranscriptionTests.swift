import Testing
import Foundation
import AVFoundation
import CoreMedia
import Captions
import Timeline
@testable import Compositing

/// **What is NOT tested here, and why.** `OnDeviceTranscription.transcript(from:locale:)` takes
/// `[SpeechTranscriber.Result]`, and that type has no public initialiser — a test cannot build
/// one, so the run-walking cannot be exercised without a real speech model, a real download and
/// a fixture with speech in it. What IS exercised is everything around it: the time conversion
/// that the run-walking calls, the audio extraction it runs on, and the errors it reports.
@Suite struct SpeechTranscriptionTests {
    /// The reason `nanoseconds` exists rather than `Int64(time.seconds * 1e9)`.
    @Test func timesConvertWithoutGoingThroughDoubleSeconds() {
        // 4.1 s at a 10-tick timescale. Through `Double` this is 4099999999.
        let time = CMTime(value: 41, timescale: 10)
        #expect(OnDeviceTranscription.nanoseconds(time) == Nanoseconds(4_100_000_000))
        #expect(OnDeviceTranscription.nanoseconds(CMTime.zero) == Nanoseconds(0))
    }

    /// A recogniser can hand back an invalid or indefinite time; a caption at
    /// `Int64.min` nanoseconds would be a cue no player and no timeline can place.
    @Test func anInvalidOrNegativeTimeBecomesZeroRatherThanGarbage() {
        #expect(OnDeviceTranscription.nanoseconds(.invalid) == Nanoseconds(0))
        #expect(OnDeviceTranscription.nanoseconds(.indefinite) == Nanoseconds(0))
        #expect(OnDeviceTranscription.nanoseconds(CMTime(value: -5, timescale: 1))
                == Nanoseconds(0))
    }

    /// A real extraction from the render-parity fixture. It has no audio track, which is exactly
    /// the case a caller has to be told about rather than left with an empty transcript.
    @Test func extractingAudioFromARecordingWithNoneSaysSoRatherThanReturningSilence() async throws {
        let silent = repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov")
        await #expect(throws: TranscriptionError.noAudioTrack) {
            try await OnDeviceTranscription.extractAudio(from: silent, range: nil)
        }
    }

    /// The whole point of the seam: a caller depends on the protocol, so a cloud backend is an
    /// implementation rather than a rewrite. Exercised with a stub, which is also the proof that
    /// the protocol is implementable by something other than the type it was extracted from.
    @Test func aCallerCanDependOnTheSeamRatherThanOnTheOnDeviceType() async throws {
        struct StubSource: TranscriptionSource {
            func transcript(of url: URL, range: Range<Int64>?,
                            onProgress: (@Sendable (TranscriptionProgress) -> Void)?
            ) async throws -> Transcript {
                onProgress?(.extractingAudio)
                onProgress?(.listening)
                return Transcript(text: "hello", languageCode: "en-US",
                                  segments: [TranscribedSegment(text: "hello",
                                                                start: Nanoseconds(0),
                                                                end: Nanoseconds(500_000_000))])
                    .offset(by: range?.lowerBound ?? 0)
            }
        }

        let source: any TranscriptionSource = StubSource()
        let phases = PhaseLog()
        let transcript = try await source.transcript(
            of: URL(fileURLWithPath: "/tmp/whatever.mov"),
            range: 2_000_000_000..<4_000_000_000,
            onProgress: { phases.append($0) })

        // The seam's contract: a transcript of a RANGE comes back in the recording's time.
        #expect(transcript.segments[0].start == Nanoseconds(2_000_000_000))
        #expect(phases.recorded == [.extractingAudio, .listening])
    }

    /// The model download is the phase worth naming: it is hundreds of megabytes on first run,
    /// and a spinner with no explanation reads as a hang.
    @Test func theProgressPhasesAreDistinctAndTheDownloadNamesItsLanguage() {
        let phases: [TranscriptionProgress] = [
            .extractingAudio, .installingModel(language: "en-US"), .listening,
        ]
        #expect(Set(phases.map(String.init(describing:))).count == 3)
        #expect(TranscriptionProgress.installingModel(language: "zh-Hant")
                != TranscriptionProgress.installingModel(language: "en-US"))
    }

    @Test func theTranscriptionErrorCasesDescribeThemselvesDistinctly() {
        let cases: [TranscriptionError] = [
            .noAudioTrack, .unsupportedLanguage("qx-QX"), .modelInstallFailed("disk full"),
            .audioExtractionFailed("bad file"), .recognitionFailed("cancelled"),
        ]
        #expect(Set(cases.map(\.description)).count == cases.count)
        #expect(TranscriptionError.unsupportedLanguage("qx-QX").description.contains("qx-QX"))
    }

    /// A caller should be able to hide the button rather than offer one that always fails.
    @Test func availabilityAndSupportedLocalesCanBeAskedWithoutTranscribingAnything() async {
        // Whichever this machine answers, asking must not trap and must not download a model.
        _ = OnDeviceTranscription.isAvailable
        let locales = await OnDeviceTranscription.supportedLocales
        // On a machine with speech support this is non-empty; on one without it is empty. Both
        // are legitimate, so what is asserted is that every entry is a real language tag.
        for locale in locales {
            #expect(!locale.identifier(.bcp47).isEmpty)
        }
    }

    @Test func theDefaultsAreNoCensoringAndTheSystemsOwnLanguage() {
        let source = OnDeviceTranscription()
        #expect(!source.censorsProfanity)
        #expect(source.locale == nil)
    }
}

/// A `@Sendable` progress callback needs somewhere thread-safe to write. `NSLock` rather than an
/// actor so the test body can read it synchronously after awaiting the call.
private final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [TranscriptionProgress] = []

    func append(_ phase: TranscriptionProgress) {
        lock.lock(); defer { lock.unlock() }
        phases.append(phase)
    }

    var recorded: [TranscriptionProgress] {
        lock.lock(); defer { lock.unlock() }
        return phases
    }
}
