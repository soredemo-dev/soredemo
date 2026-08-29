import Foundation

/// The arithmetic behind scrub audio: which samples a grain is cut from, and the
/// shape it is faded with.
///
/// No engine and no file, so the two things that actually go wrong can be checked
/// in a test: a grain cut past the end of what was read, and a grain that does not
/// fade. What a grain is and why each duration is what it is:
/// `docs/design/hearing-the-scrub.md`.
public enum ScrubGrain {
    /// How long one grain is, in seconds. 50 ms, between two failures: under
    /// ~20 ms a vowel has no pitch left, over ~100 ms the grain outlives the hand.
    public static let seconds = 0.05

    /// How long each end of a grain is faded, in seconds. Without it the whole
    /// feature is a click track; at 3 ms only six per cent of a grain is fade.
    public static let fadeSeconds = 0.003

    /// How much audio is read at once, in seconds. One read serves forty grains;
    /// reading per grain would stall the drag.
    public static let windowSeconds = 2.0

    /// Where a grain starts, in samples, for a scrub to `seconds`.
    ///
    /// Centred on the playhead, so the line is the middle of what is heard rather
    /// than its start. Clamped to zero for a scrub to the first moments.
    public static func startSample(atSeconds seconds: Double, sampleRate: Double) -> Int {
        guard seconds.isFinite, sampleRate > 0 else { return 0 }
        let centre = seconds * sampleRate
        return max(Int((centre - Self.seconds * sampleRate / 2).rounded()), 0)
    }

    /// How many samples a grain is at this rate. At least one, so a nonsensical rate cannot
    /// produce an empty grain that reads as silence rather than as an error.
    public static func length(sampleRate: Double) -> Int {
        max(Int((Self.seconds * sampleRate).rounded()), 1)
    }

    /// One grain cut out of `samples`, faded at both ends.
    ///
    /// `samples` are the window that was read and `windowStart` is where it
    /// begins, both in samples from the start of the recording. `nil` when the
    /// grain does not lie wholly inside the window: a partial grain is refused
    /// rather than padded, because padding is silence and silence mid-drag reads
    /// as a dropout.
    ///
    /// Reversed when `backwards`, which is what a drag to the left sounds like.
    public static func cut(from samples: [Float], windowStart: Int, startSample: Int,
                           length: Int, sampleRate: Double = 48_000,
                           backwards: Bool = false) -> [Float]? {
        guard length > 0, startSample >= windowStart else { return nil }
        let offset = startSample - windowStart
        guard offset + length <= samples.count else { return nil }
        var grain = Array(samples[offset..<(offset + length)])
        if backwards { grain.reverse() }
        // The rate is passed through, not defaulted: a 44.1 kHz grain faded as
        // though it were 48 kHz is faded 9% short, which is a smaller click.
        applyFades(to: &grain, sampleRate: sampleRate)
        return grain
    }

    /// Ramps the first and last `fadeSeconds` of a grain to zero. Linear: a cosine
    /// fade is inaudibly different over three milliseconds.
    ///
    /// A grain shorter than two fades is faded across its whole length rather than
    /// having its ends overlap, which would amplify the middle.
    public static func applyFades(to grain: inout [Float], sampleRate: Double = 48_000) {
        let count = grain.count
        guard count > 1 else { return }
        let requested = max(Int((fadeSeconds * sampleRate).rounded()), 1)
        let fade = min(requested, count / 2)
        guard fade > 0 else { return }
        for index in 0..<fade {
            let gain = Float(index) / Float(fade)
            grain[index] *= gain
            grain[count - 1 - index] *= gain
        }
    }

    /// The window a scrub to `seconds` should be served from, as a sample range.
    ///
    /// Grid-aligned, not centred on the request: a window that followed the hand
    /// would never be a cache hit. Widened by a grain at each end so a grain
    /// centred anywhere inside the cell lies wholly within what was read.
    public static func window(atSeconds seconds: Double, sampleRate: Double)
    -> (start: Int, length: Int) {
        guard seconds.isFinite, sampleRate > 0 else { return (0, 1) }
        let windowSamples = max(Int((windowSeconds * sampleRate).rounded()), 1)
        let grainSamples = length(sampleRate: sampleRate)
        let cell = max(Int((seconds * sampleRate).rounded()), 0) / windowSamples
        let start = max(cell * windowSamples - grainSamples, 0)
        return (start, windowSamples + grainSamples * 2)
    }
}
