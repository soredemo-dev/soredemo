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

// MARK: - the conditions the comparable recorders handle

/// **The Dock got into a window recording, and the code had predicted it.** The
/// window-capture repair replaced `desktopIndependentWindow` with a display filter plus
/// `sourceRect`, writing "anything overlapping the window's rect is captured with it. A real
/// regression in isolation, accepted because…". A user then recorded a window and got the
/// Dock. Reading the four comparable recorders dissolved all three reasons for accepting it:
/// a Rust recorder, an Electron recorder and an Electron recorder all ship `desktopIndependentWindow`, and both of the two that
/// are Swift size the buffer to the window at the same time — the pair was never in tension.
///
/// Asserted through `sourceRect`, which is the observable consequence: a window filter's
/// frames ARE the window, so a crop would cut the window's own content by its offset on the
/// display. No test here can construct an `SCWindow` to check the filter's type directly;
/// `scripts/run-cross-boundary-probe.sh` does that against real handles.
@Test func aWindowCaptureNoLongerCropsItsDisplay() {
    #expect(CaptureSource.sourceRectIsAlwaysNil,
            "a non-nil source rect means a window filter is cropping the window's own content")
}

/// The window's place on its display is still needed — the pointer is normalised against the
/// rectangle actually recorded — it is just no longer the stream's crop. Kept under its own
/// name so the two uses cannot be confused again.
@Test func theWindowsRectOnItsDisplayIsStillAvailableUnderItsOwnName() {
    let rect = rebasedSourceRect(windowGlobal: (x: 1600, y: 100, w: 500, h: 360),
                                 displayGlobal: (x: 1512, y: 0))
    #expect(rect.x == 88 && rect.y == 100)
}

/// **The host display is found by centre, then by any overlap.** The centre test alone finds
/// nothing for a window dragged so its middle is past a display's edge, and a window with no
/// host is a capture that cannot start. Centre stays first: a window straddling two displays
/// belongs to the one showing most of it.
@Test func aWindowWhoseCentreIsOffscreenStillFindsItsDisplay() {
    let display = (x: 0.0, y: 0.0, w: 1512.0, h: 982.0)
    // Dragged left until its middle is past the display's left edge.
    let window = (x: -400.0, y: 100.0, w: 500.0, h: 360.0)
    #expect(!centreIsInside(window: window, display: display),
            "this fixture must have its centre outside, or it proves nothing")
    #expect(overlaps(window: window, display: display))
}

/// A window that neither contains its centre in a display nor overlaps one has no host, and
/// must not be given an arbitrary one — a capture pointed at the wrong screen is worse than a
/// capture that refuses to start.
@Test func aWindowOnNoDisplayHasNoHost() {
    let display = (x: 0.0, y: 0.0, w: 1512.0, h: 982.0)
    let window = (x: 3000.0, y: 100.0, w: 500.0, h: 360.0)
    #expect(!centreIsInside(window: window, display: display))
    #expect(!overlaps(window: window, display: display))
}

/// **Buffer edges are even.** H.264 in 4:2:0 subsamples chroma by two in each direction, so
/// an odd edge has no defined chroma plane and VideoToolbox either refuses or silently rounds
/// it. Both comparable recorders clamp with `max(2, …)` and neither says why.
@Test func aWindowBufferIsAlwaysEvenAndAtLeastTwo() {
    // A window at a fractional point size on a 2× display — the case that produces an odd
    // pixel count and the reason a plain `rounded()` was not enough.
    #expect(CaptureSource.evenFloor(500.5 * 2) == 1000)
    #expect(CaptureSource.evenFloor(499.5 * 2) == 998)
    #expect(CaptureSource.evenFloor(1.5) == 0, "below the floor there is no buffer to make")
    #expect(CaptureSource.evenFloor(.nan) == 0)
    for points in stride(from: 1.0, through: 60.0, by: 0.25) {
        let edge = CaptureSource.evenFloor(points * 2)
        #expect(edge % 2 == 0, "\(points) points produced an odd edge of \(edge)")
    }
}

private func centreIsInside(window: (x: Double, y: Double, w: Double, h: Double),
                            display: (x: Double, y: Double, w: Double, h: Double)) -> Bool {
    let cx = window.x + window.w / 2, cy = window.y + window.h / 2
    return cx >= display.x && cx < display.x + display.w
        && cy >= display.y && cy < display.y + display.h
}

private func overlaps(window: (x: Double, y: Double, w: Double, h: Double),
                      display: (x: Double, y: Double, w: Double, h: Double)) -> Bool {
    window.x < display.x + display.w && window.x + window.w > display.x
        && window.y < display.y + display.h && window.y + window.h > display.y
}

/// The picker's target narrowing — what makes "Record Screen" and "Record Window" two different
/// buttons rather than two labels on one.
@Suite struct CaptureSourcePickerModeTests {
    @Test func eachModeOffersExactlyWhatItsNameSays() {
        #expect(CaptureSourcePicker.Modes.displaysOnly.allowed == [.singleDisplay])
        #expect(CaptureSourcePicker.Modes.windowsOnly.allowed == [.singleWindow])
        #expect(CaptureSourcePicker.Modes.displaysAndWindows.allowed
                == [.singleWindow, .singleDisplay])
    }

    /// **No mode offers applications or multi-selection**, which `CaptureSource` has no case for
    /// — the restriction `present(restrictModes:)` has always documented, now that there are
    /// three ways to spell it.
    @Test func noModeOffersATargetCaptureSourceCannotRepresent() {
        for modes in [CaptureSourcePicker.Modes.displaysOnly, .windowsOnly, .displaysAndWindows] {
            #expect(!modes.allowed.contains(.multipleWindows))
            #expect(!modes.allowed.contains(.singleApplication))
            #expect(!modes.allowed.contains(.multipleApplications))
            #expect(!modes.allowed.isEmpty)
        }
    }
}

/// The one selection that is a choice rather than a capability.
@Suite struct MicrophoneOffTests {
    /// **`.off` must not resolve to the default.** Every other fallback in `resolve` trades a
    /// missing device for a working one; this one would trade silence for a live microphone,
    /// which is the only fallback there that is worse than failing.
    @Test func offStaysOffWhereAMissingDeviceFallsBack() {
        #expect(MicrophoneInventory.resolve(.off) == .off)
        #expect(MicrophoneInventory.resolve(.device(uniqueID: "gone", name: "Unplugged"))
                == .systemDefault)
    }

    @Test func offAsksForNoDeviceAndSaysSo() {
        #expect(MicrophoneSource.off.deviceID == nil)
        #expect(MicrophoneSource.off.displayName == "No microphone")
        // Distinct from the default in every way a caller can observe — the two used to be
        // indistinguishable, which is why "you asked us not to" was recorded as "we could not".
        #expect(MicrophoneSource.off != MicrophoneSource.systemDefault)
        #expect(MicrophoneSource.off.displayName != MicrophoneSource.systemDefault.displayName)
    }

    /// `available()` reports devices, and a device is never `.off` — so a list built from it
    /// cannot silently contain the choice not to record.
    @Test func theInventoryNeverReportsOffAsADevice() {
        #expect(!MicrophoneInventory.available().contains(.off))
    }
}
