import Foundation

/// Whether the microphone has heard NOTHING for long enough to say so.
///
/// **No signal, not no speech.** A person pausing to think is not told anything; a muted
/// interface or the wrong input is — the failure found ten minutes into a take, afterwards. Two
/// ways to hear nothing, and the level alone sees only one: buffers of near-zero samples, and no
/// buffers at all. A device that stops delivering leaves `latestRMS` at its last value, so the
/// delivered count not moving is the only thing that notices.
///
/// Fed by `RecordingCoordinator.tick`, which does not run while paused; `reset()` on resume. See
/// `docs/design/2026-09-28-notch-marks-and-audio-warnings.md`.
nonisolated struct MicrophoneSilenceWatch: Equatable {
    /// −80 dBFS. **Chosen, not measured** — below any working microphone's noise floor, so that it
    /// fires on a dead input and not on a quiet room. `ARCHITECTURE.md` D6b.
    static let floorRMS = 0.0001
    /// Unbroken seconds of nothing before it is said.
    static let patience = 5.0

    private var lastDelivered: Int?
    /// **Whole milliseconds, not a sum of `Double`s.** Twenty ticks of 0.05 s summed as doubles
    /// is 0.9999999999999999 s, so the five-second patience ran one tick late — measured, by the
    /// test written to hit it exactly.
    private var quietMillis = 0

    /// Takes one tick's reading and answers whether the microphone hears nothing.
    ///
    /// A buffer whose level could not be read is counted as heard: unknown resolves to no warning,
    /// because a warning that fires on a working microphone is one people learn to ignore.
    mutating func observe(delivered: Int, latestRMS: Double?, over interval: Double) -> Bool {
        let arrived = delivered > (lastDelivered ?? 0)
        lastDelivered = delivered
        let heard = arrived && (latestRMS.map { $0 >= Self.floorRMS } ?? true)
        quietMillis = heard ? 0 : quietMillis + Int((interval * 1000).rounded())
        return quietMillis >= Int((Self.patience * 1000).rounded())
    }

    mutating func reset() {
        lastDelivered = nil
        quietMillis = 0
    }
}
