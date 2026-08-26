import Foundation
import Geometry
import Testing
import Timeline
@testable import Render

/// `CursorLoop`'s two functions, and the one promise the feature makes: at the last instant the
/// cursor is EXACTLY where it began.
@Suite struct CursorLoopTests {
    private let second: Int64 = 1_000_000_000
    /// 60 fps, what every export in this app asks for.
    private let frame = 1.0 / 60

    private func progress(_ offsetNanos: Int64, of durationNanos: Int64) -> Double? {
        CursorLoop.progress(outputOffset: Nanoseconds(offsetNanos),
                            outputDuration: Nanoseconds(durationNanos), frameDuration: frame)
    }

    // MARK: - progress

    /// The glide ends at the last FRAME, D − Δ, and starts one lead before that.
    private func leadStartNanos(of durationNanos: Int64) -> Int64 {
        durationNanos - Int64(frame * 1e9) - Int64(CursorLoop.leadSeconds * 1e9)
    }

    @Test func thereIsNoGlideUntilTheLeadBegins() {
        let duration = 10 * second
        #expect(progress(0, of: duration) == nil)
        #expect(progress(5 * second, of: duration) == nil)
        // A millisecond before the lead: still nothing. (A nanosecond would be inside the
        // rounding the half-frame window exists to absorb at the OTHER end; the claim here is
        // that the glide has a start, not where it is to the nanosecond.)
        #expect(progress(leadStartNanos(of: duration) - 1_000_000, of: duration) == nil)
    }

    /// **One at the last frame, not at the end instant.** The frame at D does not exist; the one
    /// at D − Δ does, and it is the one that has to match the first.
    @Test func progressRunsFromZeroAtTheLeadToOneAtTheLastFrame() throws {
        let duration = 10 * second
        let lastFrame = duration - Int64(frame * 1e9)
        // Within a nanosecond's rounding of 0, not exactly 0: `leadStartNanos` truncates
        // `frame × 1e9` to an integer and the function does not, so the two disagree by two
        // thirds of a nanosecond. Exactness matters at the HOME end, where a residual is a
        // visible jump, and that end is pinned to `== 1` below.
        #expect(abs(try #require(progress(leadStartNanos(of: duration), of: duration))) < 1e-8)
        #expect(try #require(progress(lastFrame, of: duration)) == 1)
        // And the end instant itself, which no frame occupies, is also fully home — a request
        // there must not glide BACK away from it.
        #expect(try #require(progress(duration, of: duration)) == 1)
        let midway = leadStartNanos(of: duration) + Int64(CursorLoop.leadSeconds * 0.5e9)
        #expect(abs(try #require(progress(midway, of: duration)) - 0.5) < 1e-9)
    }

    /// The offset arrives from a `CMTime` and disagrees with D − Δ at the tenth decimal. Anything
    /// within half a frame of the last frame is fully home, so that disagreement cannot leave a
    /// residual — a residual is the one-pixel jump the feature exists to remove.
    @Test func withinHalfAFrameOfTheLastFrameIsExactlyHome() throws {
        let duration = 10 * second
        let lastFrame = duration - Int64(frame * 1e9)
        let quarterFrameEarly = lastFrame - Int64(frame * 0.25e9)
        #expect(try #require(progress(quarterFrameEarly, of: duration)) == 1)
        // But a full frame early is still gliding.
        let frameEarly = lastFrame - Int64(frame * 1e9)
        #expect(try #require(progress(frameEarly, of: duration)) < 1)
    }

    /// A one-second clip must not spend most of itself gliding home. The lead is capped at half
    /// the video, which is `TextItem.animationState`'s rule for the same reason.
    @Test func theLeadIsCappedAtHalfTheVideo() throws {
        let short = second
        let lastFrame = short - Int64(frame * 1e9)
        // Half of the last frame's offset is less than the 0.8 s lead, so the glide begins there.
        let glideStart = lastFrame - lastFrame / 2
        #expect(progress(glideStart - 1_000_000, of: short) == nil)
        #expect(abs(try #require(progress(glideStart, of: short))) < 1e-9)
    }

    /// A zero-length output has nothing to loop across, and dividing by it would be a `NaN`
    /// progress — which reads as "no glide" by accident rather than by decision. A one-frame
    /// output has no last frame distinct from its first, and is refused for the same reason.
    @Test func aZeroOrOneFrameOutputHasNoGlide() {
        #expect(progress(0, of: 0) == nil)
        #expect(progress(0, of: Int64(frame * 1e9)) == nil)
        #expect(CursorLoop.progress(outputOffset: Nanoseconds(0), outputDuration: Nanoseconds(second),
                                    frameDuration: 0) == nil)
    }

    /// Past the end — a request AVFoundation should not make but a clamp costs nothing — is
    /// still fully home, not past it.
    @Test func progressPastTheEndIsClampedToOne() throws {
        #expect(try #require(progress(3 * second, of: 2 * second)) == 1)
    }

    // MARK: - position

    private let actual = NormalizedPoint(x: 0.8, y: 0.2)
    private let home = NormalizedPoint(x: 0.1, y: 0.9)

    /// **The promise.** Exactly, not within a tolerance: a smoothstep is precisely 1 at 1, so
    /// the lerp collapses to `home` with no residual, and a residual is a one-pixel jump at the
    /// seam — the thing this exists to remove.
    @Test func atFullProgressTheCursorIsExactlyHome() {
        let there = CursorLoop.position(actual: actual, home: home, progress: 1)
        #expect(there.x == home.x && there.y == home.y)
    }

    @Test func atZeroProgressTheCursorIsExactlyWhereItWas() {
        let still = CursorLoop.position(actual: actual, home: home, progress: 0)
        #expect(still.x == actual.x && still.y == actual.y)
    }

    /// Ease-in-out: slower than linear at both ends, faster in the middle. A glide that started
    /// at full speed would kink the cursor's path where it took over from the spring.
    @Test func theGlideEasesInAndOutRatherThanRunningLinearly() {
        let quarter = CursorLoop.position(actual: actual, home: home, progress: 0.25)
        let linearQuarter = actual.x + (home.x - actual.x) * 0.25
        // Eased in: at a quarter of the way it has covered LESS than a quarter of the distance.
        #expect(abs(quarter.x - actual.x) < abs(linearQuarter - actual.x))
        let midpoint = CursorLoop.position(actual: actual, home: home, progress: 0.5)
        #expect(abs(midpoint.x - (actual.x + home.x) / 2) < 1e-9, "symmetric about the middle")
    }

    @Test func progressOutsideZeroToOneIsClamped() {
        let over = CursorLoop.position(actual: actual, home: home, progress: 7)
        let under = CursorLoop.position(actual: actual, home: home, progress: -7)
        #expect(over.x == home.x && over.y == home.y)
        #expect(under.x == actual.x && under.y == actual.y)
    }

    // MARK: - the style

    /// A project saved before the option existed opens with it off, which is what those
    /// projects looked like. The same absence rule every other `CursorStyle` field follows.
    @Test func aStyleSavedBeforeTheLoopExistedDecodesWithItOff() throws {
        let decoded = try JSONDecoder().decode(CursorStyle.self, from: Data("{}".utf8))
        #expect(decoded.loopsToStart == false)
        let on = CursorStyle.default.changing(loopsToStart: true)
        let round = try JSONDecoder().decode(CursorStyle.self, from: JSONEncoder().encode(on))
        #expect(round.loopsToStart == true)
    }
}
