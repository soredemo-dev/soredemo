import Testing
@testable import Soredemo

// Turning `NSWindow.windowNumber` into a `CGWindowID`, which is the conversion that crashed.
//
// **Why this test exists in this exact shape.** The crashing line was written with a safety
// argument attached: window numbers on this machine topped out at 5162, far under `Int32`. That
// number was real and it was measured on the wrong set — `CGWindowListCopyWindowInfo`, the
// windows on the screen — while the code was handed `NSApp.windows`, which also contains
// AppKit's own `NSStatusBarWindow`. Measured on this machine, that window's number is
// 4294967296. So the cases below are not invented bounds: 4294967296 is the observed value that
// took the app down on the first frame of every recording.

@Test @MainActor func aWindowNumberTooLargeForAWindowIDIsLeftOut() {
    // The measured `NSStatusBarWindow` number, and `UInt32.max + 1` exactly.
    #expect(OwnWindowReporter.identifiers(of: [4_294_967_296]).isEmpty)
    // It must be DROPPED, not folded to 0 or to some other id: both of those are valid
    // `CGWindowID`s belonging to a window this app does not own.
    #expect(!OwnWindowReporter.identifiers(of: [4_294_967_296]).contains(0))
}

/// AppKit hands out negative window numbers for windows that have no window-server backing. The
/// old `UInt32(bitPattern:)` turned −1 into 4294967295 — a number in range, and not ours.
@Test @MainActor func aNegativeWindowNumberIsLeftOut() {
    #expect(OwnWindowReporter.identifiers(of: [-1, -5162]).isEmpty)
}

/// The ordinary case still survives, in order, so the drop is not eating real windows.
@Test @MainActor func ordinaryWindowNumbersSurviveInOrder() {
    #expect(OwnWindowReporter.identifiers(of: [5162, 1, 4_294_967_295]) == [5162, 1, 4_294_967_295])
}

/// The mixture is the real population: one status-bar window among several ordinary ones. The
/// ordinary ones must all still be excluded from the hit test — losing them is the crash this
/// whole file prevents, so a fix that dropped everything would be no fix.
@Test @MainActor func onlyTheUnrepresentableOneIsLost() {
    let identifiers = OwnWindowReporter.identifiers(of: [4_294_967_296, 5162, 5163, -1, 5164])
    #expect(identifiers == [5162, 5163, 5164])
}
