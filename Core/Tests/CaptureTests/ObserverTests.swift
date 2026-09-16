import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Capture

// The first `swift test` tests of the two observers, moved out of the app target in Phase
// 3A-3. `InputObserver`'s keyboard filter is this product's entire keystroke-privacy
// mechanism and had never been executed by anything automatic; `AXObserver`'s walk had a
// dependency-injection seam (`AXElementSource`) that existed specifically so it could be
// tested and, until now, nothing could link it to use one.

private let epoch = BootEpoch(id: UUID(uuidString: "5D2A9C31-77E4-4B08-9A6F-1C0E3B5A8D42")!)
private let displayUUID = UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000001")!

/// The whole-display viewport for the fixture display — what these tests always meant by
/// `arrangement()`, now said in the type the observer takes. The display path is unchanged
/// by the window repair, and these tests are the assertion of that.
private func viewport() -> CaptureViewport {
    CaptureViewport(geometry: DisplayGeometry(displayUUID: displayUUID,
                                              pixelWidth: 2000, pixelHeight: 1000, scale: 2.0),
                    globalOriginX: 0, globalOriginY: 0,
                    widthInPoints: 1000, heightInPoints: 500)
}

private func arrangement() -> DisplayArrangement {
    DisplayArrangement(placements: [
        .init(geometry: DisplayGeometry(displayUUID: displayUUID,
                                        pixelWidth: 2000, pixelHeight: 1000, scale: 2.0),
              globalOriginX: 0, globalOriginY: 0),
    ])
}

private func revision() -> GeometryRevision {
    arrangement().placements[0].geometry.revision
}

private func click(x: Double, y: Double) -> ButtonEvent {
    ButtonEvent(instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(1_000)),
                position: NormalizedPoint(x: x, y: y), revision: revision(),
                button: .left, phase: .down)
}

// MARK: - the keyboard filter: a closed allow-list, exercised

/// **The privacy mechanism, executed.** A key not on the list produces nothing — not a
/// redacted string, not a placeholder. `kVK_ANSI_Q` with ⌘ is a real shortcut in many apps
/// and is deliberately absent from this table.
@Test func aKeyOutsideTheAllowListProducesNothing() {
    #expect(InputObserver.approvedShortcut(forKeyCode: Int64(kVK_ANSI_Q),
                                           flags: [.maskCommand]) == nil)
}

/// A bare letter — ordinary typing — produces nothing. This is the case the whole file
/// exists for: without a command or control modifier there is no shortcut, so the content
/// of what someone typed never becomes a value this process holds.
@Test func ordinaryTypingProducesNothing() {
    for keyCode in [kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_Space] {
        #expect(InputObserver.approvedShortcut(forKeyCode: Int64(keyCode), flags: []) == nil,
                "an unmodified key produced a shortcut identifier")
        #expect(InputObserver.approvedShortcut(forKeyCode: Int64(keyCode),
                                               flags: [.maskShift]) == nil,
                "shift alone produced a shortcut identifier")
    }
}

/// An approved shortcut answers with its NAME, which comes from the table and never from
/// the event. The identifier for ⌘C is the string "cmd+c" whatever the keyboard layout is,
/// because `CGEvent` carries a layout-independent position.
@Test func anApprovedShortcutAnswersWithItsTableName() {
    #expect(InputObserver.approvedShortcut(forKeyCode: Int64(kVK_ANSI_C),
                                           flags: [.maskCommand]) == "cmd+c")
}

/// **Modifiers are matched exactly, not by subset** — the struct's own doc comment. ⇧⌘Z is
/// a different entry from ⌘Z, so ⌘Z's flags must not match ⇧⌘Z's row and vice versa.
@Test func modifiersAreMatchedExactlyAndNotBySubset() {
    #expect(InputObserver.approvedShortcut(forKeyCode: Int64(kVK_ANSI_Z),
                                           flags: [.maskCommand]) == "cmd+z")
    #expect(InputObserver.approvedShortcut(forKeyCode: Int64(kVK_ANSI_Z),
                                           flags: [.maskCommand, .maskShift]) == "cmd+shift+z")
    // ⌥⌘Z is on neither row: an exact match refuses it, a subset match would return "cmd+z".
    #expect(InputObserver.approvedShortcut(forKeyCode: Int64(kVK_ANSI_Z),
                                           flags: [.maskCommand, .maskAlternate]) == nil)
}

/// **Flags are masked before comparison, and this is the test that would have caught the
/// bug the file's own comment warns about.** A real `CGEvent` always carries
/// `maskNonCoalesced`; comparing raw flags to the table would match nothing, ever, and the
/// filter would silently record no shortcuts at all — a failure indistinguishable from a
/// session where nobody used one.
@Test func theNoiseFlagsARealEventCarriesDoNotDefeatTheMatch() {
    let realistic: CGEventFlags = [.maskCommand, .maskNonCoalesced, .maskNumericPad]
    #expect(InputObserver.approvedShortcut(forKeyCode: Int64(kVK_ANSI_C),
                                           flags: realistic) == "cmd+c")
}

/// Every identifier in the table is unique and every entry is reachable through the
/// filter. A duplicate identifier would make two different keystrokes indistinguishable in
/// the log; an unreachable row is a promise the filter does not keep.
@Test func everyApprovedShortcutIsUniqueAndReachable() {
    let identifiers = InputObserver.approvedShortcuts.map(\.identifier)
    #expect(Set(identifiers).count == identifiers.count, "two rows share an identifier")
    for shortcut in InputObserver.approvedShortcuts {
        #expect(InputObserver.approvedShortcut(forKeyCode: shortcut.keyCode,
                                               flags: shortcut.modifiers) == shortcut.identifier,
                "\(shortcut.identifier) is in the table but the filter does not return it")
    }
}

/// `ApprovedShortcut` is `Equatable` on all three fields — two rows differing only in
/// modifiers are different rows, which is what makes the exact-match rule expressible.
@Test func twoShortcutsDifferingOnlyInModifiersAreDifferent() {
    let a = InputObserver.ApprovedShortcut(identifier: "cmd+z", keyCode: Int64(kVK_ANSI_Z),
                                           modifiers: [.maskCommand])
    let b = InputObserver.ApprovedShortcut(identifier: "cmd+shift+z", keyCode: Int64(kVK_ANSI_Z),
                                           modifiers: [.maskCommand, .maskShift])
    #expect(a != b)
}

// MARK: - normalizedPosition: the conversion chain, end to end

/// A global point routes to its display and normalises to bottom-left 0…1. The centre is
/// chosen because it is the one point where an x/y transposition would NOT show up — so
/// the assertions below use an off-centre point as well.
@Test func aGlobalPointNormalisesWithinItsDisplay() throws {
    let result = try #require(InputObserver.normalizedPosition(
        globalTopLeftX: 300, globalTopLeftY: 200, in: viewport()))
    #expect(result.position.x > 0 && result.position.x < 1)
    #expect(result.position.y > 0 && result.position.y < 1)
    #expect(result.revision == viewport().revision)
}

/// Top-left in, bottom-left out: a point in the TOP half of the screen must land in the
/// UPPER half of a bottom-left normalised space, which is y > 0.5. A missing flip returns
/// a plausible number in the wrong half, and every pointer would be drawn mirrored.
///
/// The global coordinates here are POINTS, so the fixture display — 2000×1000 pixels at
/// scale 2.0 — is 1000×500 points. The first draft of this test used y = 900, off the
/// bottom of that, and `normalizedPosition` correctly returned nil; the code was right and
/// the test had the units wrong.
@Test func theVerticalFlipHappensOnTheWayIn() throws {
    let nearTop = try #require(InputObserver.normalizedPosition(
        globalTopLeftX: 300, globalTopLeftY: 50, in: viewport()))
    let nearBottom = try #require(InputObserver.normalizedPosition(
        globalTopLeftX: 300, globalTopLeftY: 450, in: viewport()))
    #expect(nearTop.position.y > 0.5)
    #expect(nearBottom.position.y < 0.5)
}

/// A point on no display routes nowhere. `nil`, not a clamped edge value: a clamp would
/// put a real-looking coordinate in the log for an event that happened off-screen.
@Test func aPointOnNoDisplayRoutesToNothing() {
    #expect(InputObserver.normalizedPosition(globalTopLeftX: 99_999, globalTopLeftY: 99_999,
                                             in: viewport()) == nil)
}

// MARK: - AXObserver's walk, over a fake element source

/// A hand-built AX tree. The seam this drives (`AXElementSource`) was added so the walk
/// could be tested without a running app; until Phase 3A-3 nothing could link it.
private struct FakeAXSource: AXElementSource {
    struct Node: Sendable {
        var role: String
        var title: String?
        var frame: (x: Double, y: Double, w: Double, h: Double)
        var parent: Int?
        var children: [Int]
    }
    typealias Element = Int
    let nodes: [Node]
    /// The node the hit-test answers with, or `nil` to answer with nothing.
    let hit: Int?

    func hitTest(globalTopLeftX: Double, globalTopLeftY: Double) -> Int? { hit }
    func role(of element: Int) -> String? { nodes[element].role }
    func title(of element: Int) -> String? { nodes[element].title }
    func position(of element: Int) -> (x: Double, y: Double)? {
        (nodes[element].frame.x, nodes[element].frame.y)
    }
    func size(of element: Int) -> (width: Double, height: Double)? {
        (nodes[element].frame.w, nodes[element].frame.h)
    }
    func parent(of element: Int) -> Int? { nodes[element].parent }
    func children(of element: Int) -> [Int]? { nodes[element].children }
}

/// window(0) → group(1) → button(2), with the click on the button.
private func threeLevelTree(hit: Int?) -> FakeAXSource {
    FakeAXSource(nodes: [
        .init(role: "AXWindow", title: "a window", frame: (0, 0, 1000, 500),
              parent: nil, children: [1]),
        .init(role: "AXGroup", title: nil, frame: (100, 100, 400, 200),
              parent: 0, children: [2]),
        .init(role: "AXButton", title: "Record", frame: (200, 150, 100, 40),
              parent: 1, children: []),
    ], hit: hit)
}

/// `Capture.AXObserver`, qualified: ApplicationServices exports a C type of the same
/// name, and an unqualified reference is ambiguous wherever both are in scope.
private func observer() -> Capture.AXObserver {
    Capture.AXObserver(viewport: viewport(), epoch: epoch,
                        accessibilityIsGranted: { true })
}

/// The walk climbs from the hit element to the root and records the ancestors INNERMOST
/// FIRST — the order the record's own doc comment promises, and the order that makes
/// truncation drop the outermost rather than the nearest.
@Test func theWalkRecordsAncestorsInnermostFirst() throws {
    let record = try #require(observer().chain(at: click(x: 0.25, y: 0.7),
                                               source: threeLevelTree(hit: 2)))
    #expect(record.hit?.role == "AXButton")
    #expect(record.ancestors.map(\.role) == ["AXGroup", "AXWindow"])
    #expect(record.truncation == .reachedRoot)
}

/// A hit-test that answers with nothing produces a record that SAYS so, rather than no
/// record at all: a click whose AX lookup failed is evidence, and a missing record would
/// be indistinguishable from a click that never happened.
@Test func aHitTestThatAnswersNothingStillProducesARecordThatSaysSo() throws {
    let record = try #require(observer().chain(at: click(x: 0.25, y: 0.7),
                                               source: threeLevelTree(hit: nil)))
    #expect(record.hit == nil)
    #expect(record.truncation == .hitTestReturnedNothing)
    #expect(record.ancestors.isEmpty)
}

/// One level down, never a deeper search — the leaf's children list is recorded as empty,
/// which is a different fact from "no list was recorded" (`nil`).
@Test func theChildrenOfALeafAreRecordedAsEmptyAndNotAsAbsent() throws {
    let record = try #require(observer().chain(at: click(x: 0.25, y: 0.7),
                                               source: threeLevelTree(hit: 2)))
    #expect(record.children != nil, "an empty children list must not be recorded as absent")
    #expect(record.children?.isEmpty == true)
}

/// The record's instant is the CLICK's, not the observer's — the two have to be on one
/// clock for the log's join key to work, which is what the implementation's own comment
/// says and what nothing had executed until now.
@Test func theRecordIsStampedWithTheClicksInstantAndEpoch() throws {
    let event = click(x: 0.25, y: 0.7)
    let record = try #require(observer().chain(at: event, source: threeLevelTree(hit: 2)))
    #expect(record.instant == event.instant)
    #expect(record.clickPosition == event.position)
    #expect(record.clickRevision == event.revision)
}

/// Every AX round trip is counted, including the hit-test, so a log can say how expensive
/// an observation was. Zero would mean the counter never incremented.
@Test func everyAXRoundTripIsCounted() throws {
    let record = try #require(observer().chain(at: click(x: 0.25, y: 0.7),
                                               source: threeLevelTree(hit: 2)))
    #expect(record.axCalls > 0)
}

/// `InputObserver.Observation` is the closed enum every callback delivers — named cases,
/// so a caller cannot wire up some and silently drop the rest. Constructed here from a
/// real `PointerSample` to assert the association survives the wrapping.
@Test func anObservationCarriesTheRecordItWraps() {
    let sample = PointerSample(instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(7)),
                               position: NormalizedPoint(x: 0.5, y: 0.5), revision: revision())
    let observation = InputObserver.Observation.pointer(sample)
    guard case .pointer(let unwrapped) = observation else {
        Issue.record("a .pointer observation did not carry a PointerSample")
        return
    }
    #expect(unwrapped == sample)
    #expect(observation != InputObserver.Observation.pointer(
        PointerSample(instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(8)),
                      position: NormalizedPoint(x: 0.5, y: 0.5), revision: revision())))
}

/// `LiveAXElementSource` is the production conformer and is named here so the entry rule
/// sees it. It is NOT exercised: every method goes into the real accessibility API, which
/// needs a trusted process and a running app — the same limit `CaptureSourceTests` states
/// for ScreenCaptureKit, and for the same reason.
@Test func theProductionSourceConformsToTheSeamTheTestsDrive() {
    let live: any AXElementSource = LiveAXElementSource()
    #expect(type(of: live) == LiveAXElementSource.self)
}

// MARK: - the cursor normalises against what is RECORDED, not against a display

/// **The defect a real window recording showed.** A window occupying the display's right
/// half: a click at its own centre must normalise to (0.5, 0.5). Against the DISPLAY — what
/// the observer did before the viewport landed — the same point is 0.75, and every drawn
/// cursor in a window recording was offset by exactly that difference.
///
/// The two bases are asserted to genuinely differ, so a viewport that silently fell back to
/// the display would fail rather than pass for the wrong reason.
@Test func aWindowCaptureNormalisesThePointerAgainstTheWindow() throws {
    let display = DisplayGeometry(displayUUID: displayUUID,
                                  pixelWidth: 2000, pixelHeight: 1000, scale: 2.0)
    // The display is 1000×500 POINTS; the window is its right half.
    let windowViewport = CaptureViewport(geometry: display, globalOriginX: 500, globalOriginY: 0,
                                         widthInPoints: 500, heightInPoints: 500)
    let displayViewport = CaptureViewport(geometry: display, globalOriginX: 0, globalOriginY: 0,
                                          widthInPoints: 1000, heightInPoints: 500)

    let inWindow = try #require(InputObserver.normalizedPosition(
        globalTopLeftX: 750, globalTopLeftY: 250, in: windowViewport))
    #expect(abs(inWindow.position.x - 0.5) < 1e-9,
            "the window's own centre normalised to \(inWindow.position.x)")

    let inDisplay = try #require(InputObserver.normalizedPosition(
        globalTopLeftX: 750, globalTopLeftY: 250, in: displayViewport))
    #expect(abs(inDisplay.position.x - 0.75) < 1e-9,
            "the two bases must genuinely differ, or this test proves nothing")
}

/// A pointer on the display but outside the recorded window is not in the recording, so it
/// has no position — `nil`, never clamped. A clamped value would put a real-looking
/// coordinate in the log for a pointer that was never in shot.
@Test func aPointerOutsideTheRecordedWindowHasNoPosition() {
    let display = DisplayGeometry(displayUUID: displayUUID,
                                  pixelWidth: 2000, pixelHeight: 1000, scale: 2.0)
    let windowViewport = CaptureViewport(geometry: display, globalOriginX: 500, globalOriginY: 0,
                                         widthInPoints: 500, heightInPoints: 500)
    #expect(InputObserver.normalizedPosition(globalTopLeftX: 100, globalTopLeftY: 250,
                                             in: windowViewport) == nil)
}

/// The revision travels from the viewport, so a sample is stamped with the coordinate
/// system it was measured in rather than with whatever display happened to be nearby.
@Test func theSamplesRevisionComesFromTheViewport() throws {
    let display = DisplayGeometry(displayUUID: displayUUID,
                                  pixelWidth: 2000, pixelHeight: 1000, scale: 2.0)
    let viewport = CaptureViewport(geometry: display, globalOriginX: 0, globalOriginY: 0,
                                   widthInPoints: 1000, heightInPoints: 500)
    let result = try #require(InputObserver.normalizedPosition(
        globalTopLeftX: 300, globalTopLeftY: 200, in: viewport))
    #expect(result.revision == viewport.revision)
}

// MARK: - the shape read must not run inside the tap callback

/// **A regression this project introduced and a real recording found.** Phase "Parity 2"
/// gave `InputObserver` a `pointerShapeReader` and called it once per pointer sample —
/// inside the `CGEvent.tapCreate` callback. The production reader asks AppKit for
/// `NSCursor.currentSystem` and compares TIFF bytes; at 120 Hz during fast movement that is
/// enough work for macOS to disable the tap with `kCGEventTapDisabledByTimeout`, which
/// becomes a `tapDisabled` blind interval, which draws no pointer at all. The reported
/// symptom was the cursor flickering when moved quickly.
///
/// The fix is the standard one for this problem:
/// the shape is SAMPLED on its own cadence and the callback reads a cached value. This test
/// pins the property that matters — **the callback does not call the reader** — by counting
/// reads against samples.
@Test func theTapCallbackDoesNotReadTheCursorShapePerSample() {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() -> PointerShape? { lock.withLock { value += 1 }; return .arrow }
        var count: Int { lock.withLock { value } }
    }
    let reads = Counter()
    let observer = InputObserver(viewport: viewport(), epoch: epoch,
                                 pointerShapeReader: { reads.bump() })

    // Fifty pointer events through `handle(type:event:)` — the tap callback's own body,
    // driven with synthetic `CGEvent`s so no Input Monitoring grant is needed.
    observer.setObservationSink { _ in }
    for index in 0..<50 {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                  mouseCursorPosition: CGPoint(x: 300 + Double(index) * 2, y: 200),
                                  mouseButton: .left) else {
            Issue.record("could not synthesise a mouseMoved event")
            return
        }
        observer.handle(type: .mouseMoved, event: event)
    }

    #expect(reads.count == 0, """
        the shape reader ran \(reads.count) times for 50 pointer samples — it is being \
        called from the sample path, which is what disabled the tap during fast movement
        """)
}

/// And the shape still reaches the samples: a reader that was simply never called would
/// pass the test above and silently undo Parity 2. The observer refreshes its cached shape
/// on demand, so an explicit refresh followed by samples stamps them.
@Test func aRefreshedShapeStillReachesTheSamples() async {
    // **Skipped while the system has secure input on, because the product is right to emit
    // nothing then.** `handle` checks `IsSecureEventInputEnabled()` before it reads anything
    // off the event: a password field must not reach an observation log. A LOCKED SCREEN
    // turns that on — measured 2026-09-16, `kCGSSessionSecureInputPID` set and
    // `CGSSessionScreenIsLocked` Yes — so this failed on every run, on a machine whose
    // screen had locked itself, and read exactly like a regression in the shape path.
    // Named rather than waited out: no budget is long enough for a screen somebody has to
    // come back and unlock.
    guard !IsSecureEventInputEnabled() else {
        // Printed, not recorded: `Issue.record` fails the test, and a skip that fails
        // is a red gate blaming the wrong thing. The line names itself in the run's
        // output, which is the same discipline the probe applies to its own skips.
        print("SKIPPED aRefreshedShapeStillReachesTheSamples - secure input is on "
              + "system-wide (a locked screen does this), so `handle` emits nothing by "
              + "design. Unlock and re-run.")
        return
    }
    let observer = InputObserver(viewport: viewport(), epoch: epoch,
                                 pointerShapeReader: { .iBeam })
    observer.refreshPointerShape()

    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [PointerShape?] = []
        func record(_ shape: PointerShape?) { lock.withLock { seen.append(shape) } }
        var shapes: [PointerShape?] { lock.withLock { seen } }
    }
    let sink = Sink()
    observer.setObservationSink { observation in
        if case .pointer(let sample) = observation { sink.record(sample.shape) }
    }
    guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: CGPoint(x: 300, y: 200),
                              mouseButton: .left) else {
        Issue.record("could not synthesise a mouseMoved event")
        return
    }
    observer.handle(type: .mouseMoved, event: event)
    // **Waited for, not assumed — and the comment that used to sit here said this is what to do
    // if it failed again.** The sample is delivered on `pollQueue`, deliberately not the main
    // queue (see the note below), so whether it has arrived by the time the expectation runs is
    // a race the assertion does not control. It was observed failing once on 2026-09-15 and
    // left alone because one occurrence does not say which sample was lost; on 2026-09-16 it
    // failed on every run, on a machine that had been busy all day, which is what a race looks
    // like when the timing tips.
    //
    // **A budget, not a sleep.** Polling until the sample arrives costs nothing when it is
    // already there — the common case — and a fixed sleep would be either flaky or slow. Two
    // seconds is far longer than a queue hop and far shorter than a person waiting for a gate.
    let deadline = ContinuousClock.now + .seconds(2)
    while sink.shapes.isEmpty, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(sink.shapes == [.iBeam],
            "no pointer sample arrived within two seconds of the synthesised move")
}

/// **The contract the cursor-flicker repair created, and then broke.** Moving the shape
/// read onto the poll timer moved it onto `pollQueue`, which is deliberately NOT the main
/// queue — the whole reason that timer exists is to notice the callback thread being stuck,
/// so it must not share a thread with it. The app-tier reader kept a
/// `MainActor.assumeIsolated`, which asserts the opposite, and a real run trapped with
/// `EXC_BREAKPOINT` on the poll thread.
///
/// So: **the reader is called off the main thread, and that is a requirement rather than an
/// accident**. Asserted here from the side that can be tested — the app tier has no test
/// target — so an implementation that quietly needs the main actor fails a package test
/// instead of a person's recording.
@Test func theShapeReaderIsCalledOffTheMainThread() async {
    final class Observed: @unchecked Sendable {
        private let lock = NSLock()
        private var sawMain: Bool?
        func note(isMain: Bool) { lock.withLock { if sawMain == nil { sawMain = isMain } } }
        var wasMain: Bool? { lock.withLock { sawMain } }
    }
    let observed = Observed()
    let observer = InputObserver(viewport: viewport(), epoch: epoch,
                                 pointerShapeReader: {
                                     observed.note(isMain: Thread.isMainThread)
                                     return .arrow
                                 })
    // `refreshPointerShape()` is what the poll timer calls; driving it from a background
    // queue is that call site's own condition.
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            observer.refreshPointerShape()
            continuation.resume()
        }
    }
    #expect(observed.wasMain == false,
            "the reader ran on the main thread — the poll queue deliberately is not it")
}

// MARK: - the window viewport, which is what the two observers used to disagree about

/// A window 400×300 points at (500, 200) on the fixture display — the shape a window capture
/// records, and the one where a display-normalised hit-test lands somewhere else entirely.
private func windowViewport() -> CaptureViewport {
    CaptureViewport(geometry: DisplayGeometry(displayUUID: displayUUID,
                                              pixelWidth: 2000, pixelHeight: 1000, scale: 2.0),
                    globalOriginX: 500, globalOriginY: 200,
                    widthInPoints: 400, heightInPoints: 300)
}

/// **The defect, stated as the round trip it broke.** A click is normalised by
/// `InputObserver` against the viewport; `AXObserver` denormalises it to decide where to
/// hit-test. The two are inverses, and while the AX side used a `DisplayArrangement` they were
/// inverses only when the viewport WAS the display — so window and region recordings
/// hit-tested a point the click was never at, every chain was refused, and neither mode ever
/// zoomed.
@Test func aClickNormalisedAgainstAWindowHitTestsWhereItActuallyHappened() throws {
    let window = windowViewport()
    // The middle of the window is global (700, 350): 500 + 400/2, 200 + 300/2.
    let normalised = try #require(window.normalise(globalTopLeftX: 700, globalTopLeftY: 350))
    let back = try #require(Capture.AXObserver.globalPoint(of: normalised,
                                                           revision: window.revision,
                                                           in: window))
    #expect(abs(back.x - 700) < 0.001 && abs(back.y - 350) < 0.001, """
        the round trip landed at (\(back.x), \(back.y)) rather than (700, 350) — the hit-test \
        would ask accessibility about a place the click was not
        """)
}

/// The same click against the whole display denormalises somewhere else entirely, which is
/// what the old code did for a window recording. Kept as the negative control: without it the
/// test above passes on any pair of functions that agree with each other, including two that
/// are both wrong.
@Test func theSameClickAgainstTheWholeDisplayLandsSomewhereElse() throws {
    let window = windowViewport()
    let normalised = try #require(window.normalise(globalTopLeftX: 700, globalTopLeftY: 350))
    let asDisplay = try #require(Capture.AXObserver.globalPoint(of: normalised,
                                                                revision: viewport().revision,
                                                                in: viewport()))
    let apart = ((asDisplay.x - 700) * (asDisplay.x - 700)
                 + (asDisplay.y - 350) * (asDisplay.y - 350)).squareRoot()
    #expect(apart > 100, """
        denormalising a window-normalised click against the whole display landed \(apart) points \
        from the truth; if that is small this fixture cannot show the defect
        """)
}

/// An element's frame and the click that found it come back in the SAME space, so
/// `AXChainRecord.clickContainment` can compare them at all. This is the half `FramingGate`
/// reads, and the half that made every window-mode chain answer `doesNotContainTheClick`.
@Test func anElementAroundTheClickContainsItInTheWindowsOwnSpace() throws {
    let window = windowViewport()
    let click = try #require(window.normalise(globalTopLeftX: 700, globalTopLeftY: 350))
    // A 100×80 point element whose top-left is 20 points up and left of the click.
    let frame = try #require(Capture.AXObserver.normalizedFrame(
        globalTopLeftX: 680, globalTopLeftY: 330, width: 100, height: 80, in: window))
    #expect(frame.minX <= click.x && click.x <= frame.maxX)
    #expect(frame.minY <= click.y && click.y <= frame.maxY)
    #expect(frame.revision == window.revision)
}

/// A viewport that has moved on — the window was followed onto another display — refuses an
/// old click rather than hit-testing it against the new rectangle. `nil` is counted as
/// `clicksWithNoGlobalPoint`; a guess would be a real-looking element from a place the click
/// was never on.
@Test func aClickFromAnotherRevisionHasNoGlobalPoint() {
    let other = CaptureViewport(
        geometry: DisplayGeometry(displayUUID: UUID(uuidString: "F1E2D3C4-B5A6-4978-8A9B-0C1D2E3F4A5B")!,
                                  pixelWidth: 1000, pixelHeight: 800, scale: 1.0),
        globalOriginX: 0, globalOriginY: 0, widthInPoints: 1000, heightInPoints: 800)
    let point = Capture.AXObserver.globalPoint(of: NormalizedPoint(x: 0.5, y: 0.5),
                                                revision: revision(), in: other)
    #expect(point == nil)
}

/// The window observer follows its window, like the input observer does. A hit-test aimed at
/// where the window WAS is the same defect one move later.
@Test func theObserverFollowsItsWindow() {
    let ax = Capture.AXObserver(viewport: windowViewport(), epoch: epoch,
                                accessibilityIsGranted: { true })
    #expect(ax.currentViewport.globalOriginX == 500)
    let moved = CaptureViewport(geometry: windowViewport().geometry,
                                globalOriginX: 900, globalOriginY: 400,
                                widthInPoints: 400, heightInPoints: 300)
    ax.updateViewport(moved)
    #expect(ax.currentViewport.globalOriginX == 900)
}
