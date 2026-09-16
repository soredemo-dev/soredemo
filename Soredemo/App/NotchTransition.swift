import Foundation

/// When each part of the editor's opening animation runs.
///
/// **The timings are a value, not three numbers spread across three `withAnimation` calls.**
/// What the design actually specifies is a set of RELATIONS — the shape starts before the
/// backdrop has finished so the two read as one gesture, the reveal starts before the shape
/// has finished so the window is already there when the panel goes — and relations written as
/// literals inside animation calls are relations nothing checks. Written here they can be.
///
/// **The durations themselves are a starting point and are named as such.** They come from
/// a notch library's 0.4 s over a much shorter distance, and the honest way to settle them is
/// the way the countdown was settled: `--show-notch-transition` plays it on demand and a
/// person looks at it. See docs/design/the-editor-comes-out-of-the-notch.md.
struct NotchTransition: Equatable {
    /// A span of the animation, in seconds from the moment it begins.
    struct Phase: Equatable {
        let start: Double
        let duration: Double
        var end: Double { start + duration }

        /// How far through this phase a given moment is, 0 before it and 1 after it.
        ///
        /// Clamped at both ends rather than extrapolated: a phase asked about a moment outside
        /// itself has an answer, and it is not a number beyond its own range.
        func progress(at time: Double) -> Double {
            guard duration > 0 else { return time >= start ? 1 : 0 }
            return min(1, max(0, (time - start) / duration))
        }
    }

    /// The ground goes dark. **Full-screen AND opaque from its first frame.**
    ///
    /// This faded in over 0.10 s, and the fade was a hole exactly its own size. The editor
    /// window is created, ordered front at whatever frame was autosaved, resized and only then
    /// asked for full screen — and the first of those happens inside 100 ms, in front of a
    /// cover that is still mostly transparent. Reported as the editor "zooming to the bottom
    /// right and then the notch animation": the bottom right is where the autosaved frame was.
    ///
    /// A cover whose whole job is to be opaque cannot fade in. What it was fading over is a
    /// desktop that is about to be replaced by an editor, and nobody is looking at it.
    let backdrop: Phase
    /// The notch becomes the window. Zero duration when Reduce Motion is on, which is what
    /// "there is no shape" means here.
    let shape: Phase
    /// The panel cross-fades out, revealing the editor that was underneath all along.
    let reveal: Phase

    var total: Double { max(backdrop.end, max(shape.end, reveal.end)) }

    /// Whether a shape is drawn at all. False under Reduce Motion.
    var drawsShape: Bool { shape.duration > 0 }

    /// The animation as designed.
    ///
    /// **The backdrop has no duration and that is not an omission.** See `backdrop`: it is
    /// there to hide a window being built, and a fade is transparent for as long as it lasts.
    /// The shape then starts a beat later, so the two still read as one gesture rather than a
    /// cut followed by an unrelated animation.
    static let standard = NotchTransition(
        backdrop: Phase(start: 0, duration: 0),
        shape: Phase(start: 0.05, duration: 0.45),
        reveal: Phase(start: 0.35, duration: 0.20))

    /// **Reduce Motion is not a smaller version of this.** An animation that travels 918 points
    /// is exactly what that setting exists to prevent, and halving it is not honouring it. What
    /// is left is a cross-fade: the ground darkens and clears, and the editor is there.
    static let reduced = NotchTransition(
        backdrop: Phase(start: 0, duration: 0),
        shape: Phase(start: 0, duration: 0),
        reveal: Phase(start: 0, duration: 0.20))

    static func chosen(reduceMotion: Bool) -> NotchTransition { reduceMotion ? reduced : standard }
}
