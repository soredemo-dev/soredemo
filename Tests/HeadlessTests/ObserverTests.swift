import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Headless

// The first `swift test` tests of the two observers, moved out of the app target in Phase
// 3A-3. `InputObserver`'s keyboard filter is this product's entire keystroke-privacy
// mechanism and had never been executed by anything automatic; `AXObserver`'s walk had a
// dependency-injection seam (`AXElementSource`) that existed specifically so it could be
// tested and, until now, nothing could link it to use one.

private let epoch = BootEpoch(id: UUID(uuidString: "5D2A9C31-77E4-4B08-9A6F-1C0E3B5A8D42")!)
private let displayUUID = UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000001")!

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
        globalTopLeftX: 300, globalTopLeftY: 200, in: arrangement()))
    #expect(result.position.x > 0 && result.position.x < 1)
    #expect(result.position.y > 0 && result.position.y < 1)
    #expect(result.revision == revision())
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
        globalTopLeftX: 300, globalTopLeftY: 50, in: arrangement()))
    let nearBottom = try #require(InputObserver.normalizedPosition(
        globalTopLeftX: 300, globalTopLeftY: 450, in: arrangement()))
    #expect(nearTop.position.y > 0.5)
    #expect(nearBottom.position.y < 0.5)
}

/// A point on no display routes nowhere. `nil`, not a clamped edge value: a clamp would
/// put a real-looking coordinate in the log for an event that happened off-screen.
@Test func aPointOnNoDisplayRoutesToNothing() {
    #expect(InputObserver.normalizedPosition(globalTopLeftX: 99_999, globalTopLeftY: 99_999,
                                             in: arrangement()) == nil)
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

/// `Headless.AXObserver`, qualified: ApplicationServices exports a C type of the same
/// name, and an unqualified reference is ambiguous wherever both are in scope.
private func observer() -> Headless.AXObserver {
    Headless.AXObserver(arrangement: arrangement(), epoch: epoch,
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
