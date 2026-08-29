import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Render

/// The press curve, and the track edge it reads. Both references that draw their own cursor move
/// it on click — a scale modifier applied while the button is down, or a
/// `cursorClickBounce` — and this app drew a ring beside an inert arrow.
@Suite struct CursorPressTests {
    private let epoch = BootEpoch(id: UUID(uuidString: "3C7A1E90-55B2-4D6F-9A08-11FE2D3C4B5A")!)
    private let revision = GeometryRevision(id: 3)

    private func instant(_ seconds: Double) -> HostInstant {
        HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64(seconds * 1e9)))
    }

    private func click(_ seconds: Double, _ phase: ButtonPhase) -> ButtonEvent {
        ButtonEvent(instant: instant(seconds), position: NormalizedPoint(x: 0.5, y: 0.5),
                    revision: revision, button: .left, phase: phase)
    }

    // MARK: - the curve

    @Test func nothingPressedIsFullSize() {
        #expect(CursorPress.scale(sincePress: nil, sinceRelease: nil) == 1)
        #expect(CursorPress.scale(sincePress: nil, sinceRelease: 0.05) == 1)
    }

    /// At the instant of contact the cursor is still full size; it arrives at the pressed size
    /// over `pressSeconds`. A step would read as the art being swapped rather than pressed.
    @Test func thePressShrinksOverItsOwnDurationRatherThanSnapping() {
        #expect(CursorPress.scale(sincePress: 0, sinceRelease: nil) == 1)
        let quarter = CursorPress.scale(sincePress: CursorPress.pressSeconds * 0.25,
                                        sinceRelease: nil)
        #expect(quarter < 1 && quarter > CursorPress.pressedScale)
        #expect(CursorPress.scale(sincePress: CursorPress.pressSeconds, sinceRelease: nil)
                == CursorPress.pressedScale)
    }

    /// **Held, not timed out.** A drag holds the button for as long as it lasts, and a curve
    /// that sprang back on its own would inflate the cursor in the middle of one.
    @Test func aHeldButtonStaysPressedHoweverLongItIsHeld() {
        #expect(CursorPress.scale(sincePress: 5, sinceRelease: nil) == CursorPress.pressedScale)
        // A release OLDER than the press is a previous click; the button is still down.
        #expect(CursorPress.scale(sincePress: 5, sinceRelease: 9) == CursorPress.pressedScale)
    }

    @Test func theReleaseSpringsBackAndSettlesAtExactlyOne() {
        // Just released: still near the pressed size.
        let early = CursorPress.scale(sincePress: 1, sinceRelease: 0.001)
        #expect(abs(early - CursorPress.pressedScale) < 0.02)
        // Past the spring: exactly 1, not a hair off it forever.
        #expect(CursorPress.scale(sincePress: 1, sinceRelease: CursorPress.releaseSeconds) == 1)
        // **The release must be MORE RECENT than the press to count as released.** A first
        // draft wrote `sincePress: 1, sinceRelease: 5` here meaning "released ages ago" — which
        // is the opposite: pressed one second ago and released five seconds ago is a button
        // still held, and the curve was right to say so.
        #expect(CursorPress.scale(sincePress: 6, sinceRelease: 5) == 1)
    }

    /// A small overshoot on the way back. Coming to 1 without passing it reads as the cursor
    /// inflating; 4% reads as a release. `TextAnimation.pop` makes the same argument.
    @Test func theSpringOvershootsSlightlyRatherThanEasingFlatlyToOne() {
        let peak = stride(from: 0.0, to: CursorPress.releaseSeconds, by: 0.005)
            .map { CursorPress.scale(sincePress: 1, sinceRelease: $0) }
            .max() ?? 0
        #expect(peak > 1, "the spring never passes 1, so the release reads as an inflation")
        #expect(peak < 1.06, "the overshoot is \(peak), which is a bounce rather than a release")
    }

    /// A negative elapsed time is a frame before the edge it is measured from — which a
    /// caller can produce at the very start of a composition — and must not be extrapolated
    /// into a scale nobody asked for.
    @Test func anEdgeInTheFutureLeavesTheCursorAlone() {
        #expect(CursorPress.scale(sincePress: -0.1, sinceRelease: nil) == 1)
    }

    // MARK: - the track edge

    /// **The release edge is why `ClickTrack` keeps `.up` events**, which it used to discard.
    /// Without them a hold cannot be told from a click that is over.
    @Test func theTrackHoldsThePressUntilTheButtonComesUp() {
        let track = ClickTrack(events: [click(1, .down), click(3, .up)])
        #expect(track.pressScale(at: instant(1.5)) == CursorPress.pressedScale)
        #expect(track.pressScale(at: instant(2.9)) == CursorPress.pressedScale)
        // After the release plus the spring, back to full size.
        #expect(track.pressScale(at: instant(3 + CursorPress.releaseSeconds + 0.1)) == 1)
    }

    @Test func beforeAnyClickTheCursorIsFullSize() {
        let track = ClickTrack(events: [click(2, .down), click(2.1, .up)])
        #expect(track.pressScale(at: instant(1)) == 1)
    }

    /// A click from another boot session's overlapping host times must not press this one's
    /// cursor — `ripplePhase`'s rule, applied to the same edges.
    @Test func aClickFromAnotherBootSessionDoesNotPressThisOne() {
        let other = BootEpoch(id: UUID(uuidString: "9F8E7D6C-5B4A-4392-8271-60514F3E2D1C")!)
        let stranger = ButtonEvent(instant: HostInstant(epoch: other,
                                                        hostTime: Nanoseconds(Int64(1e9))),
                                   position: NormalizedPoint(x: 0.5, y: 0.5), revision: revision,
                                   button: .left, phase: .down)
        let track = ClickTrack(events: [stranger])
        #expect(track.pressScale(at: instant(1.5)) == 1)
    }

    /// The ripple still starts on the press and ignores the release, which is what its own
    /// header argues for. Keeping the `.up` events did not change that question's answer.
    @Test func keepingTheReleaseEdgeDidNotChangeTheRipple() throws {
        let track = ClickTrack(events: [click(1, .down), click(1.05, .up)])
        let phase = try #require(track.ripplePhase(at: instant(1.2)))
        #expect(phase > 0 && phase < 1)
        // Past the ripple's own duration, gone — measured from the DOWN edge, not the up one.
        let after = Double(ClickTrack.rippleDuration.rawValue) / 1e9
        #expect(track.ripplePhase(at: instant(1 + after)) == nil)
    }

    // MARK: - the plan

    @Test func aPlacementClampsAPressItCouldNotDraw() {
        let vanishing = NormalizedPointerPlacement(x: 0, y: 0, ripplePhase: nil, pressScale: 0)
        #expect(vanishing.pressScale >= 0.2, """
            a zero press draws nothing, which reads as the cursor disappearing on click
            """)
        let corrupt = NormalizedPointerPlacement(x: 0, y: 0, ripplePhase: nil, pressScale: .nan)
        #expect(corrupt.pressScale == 1)
    }

    @Test func aPlacementWithoutAPressIsFullSize() {
        #expect(NormalizedPointerPlacement(x: 0, y: 0, ripplePhase: nil).pressScale == 1)
    }
}
