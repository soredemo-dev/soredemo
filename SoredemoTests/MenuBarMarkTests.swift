import AppKit
import Testing
@testable import Soredemo

/// The menu bar's daruma: which state it shows, the countdown's ring, the eye painted when a take
/// finishes, and the ring drawn where the script drew the eye.
/// `docs/design/2026-10-25-the-menu-bar-counts-down-and-paints-the-eye.md`.
@MainActor @Suite(.serialized) struct MenuBarMarkTests {
    /// A count in its second second, three tenths in — not at a whole second, where the ring is
    /// full whatever the tenths say.
    private func counting(tenthsGone: Int = 3) -> CountdownState {
        let state = CountdownState(total: 3, subject: "Keynote")
        state.remaining = 2
        state.tenthsGone = tenthsGone
        return state
    }

    private func mark(_ countdown: CountdownState? = nil, starting: Bool = false,
                      recording: Bool = false, paused: Bool = false,
                      finished: Bool = false) -> MenuBarMark {
        MenuBarMark.state(countdown: countdown, isStarting: starting, isRecording: recording,
                          isPaused: paused, isFinished: finished)
    }

    @Test func eachStateComesFromItsOwnInput() {
        #expect(mark() == .idle)
        #expect(mark(counting()) == .countingDown(ring: 0.7))
        #expect(mark(recording: true) == .recording)
        #expect(mark(recording: true, paused: true) == .paused)
        #expect(mark(finished: true) == .finished)
    }

    /// Recording and paused outrank everything; the countdown outranks the painted eye, because
    /// a count that has started is the next take.
    @Test func theStatesOutrankEachOtherInOneOrder() {
        #expect(mark(counting(), recording: true, finished: true) == .recording)
        #expect(mark(counting(), recording: true, paused: true, finished: true) == .paused)
        #expect(mark(counting(), finished: true) == .countingDown(ring: 0.7))
    }

    /// **The count has ended and the capture has not started yet** — `newSession.start()` is
    /// awaited between them. Looked at on 2026-10-25, the item fell back to idle for that moment,
    /// a flash of the resting mark in the middle of starting. It holds the count's last frame: the
    /// faint eye, the ring run out.
    @Test func betweenTheCountAndTheCaptureTheCountHoldsItsLastFrame() {
        #expect(mark(starting: true) == .countingDown(ring: 0))
        #expect(mark(starting: true, finished: true) == .countingDown(ring: 0))
        #expect(mark(starting: true, recording: true) == .recording)
    }

    /// ⎋ ends the count before the presenter lets go of it; the mark goes back at once.
    @Test func aCancelledCountShowsNoCount() {
        let cancelled = counting()
        cancelled.isCancelled = true
        #expect(mark(cancelled) == .idle)
    }

    @Test func theRingDrainsInTenthsWithinEachSecond() {
        #expect(counting(tenthsGone: 0).ringRemaining == 1)
        #expect(counting(tenthsGone: 7).ringRemaining == 0.3)
        #expect(counting(tenthsGone: 9).ringRemaining == 0.1)
    }

    @Test func theEyeIsPaintedAndWipedAfterItsDuration() async throws {
        let eye = PaintedEye()
        eye.paint(for: .milliseconds(40))
        #expect(eye.isPainted)
        for _ in 0..<100 where eye.isPainted { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!eye.isPainted, "still painted two seconds after a 40 ms paint")
    }

    /// Waits for the first timer to have FINISHED before looking, so this cannot pass by looking
    /// too early — a race the main actor's other work would otherwise decide.
    @Test func anEarlierTimerDoesNotWipeALaterPaint() async throws {
        let eye = PaintedEye()
        eye.paint(for: .milliseconds(30))
        eye.paint(for: .seconds(30))
        for _ in 0..<100 where eye.timersFinished < 1 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(eye.timersFinished >= 1, "the first timer never finished")
        #expect(eye.isPainted, "the first paint's timer wiped the second paint")
    }

    /// **Two places hold one geometry**: the script baked the eye into `LogomarkCountdownEye`, and
    /// the code draws the ring around where it thinks the eye is. The centre of the asset's ink is
    /// measured and compared — at a canvas size that is not the asset's own, so the scaling is in
    /// the comparison.
    @Test func theRingIsDrawnRoundTheEyeTheScriptBaked() throws {
        let asset = try #require(NSImage(named: "LogomarkCountdownEye"))
        let side = 72
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        asset.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var weight = 0.0, sumX = 0.0, sumY = 0.0
        for y in 0..<side {
            for x in 0..<side {
                let alpha = Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                weight += alpha
                sumX += alpha * (Double(x) + 0.5)
                sumY += alpha * (Double(y) + 0.5)
            }
        }
        try #require(weight > 10, "the asset drew no ink: \(weight)")
        let eye = MenuBarMarkGeometry.point(x: MenuBarMarkGeometry.eyeX, y: MenuBarMarkGeometry.eyeY,
                                            side: Double(side))
        #expect(abs(sumX / weight - eye.x) < 0.5, "ink centre x \(sumX / weight), code's eye x \(eye.x)")
        #expect(abs(sumY / weight - eye.y) < 0.5, "ink centre y \(sumY / weight), code's eye y \(eye.y)")
    }
}
