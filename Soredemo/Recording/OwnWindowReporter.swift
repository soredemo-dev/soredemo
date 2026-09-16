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
        OwnWindowExclusion(identifiers: identifiers(of: NSApp.windows.map(\.windowNumber))) {
            CGGeometryBridge.windowBounds($0)
        }
    }

    /// The window numbers that are `CGWindowID`s, with the ones that are not left out.
    ///
    /// **This crashed, and the safety argument for it had measured the wrong set.** The line was
    /// `UInt32(bitPattern: Int32(number))`, defended on window numbers topping out at 5162
    /// against an `Int32` limit of 2.1 billion — a figure taken from `CGWindowListCopyWindowInfo`,
    /// the windows on the SCREEN. What arrives here is `NSApp.windows`, a different population:
    /// it carries AppKit's `NSStatusBarWindow`, measured at **4294967296**, which is exactly
    /// `UInt32.max + 1`. `Int32(_:)` trapped on it on the first frame of every recording.
    ///
    /// **Dropped rather than converted.** Truncating turns that number into 0, and `bitPattern`
    /// turns a negative one — AppKit hands those out — into something near `UInt32.max`. Both
    /// produce a valid `CGWindowID` belonging to somebody else, and the exclusion would then read
    /// a stranger's window bounds and report a pointer inside it as over one of ours: clicks
    /// silently missing from the recording. A number that does not fit is not a window id. **The
    /// cost:** a real on-screen window numbered this way goes unexcluded and could crash the way
    /// this file exists to prevent — weighed against a wrong id, which is silent and permanent.
    static func identifiers(of windowNumbers: [Int]) -> [UInt32] {
        windowNumbers.compactMap(UInt32.init(exactly:))
    }
}
