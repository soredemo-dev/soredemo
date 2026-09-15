import AppKit

/// What the editor's window IS — its buttons, its Spaces behaviour, its floor size.
///
/// **One reason to change: what an editor window should look like.** It was part of a type that
/// also decided when to go full screen, when to grow a window back, and which observers to
/// register; a full-screen defect then took four attempts to find because the decision was
/// spread across three places and no one of them could state the order the others ran in.
///
/// **Everything here is idempotent**, because `WindowConfigurator.configure()` runs on every
/// SwiftUI update and SwiftUI re-asserts what it owns. Setting a style bit twice is setting it
/// once; that is the property that lets this be applied unconditionally while registration —
/// which is not idempotent — is guarded.
@MainActor
enum EditorWindowStyle {
    /// Below this the timeline has no length worth dragging.
    static let minimumSize = NSSize(width: 1000, height: 680)

    /// The collection behaviour an editor window should have.
    ///
    /// **Pure, and separated from the window so it can be tested without one.** The
    /// `moveToActiveSpace` rule is the whole reason this is a function rather than four lines
    /// in a row: it is not a constant, it depends on whether the window has already been full
    /// screen, and getting that wrong is invisible — AppKit refuses the transition in silence.
    ///
    /// See docs/design/full-screen-and-window-behaviour.md for the measurements.
    static func collectionBehavior(
        from current: NSWindow.CollectionBehavior,
        hasBeenFullScreen: Bool
    ) -> NSWindow.CollectionBehavior {
        var behavior = current
        // `.fullScreenNone` wins over `.fullScreenPrimary`, so it comes off first.
        behavior.remove(.fullScreenNone)
        behavior.insert(.fullScreenPrimary)
        if hasBeenFullScreen {
            // An ordinary window should follow the Space somebody is on — the reason it is
            // wanted at all, and meaningful again once full screen is behind it.
            behavior.insert(.moveToActiveSpace)
        } else {
            behavior.remove(.moveToActiveSpace)
        }
        return behavior
    }

    /// The style mask an editor window should have.
    ///
    /// `.miniaturizable` because a `Window` scene comes up without it and the middle traffic
    /// light is drawn and dead; `.resizable` because full screen requires it whatever the
    /// collection behaviour says.
    static func styleMask(from current: NSWindow.StyleMask) -> NSWindow.StyleMask {
        current.union([.miniaturizable, .resizable])
    }

    /// Applies all of it. The only part that touches AppKit.
    static func apply(to window: NSWindow, hasBeenFullScreen: Bool) {
        window.styleMask = styleMask(from: window.styleMask)
        window.collectionBehavior = collectionBehavior(from: window.collectionBehavior,
                                                       hasBeenFullScreen: hasBeenFullScreen)
        window.minSize = minimumSize
    }
}
