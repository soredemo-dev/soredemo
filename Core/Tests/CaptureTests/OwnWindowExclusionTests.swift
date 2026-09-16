import Foundation
import Geometry
import Testing
@testable import Capture

// Whether a point is over one of this app's own windows — asked before the accessibility hit
// test, because that call is served in-process when the answer is yes, on a background queue,
// where AppKit reads window geometry off the main thread. See `OwnWindowExclusion`.

private func exclusion(_ windows: [UInt32: PointRect]) -> OwnWindowExclusion {
    OwnWindowExclusion(identifiers: Array(windows.keys).sorted()) { windows[$0] }
}

private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> PointRect {
    PointRect(x: x, y: y, width: width, height: height)
}

@Test func aPointInsideOneOfOurWindowsIsOurs() {
    #expect(exclusion([1: rect(0, 0, 100, 100)]).contains(globalTopLeftX: 50, globalTopLeftY: 50))
}

@Test func aPointOutsideAllOfThemIsNot() {
    #expect(!exclusion([1: rect(0, 0, 100, 100)]).contains(globalTopLeftX: 500, globalTopLeftY: 50))
}

/// **Every window is asked, not only the first.** The recording bar, the camera bubble and the
/// editor are all ours and all on screen at once; stopping at the first miss would leave the
/// other two hit-testable and the crash in place.
@Test func aPointInTheSecondWindowIsAlsoOurs() {
    let ours = exclusion([1: rect(0, 0, 100, 100), 2: rect(400, 400, 100, 100)])
    #expect(ours.contains(globalTopLeftX: 450, globalTopLeftY: 450))
}

/// **Nothing published means nothing excluded.** The state before the app has said anything, and
/// the one that must not accidentally cover the screen: a `true` here would stop the observer
/// recording any click at all.
@Test func theEmptyExclusionOwnsNoPoint() {
    #expect(!OwnWindowExclusion.nothing.contains(globalTopLeftX: 0, globalTopLeftY: 0))
    #expect(!OwnWindowExclusion.nothing.contains(globalTopLeftX: 500, globalTopLeftY: 500))
}

/// A window id that no longer resolves — closed, or on another Space — is skipped rather than
/// treated as covering everything. `CGGeometryBridge.windowBounds` returns `nil` for both.
@Test func anIdThatResolvesToNothingIsSkipped() {
    let stale = OwnWindowExclusion(identifiers: [1, 2]) { id in
        id == 2 ? rect(0, 0, 100, 100) : nil
    }
    #expect(stale.contains(globalTopLeftX: 50, globalTopLeftY: 50),
            "a stale id ahead of a live one stopped the search")
    #expect(!stale.contains(globalTopLeftX: 500, globalTopLeftY: 500))
}

/// A zero-sized window covers nothing, and a window server that reports one must not make the
/// whole screen ours.
@Test func aZeroSizedWindowOwnsNoPoint() {
    #expect(!exclusion([1: rect(0, 0, 0, 0)]).contains(globalTopLeftX: 0, globalTopLeftY: 0))
}

/// Half-open on both axes, so the right and bottom edges belong to whatever is beyond them —
/// the same rule `CaptureViewport.normalise` uses, and for the same reason: two rectangles edge
/// to edge must not both own one point.
@Test func theEdgesAreHalfOpen() {
    let ours = exclusion([1: rect(0, 0, 100, 100)])
    #expect(ours.contains(globalTopLeftX: 0, globalTopLeftY: 0))
    #expect(ours.contains(globalTopLeftX: 99.9, globalTopLeftY: 99.9))
    #expect(!ours.contains(globalTopLeftX: 100, globalTopLeftY: 50))
    #expect(!ours.contains(globalTopLeftX: 50, globalTopLeftY: 100))
    #expect(!ours.contains(globalTopLeftX: -0.1, globalTopLeftY: 50))
}

/// A window at a negative origin is ours too. Not hypothetical: a display placed left of the
/// primary one starts at a negative x, which is where this project's two multi-display defects
/// lived — see `docs/design/a-window-on-the-other-display.md`.
@Test func aWindowOnADisplayLeftOfThePrimaryIsStillOurs() {
    let ours = exclusion([1: rect(-1920, -63, 400, 300)])
    #expect(ours.contains(globalTopLeftX: -1800, globalTopLeftY: 0))
    #expect(!ours.contains(globalTopLeftX: -100, globalTopLeftY: 0))
}

/// **The live source is wired, which a pure test cannot show.** `OwnWindowExclusion` is only
/// useful if the hit test consults it; this drives `LiveAXElementSource` with an exclusion that
/// claims the point and asserts it refuses rather than calling into accessibility.
@Test func theLiveHitTestRefusesAPointInsideOurOwnWindow() {
    let source = LiveAXElementSource(exclusion: exclusion([1: rect(0, 0, 2000, 2000)]))
    #expect(source.hitTest(globalTopLeftX: 100, globalTopLeftY: 100) == nil,
            "the hit test ran anyway, which is the call that crashes")
}
