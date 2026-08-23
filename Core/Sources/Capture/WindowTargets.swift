import CoreGraphics
import Foundation
import Geometry
// `@unsafe`, as `CaptureSource.swift` marks the same import: ScreenCaptureKit is a C-backed
// framework the strict-memory-safety gate cannot see into, and the mark is the acknowledgement
// rather than an exemption.
@unsafe @preconcurrency import ScreenCaptureKit

/// A window a person could point at, described without reading anything private about it.
///
/// **The application's name, never the window's title.** ScreenKite's picker shows both — its
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
        // The display whose bounds contain the window's CENTRE — `CaptureSource`'s own rule for
        // which display a window belongs to, stated in `init(pickerFilter:availableDisplays:)`.
        let centreX = Double(window.frame.midX)
        let centreY = Double(window.frame.midY)
        let display = content.displays.first { candidate in
            let bounds = CGGeometryBridge.pointRect(from: candidate.frame)
            return centreX >= bounds.x && centreX < bounds.x + bounds.width
                && centreY >= bounds.y && centreY < bounds.y + bounds.height
        } ?? content.displays.first
        guard let display else { return nil }
        let scale = Self.scale(of: display)
        let rect = CGGeometryBridge.pointRect(from: window.frame)
        return .window(WindowCapture(
            window: window, display: display, sourceRect: rect,
            bufferWidth: Self.evenFloor(Int((rect.width * scale).rounded())),
            bufferHeight: Self.evenFloor(Int((rect.height * scale).rounded()))))
    }

    /// The displays a person could record, in the order the system reports them.
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

    /// Even, because an odd buffer dimension is where a stray column of green comes from —
    /// the same rule `CaptureSource` applies to its own buffer sizes.
    static func evenFloor(_ value: Int) -> Int { max(2, value - (value % 2)) }
}
