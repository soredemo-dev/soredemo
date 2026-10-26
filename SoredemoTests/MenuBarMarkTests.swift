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

    /// **The menu bar's daruma is the character, drawn** — the panel's figure at 18 points, not
    /// an image baked by a script. Ink only while nothing records, so the system tints it; the
    /// record eye red while a take runs; the countdown's ring red round that eye, and no red at
    /// all once the ring is spent. Measured in the pixels: red, and on which side of the mark.
    @Test func theMenuBarDarumaIsInkUntilItRecords() throws {
        func redPixels(_ image: NSImage) throws -> (count: Int, meanX: Double) {
            let side = 72
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            var count = 0, sumX = 0.0, ink = 0
            for y in 0..<side { for x in 0..<side {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                ink += 1
                if c.redComponent > 0.75, c.greenComponent < 0.45 { count += 1; sumX += Double(x) }
            } }
            try #require(ink > 50, "the mark drew no ink")
            return (count, count > 0 ? sumX / Double(count) / Double(side) : 0)
        }
        for state in [MenuBarMark.idle, .paused, .finished] {
            let image = DarumaMark.image(for: state)
            #expect(image.isTemplate, "\(state) should be tinted by the system")
            #expect(try redPixels(image).count == 0, "\(state) drew red")
        }
        let recording = try redPixels(DarumaMark.image(for: .recording))
        #expect(recording.count > 4 && recording.meanX > 0.5, "the record eye is red and on the right: \(recording)")
        #expect(!DarumaMark.image(for: .recording).isTemplate)
        #expect(try redPixels(DarumaMark.image(for: .countingDown(ring: 0.6))).count > 4, "the ring is red")
        #expect(try redPixels(DarumaMark.image(for: .countingDown(ring: 0))).count == 0, "a spent ring draws nothing")
    }
}
