import AppKit
import Capture
import Geometry
import Render
import SwiftUI
import Timeline

/// The countdown's daruma flying to where the take is shown: from where it counted, along a hop,
/// to the notch's live mark, shrinking to the mark's size and fading as it lands, so the notch's
/// own takes over. One character from the count to the take.
/// `docs/design/2026-10-27-the-daruma-tips-flies-and-paints.md`.
///
/// Places are top-left points in the flight's window. Pure, so the arc is a test.
struct CountdownFlight {
    typealias Place = (x: Double, y: Double)
    let from: Place, to: Place, endScale: Double

    static let duration = 0.55

    /// Seconds since take-off as 0 … 1, eased in and out.
    static func progress(elapsed: Double) -> Double {
        let t = min(1, max(0, elapsed / duration))
        return t * t * (3 - 2 * t)
    }

    /// Where it is, how large and how visible, `p` of the way: a quadratic arc whose control
    /// point is above the higher end, so it hops rather than slides; fading over the last fifth.
    func frame(at p: Double) -> (x: Double, y: Double, scale: Double, opacity: Double) {
        let control: Place = (from.x + (to.x - from.x) * 0.3, min(from.y, to.y) - 30)
        let a = (1 - p) * (1 - p), b = 2 * (1 - p) * p, c = p * p
        return (a * from.x + b * control.x + c * to.x,
                a * from.y + b * control.y + c * to.y,
                1 + (endScale - 1) * p,
                p < 0.8 ? 1 : max(0, (1 - p) / 0.2))
    }
}

/// Shows one flight in a window over the screen, above everything and through to the clicks,
/// then takes it down. Soredemo's windows are excluded from every capture (`CaptureSource.filter`),
/// so the flight runs beside the start of the take and is never in it.
@MainActor
enum CountdownFlightPresenter {
    /// `from` and `to` are global screen points, y up; `to` is `nil` when nothing on screen shows
    /// the take — then it rises to the top of the screen and fades.
    static func fly(from: (x: Double, y: Double), to: (x: Double, y: Double)?, on screen: NSScreen, size: Double, endScale: Double) {
        let frame = CGGeometryBridge.pointRect(from: screen.frame)
        func local(_ p: (x: Double, y: Double)) -> CountdownFlight.Place { (p.x - frame.x, frame.y + frame.height - p.y) }
        let landing = to ?? (from.x, frame.y + frame.height - 6)
        let flight = CountdownFlight(from: local(from), to: local(landing), endScale: endScale)

        let panel = NSPanel(contentRect: CGGeometryBridge.rect(from: frame), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // `isFloatingPanel` before `level`, which it overwrites (`CountdownPresenter.show`).
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: FlightView(flight: flight, size: size, began: Minting.continuousNow()))
        panel.setFrame(CGGeometryBridge.rect(from: frame), display: true)
        panel.orderFrontRegardless()
        Task {
            try? await Task.sleep(for: .seconds(CountdownFlight.duration + 0.05))
            panel.orderOut(nil)
        }
    }
}

private struct FlightView: View {
    let flight: CountdownFlight
    let size: Double
    let began: Nanoseconds

    var body: some View {
        TimelineView(.animation) { _ in
            let p = CountdownFlight.progress(elapsed: Double((Minting.continuousNow() - began).rawValue) / 1_000_000_000)
            let at = flight.frame(at: p)
            LivingDaruma(pose: pose, rimmed: true)
                .environment(\.colorScheme, .light)
                .shadow(color: .black.opacity(0.45), radius: 26)
                .frame(width: size, height: size)
                .scaleEffect(at.scale)
                .opacity(at.opacity)
                .position(x: at.x, y: at.y)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// As the count left it — eye painted, ring closed — looking up, toward where it is going.
    private var pose: DarumaPose {
        var pose = DarumaPose.counting(remaining: 1, ringRemaining: 0)
        (pose.yaw, pose.pitch) = (flight.to.x < flight.from.x ? -0.6 : 0.6, -0.7)
        return pose
    }
}
