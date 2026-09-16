import Foundation
import Geometry

/// Whether a point on screen is over one of THIS app's own windows.
///
/// **The defect it closes.** `LiveAXElementSource.hitTest` asks the system-wide accessibility
/// element what is under the pointer, from `video.soredemo.ax-observation` — a background queue,
/// deliberately, so a slow app cannot stall the event tap. When the thing under the pointer
/// belongs to ANOTHER process that is an IPC and costs this app nothing. When it belongs to
/// **this** one, the request is served in-process, on that same background thread, and AppKit's
/// accessibility server reads window geometry there. Recorded 2026-09-16 as
/// `NSInternalInconsistencyException: NSWindow geometry should only be modified on the main
/// thread!`, one line after `NSAccessibility Request Received`, and reported as "dragging the
/// recording bar while recording crashes" — which is exactly the moment the pointer is over one
/// of this app's own windows AND that window's frame is being written.
///
/// **Asked before the hit test, not after.** `AXUIElementGetPid` on the returned element answers
/// the same question too late: by then the call has already crossed into this process.
///
/// **Our own window IDs, never the machine's window list.** The first version of this asked
/// `CGWindowListCopyWindowInfo` for every on-screen window and compared owner PIDs.
/// `AppSourceAllowListTests.theScopedWindowLookupIsConfinedAndStaysScoped` refused it, and was
/// right to: that call enumerates every window on the machine and each entry carries
/// `kCGWindowName` — other people's window titles, which this app must never read. The rule
/// leaves one narrow opening, `CGGeometryBridge.windowBounds(_:)`, for ONE known window ID. So
/// the app publishes the IDs of its own windows and this asks only about those. It cannot see
/// anybody else's window either way, which is a better answer than the one the gate rejected.
public struct OwnWindowExclusion: Sendable {
    /// The app's own window IDs, as AppKit reports them. Published from the main actor; read
    /// from the observation queue.
    private let identifiers: [UInt32]
    /// How a window ID becomes a rectangle. Injected so the decision can be tested without a
    /// window server — `CGGeometryBridge.windowBounds` in production.
    private let bounds: @Sendable (UInt32) -> PointRect?

    public init(identifiers: [UInt32],
                bounds: @escaping @Sendable (UInt32) -> PointRect?) {
        self.identifiers = identifiers
        self.bounds = bounds
    }

    /// Nothing of ours is on screen, so nothing is excluded. The state before the app has
    /// published anything, and the one that must not accidentally exclude the whole screen.
    public static let nothing = OwnWindowExclusion(identifiers: [], bounds: { _ in nil })

    /// Whether the point is inside any of our own windows.
    ///
    /// **`false` when we own no windows and when the lookup refuses** — a refusal to answer is
    /// not a claim of ownership, and treating it as one would silently stop the observer
    /// recording clicks anywhere on screen, which is worse than the crash it prevents.
    ///
    /// Half-open on both axes, so a window's right and bottom edges belong to whatever is
    /// beyond them.
    public func contains(globalTopLeftX: Double, globalTopLeftY: Double) -> Bool {
        for identifier in identifiers {
            guard let rect = bounds(identifier), rect.width > 0, rect.height > 0 else { continue }
            if globalTopLeftX >= rect.x, globalTopLeftX < rect.x + rect.width,
               globalTopLeftY >= rect.y, globalTopLeftY < rect.y + rect.height {
                return true
            }
        }
        return false
    }
}
