import CoreGraphics
import Foundation
import Geometry
// `@unsafe`, as `CaptureSource.swift` marks the same import: ScreenCaptureKit is a C-backed
// framework the strict-memory-safety gate cannot see into, and the mark is the acknowledgement
// rather than an exemption.
@unsafe @preconcurrency import ScreenCaptureKit

/// A window a person could point at, described without reading anything private about it.
///
/// **The application's name, never the window's title.** A picker can show both — the
/// card reads "Spotify" over "Spotify Premium". The second line is the window title, and a
/// window title carries whatever is open in it: a document name, a customer's name, a URL with a
/// token in it. `ObservationLog`'s rule is that this app does not read ambient user content, and
/// `noAppSourceReadsUserContent` names `SCWindow.title` as a gap its scan cannot catch
/// textually — a gap is a place to be careful, not a permission. The app name and the size
/// answer "which window is this", which is what a picker is for.
public struct WindowTarget: Sendable, Identifiable, Hashable {
    public let id: CGWindowID
    public let applicationName: String
    public let bundleIdentifier: String?
    /// Where it is, in global points with a top-left origin — `CGDisplayBounds`' space.
    public let frame: PointRect

    public init(id: CGWindowID, applicationName: String, bundleIdentifier: String?,
                frame: PointRect) {
        self.id = id
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.frame = frame
    }

    /// The size a person reads on the card, in points.
    public var sizeDescription: String {
        "\(Int(frame.width.rounded()))\u{00D7}\(Int(frame.height.rounded()))"
    }
}

/// The windows and displays this app can offer to record, and the `CaptureSource` for one.
public enum WindowTargets {
    /// Every ordinary window on screen, front to back.
    ///
    /// **Layer zero only, and this process excluded.** A window at a non-zero layer is a panel,
    /// a menu, or the Dock — things a person does not mean by "record that window" — and
    /// offering this app's own floating bar as a target would be offering to record the
    /// controls. `onScreenWindowsOnly` drops the minimised ones, which cannot be recorded at all.
    ///
    /// **Ordered as ScreenCaptureKit returns them**, which is front to back. A hit test wants
    /// the topmost window under the pointer, so the first match in this order is the answer —
    /// sorting by area or by name would put the wrong one under the cursor.
    public static func onScreen() async -> [WindowTarget] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true) else { return [] }
        let pid = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { window -> WindowTarget? in
            guard window.windowLayer == 0,
                  let application = window.owningApplication,
                  application.processID != pid,
                  window.frame.width > 1, window.frame.height > 1 else { return nil }
            return WindowTarget(
                id: window.windowID,
                applicationName: application.applicationName,
                bundleIdentifier: application.bundleIdentifier,
                frame: CGGeometryBridge.pointRect(from: window.frame))
        }
    }

    /// The topmost target containing a point in global top-left points, or `nil`.
    public static func target(at x: Double, y: Double, in targets: [WindowTarget]) -> WindowTarget? {
        targets.first { target in
            x >= target.frame.x && x < target.frame.x + target.frame.width
                && y >= target.frame.y && y < target.frame.y + target.frame.height
        }
    }

    /// The `CaptureSource` for a chosen window.
    ///
    /// Re-queries rather than holding the `SCWindow` on `WindowTarget`: an `SCWindow` is not
    /// `Sendable` and carrying one through a view's state is exactly the boundary this project
    /// keeps. The window may also have closed between the pick and the click, and re-querying is
    /// how that becomes `nil` rather than a stale capture of a window that is gone.
    public static func source(for target: WindowTarget) async -> CaptureSource? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
                  true, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == target.id })
        else { return nil }
        // **`DisplayHost`, and this is where the rules disagreed.** This said it used
        // `CaptureSource`'s rule and did not: when the centre was on no display it took the
        // FIRST display, overlapping or not — a recording of a screen the window was not on.
        let rect = CGGeometryBridge.pointRect(from: window.frame)
        guard let index = DisplayHost.index(
                for: rect, among: content.displays.map { CGGeometryBridge.pointRect(from: $0.frame) })
        else { return nil }
        let display = content.displays[index]
        let scale = Self.scale(of: display)
        // **`SCWindow.frame` is GLOBAL; `WindowCapture.sourceRect` is DISPLAY-LOCAL.** This
        // handed the first straight into the second, which is harmless only on a display whose
        // origin is zero — elsewhere the recording is placed a whole display away and no cursor
        // is drawn at all. Rebased, not clipped: the buffer below is sized from the FULL window.
        // `docs/design/a-window-on-the-other-display.md` has the measurement.
        let bounds = CGGeometryBridge.pointRect(from: display.frame)
        let local = PointRect(x: rect.x - bounds.x, y: rect.y - bounds.y,
                              width: rect.width, height: rect.height)
        return .window(WindowCapture(
            window: window, display: display, sourceRect: local,
            // `RegionCapture.buffer`'s rule — floor to even, at least 2 — which the picker's
            // window path already used. This ROUNDED first, so a 100.8-point window at 2× was a
            // 202-pixel buffer here and 200 through the picker: one window, two sizes.
            bufferWidth: RegionCapture.buffer(for: rect, scale: scale).width,
            bufferHeight: RegionCapture.buffer(for: rect, scale: scale).height))
    }

    /// The displays a person could record, in the order the system reports them.
    ///
    /// **Kept beside the window targets on purpose.** Both are answers to "what can this
    /// recording point at", and a caller that had to ask two modules would be a caller that
    /// could get the display list from one and the crop from the other.

    public static func displays() async -> [SCDisplay] {
        (try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true))?
            .displays ?? []
    }

    /// A display's backing scale, from its mode. `2` when it cannot be read, which is what every
    /// Mac made this decade reports and the safer guess for a buffer size.
    static func scale(of display: SCDisplay) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(display.displayID), mode.width > 0 else {
            return 2
        }
        return Double(mode.pixelWidth) / Double(mode.width)
    }
}

/// A rectangle of the screen a person dragged out, turned into something recordable.
///
/// **Separate from `WindowTargets` because the question is different.** That one asks "which
/// window is under this point"; this one is handed a rectangle and has to work out which display
/// owns it and where the rectangle sits inside that display's own space.
public enum RegionTargets {
    /// A global rectangle clamped into a display and rebased into that display's own space.
    ///
    /// **Clamped, because a drag can start on one display and end on another.** The part outside
    /// the owning display cannot be captured, and asking ScreenCaptureKit to crop outside its own
    /// bounds is asking for a frame it has no answer for.
    ///
    /// `nil` when nothing is left — a rectangle entirely on the other display, which is what a
    /// drag that crossed and came back looks like by the time it is measured.
    ///
    /// Separate from `source(for:)` so it can be tested: that one needs an `SCDisplay` no unit
    /// test can construct, and this is where the arithmetic lives.
    public nonisolated static func localRect(of rect: PointRect, inDisplay bounds: PointRect)
    -> PointRect? {
        let left = max(rect.x, bounds.x)
        let top = max(rect.y, bounds.y)
        let right = min(rect.x + rect.width, bounds.x + bounds.width)
        let bottom = min(rect.y + rect.height, bounds.y + bounds.height)
        guard right > left, bottom > top else { return nil }
        return PointRect(x: left - bounds.x, y: top - bounds.y,
                         width: right - left, height: bottom - top)
    }

    /// The `CaptureSource` for a region given in GLOBAL top-left points.
    ///
    /// **The display `DisplayHost` names** — the region's centre, then any display it overlaps —
    /// the same rule as a window's and for the same reason: a rectangle straddling two displays
    /// belongs to one of them, and the centre is the only answer that does not depend on which
    /// edge is asked about.
    ///
    /// Returns `nil` when no display owns it — a rectangle from a monitor unplugged between the
    /// drag and the click, which is a real gap between two user actions.
    public static func source(for rect: PointRect) async -> CaptureSource? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
                  true, onScreenWindowsOnly: true) else { return nil }
        // `DisplayHost` — which adds the overlap fallback this lacked: a region whose centre
        // fell in the gap under a shorter display was refused, though it overlapped one.
        guard let index = DisplayHost.index(
                for: rect, among: content.displays.map { CGGeometryBridge.pointRect(from: $0.frame) })
        else { return nil }
        let display = content.displays[index]
        let bounds = CGGeometryBridge.pointRect(from: display.frame)
        guard let local = localRect(of: rect, inDisplay: bounds) else { return nil }
        let scale = WindowTargets.scale(of: display)
        let buffer = RegionCapture.buffer(for: local, scale: scale)
        return .region(RegionCapture(display: display, sourceRect: local,
                                     bufferWidth: buffer.width, bufferHeight: buffer.height))
    }
}
