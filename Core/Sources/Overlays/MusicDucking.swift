import Foundation
import Timeline

/// **Music under narration, and how far out of the way it gets.**
///
/// A bed of music under a demo is one of the few things that separates a recording from a
/// video, and it is also the one that ruins a recording fastest: at a fixed level it either
/// buries the narration or is inaudible. Every tool that offers music therefore ducks it —
/// Background music that lowers itself when somebody speaks; sold elsewhere as voice
/// the same thing voice ducking. This is the envelope that does it: a level for when nobody
/// is speaking, a lower one for when somebody is, and the shape of the move between them.
///
/// **Pure, and over spans rather than over samples.** Where the speech is has already been
/// decided — `SilenceFinder` finds the silences in the microphone's own waveform and the
/// speech is what is left. Taking spans keeps this testable against a handful of numbers
/// rather than against an audio file, and keeps one answer to "where is the voice" rather
/// than two.
///
/// **The output is ramps, because that is what `AVAudioMix` takes.** A volume automation on
/// an `AVMutableAudioMixInputParameters` is a list of linear ramps over time ranges, and they
/// must be ordered and must not overlap. Producing them here — rather than a curve a caller
/// samples — means the thing that has to satisfy those two rules is the thing that is tested.
public enum MusicDucking {
    /// How far the music gets out of the way, and how quickly.
    public struct Settings: Hashable, Sendable, Codable {
        /// The music's level when nobody is speaking, linear.
        public var bedGain: Double
        /// Its level while somebody is, linear. **−12 dB under the bed by default**, which is
        /// the figure broadcast practice settles on: enough that speech sits clearly on top,
        /// little enough that the music does not audibly disappear and reappear.
        public var duckedGain: Double
        /// How long the drop takes. Short: the music must already be down when the first
        /// syllable lands, or the syllable is what it lands on.
        public var attack: Nanoseconds
        /// How long the recovery takes. Long, and deliberately much longer than the attack —
        /// a bed that springs back is more distracting than one that never ducked.
        public var release: Nanoseconds
        /// How long it stays down after the voice stops, before the release begins. This is
        /// what stops the music pumping between two words.
        public var hold: Nanoseconds

        /// **Uncalibrated in this project's sense**: −12 dB, 150 ms, 800 ms and 400 ms are the
        /// numbers broadcast ducking converges on rather than a measurement of this app.
        public static let `default` = Settings(
            bedGain: 0.25, duckedGain: 0.25 * 0.251,
            attack: Nanoseconds(150_000_000),
            release: Nanoseconds(800_000_000),
            hold: Nanoseconds(400_000_000))

        public init(bedGain: Double, duckedGain: Double, attack: Nanoseconds,
                    release: Nanoseconds, hold: Nanoseconds) {
            // Clamped rather than trapped: every one of these arrives from a slider and from a
            // decoder, which is rule 8's case. The ducked level is additionally held at or
            // below the bed, because "ducking" that raises the music is not ducking.
            self.bedGain = min(max(bedGain, 0), 1)
            self.duckedGain = min(max(duckedGain, 0), self.bedGain)
            self.attack = Nanoseconds(max(attack.rawValue, 0))
            self.release = Nanoseconds(max(release.rawValue, 0))
            self.hold = Nanoseconds(max(hold.rawValue, 0))
        }
    }

    /// One linear move, in the form `AVMutableAudioMixInputParameters.setVolumeRamp` takes.
    /// A flat stretch is a ramp whose ends are equal, so a caller has one thing to apply.
    public struct Ramp: Hashable, Sendable {
        public let start: Nanoseconds
        public let end: Nanoseconds
        public let from: Double
        public let to: Double

        public init(start: Nanoseconds, end: Nanoseconds, from: Double, to: Double) {
            self.start = start
            self.end = end
            self.from = from
            self.to = to
        }
    }

    /// **The music's volume over the whole timeline, as ordered non-overlapping ramps.**
    ///
    /// `speech` are the spans where somebody is talking, in the same time base as `duration`;
    /// they need not be sorted or disjoint. Everything else is bed.
    ///
    /// **The duck begins BEFORE the speech does.** A drop that starts when the voice starts is
    /// a drop the first syllable happens during. The attack is therefore placed in the
    /// `attack` before each span — and a span that starts inside the first `attack` of the
    /// timeline simply starts already ducked, since there is nowhere earlier to put it.
    ///
    /// **Spans too close together are one span.** Two words separated by less than the hold
    /// and release together would otherwise produce a rise the release never finishes and an
    /// immediate second fall — the pumping this exists to avoid. Merging happens before any
    /// ramp is placed, so the merged run is what everything downstream sees.
    public static func ramps(speech: [Range<Nanoseconds>], over duration: Nanoseconds,
                             settings: Settings) -> [Ramp] {
        let total = max(duration.rawValue, 0)
        guard total > 0 else { return [] }
        let bed = settings.bedGain, ducked = settings.duckedGain
        let runs = merged(speech, within: settings.hold.rawValue + settings.release.rawValue,
                          upTo: total)
        guard !runs.isEmpty else {
            return [Ramp(start: Nanoseconds(0), end: Nanoseconds(total), from: bed, to: bed)]
        }

        var ramps: [Ramp] = []
        var cursor: Int64 = 0
        var level = bed

        for run in runs {
            // Down: the attack sits in front of the voice, clamped to whatever room there is.
            let fallEnd = run.lowerBound
            let fallStart = max(cursor, fallEnd - settings.attack.rawValue)
            if fallStart > cursor {
                ramps.append(Ramp(start: Nanoseconds(cursor), end: Nanoseconds(fallStart),
                                  from: level, to: level))
            }
            if fallEnd > fallStart {
                ramps.append(Ramp(start: Nanoseconds(fallStart), end: Nanoseconds(fallEnd),
                                  from: level, to: ducked))
            }
            level = ducked
            cursor = max(fallEnd, fallStart)

            // Held down through the voice and for `hold` after it.
            let holdEnd = min(run.upperBound + settings.hold.rawValue, total)
            if holdEnd > cursor {
                ramps.append(Ramp(start: Nanoseconds(cursor), end: Nanoseconds(holdEnd),
                                  from: ducked, to: ducked))
                cursor = holdEnd
            }

            // Up, unless the timeline ends first.
            let riseEnd = min(cursor + settings.release.rawValue, total)
            if riseEnd > cursor {
                ramps.append(Ramp(start: Nanoseconds(cursor), end: Nanoseconds(riseEnd),
                                  from: ducked, to: bed))
                // A release cut short by the end of the timeline leaves the level where it
                // actually got to, not at the bed it was heading for.
                let reached = riseEnd - cursor >= settings.release.rawValue
                    || settings.release.rawValue == 0
                level = reached ? bed : ducked
                    + (bed - ducked) * Double(riseEnd - cursor) / Double(settings.release.rawValue)
                cursor = riseEnd
            }
        }
        if cursor < total {
            ramps.append(Ramp(start: Nanoseconds(cursor), end: Nanoseconds(total),
                              from: level, to: level))
        }
        return ramps
    }

    /// Sorted, clamped to `[0, total)`, and joined where the gap between two is smaller than
    /// `gap` — which is what makes a sentence one run rather than a run per word.
    static func merged(_ spans: [Range<Nanoseconds>], within gap: Int64,
                       upTo total: Int64) -> [Range<Int64>] {
        let clamped = spans.compactMap { span -> Range<Int64>? in
            let low = max(span.lowerBound.rawValue, 0)
            let high = min(span.upperBound.rawValue, total)
            return high > low ? low..<high : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        guard var current = clamped.first else { return [] }

        var runs: [Range<Int64>] = []
        for span in clamped.dropFirst() {
            if span.lowerBound - current.upperBound <= gap {
                current = current.lowerBound..<max(current.upperBound, span.upperBound)
            } else {
                runs.append(current)
                current = span
            }
        }
        runs.append(current)
        return runs
    }

    /// **The speech in a recording, as the complement of its silences.** `SilenceFinder` is
    /// the one place that decides where the voice is; this turns its answer inside out rather
    /// than deciding again.
    public static func speech(betweenSilences silences: [SilenceFinder.Span],
                              over duration: Nanoseconds) -> [Range<Nanoseconds>] {
        let total = max(duration.rawValue, 0)
        guard total > 0 else { return [] }
        let quiet = silences.map { $0.start.rawValue..<$0.end.rawValue }
            .sorted { $0.lowerBound < $1.lowerBound }
        var spans: [Range<Nanoseconds>] = []
        var cursor: Int64 = 0
        for span in quiet {
            let low = max(span.lowerBound, 0), high = min(span.upperBound, total)
            if low > cursor { spans.append(Nanoseconds(cursor)..<Nanoseconds(low)) }
            cursor = max(cursor, high)
        }
        if cursor < total { spans.append(Nanoseconds(cursor)..<Nanoseconds(total)) }
        return spans
    }
}
