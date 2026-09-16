import Testing
@testable import Soredemo

// When each part of the editor's opening runs, and the shape at any moment of it.
//
// **What is asserted here is RELATIONS, not durations.** The durations are a starting point
// derived from another library's 0.4 s over a much shorter distance, and the only instrument
// that can settle them is somebody watching at full speed — which is what
// `--show-notch-transition` exists for. What a test can hold is the shape of the gesture: that
// the three phases overlap so it reads as one thing, that the rectangle starts on the notch and
// ends on the window, and that Reduce Motion is not a smaller version of the same animation.

@Suite struct NotchTransitionTests {

    // MARK: - the phases

    /// **The ground is dark before anything else happens, and it does not fade there.**
    ///
    /// It faded over 0.10 s, and the fade was a hole exactly its own size: the editor window is
    /// created and ordered front inside that, at whatever frame was autosaved, in front of a
    /// cover that is still mostly transparent. Reported as the editor zooming to the bottom
    /// right before the notch animation — the bottom right being where the autosaved frame was.
    @Test @MainActor func theGroundIsAlreadyDarkWhenAnythingElseStarts() {
        for transition in [NotchTransition.standard, .reduced] {
            #expect(transition.backdrop.duration == 0, "the cover fades in; that is a hole")
            #expect(transition.backdrop.progress(at: 0) == 1,
                    "the cover is not opaque at the first frame")
        }
        // The shape still starts a beat later, so the two read as one gesture rather than a cut
        // followed by an unrelated animation.
        #expect(NotchTransition.standard.shape.start > NotchTransition.standard.backdrop.end)
        #expect(NotchTransition.standard.shape.start < 0.1,
                "the pause between the cover and the shape is long enough to read as two things")
    }

    /// **The reveal starts before the shape has finished**, so the editor is already there when
    /// the panel goes rather than appearing after it.
    @Test @MainActor func theEditorArrivesBeforeTheShapeHasStopped() {
        let transition = NotchTransition.standard
        #expect(transition.reveal.start < transition.shape.end)
        #expect(transition.reveal.end >= transition.shape.end,
                "the panel would clear before the shape had landed")
    }

    /// Nothing starts before the beginning, and the total is the last thing to end — a total
    /// that did not cover every phase would cut one off mid-way.
    @Test @MainActor func everyPhaseFitsInsideTheTotal() {
        for transition in [NotchTransition.standard, .reduced] {
            for phase in [transition.backdrop, transition.shape, transition.reveal] {
                #expect(phase.start >= 0)
                #expect(phase.duration >= 0)
                #expect(phase.end <= transition.total + 0.0001)
            }
        }
    }

    /// **Reduce Motion removes the travelling shape rather than shortening it.** An animation
    /// that crosses 918 points is exactly what that setting exists to prevent, and halving it
    /// is not honouring it.
    @Test @MainActor func reduceMotionLeavesACrossFadeAndNoShape() {
        #expect(!NotchTransition.reduced.drawsShape)
        #expect(NotchTransition.standard.drawsShape)
        #expect(NotchTransition.reduced.total < NotchTransition.standard.total / 2)
        #expect(NotchTransition.chosen(reduceMotion: true) == .reduced)
        #expect(NotchTransition.chosen(reduceMotion: false) == .standard)
    }

    /// A phase asked about a moment outside itself has an answer, and it is not a number beyond
    /// its own range — the view multiplies opacities by these.
    @Test @MainActor func aPhaseClampsAtBothEnds() {
        let phase = NotchTransition.Phase(start: 0.2, duration: 0.4)
        // **Tolerance on the interpolated readings, equality only where the clamp is what
        // answers.** `(0.4 - 0.2) / 0.4` is 0.5000000000000001 in binary floating point and
        // `(0.6 - 0.2) / 0.4` is 0.9999999999999999 — this test failed twice on that
        // arithmetic rather than on the clamping it is about. A moment before the phase and a
        // moment far past it are exact, because those answers come from the clamp itself.
        #expect(phase.progress(at: 0) == 0)
        #expect(phase.progress(at: 0.1) == 0)
        #expect(abs(phase.progress(at: 0.4) - 0.5) < 1e-9)
        #expect(abs(phase.progress(at: 0.6) - 1) < 1e-9)
        #expect(phase.progress(at: 99) == 1)
    }

    /// A zero-length phase — which is what Reduce Motion's shape is — must not divide by its own
    /// duration. It is over the moment it starts.
    @Test @MainActor func aPhaseWithNoDurationIsOverWhenItStarts() {
        let instant = NotchTransition.Phase(start: 0.3, duration: 0)
        #expect(instant.progress(at: 0.29) == 0)
        #expect(instant.progress(at: 0.3) == 1)
    }
}
