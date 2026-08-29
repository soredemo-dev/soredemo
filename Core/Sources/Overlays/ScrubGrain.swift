import Foundation

/// The arithmetic behind scrub audio: which samples a grain is cut from, and the shape it is
/// faded with.
///
/// **Dragging a playhead in silence is the difference between finding a word and hunting for
/// one.** A picture at 3.2 seconds looks like the picture at 3.4; the sentence does not.
///
/// A grain is a short slice of the recording played whole each time the playhead moves. Held
/// still, the same grain repeats and reads as a held note; dragged, successive grains walk
/// through the recording and read as speech at whatever speed the hand is moving.
///
/// **This type has no engine in it and no file**, so the two things that go wrong can be checked:
/// a grain cut past the end of what was read, and a grain that does not fade.
public enum ScrubGrain {
    /// How long one grain is, in seconds.
    ///
    /// **50 ms, between two failures.** Shorter than about 20 ms and a vowel has no pitch left —
    /// the result is a series of ticks rather than a voice. Longer than about 100 ms and the
    /// grain outlives the hand: a drag that has already moved on is still hearing where it was,
    /// which reads as lag rather than as scrubbing.
    public static let seconds = 0.05

    /// How long each end of a grain is faded, in seconds.
    ///
    /// **3 ms, and without it the whole feature is a click track.** A grain begins and ends at an
    /// arbitrary point in a waveform, so its first and last samples are almost never zero — and a
    /// step from silence to mid-waveform is a click. Every grain would have two.
    ///
    /// Long enough to remove the step and short enough that a 50 ms grain is still mostly itself:
    /// six per cent of it is fade.
    public static let fadeSeconds = 0.003

    /// How much audio is read at once, in seconds.
    ///
    /// **2 seconds, because reading per grain would stall the drag.** Decoding a compressed
    /// stream to reach one 50 ms slice costs far more than the slice, and a drag asks for a new
    /// slice sixty times a second. One read serves forty grains.
    public static let windowSeconds = 2.0

    /// Where a grain starts, in samples, for a scrub to `seconds`.
    ///
    /// **Centred on the playhead rather than starting at it.** A grain that starts at the
    /// playhead plays the 50 ms AFTER where somebody is pointing, so the sound is consistently
    /// ahead of the line. Centring makes the line the middle of what is heard.
    ///
    /// Clamped to zero: a scrub to the first moments of a recording would otherwise ask for
    /// samples before the beginning.
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
    /// `samples` are the window that was read and `windowStart` is where it begins, both in
    /// samples from the start of the recording. Returns `nil` when the grain does not lie wholly
    /// inside the window — **a partial grain is refused rather than padded**, because padding is
    /// silence and a burst of silence in the middle of a drag reads as a dropout.
    ///
    /// Reversed when `backwards`, which is what a drag to the left should sound like. Speech
    /// played backwards is unintelligible and that is not the point: what it carries is the
    /// rhythm, and the rhythm is what somebody is navigating by.
    public static func cut(from samples: [Float], windowStart: Int, startSample: Int,
                           length: Int, sampleRate: Double = 48_000,
                           backwards: Bool = false) -> [Float]? {
        guard length > 0, startSample >= windowStart else { return nil }
        let offset = startSample - windowStart
        guard offset + length <= samples.count else { return nil }
        var grain = Array(samples[offset..<(offset + length)])
        if backwards { grain.reverse() }
        // **The rate is passed through rather than defaulted here.** A fade written in seconds
        // is a different number of samples at every rate, and a grain cut from a 44.1 kHz file
        // faded as though it were 48 kHz is faded 9% short — which is a smaller click, not none.
        applyFades(to: &grain, sampleRate: sampleRate)
        return grain
    }

    /// Ramps the first and last `fadeSeconds` of a grain to zero.
    ///
    /// **Linear, not raised-cosine.** A cosine fade is the textbook answer and is inaudibly
    /// different over three milliseconds; a straight line is two multiplications and no table.
    ///
    /// A grain shorter than two fades is faded across its whole length rather than having its
    /// ends overlap, which would amplify the middle.
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
    /// **Aligned to a grid rather than centred on the request.** A window centred on wherever the
    /// hand happens to be is a different window on every frame of a drag, so nothing is ever a
    /// cache hit. On a grid, a drag through one window's worth of recording reads once.
    ///
    /// The window is widened by a grain at each end so a grain centred anywhere inside the grid
    /// cell still lies wholly within what was read — the case `cut` refuses.
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
