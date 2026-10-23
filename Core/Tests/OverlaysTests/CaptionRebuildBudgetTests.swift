import Foundation
import Overlays
import Testing
import Timeline

/// What it costs to rebuild a caption track, at the size a real recording produces.
///
/// **§ 5.2 of docs/TESTING.md named this as unmeasured and it stayed that way for ten days.**
/// It is not an idle number: `CaptionsModel.rebuild` runs on every change to the caption style,
/// the output size and the maximum words per line — a slider, in other words. A rebuild that
/// takes 200 ms is a slider that stutters, and nothing would have said so.
///
/// 270 cues is the figure the surveyed subtitle editor showed on a real film, and it is the
/// size this project has used as "a long recording" since the caption work began.
///
/// **Measured 2026-09-15 on macOS 27: 60.5 ms**, tight (60.15–61.04 over five runs). The budget
/// is 150 — about two and a half times it, the same convention the frame budgets use.
///
/// **What the measurement settled, and it was not what prompted it.** 60 ms a call is sixteen
/// frames a second, which would be a visibly stuttering slider — so the first question was
/// whether a caption-style slider rebuilds. It does not: `setStyle` publishes without
/// rebuilding, and the only callers are the words-per-line picker and the spoken-terms list,
/// both discrete actions where 60 ms is not felt. The number was worth having either way, and
/// the thing it now guards is a rebuild going quadratic — which is how `CameraMotion` shipped
/// once and was found by a person watching a recording stutter.
@Suite struct CaptionRebuildBudgetTests {

    /// A transcript of `cues` sentences, each long enough to break into one caption.
    private static func transcript(sentences: Int) -> Transcript {
        var words: [TranscribedWord] = []
        var segments: [TranscribedSegment] = []
        var text = ""
        // Six words a sentence, half a second each: three seconds a cue, which is what the
        // reading-speed rules produce for a line of this length.
        let wordNanos: Int64 = 500_000_000
        var clock: Int64 = 0
        for sentence in 0..<sentences {
            let start = clock
            var sentenceText = ""
            for word in 0..<6 {
                let spelling = "word\(sentence)\(word)"
                words.append(TranscribedWord(text: spelling,
                                             start: Nanoseconds(clock),
                                             end: Nanoseconds(clock + wordNanos)))
                sentenceText += sentenceText.isEmpty ? spelling : " " + spelling
                clock += wordNanos
            }
            sentenceText += "."
            segments.append(TranscribedSegment(text: sentenceText,
                                               start: Nanoseconds(start),
                                               end: Nanoseconds(clock)))
            text += text.isEmpty ? sentenceText : " " + sentenceText
        }
        return Transcript(text: text, languageCode: "en", words: words, segments: segments)
    }

    /// **Two decimals, in one place.** `String(format:)` is a C variadic and the compiler
    /// cannot see that the format string matches its argument.
    private static func ms(_ value: Double) -> String { unsafe String(format: "%.2f", value) }

    /// **A slider's worth of work, measured at the size that makes it hurt.**
    ///
    /// The budget is deliberately generous against the measurement — this runs on whatever
    /// machine somebody has — but it is not so generous that a rebuild going quadratic could
    /// hide inside it. The `CameraMotion` O(n²) shipped once and was found by a person watching
    /// a recording stutter; this is the shape of instrument that finds the next one first.
    @Test func rebuildingTwoHundredAndSeventyCuesIsFastEnoughForASlider() {
        let transcript = Self.transcript(sentences: 270)
        // 42 display columns is the Latin line length; measuring against the real rule rather
        // than a stub keeps the cost representative of what the app actually does.
        let fits: (String) -> Bool = { CaptionMeasurement.width(of: $0) <= 42 }

        // Warm first: the first call pays for whatever the runtime sets up once.
        _ = CaptionBuilder.cues(for: transcript, fits: fits)

        var timings: [Double] = []
        for _ in 0..<5 {
            let started = ContinuousClock.now
            let cues = CaptionBuilder.cues(for: transcript, fits: fits)
            let took = ContinuousClock.now - started
            timings.append(Double(took.components.seconds) * 1000
                           + Double(took.components.attoseconds) / 1e15)
            #expect(cues.count >= 200, "only \(cues.count) cues — the fixture is not 270 lines")
        }
        timings.sort()
        let median = timings[timings.count / 2]

        #expect(median < 150, """
            rebuilding 270 cues took \(Self.ms(median)) ms, budget 150. Every caption-style \
            slider rebuilds the whole track, so this is the cost of one drag frame. \
            Fastest \(Self.ms(timings[0])), slowest \(Self.ms(timings[timings.count - 1])).
            """)
    }
}
