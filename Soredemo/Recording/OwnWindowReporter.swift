import AppKit
import Capture

/// Tells the running capture which windows belong to this app.
///
/// **Why the app has to say, rather than the observer ask.** The observer runs its accessibility
/// hit test on a background queue, and a hit test that lands on one of this app's own windows is
/// served by this process on that queue — where AppKit reads window geometry off the main
/// thread, which is the `NSWindow geometry should only be modified on the main thread!` fault
/// behind "dragging the recording bar while recording crashes". It cannot find out for itself
/// without enumerating every window on the machine, and that call carries every window's title:
/// `AppSourceAllowListTests.theScopedWindowLookupIsConfinedAndStaysScoped` refuses it, correctly.
/// So the answer comes from here, where `NSApp.windows` is free and on the right thread.
///
/// **Window NUMBERS, not frames.** A frame goes stale the instant somebody drags, which is the
/// exact moment this matters; an id does not. `CGGeometryBridge.windowBounds` resolves each id
/// when the question is asked, from the observation queue, one known window at a time — the one
/// narrow opening the window-list ban leaves.
@MainActor
enum OwnWindowReporter {
    /// Every window this app currently has on screen, as `OwnWindowExclusion` wants it.
    ///
    /// Off-screen windows are included deliberately: `windowNumber` stays valid and
    /// `windowBounds` returns `nil` for one that is not on screen, so the extra ids cost a
    /// lookup that answers "not here" — which is cheaper than being wrong when a panel is
    /// ordered back in between two clicks.
    static func current() -> OwnWindowExclusion {
        let identifiers = NSApp.windows.map { UInt32(bitPattern: Int32($0.windowNumber)) }
        return OwnWindowExclusion(identifiers: identifiers) {
            CGGeometryBridge.windowBounds($0)
        }
    }
}
