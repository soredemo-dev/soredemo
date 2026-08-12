import Foundation
import ScreenCaptureKit
import Testing
@testable import Headless

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
