import Foundation
import Testing
@testable import Capture

/// **The rule that decides which of the Dock's eleven windows IS the Dock.**
///
/// `SCWindow` has no public initialiser, so the live half of this cannot be built here and the
/// rule was kept as a free predicate over two plain values precisely so that this file could
/// exist. The case that matters is not the Dock — it is the five windows titled
/// `Wallpaper-<UUID>` that the same process owns. Getting those wrong does not fail loudly; it
/// silently blanks the desktop picture in somebody's recording, which is the kind of defect that
/// is found by a viewer rather than by a developer.
///
/// The window levels below are the ones measured on this machine on 2026-08-29, printed from a
/// live `SCShareableContent`:
///
///     layer           20   1512x982   onScreen=Y  title Dock
///     layer  -2147483624   1512x982   onScreen=Y  title Wallpaper-
///     layer  -2147483624   1512x982   onScreen=n  title Wallpaper-051B30CB-…   (and four more)
///     layer  -2147483622   1512x982   onScreen=n  title Fullscreen Backdrop    (and three more)
@Suite("Which window is the Dock")
struct DockWindowTests {
    /// **Pinned to 20, deliberately.** `DockWindow.level` asks the system
    /// (`CGWindowLevelForKey(.dockWindow)`) rather than hard-coding it, which is the right way to
    /// ask — but a level that changed under us would turn the whole feature into a silent no-op,
    /// and a silent no-op is exactly what this project does not ship. If macOS ever moves the
    /// Dock, this goes red and somebody re-measures instead of a person wondering why a switch
    /// they turned on did nothing.
    @Test("the Dock's window level is the one every measurement here was taken at")
    func theDockLevelIsTwenty() {
        #expect(DockWindow.level == 20)
    }

    @Test("the Dock itself is the Dock")
    func theDockIsTheDock() {
        #expect(DockWindow.isTheDock(bundleIdentifier: "com.apple.dock", windowLayer: 20))
    }

    /// The five wallpaper windows. If these were excluded with the Dock, the recording would
    /// have no desktop picture — measured as a real risk, not a hypothetical one.
    @Test("the wallpaper windows the Dock also owns are not the Dock")
    func wallpaperIsNotTheDock() {
        #expect(!DockWindow.isTheDock(bundleIdentifier: "com.apple.dock",
                                      windowLayer: -2_147_483_624))
    }

    @Test("the full-screen backdrops the Dock also owns are not the Dock")
    func backdropsAreNotTheDock() {
        #expect(!DockWindow.isTheDock(bundleIdentifier: "com.apple.dock",
                                      windowLayer: -2_147_483_622))
    }

    /// **The identifier is required as well as the level**, and this is the case that says why:
    /// excluding somebody else's window from their own recording because it happens to sit at
    /// the Dock's level is worse than leaving the Dock in the picture.
    @Test("another application's window at the Dock's level is not the Dock")
    func somebodyElseAtTheSameLevelIsNotTheDock() {
        #expect(!DockWindow.isTheDock(bundleIdentifier: "com.example.someLauncher",
                                      windowLayer: 20))
    }

    /// `SCWindow.owningApplication` is optional, so this is reachable rather than defensive.
    @Test("a window with no owning application is not the Dock")
    func anUnownedWindowIsNotTheDock() {
        #expect(!DockWindow.isTheDock(bundleIdentifier: nil, windowLayer: 20))
    }

    /// Every level the Dock's own process was measured at, in one sweep — so a rule that
    /// widened to "anything the Dock owns" fails here rather than in a recording.
    @Test("of the levels the Dock's process was measured at, exactly one is the Dock")
    func exactlyOneMeasuredLevelIsTheDock() {
        let measured = [20, -2_147_483_624, -2_147_483_622]
        let matches = measured.filter {
            DockWindow.isTheDock(bundleIdentifier: "com.apple.dock", windowLayer: $0)
        }
        #expect(matches == [20])
    }
}

/// The switch itself: what it costs when it is off, what it promises when it is on, and what it
/// does with a project written before it existed.
@Suite("Capture exclusions")
struct CaptureExclusionsTests {
    @Test("nothing hidden is the default, and it asks the system for nothing")
    func noneWantsNothing() {
        #expect(CaptureExclusions.none.hidesDock == false)
        #expect(CaptureExclusions.none.hidesMenuBar == false)
        #expect(CaptureExclusions.none.wantsAnything == false)
        #expect(CaptureExclusions() == CaptureExclusions.none)
    }

    /// **The menu bar deliberately does not make `wantsAnything` true**, and getting this
    /// backwards would be invisible: everything would still work, and every recording with the
    /// menu bar hidden would quietly enumerate every window on the machine to answer a question
    /// that is settled by a property on the filter. `SCContentFilter.includeMenuBar` needs no
    /// window list, so hiding the menu bar must cost no query.
    @Test("hiding the menu bar needs no window list, so it asks the system for nothing")
    func hidingTheMenuBarNeedsNoQuery() {
        let menuBarOnly = CaptureExclusions(hidesMenuBar: true)
        #expect(menuBarOnly.hidesMenuBar)
        #expect(!menuBarOnly.wantsAnything)
    }

    /// And the query is really skipped: asked for the menu bar alone, `resolve()` reports that
    /// nothing was asked of the WINDOW LIST rather than going and reading one.
    @Test("resolving a menu-bar-only request reports that no window list was needed")
    func resolvingAMenuBarOnlyRequestAsksNothing() async {
        let resolution = await CaptureExclusions(hidesMenuBar: true).resolve()
        #expect(resolution.outcome == .notAsked)
        #expect(resolution.applications.isEmpty)
    }

    @Test("asking for the Dock to be hidden is asking for something")
    func hidingTheDockWantsSomething() {
        #expect(CaptureExclusions(hidesDock: true).wantsAnything)
    }

    /// **The query is skipped, not just ignored.** `resolve()` reads `wantsAnything` before it
    /// touches `SCShareableContent`, so a person with the switch off pays nothing for a feature
    /// they did not ask for — and this is the check that says the early return is still there.
    /// It also has to be `.notAsked` rather than `.contentUnavailable`: this test process has no
    /// Screen Recording grant, so a `resolve()` that queried anyway would come back with the
    /// wrong reason and the diagnostic would blame a permission for a switch nobody flipped.
    @Test("with nothing asked for, resolving asks the system nothing and says so")
    func resolvingNothingAsksNothing() async {
        // Named rather than inferred: `Resolution` is the value the capture filter is built out
        // of, and all three of its fields are checked below. The entry-rule scan wants the name
        // in a test; what makes that honest here is the three lines after it, not the annotation.
        let resolution: CaptureExclusions.Resolution = await CaptureExclusions.none.resolve()
        #expect(resolution.outcome == .notAsked)
        #expect(resolution.applications.isEmpty)
        #expect(resolution.exceptedWindows.isEmpty)
    }

    /// **Whatever the machine answers, the answer is named.**
    ///
    /// This cannot assert `.dockExcluded`: a test process has no Screen Recording grant, so on a
    /// clean machine the honest result is `.contentUnavailable`, while on a developer's Mac that
    /// has granted the terminal it may well be `.dockExcluded`. Asserting either would make this
    /// test a report on the machine rather than on the code. What holds everywhere is the
    /// invariant the `Outcome` type exists for: having been asked, the answer is never
    /// `.notAsked` — a recording that still shows the Dock always has a reason attached to it
    /// instead of a silence.
    @Test("having been asked, the outcome is never the one that means nobody asked")
    func askingAlwaysProducesAReason() async {
        let resolution: CaptureExclusions.Resolution
            = await CaptureExclusions(hidesDock: true).resolve()
        #expect(resolution.outcome != .notAsked)
        // And an empty exclusion list is never reported as a success.
        if resolution.outcome == .dockExcluded {
            #expect(!resolution.applications.isEmpty)
        } else {
            #expect(resolution.applications.isEmpty)
        }
    }

    /// **A project written before this switch existed reads as "off", not as a failure.** The
    /// alternative — a required key — would refuse to open every project made before today, to
    /// learn a fact whose absence already means exactly one thing.
    @Test("a stored value from before the switch existed decodes as off")
    func anOlderProjectDecodesAsOff() throws {
        let decoded = try JSONDecoder().decode(CaptureExclusions.self, from: Data("{}".utf8))
        #expect(decoded == .none)
    }

    @Test("the switch survives a round trip")
    func roundTrips() throws {
        for value in [CaptureExclusions.none,
                      CaptureExclusions(hidesDock: true),
                      CaptureExclusions(hidesMenuBar: true),
                      CaptureExclusions(hidesDock: true, hidesMenuBar: true)] {
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(CaptureExclusions.self, from: data) == value)
        }
    }

    /// A stored value of the wrong type is refused rather than quietly read as `false`, which
    /// would be indistinguishable from a project that never had the switch on.
    @Test("a stored value of the wrong type is refused")
    func aWrongTypeIsRefused() {
        for json in [#"{"hidesDock": "yes"}"#, #"{"hidesMenuBar": 1}"#] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(CaptureExclusions.self, from: Data(json.utf8))
            }
        }
    }

    /// **Every field must be in the decoder, and forgetting one is silent.** A field added to the
    /// type and not to `init(from:)` reads back as its default on every project ever saved, with
    /// nothing to see. Walked with a `Mirror` so the next field is covered before it is written.
    @Test("every field of the type survives being written and read back")
    func everyFieldSurvivesTheRoundTrip() throws {
        let all = CaptureExclusions(hidesDock: true, hidesMenuBar: true)
        let decoded = try JSONDecoder().decode(CaptureExclusions.self,
                                               from: try JSONEncoder().encode(all))
        func fields(of value: CaptureExclusions) -> [String: String] {
            var found: [String: String] = [:]
            for child in Mirror(reflecting: value).children where child.label != nil {
                found[child.label!] = String(describing: child.value)
            }
            return found
        }
        #expect(fields(of: decoded) == fields(of: all))
        // A guard on the guard: reflection that saw no fields would pass the line above while
        // checking nothing at all.
        #expect(fields(of: all).count >= 2)
    }
}

// MARK: - the desktop widgets

/// **The sign is the discriminator, not the level.** Measured on macOS 26 with three widgets
/// on the desktop, one process draws both them and Notification Center:
///
///     layer -2147483601   360×360   the calendar
///     layer -2147483601   360×180   the weather
///     layer -2147483601   360×180   the battery
///     layer          21  1512×982   Notification Center
///
/// Excluding the application takes both, so the panel has to come back — and it is separated
/// by SIGN rather than by that measured number, which has no published constant behind it.
@Test func aDesktopWidgetIsToldApartFromTheNotificationPanel() {
    let widgets = DesktopWidgetWindow.bundleIdentifier
    // The three measured widget layers, and the panel's.
    #expect(DesktopWidgetWindow.isADesktopWidget(bundleIdentifier: widgets,
                                                 windowLayer: -2_147_483_601))
    #expect(DesktopWidgetWindow.isADesktopWidget(bundleIdentifier: widgets, windowLayer: 21)
            == false, "the notification panel was taken for a widget")
    // A level Apple might move it to, still below every ordinary window.
    #expect(DesktopWidgetWindow.isADesktopWidget(bundleIdentifier: widgets, windowLayer: -5),
            "the rule pinned one measured level instead of the sign")
}

/// Both halves are required, for `DockWindow.isTheDock`'s reason: excluding somebody else's
/// desktop-level window from their own recording is worse than leaving a widget in.
@Test func anotherApplicationsDesktopWindowIsNotAWidget() {
    #expect(DesktopWidgetWindow.isADesktopWidget(bundleIdentifier: "com.example.wallpaper",
                                                 windowLayer: -2_147_483_601) == false)
    #expect(DesktopWidgetWindow.isADesktopWidget(bundleIdentifier: nil,
                                                 windowLayer: -2_147_483_601) == false)
}

/// Widgets cost a window query, so they belong in `wantsAnything` — unlike the menu bar,
/// which is a property on the filter and needs no list. A person who wants nothing hidden
/// still pays for nothing.
@Test func askingForWidgetsCostsTheQueryAndAskingForTheMenuBarDoesNot() {
    #expect(CaptureExclusions.none.wantsAnything == false)
    #expect(CaptureExclusions(hidesMenuBar: true).wantsAnything == false)
    #expect(CaptureExclusions(hidesDesktopWidgets: true).wantsAnything)
    #expect(CaptureExclusions(hidesDock: true).wantsAnything)
}

/// A project written before this switch existed opens with it off, which is the honest
/// reading of a file made when the switch did not exist.
@Test func aProjectWithoutTheWidgetSwitchDecodesWithItOff() throws {
    let older = Data(#"{"hidesDock":true,"hidesMenuBar":true}"#.utf8)
    let decoded = try JSONDecoder().decode(CaptureExclusions.self, from: older)
    #expect(decoded.hidesDock)
    #expect(decoded.hidesMenuBar)
    #expect(decoded.hidesDesktopWidgets == false)

    // And it survives its own round trip once it is set.
    let asked = CaptureExclusions(hidesDock: false, hidesMenuBar: false,
                                  hidesDesktopWidgets: true)
    let coded = try JSONDecoder().decode(CaptureExclusions.self,
                                         from: try JSONEncoder().encode(asked))
    #expect(coded == asked)
}
