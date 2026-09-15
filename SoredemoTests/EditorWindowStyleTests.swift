import AppKit
import Testing
@testable import Soredemo

/// What an editor window should be, decided without one.
///
/// **These are the tests the split made possible.** The same rules lived inside a notification
/// block against a live `NSWindow` until 2026-09-15, where nothing could reach them: a
/// full-screen defect took four attempts to find because the only way to ask what the code
/// decided was to open a window and look at it.
@Suite struct EditorWindowStyleTests {

    /// **The rule that silently broke full screen for a week.** `.moveToActiveSpace` asks for
    /// the opposite of full screen — one Space that follows you, against a Space of its own —
    /// and AppKit refuses the transition without reporting anything.
    @Test @MainActor func moveToActiveSpaceIsOffUntilTheWindowHasBeenFullScreen() {
        let behavior = EditorWindowStyle.collectionBehavior(from: [], hasBeenFullScreen: false)
        #expect(!behavior.contains(.moveToActiveSpace))
        #expect(behavior.contains(.fullScreenPrimary))
    }

    /// And back on afterwards, because the reason it is wanted survives: an editor opened from
    /// the menu bar should appear on the Space somebody is looking at.
    @Test @MainActor func moveToActiveSpaceReturnsOnceFullScreenHasHappened() {
        let behavior = EditorWindowStyle.collectionBehavior(from: [], hasBeenFullScreen: true)
        #expect(behavior.contains(.moveToActiveSpace))
        #expect(behavior.contains(.fullScreenPrimary))
    }

    /// **`.fullScreenNone` wins over `.fullScreenPrimary`**, so it has to come off rather than
    /// be out-voted. SwiftUI sets it from `.defaultSize`, which is why that modifier is absent
    /// from the scene — this is the second lock on the same door.
    @Test @MainActor func fullScreenNoneIsRemovedRatherThanOutvoted() {
        let behavior = EditorWindowStyle.collectionBehavior(from: [.fullScreenNone],
                                                            hasBeenFullScreen: false)
        #expect(!behavior.contains(.fullScreenNone))
        #expect(behavior.contains(.fullScreenPrimary))
    }

    /// **Idempotent, and that is what lets it run on every SwiftUI update.** Applying it to its
    /// own output must not change anything, or re-asserting the style would drift.
    @Test @MainActor func applyingTwiceIsApplyingOnce() {
        for hasBeenFullScreen in [false, true] {
            let once = EditorWindowStyle.collectionBehavior(from: [.fullScreenNone, .managed],
                                                            hasBeenFullScreen: hasBeenFullScreen)
            let twice = EditorWindowStyle.collectionBehavior(from: once,
                                                             hasBeenFullScreen: hasBeenFullScreen)
            #expect(once == twice)
        }
    }

    /// Bits the app has no opinion about are left alone. A style function that returned a fixed
    /// set would silently drop whatever SwiftUI had put there.
    @Test @MainActor func behaviourItDoesNotOwnSurvives() {
        let behavior = EditorWindowStyle.collectionBehavior(from: [.managed, .participatesInCycle],
                                                            hasBeenFullScreen: false)
        #expect(behavior.contains(.managed))
        #expect(behavior.contains(.participatesInCycle))
    }

    /// Full screen needs a resizable window whatever the collection behaviour says, and the
    /// middle traffic light is drawn and dead without `.miniaturizable`.
    @Test @MainActor func theMaskGainsWhatFullScreenAndTheYellowButtonNeed() {
        let mask = EditorWindowStyle.styleMask(from: [.titled, .closable])
        #expect(mask.contains(.resizable))
        #expect(mask.contains(.miniaturizable))
        #expect(mask.contains(.titled))
        #expect(EditorWindowStyle.styleMask(from: mask) == mask)
    }
}
