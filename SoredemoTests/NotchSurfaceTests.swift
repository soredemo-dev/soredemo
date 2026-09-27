import Foundation
import Geometry
import Testing
@testable import Soredemo

// The notch surface: its states, and where each one is on every Mac shape.
//
// **Properties, not golden rectangles.** The notch is a fixed number of pixels, so its size in
// points moves with every scaled mode — 117 to 220 points wide on one 14-inch panel alone — and a
// test that knew "185" would pass on one machine for the wrong reason. The matrix is the one the
// withdrawn notch transition was checked against (`e2b7863^`), restored.

private struct Mac: Sendable {
    let name: String
    let width: Double
    let height: Double
    let safeAreaTop: Double
    let aux: (left: Double, right: Double)?

    nonisolated var metrics: ScreenMetrics {
        ScreenMetrics(frame: PointRect(x: 0, y: 0, width: width, height: height),
                      safeAreaTop: safeAreaTop,
                      auxiliaryLeftWidth: aux?.left, auxiliaryRightWidth: aux?.right)
    }
}

nonisolated private func notched(_ name: String, _ width: Double, _ height: Double, top: Double,
                     fraction: Double = 185.0 / 1512.0) -> Mac {
    let side = (width - width * fraction) / 2
    return Mac(name: name, width: width, height: height, safeAreaTop: top, aux: (side, side))
}

nonisolated private func plain(_ name: String, _ width: Double, _ height: Double) -> Mac {
    Mac(name: name, width: width, height: height, safeAreaTop: 0, aux: nil)
}

nonisolated private let notchedMacs: [Mac] = [
    notched("MacBook Pro 14 (1512x982)", 1512, 982, top: 32),
    notched("…scaled 960x600", 960, 600, top: 20),
    notched("…scaled 1147x716", 1147, 716, top: 24),
    notched("…scaled 1280x800", 1280, 800, top: 27),
    notched("…scaled 1800x1169", 1800, 1169, top: 38),
    notched("MacBook Pro 16 (1728x1117)", 1728, 1117, top: 32),
    notched("MacBook Air 13 M2 (1470x956)", 1470, 956, top: 32),
    notched("MacBook Air 15 (1710x1112)", 1710, 1112, top: 32),
]

nonisolated private let plainMacs: [Mac] = [
    plain("MacBook Pro 14, notch excluded (1512x945)", 1512, 945),
    plain("external 1920x1080", 1920, 1080),
    plain("external 3440x1440 ultrawide", 3440, 1440),
    plain("external 2560x1440", 2560, 1440),
    plain("MacBook Air 13 Intel (1440x900)", 1440, 900),
]

private let everyState: [NotchSurfaceState] = [
    .dormant, .glance, .open, .live(expanded: false), .live(expanded: true),
]

// MARK: - which screens have a notch

@Test(arguments: notchedMacs.map(\.name))
func aNotchedScreenReportsItsNotch(name: String) throws {
    let mac = try #require(notchedMacs.first { $0.name == name })
    let notch = try #require(mac.metrics.notch, "\(name) reported no notch")
    #expect(notch.y == 0 && notch.height == mac.safeAreaTop)
    #expect(abs((notch.x + notch.width / 2) - mac.width / 2) < 0.5, "not centred on \(name)")
}

@Test(arguments: plainMacs.map(\.name))
func aScreenWithoutAuxiliaryAreasHasNoNotch(name: String) throws {
    let mac = try #require(plainMacs.first { $0.name == name })
    #expect(mac.metrics.notch == nil)
}

/// One auxiliary area and a top inset is not a notch — deciding from the inset alone would say it is.
@Test func oneAuxiliaryAreaIsNotANotch() {
    let screen = ScreenMetrics(frame: PointRect(x: 0, y: 0, width: 1512, height: 982),
                               safeAreaTop: 32, auxiliaryLeftWidth: 663, auxiliaryRightWidth: nil)
    #expect(screen.notch == nil)
}

// MARK: - the states

@Test func thePointerOnTheNotchWakesItAndLeavingPutsItBack() {
    #expect(NotchSurfaceState.dormant.handling(.pointerEntered) == .glance)
    #expect(NotchSurfaceState.glance.handling(.pointerLeft) == .dormant)
}

@Test func aClickOpensTheRecorderFromTheNotchWhetherOrNotItWasHovered() {
    #expect(NotchSurfaceState.glance.handling(.clicked) == .open)
    #expect(NotchSurfaceState.dormant.handling(.clicked) == .open)
}

/// **Open survives the pointer leaving.** Its pickers open menus, and a menu is outside the
/// surface: closing on pointer-left would close the recorder under the menu somebody just opened.
@Test func theOpenRecorderStaysOpenWhenThePointerLeavesAndClosesOnAClickOutsideOrEscape() {
    #expect(NotchSurfaceState.open.handling(.pointerLeft) == .open)
    #expect(NotchSurfaceState.open.handling(.clickedOutside) == .dormant)
    #expect(NotchSurfaceState.open.handling(.escape) == .dormant)
}

@Test func aTakeTurnsAnyStateLiveAndItsEndPutsTheNotchBack() {
    for state in [NotchSurfaceState.dormant, .glance, .open] {
        #expect(state.handling(.recordingBegan) == .live(expanded: false), "from \(state)")
    }
    #expect(NotchSurfaceState.live(expanded: true).handling(.recordingEnded) == .dormant)
    #expect(NotchSurfaceState.live(expanded: false).handling(.recordingEnded) == .dormant)
}

/// During a take the pointer only reveals the controls; a click, a click outside or escape must
/// not end or hide the live state, because nothing else on screen says a recording is running.
@Test func duringATakeThePointerExpandsTheControlsAndNothingElseLeavesLive() {
    #expect(NotchSurfaceState.live(expanded: false).handling(.pointerEntered) == .live(expanded: true))
    #expect(NotchSurfaceState.live(expanded: true).handling(.pointerLeft) == .live(expanded: false))
    for event in [NotchSurfaceState.Event.clicked, .clickedOutside, .escape] {
        #expect(NotchSurfaceState.live(expanded: true).handling(event) == .live(expanded: true), "\(event)")
        #expect(NotchSurfaceState.live(expanded: false).handling(event) == .live(expanded: false), "\(event)")
    }
}

/// Events that do not apply leave the state alone — a recording ending while dormant is a no-op,
/// not a reason to invent a state.
@Test func anEventThatDoesNotApplyChangesNothing() {
    #expect(NotchSurfaceState.dormant.handling(.recordingEnded) == .dormant)
    #expect(NotchSurfaceState.dormant.handling(.pointerLeft) == .dormant)
    #expect(NotchSurfaceState.glance.handling(.pointerEntered) == .glance)
}

// MARK: - where each state is

private func rects(on mac: Mac) throws -> [(NotchSurfaceState, PointRect)] {
    let notch = try #require(mac.metrics.notch)
    return everyState.map { ($0, NotchSurfaceLayout.rect(for: $0, notch: notch, screen: mac.metrics.frame)) }
}

@Test(arguments: notchedMacs.map(\.name))
func everyStateHangsFromTheTopOfTheScreenCentredOnTheNotchAndInsideTheScreen(name: String) throws {
    let mac = try #require(notchedMacs.first { $0.name == name })
    let notch = try #require(mac.metrics.notch)
    for (state, rect) in try rects(on: mac) {
        #expect(rect.y == 0, "\(state) on \(name) does not start at the top")
        #expect(abs((rect.x + rect.width / 2) - (notch.x + notch.width / 2)) < 0.5, "\(state) not centred")
        #expect(rect.x >= 0 && rect.x + rect.width <= mac.width, "\(state) leaves \(name)")
        #expect(rect.width >= notch.width && rect.height >= notch.height, "\(state) is smaller than the notch")
    }
}

@Test(arguments: notchedMacs.map(\.name))
func dormantIsTheNotchAndTheOtherStatesAreLargerThanIt(name: String) throws {
    let mac = try #require(notchedMacs.first { $0.name == name })
    let notch = try #require(mac.metrics.notch)
    let all = Dictionary(uniqueKeysWithValues: try rects(on: mac).map { ("\($0.0)", $0.1) })
    #expect(all["dormant"] == notch)
    for state in ["glance", "open", "live(expanded: false)", "live(expanded: true)"] {
        #expect((all[state]?.width ?? 0) > notch.width, "\(state) on \(name) is no wider than the notch")
    }
    // Glance is a hint and open is the recorder: open holds glance.
    let glance = try #require(all["glance"]), open = try #require(all["open"])
    #expect(open.width >= glance.width && open.height > glance.height)
}

/// **A take's own surface never comes down over what is being recorded.** Compact live is the
/// notch's height exactly; only the pointer's presence expands it.
@Test(arguments: notchedMacs.map(\.name))
func compactLiveIsNeverTallerThanTheNotch(name: String) throws {
    let mac = try #require(notchedMacs.first { $0.name == name })
    let notch = try #require(mac.metrics.notch)
    let live = NotchSurfaceLayout.rect(for: .live(expanded: false), notch: notch, screen: mac.metrics.frame)
    let expanded = NotchSurfaceLayout.rect(for: .live(expanded: true), notch: notch, screen: mac.metrics.frame)
    #expect(live.height == notch.height)
    #expect(expanded.height > notch.height)
}

/// The wings scale with the notch: on the smallest scaled mode they are proportionally the same
/// share of the notch as on the largest, so nothing is a fixed number of points.
@Test func theWingsAreAShareOfTheNotchNotANumberOfPoints() throws {
    let small = try #require(notchedMacs.first { $0.name.contains("960x600") })
    let large = try #require(notchedMacs.first { $0.name.contains("1800x1169") })
    func wing(_ mac: Mac) throws -> Double {
        let notch = try #require(mac.metrics.notch)
        let glance = NotchSurfaceLayout.rect(for: .glance, notch: notch, screen: mac.metrics.frame)
        return (glance.width - notch.width) / 2 / notch.height
    }
    // Positive first: two zero-width wings are "the same share" and say nothing.
    #expect(try wing(small) > 1, "the glance has no wings to compare")
    #expect(abs(try wing(small) - (try wing(large))) < 0.01)
}

// MARK: - the pointer

private let pointerNotch = PointRect(x: 663.5, y: 0, width: 185, height: 32)
private let pointerScreen = PointRect(x: 0, y: 0, width: 1512, height: 982)

private func event(_ x: Double, _ y: Double, _ state: NotchSurfaceState) -> NotchSurfaceState.Event? {
    NotchSurfacePointer.event(atX: x, y: y, state: state, notch: pointerNotch,
                              surface: NotchSurfaceLayout.rect(for: state, notch: pointerNotch, screen: pointerScreen))
}

@Test func thePointerOnTheNotchWakesADormantOrCompactSurfaceAndAwayFromItDoesNothing() {
    #expect(event(756, 6, .dormant) == .pointerEntered)
    #expect(event(756, 0, .dormant) == .pointerEntered, "the very top edge is on the notch")
    #expect(event(756, 6, .live(expanded: false)) == .pointerEntered)
    #expect(event(200, 400, .dormant) == nil)
    #expect(event(200, 400, .live(expanded: false)) == nil)
}

/// **The hysteresis.** A point in the glance's wing is NOT on the notch — it would not wake a
/// dormant surface — and it must not count as leaving a glance, or the wing a person moves into
/// to click "Record" would close under them.
@Test func aPointInTheWingNeitherWakesTheNotchNorLeavesTheGlance() {
    let wing = (x: 663.5 - 40, y: 16.0)
    #expect(event(wing.x, wing.y, .dormant) == nil, "the wing is not the notch")
    #expect(event(wing.x, wing.y, .glance) == nil, "and being in it is not leaving")
    #expect(event(200, 400, .glance) == .pointerLeft)
}

@Test func leavingTheExpandedTakeCollapsesItAndTheOpenRecorderIgnoresThePointer() {
    #expect(event(756, 60, .live(expanded: true)) == nil, "inside the expanded controls")
    #expect(event(200, 400, .live(expanded: true)) == .pointerLeft)
    #expect(event(200, 400, .open) == nil, "open closes on a click outside, not on the pointer")
    #expect(event(756, 6, .open) == nil)
}
