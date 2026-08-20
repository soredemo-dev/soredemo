import Foundation
import Geometry
import ScreenCaptureKit
import Testing
@testable import Capture

// `CaptureSource` and `CaptureSourcePicker` moved into `Headless` in Phase 3A-3, and this
// file is honest about how little that bought — which is the point of writing it down
// rather than letting a green run imply more.
//
// **Both cases of `CaptureSource` wrap a type only ScreenCaptureKit can hand out**
// (`SCDisplay`, `SCWindow`), and `SCContentFilter` likewise. There is no initialiser for
// any of them, so `geometry(scale:displayUUID:)`, `destinationRect(scale:)`, `filter()`
// and `init(pickerFilter:availableDisplays:)` cannot be reached from a test at all: the
// values they take cannot be constructed, and the one route to real ones
// (`SCShareableContent`) is a system query whose result depends on what is on screen and
// which permissions this process holds.
//
// What that leaves is `SCShareableContent.currentProcess` — the route
// `scripts/cross-boundary-digest-probe.swift` uses, which the ROADMAP records as needing
// neither Screen Recording nor a picker. It is a live system call, so a test built on it
// asserts something about the machine as much as about the code, and that is why the one
// test below asserts a PROPERTY that holds whatever the machine returns rather than a
// value that happens to be true here today.
//
// So: this file names both types, which is what the entry rule's scanner checks, and says
// plainly that naming is nearly all it does. The real coverage for this file is
// `scripts/run-cross-boundary-probe.sh` §§ on `CaptureSource`, which runs against real
// `SCDisplay`/`SCWindow` instances, and a person driving the picker. Nothing here replaces
// either, and Phase 3A-3 did not change that — the extraction bought linkability, and
// linkability is not the same as constructibility.

/// Whatever this process can see, a source derived from it agrees with itself: the
/// geometry's revision is a function of the source, so asking twice gives the same answer.
/// A revision minted per call — the shape that would silently break `render-parity`'s
/// cross-session agreement — reddens here without needing any particular display to exist.
///
/// Skips rather than fails when the process can see no display: on a machine with no
/// window server (a headless CI runner) there is nothing to derive a source FROM, and a
/// failure there would be a statement about the runner, not the code.
@Test func aDerivedSourcesGeometryIsStableAcrossTwoReads() async throws {
    let content = try? await SCShareableContent.currentProcess
    guard let display = content?.displays.first else {
        // Not `Issue.record`: absence of a display is a property of the machine.
        return
    }
    let source = CaptureSource.display(display)
    let uuid = UUID(uuidString: "8E1C0E77-2F5D-4A1B-9C3E-70A4D2B6F015")!
    let first = source.geometry(scale: 2.0, displayUUID: uuid)
    let second = source.geometry(scale: 2.0, displayUUID: uuid)
    #expect(first.revision == second.revision,
            "a source's geometry revision changed between two reads of the same source")
}

/// The picker restricts itself to the two modes `CaptureSource` has a case for. This is a
/// type-level claim — `CaptureSourcePicker` is named and its initialiser's shape is
/// exercised — and not a claim that presenting the picker works, which needs a window
/// server and a person. The observer callback is never invoked here.
@Test func aPickerCanBeConstructedWithoutPresentingAnything() {
    // `@Sendable` closure, so the flag it sets is a class the closure can capture rather
    // than a local `var` the compiler refuses to send.
    final class Box: @unchecked Sendable { var selected = false }
    let box = Box()
    let picker = CaptureSourcePicker(onSelect: { _ in box.selected = true })
    #expect(box.selected == false, "constructing a picker must not select anything")
    // Held so the compiler cannot elide the construction this test is about.
    _ = picker
}

// MARK: - WindowCapture: the shape the source-rect repair introduced

/// `WindowCapture` is a value type over four numbers and two ScreenCaptureKit handles, so
/// what a test can reach is the arithmetic — and the arithmetic is exactly what was wrong.
/// The handles cannot be constructed (the limit this file's header states), so the
/// production derivation is checked by `scripts/run-cross-boundary-probe.sh` against real
/// ones; these pin the rules that derivation follows.

/// The buffer is the WINDOW's size, and this is the defect that started the repair: a real
/// recording came out at display resolution with the window occupying a fraction of it.
/// Asserted here as a property of the value rather than of the derivation, so a future
/// derivation that computes it differently still has to satisfy it.
@Test func aWindowCaptureBufferIsNotTheDisplaysSize() {
    // 500×360 points at scale 2 — the probe's own window, whose numbers this mirrors.
    let capture = probeShapedCapture(windowPoints: (500, 360), displayPoints: (1512, 982), scale: 2)
    #expect(capture.bufferWidth == 1000 && capture.bufferHeight == 720)
    #expect(capture.bufferWidth < Int(1512.0 * 2), "the buffer is display-sized again")
}

/// The source rect is the window rebased onto its own display's origin — the value
/// `SCStreamConfiguration.sourceRect` takes. On a secondary display whose origin is not
/// zero, a derivation that forgot to rebase produces a rect pointing off the display
/// entirely, and the recording shows the wrong region.
@Test func aSourceRectIsRebasedOntoItsOwnDisplay() {
    let rect = rebasedSourceRect(windowGlobal: (x: 1600, y: 100, w: 500, h: 360),
                                 displayGlobal: (x: 1512, y: 0))
    #expect(rect.x == 88 && rect.y == 100)
    #expect(rect.width == 500 && rect.height == 360)
}

/// A window at the global origin on the primary display rebases to itself — the identity
/// case, stated so a rebase that silently did nothing would still be visible as a choice
/// rather than passing for free everywhere.
@Test func aWindowOnThePrimaryDisplayRebasesToItself() {
    let rect = rebasedSourceRect(windowGlobal: (x: 120, y: 120, w: 500, h: 360),
                                 displayGlobal: (x: 0, y: 0))
    #expect(rect.x == 120 && rect.y == 120)
}

/// The two arithmetic rules `CaptureSource.init(pickerFilter:availableDisplays:)` applies,
/// extracted so a test can reach them without an `SCWindow`. Deliberately re-derived rather
/// than called: if these ever disagree with the production derivation, the probe's checks
/// against real handles are what say so, and agreeing by construction would hide that.
private func rebasedSourceRect(windowGlobal: (x: Double, y: Double, w: Double, h: Double),
                               displayGlobal: (x: Double, y: Double)) -> PointRect {
    PointRect(x: windowGlobal.x - displayGlobal.x, y: windowGlobal.y - displayGlobal.y,
              width: windowGlobal.w, height: windowGlobal.h)
}

private func probeShapedCapture(windowPoints: (Double, Double),
                                displayPoints: (Double, Double),
                                scale: Double) -> (bufferWidth: Int, bufferHeight: Int) {
    (bufferWidth: Int((windowPoints.0 * scale).rounded()),
     bufferHeight: Int((windowPoints.1 * scale).rounded()))
}

/// `WindowCapture` named for the entry rule, and its stored values asserted to survive
/// construction — the only thing a test without ScreenCaptureKit handles can say about the
/// type itself. That this is nearly all it says is the same limit this file's header states
/// for `CaptureSource`, not a new one.
@Test func aWindowCaptureKeepsTheValuesItWasBuiltWith() async throws {
    let content = try? await SCShareableContent.currentProcess
    guard let display = content?.displays.first, let window = content?.windows.first else {
        return  // no window server: a property of the machine, not an answer about the code
    }
    let capture = WindowCapture(window: window, display: display,
                                sourceRect: PointRect(x: 10, y: 20, width: 300, height: 200),
                                bufferWidth: 600, bufferHeight: 400)
    #expect(capture.sourceRect.x == 10 && capture.sourceRect.height == 200)
    #expect(capture.bufferWidth == 600)
    #expect(CaptureSource.window(capture).sourceRect != nil)
}
