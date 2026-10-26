import AppKit
import Capture
import Observation
import Render
import SwiftUI

/// What the menu bar's daruma shows, decided in one place from what the recording is doing.
///
/// The order between the states is the whole content of this type, so it is a function with a
/// test rather than an `if` chain in a view. See
/// `docs/design/2026-10-25-the-menu-bar-counts-down-and-paints-the-eye.md`.
enum MenuBarMark: Equatable {
    case idle
    /// `ring` is the share of the current second still to run, 1 down to 0.1.
    case countingDown(ring: Double)
    case recording
    case paused
    /// The second eye painted in: a recording has just finished.
    case finished

    /// Recording and paused outrank everything; a count that has started is the next take, so it
    /// outranks the eye still painted from the last one. `isStarting` is the moment after the count
    /// and before the capture runs, which holds the count's last frame rather than flashing idle.
    static func state(countdown: CountdownState?, isStarting: Bool, isRecording: Bool,
                      isPaused: Bool, isFinished: Bool) -> MenuBarMark {
        if isRecording { return isPaused ? .paused : .recording }
        if let countdown, !countdown.isCancelled { return .countingDown(ring: countdown.ringRemaining) }
        if isStarting { return .countingDown(ring: 0) }
        return isFinished ? .finished : .idle
    }
}

/// The second eye, painted when a take finishes and wiped 2.6 seconds later — 目入れ.
///
/// **Each paint owns its own wipe.** Painting again restarts the time, and the earlier timer,
/// still sleeping, must not wipe the later paint; the generation is how it knows it is stale.
@MainActor
@Observable
final class PaintedEye {
    nonisolated static let duration = Duration.milliseconds(2600)
    private(set) var isPainted = false
    /// How many wipes have come due, stale or not — what a test waits on instead of a guess at
    /// how long the main actor will take.
    private(set) var timersFinished = 0
    @ObservationIgnored private var generation = 0

    func paint(for duration: Duration = PaintedEye.duration) {
        generation += 1
        let mine = generation
        isPainted = true
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self else { return }
            if generation == mine { isPainted = false }
            timersFinished += 1
        }
    }
}

/// The menu bar's daruma: the character's figure at 18 points, drawn rather than baked, so the
/// menu bar and the panel cannot disagree about what it looks like.
///
/// **Ink only while nothing records**, as a template image the system tints for the bar it sits
/// on. **Recording and counting down carry red**, which a template image cannot, so those two are
/// drawn in the label colour, resolved when the item draws, with the record eye or the ring red.
/// Still in the menu bar: no blink, no breath — it is beside the clock, and moving there is noise.
enum DarumaMark {
    static let side = 18.0
    /// The body — 82 of the figure's units — takes 88% of the canvas, measured against the
    /// system's own symbols (2026-10-25).
    static let inkShare = 0.88

    static func pose(for state: MenuBarMark) -> DarumaPose {
        switch state {
        case .idle: .resting
        case .paused: DarumaPose(left: .pause, right: .pause)
        case .finished: DarumaPose(left: .happy, right: .happy)
        case .recording: DarumaPose(right: .record)
        case .countingDown(let ring): DarumaPose(countRing: ring)
        }
    }

    static func image(for state: MenuBarMark, faceWindow: Bool = true) -> NSImage {
        var pose = pose(for: state)
        pose.faceWindow = faceWindow
        let figure = DarumaFigure.make(pose)
        let unit = side * inkShare / 82
        // The body's middle (50, 52) at the canvas's middle.
        let mapping = DarumaView.Mapping(unit: unit, left: side / 2 - 50 * unit, top: side / 2 - 52 * unit)
        let isRecording = pose.right == .record
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let ink = DarumaView.templatePath(figure, mapping: mapping, omitting: isRecording ? 1 : nil, window: faceWindow)
            context.addPath(ink.cgPath)
            context.setFillColor((pose.countRing == nil && !isRecording ? NSColor.black : NSColor.labelColor).cgColor)
            context.fillPath(using: .evenOdd)
            let red = NSColor(Signal.record).cgColor
            let eye = figure.eyes[1]
            if isRecording {
                context.addPath(DarumaView.eyePath(eye, mapping).cgPath)
                context.setFillColor(red)
                context.fillPath()
            }
            if let ring = pose.countRing, ring > 0 {
                let radius = (max(eye.width, eye.height) / 2 + 3.6) * unit
                context.addPath(CGGeometryBridge.countdownArc(centreX: mapping.x(eye.x), centreY: mapping.y(eye.y),
                                                              radius: radius, remaining: ring))
                context.setStrokeColor(red)
                context.setLineWidth(3 * unit)
                context.setLineCap(.round)
                context.strokePath()
            }
            return true
        }
        image.isTemplate = pose.countRing == nil && !isRecording
        return image
    }
}
