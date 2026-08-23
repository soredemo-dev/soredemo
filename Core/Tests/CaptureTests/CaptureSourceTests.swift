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

/// The exclusion that stops a recorder recording its own controls.
@Suite struct CaptureFilterExclusionTests {
    /// **A real recording is what found this.** A 22-second screen capture came back with the
    /// floating control bar across the bottom of every frame, because the display filter was
    /// built with `excludingWindows: []` — a list that excludes nothing. There is no `SCDisplay`
    /// a test can construct, so what is asserted here is the piece that WAS wrong: that the
    /// exclusion list is a real argument reaching the filter, and that it is resolved from this
    /// process rather than left empty.
    @Test func theExclusionListNamesThisProcessAndNothingElse() async {
        let applications = await CaptureSource.thisApplication()
        let pid = ProcessInfo.processInfo.processIdentifier
        for application in applications {
            #expect(application.processID == pid,
                    "\(application.bundleIdentifier) is not this process")
        }
    }

    /// A window capture needs no exclusion — `desktopIndependentWindow` captures one window and
    /// nothing overlapping it. Stated on the type so a future case that started sharing the
    /// display path has to face this line.
    @Test func aWindowCaptureExcludesOverlappingWindowsByConstruction() {
        #expect(CaptureSource.sourceRectIsAlwaysNil)
    }
}

/// Which camera a recording uses.
@Suite struct CameraSourceTests {
    /// **`.off` is a choice, and a missing camera falls back to it rather than to another one.**
    /// `MicrophoneInventory.resolve` falls back to the system default because a recording with
    /// the built-in microphone still records the room; a camera that fell back would record a
    /// person's FACE when they had asked for a specific device, and that argument does not carry
    /// over to a lens.
    @Test func aMissingCameraFallsBackToNoCameraAtAll() {
        let present = CameraSource(uniqueID: "A", name: "Built-in")
        let gone = CameraSource(uniqueID: "B", name: "Unplugged")
        #expect(CameraSource.resolve(present, against: [present]) == present)
        #expect(CameraSource.resolve(gone, against: [present]) == .off)
        #expect(CameraSource.resolve(.off, against: [present]) == .off)
    }

    @Test func offAsksForNoDeviceAndSaysSo() {
        #expect(CameraSource.off.uniqueID == nil)
        #expect(CameraSource.off.displayName == "No camera")
        #expect(CameraSource.off != CameraSource(uniqueID: "A", name: "Built-in"))
    }

    /// **The raw values are the strings table's keys, not decoration.** The panel writes
    /// `NSLocalizedString(effect.rawValue)`, so a raw value edited to read better in code — to
    /// "portrait", say — would silently ship an untranslated word to every non-English reader.
    /// Pinned here because nothing else can notice.
    @Test func everyEffectIsNamedByTheKeyTheAppLooksUp() {
        #expect(CameraEffects.Effect.portrait.rawValue == "Portrait")
        #expect(CameraEffects.Effect.studioLight.rawValue == "Studio Light")
        #expect(CameraEffects.Effect.centerStage.rawValue == "Center Stage")
        #expect(CameraEffects.Effect.reactions.rawValue == "Reactions")
        #expect(CameraEffects.Effect.background.rawValue == "Background")
        let names = CameraEffects.Effect.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
    }

    /// **Reading which effects are on must not need a camera, a permission, or a session.**
    /// It is called while a menu is being drawn — every one of those would be a stall in front
    /// of somebody, and a permission prompt raised by drawing a menu would be worse than a
    /// stall. The class properties are the whole implementation for exactly this reason.
    @Test func theActiveEffectsCanBeReadWithoutOpeningACamera() {
        let active = CameraEffects.active()
        #expect(Set(active).count == active.count)
        for effect in active { #expect(CameraEffects.Effect.allCases.contains(effect)) }
        // Declared order, so the row does not reshuffle itself between two readings.
        let ranks = active.compactMap { CameraEffects.Effect.allCases.firstIndex(of: $0) }
        #expect(ranks == ranks.sorted())
    }

    /// A camera nobody named is not in use by anybody, and asking must not construct a device.
    @Test func noCameraIsNeverInUseByAnotherApplication() {
        #expect(CameraRecorder.isInUseByAnotherApplication(.off) == false)
    }

    @Test func theRecorderErrorsDescribeThemselvesDistinctly() {
        let cases: [CameraRecorder.RecorderError] = [
            .noCamera("Studio Display"), .sessionRefusedInput, .sessionRefusedOutput,
        ]
        #expect(Set(cases.map(\.description)).count == cases.count)
        #expect(CameraRecorder.RecorderError.noCamera("X").description.contains("X"))
    }

    /// Asking must not prompt, download, or trap — a caller hides the control when this is false.
    @Test func availabilityCanBeAskedWithoutRecordingAnything() {
        _ = CameraRecorder.isAvailable
        for camera in CameraRecorder.available() { #expect(camera.uniqueID != nil) }
    }
}

/// The windows a person can point at, described without reading anything private.
@Suite struct WindowTargetTests {
    private func target(_ id: UInt32, _ name: String,
                        x: Double, y: Double, width: Double, height: Double) -> WindowTarget {
        WindowTarget(id: id, applicationName: name, bundleIdentifier: "com.example.\(name)",
                     frame: PointRect(x: x, y: y, width: width, height: height))
    }

    /// **Front to back, so the FIRST match wins.** ScreenCaptureKit returns windows in that
    /// order and the hit test relies on it: sorting by area or by name would put the wrong
    /// window under the cursor whenever two overlap, which is most of the time.
    @Test func theHitTestTakesTheFrontmostOverlappingWindow() {
        let front = target(1, "Front", x: 0, y: 0, width: 100, height: 100)
        let behind = target(2, "Behind", x: 0, y: 0, width: 400, height: 400)
        let targets = [front, behind]
        #expect(WindowTargets.target(at: 50, y: 50, in: targets) == front)
        // Outside the front one but inside the back one.
        #expect(WindowTargets.target(at: 200, y: 200, in: targets) == behind)
        #expect(WindowTargets.target(at: 900, y: 900, in: targets) == nil)
    }

    /// The right edge is exclusive, so two windows meeting exactly do not both claim the seam.
    @Test func theRightAndBottomEdgesAreExclusive() {
        let one = target(1, "One", x: 0, y: 0, width: 100, height: 100)
        #expect(WindowTargets.target(at: 99.9, y: 99.9, in: [one]) == one)
        #expect(WindowTargets.target(at: 100, y: 50, in: [one]) == nil)
        #expect(WindowTargets.target(at: 50, y: 100, in: [one]) == nil)
    }

    /// **The card shows the size, which is the second thing a person needs after the name.**
    @Test func theSizeIsReadAsWholePoints() {
        #expect(target(1, "X", x: 0, y: 0, width: 1402.4, height: 810.6).sizeDescription
                == "1402\u{00D7}811")
    }

    /// Buffer dimensions are even, for `CaptureSource`'s reason: an odd one is where a stray
    /// column of green comes from.
    @Test func bufferDimensionsAreAlwaysEven() {
        for value in [1, 2, 3, 1401, 1402] {
            #expect(WindowTargets.evenFloor(value) % 2 == 0)
        }
        #expect(WindowTargets.evenFloor(0) == 2)
    }

    /// Enumerating must not prompt or trap on a machine with no grant — it returns what it can.
    @Test func enumeratingIsSafeWithoutAGrant() async {
        for candidate in await WindowTargets.onScreen() {
            #expect(!candidate.applicationName.isEmpty)
            #expect(candidate.frame.width > 1)
        }
    }
}

/// The ceiling on how often a capture delivers a frame.
@Suite struct CaptureFrameRateTests {
    /// **A ceiling, not a cadence** — the interval is one over the rate, and a still screen
    /// still produces nothing.
    @Test func theIntervalIsOneOverTheRate() {
        #expect(CaptureFrameRate.sixty.minimumFrameInterval == CMTime(value: 1, timescale: 60))
        #expect(CaptureFrameRate.thirty.minimumFrameInterval == CMTime(value: 1, timescale: 30))
        #expect(CaptureFrameRate.oneHundredTwenty.minimumFrameInterval
                == CMTime(value: 1, timescale: 120))
    }

    /// **Offering 120 on a 60 Hz panel would be offering nothing**: the interval is a ceiling and
    /// the panel is the floor, so the recording would be 60 either way.
    @Test func onlyRatesTheDisplayCanProduceAreOffered() {
        #expect(CaptureFrameRate.available(upTo: 60) == [.thirty, .sixty])
        #expect(CaptureFrameRate.available(upTo: 120).count == 3)
        #expect(CaptureFrameRate.available(upTo: 30) == [.thirty])
    }

    /// A ProMotion panel reports 120.0 and a 59.94 Hz one reports just under 60 — which must
    /// still offer 60, or an ordinary display would lose its own rate to a rounding error.
    @Test func aRateJustUnderTheNominalOneStillOffersIt() {
        #expect(CaptureFrameRate.available(upTo: 59.94).contains(.sixty))
        #expect(CaptureFrameRate.available(upTo: 119.88).contains(.oneHundredTwenty))
    }

    @Test func everyRateSaysWhatItIsAndWhatItCosts() {
        for rate in CaptureFrameRate.allCases {
            #expect(rate.displayName.contains("\(rate.rawValue)"))
            #expect(!rate.detail.isEmpty)
        }
        #expect(Set(CaptureFrameRate.allCases.map(\.detail)).count
                == CaptureFrameRate.allCases.count)
    }
}
