import AVFoundation
import Overlays
import Foundation
import NaturalLanguage
import Speech
import Timeline

/// Turning a recording's speech into a `Transcript`.
///
/// **On device, and that is a privacy decision before it is a quality one.** A cloud recogniser
/// is more accurate — measurably so for accented speech and for Chinese — and it is the right
/// thing to offer. What it cannot be is the DEFAULT: transcribing in the cloud means uploading
/// the audio of whatever a person was demonstrating, which may be a bug report containing their
/// own customer's data. `../opensource/Screen Record Opensource/a native editor` models exactly
/// this as `TranscriptionProvider { local, cloud }` and this type is the `local` half; the seam
/// is `TranscriptionSource` below, so adding a cloud backend later adds an implementation rather
/// than rewriting the caption path.
///
/// Second-order: on device there is no key to hold, no quota to run out of, and it works on a
/// plane. For a screen recorder those are not small.
public protocol TranscriptionSource: Sendable {
    /// The transcript for `range` of the recording at `url`, in the RECORDING's time — an
    /// implementation transcribing an extracted span must offset its result back.
    func transcript(of url: URL, range: Range<Int64>?,
                    onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcript
}

/// Where transcription has got to. Three phases and no fraction, because none of them has an
/// honest one: a model download reports bytes we do not control, and `SpeechAnalyzer` reports
/// results as it finds them rather than a position.
public enum TranscriptionProgress: Sendable, Equatable {
    /// Pulling the audio out of the recording.
    case extractingAudio
    /// Downloading the on-device model for this language. First run only, and it is hundreds of
    /// megabytes — a person watching a spinner with no explanation would reasonably assume the
    /// app had hung.
    case installingModel(language: String)
    case listening
}

/// The on-device implementation, over macOS 26's `SpeechAnalyzer`.
public struct OnDeviceTranscription: TranscriptionSource {
    /// Replaces recognised profanity with its first letter and asterisks. Off by default: this
    /// is a recording of what a person said.
    public var censorsProfanity: Bool
    /// The language to recognise, or `nil` to pick from the system's preferred languages.
    public var locale: Locale?

    public init(censorsProfanity: Bool = false, locale: Locale? = nil) {
        self.censorsProfanity = censorsProfanity
        self.locale = locale
    }

    /// Whether this machine can transcribe at all, so a caller can hide the button rather than
    /// offer one that always fails.
    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    public static var supportedLocales: [Locale] {
        get async { await SpeechTranscriber.supportedLocales }
    }

    /// The locales this machine has already downloaded a model for.
    ///
    /// **Worth distinguishing from `supportedLocales`.** Choosing a supported-but-not-installed
    /// language is legitimate and triggers a several-hundred-megabyte download; a person picking
    /// from a list should be able to see which choice is instant and which is not.
    public static var installedLocales: [Locale] {
        get async { await SpeechTranscriber.installedLocales }
    }

    /// **On the mixed-language question, plainly: this cannot do it.**
    ///
    /// `SpeechTranscriber` is given one locale and recognises that language. A sentence that
    /// switches between Traditional Chinese and English mid-way is transcribed by whichever
    /// model was chosen, and the other language's words come back wrong or missing. That is a
    /// property of the on-device model, not of how it is driven here — there is no code-switching
    /// option to turn on.
    ///
    /// What IS possible, and what this reports: transcribe, then look at what came back. If the
    /// text is not the language that was asked for, say so, so a person can choose again rather
    /// than reading a page of nonsense and blaming the app. `NLLanguageRecognizer` is what
    /// answers that — it reads text, so it can only run after the fact.
    ///
    /// The real fix is a cloud recogniser that does code-switching, which is what
    /// `TranscriptionSource` exists to let someone plug in.
    public static func dominantLanguage(of transcript: Transcript) -> String? {
        guard !transcript.text.isEmpty else { return nil }
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(transcript.text)
        return recogniser.dominantLanguage?.rawValue
    }

    /// True when the text that came back does not look like the language that was asked for.
    ///
    /// Compared on the LANGUAGE, not the full tag: asking for `zh-TW` and getting text
    /// `NLLanguageRecognizer` calls `zh-Hant` is a match, and treating it as a mismatch would
    /// warn on every correct Chinese transcription.
    public static func languageLooksWrong(_ transcript: Transcript) -> Bool {
        guard let asked = transcript.languageCode,
              let found = dominantLanguage(of: transcript),
              // Under a handful of words the recogniser guesses, and a warning on a two-word
              // caption would be noise on exactly the recordings that need it least.
              transcript.text.count > 24 else { return false }
        let askedLanguage = Locale(identifier: asked).language.languageCode?.identifier
        let foundLanguage = Locale(identifier: found).language.languageCode?.identifier
        guard let askedLanguage, let foundLanguage else { return false }
        return askedLanguage != foundLanguage
    }

    public func transcript(of url: URL, range: Range<Int64>? = nil,
                           onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcript {
        onProgress?(.extractingAudio)
        let audioURL = try await Self.extractAudio(from: url, range: range)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let locale = try await Self.resolvedLocale(preferring: locale)
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: censorsProfanity ? [.etiquetteReplacements] : [],
            reportingOptions: [],
            // **Without this the words have no times**, and a caption track timed by sharing out
            // a sentence is the fallback rather than the design — see `CaptionBuilder`.
            attributeOptions: [.audioTimeRange])

        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onProgress?(.installingModel(language: locale.identifier(.bcp47)))
            do {
                try await install.downloadAndInstall()
            } catch {
                throw TranscriptionError.modelInstallFailed(String(describing: error))
            }
        }

        onProgress?(.listening)
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw TranscriptionError.audioExtractionFailed(String(describing: error))
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // **Collecting starts BEFORE analysis does.** `results` is a live sequence; a collector
        // started afterwards would miss everything the analyzer had already emitted, and on a
        // short recording that is all of it.
        let collecting = Task { () throws -> [SpeechTranscriber.Result] in
            var collected: [SpeechTranscriber.Result] = []
            for try await result in transcriber.results { collected.append(result) }
            return collected
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collecting.cancel()
            throw TranscriptionError.recognitionFailed(String(describing: error))
        }

        let results: [SpeechTranscriber.Result]
        do {
            results = try await collecting.value
        } catch {
            throw TranscriptionError.recognitionFailed(String(describing: error))
        }

        let transcript = Self.transcript(from: results, locale: locale)
        // Back into the recording's own time — a caller who transcribed a selection asked about
        // the recording, not about the extract.
        return transcript.offset(by: range?.lowerBound ?? 0)
    }

    // MARK: - locale

    /// The recogniser's own matcher first, then the system's preferred languages, then the
    /// current locale. a native editor hand-rolls this walk because it predates
    /// `supportedLocale(equivalentTo:)`; that call handles the BCP 47 subtleties its comment
    /// describes — stripping `-u-` extension tags, falling back from a region to its language —
    /// so it is used instead of a second copy of the logic.
    static func resolvedLocale(preferring preferred: Locale?) async throws -> Locale {
        let candidates = [preferred].compactMap(\.self)
            + Locale.preferredLanguages.map(Locale.init(identifier:))
            + [Locale.current]
        for candidate in candidates {
            if let match = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
                return match
            }
        }
        throw TranscriptionError.unsupportedLanguage(
            (preferred ?? Locale.current).identifier(.bcp47))
    }

    // MARK: - audio

    /// The recording's audio as an m4a `AVAudioFile` can open.
    ///
    /// **An export rather than a hand-rolled PCM extraction.** a native editor decodes to 16 kHz
    /// mono PCM itself through an `AVAssetReader`, which means walking `AudioBufferList`s
    /// through raw pointers; under `.strictMemorySafety()` that is a page of `unsafe` marks
    /// buying a re-encode we do not need to avoid, since a speech model resamples to 16 kHz
    /// regardless of what it is given.
    static func extractAudio(from url: URL, range: Range<Int64>?) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw TranscriptionError.noAudioTrack
        }
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.audioExtractionFailed("no m4a export preset for this asset")
        }
        if let range {
            session.timeRange = CMTimeRange(
                start: CMTime(value: range.lowerBound, timescale: 1_000_000_000),
                end: CMTime(value: range.upperBound, timescale: 1_000_000_000))
        }
        // A name from the source rather than a minted one: rule 3 forbids this tier reading
        // ambient randomness, and the process's own temporary directory already isolates it.
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "soredemo-speech-\(url.deletingPathExtension().lastPathComponent).m4a")
        try? FileManager.default.removeItem(at: outputURL)
        do {
            try await session.export(to: outputURL, as: .m4a)
        } catch {
            throw TranscriptionError.audioExtractionFailed(String(describing: error))
        }
        return outputURL
    }

    // MARK: - decoding

    /// Each `Result` is one endpointed run of speech: emitted as a segment, and its attributed
    /// runs walked into words. A run with no `audioTimeRange` is dropped from `words` rather
    /// than given the segment's time — a word timing that is a guess is worse than none, because
    /// `CaptionBuilder` can tell the difference and falls back deliberately.
    static func transcript(from results: [SpeechTranscriber.Result],
                           locale: Locale) -> Transcript {
        var words: [TranscribedWord] = []
        var segments: [TranscribedSegment] = []
        var whole = ""

        for result in results {
            let attributed = result.text
            let spoken = plainText(attributed)
            whole += spoken

            let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(TranscribedSegment(text: text,
                                                   start: nanoseconds(result.range.start),
                                                   end: nanoseconds(result.range.end)))
            }

            for run in attributed.runs {
                let text = plainText(AttributedString(attributed[run.range]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let span = run.audioTimeRange else { continue }
                words.append(TranscribedWord(text: text,
                                             start: nanoseconds(span.start),
                                             end: nanoseconds(span.start + span.duration)))
            }
        }

        return Transcript(text: whole.trimmingCharacters(in: .whitespacesAndNewlines),
                          languageCode: locale.identifier(.bcp47),
                          words: words, segments: segments)
    }

    /// The plain text of an `AttributedString`, through `NSAttributedString` rather than
    /// `.characters`.
    ///
    /// **`.characters` cannot be named anywhere in this repository.**
    /// `noAppSourceReadsKeystrokeText` bans it, because it is also how an `NSEvent` yields the
    /// text of a keystroke, and that check's whole value is in being absolute — its own words
    /// are that "a filter can be bypassed by a second code path and an unnameable API cannot".
    /// An exemption for this file would trade that guarantee for one allocation per run. This is
    /// the allocation.
    static func plainText(_ attributed: AttributedString) -> String {
        NSAttributedString(attributed).string
    }

    /// `CMTime` to nanoseconds without going through `seconds`. The `Double` round trip is what
    /// turns 4.1 into 4099999999, and a caption is compared against frame boundaries.
    static func nanoseconds(_ time: CMTime) -> Nanoseconds {
        guard time.isValid, !time.isIndefinite, time.timescale != 0 else { return Nanoseconds(0) }
        let scaled = time.convertScale(1_000_000_000, method: .roundHalfAwayFromZero)
        return Nanoseconds(max(0, scaled.value))
    }
}

public enum TranscriptionError: Error, CustomStringConvertible, Sendable, Equatable {
    case noAudioTrack
    case unsupportedLanguage(String)
    case modelInstallFailed(String)
    case audioExtractionFailed(String)
    case recognitionFailed(String)

    public var description: String {
        switch self {
        case .noAudioTrack:
            "the recording has no audio to transcribe"
        case .unsupportedLanguage(let code):
            "on-device transcription is not available for \(code)"
        case .modelInstallFailed(let reason):
            "could not install the speech model: \(reason)"
        case .audioExtractionFailed(let reason):
            "could not read the recording's audio: \(reason)"
        case .recognitionFailed(let reason):
            "transcription failed: \(reason)"
        }
    }
}
