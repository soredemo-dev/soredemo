import AppKit
import Observation
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

/// Where the menu bar mark's parts are on its canvas: the small mark's numbers, in the website's
/// 100-unit box, with the body filling 88 % of the canvas's height — what
/// `scripts/make-daruma-marks.swift` bakes into the images. Two places hold one geometry, so
/// `MenuBarMarkTests` measures the baked eye and compares it with `point`.
enum MenuBarMarkGeometry {
    static let inkShare = 0.88
    static let eyeX = 62.0
    static let eyeY = 47.0
    /// The countdown ring: five units outside the eye's radius of 9, as the website draws it.
    static let ringRadius = 14.0
    static let ringWidth = 3.0

    /// Units to points on a `side`-point canvas: the body is 84 units tall.
    static func scale(side: Double) -> Double { side * inkShare / 84 }

    /// A point in the 100-unit box on a `side`-point canvas, y down, the box's centre at the
    /// canvas's centre.
    static func point(x: Double, y: Double, side: Double) -> NSPoint {
        let scale = scale(side: side)
        return NSPoint(x: side / 2 + (x - 50) * scale, y: side / 2 + (y - 50) * scale)
    }
}

/// The counting-down mark: the body in the menu bar's ink, the eye faint in the record red, and a
/// red ring draining round it — the countdown panel's ring at menu bar size.
///
/// Drawn rather than baked, for the reason `RecordingMark` is: a template image cannot carry
/// red. The ring is a new image per tenth, which is what makes the label redraw.
enum CountdownMark {
    static func image(ring: Double) -> NSImage {
        let body = NSImage(named: "LogomarkRecordingBody")
        let eye = NSImage(named: "LogomarkCountdownEye")
        let size = body?.size ?? NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: true) { rect in
            guard let body, let eye else { return false }
            body.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            eye.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: true, hints: nil)
            // An empty arc with round caps would still draw a dot.
            guard ring > 0 else { return true }
            let side = Double(rect.width)
            let centre = MenuBarMarkGeometry.point(x: MenuBarMarkGeometry.eyeX,
                                                   y: MenuBarMarkGeometry.eyeY, side: side)
            let arc = NSBezierPath()
            // From twelve o'clock, clockwise: in a flipped canvas that is increasing angle.
            arc.appendArc(withCenter: centre,
                          radius: MenuBarMarkGeometry.ringRadius * MenuBarMarkGeometry.scale(side: side),
                          startAngle: -90, endAngle: -90 + 360 * ring, clockwise: false)
            arc.lineWidth = MenuBarMarkGeometry.ringWidth * MenuBarMarkGeometry.scale(side: side)
            arc.lineCapStyle = .round
            NSColor(Signal.record).setStroke()
            arc.stroke()
            return true
        }
    }
}
