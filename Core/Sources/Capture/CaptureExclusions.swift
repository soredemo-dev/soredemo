// `@unsafe` because `@preconcurrency` suppresses the concurrency checking that would otherwise
// catch a data race across this import — required by `.strictMemorySafety()`. The same mark
// `CaptureSource.swift` carries, for the same reason: `SCWindow` and `SCRunningApplication` are
// only ever read here, never mutated, and every use is on one task.
@preconcurrency @unsafe import ScreenCaptureKit
import CoreGraphics
import Foundation

/// What macOS furniture is kept out of a recording: the Dock, the menu bar.
///
/// Nothing here changes the machine — both are excluded from the CAPTURE, so they
/// keep working while somebody records and are simply not in the picture. A
/// WINDOW capture needs none of it: `SCContentFilter(desktopIndependentWindow:)`
/// excludes both by construction.
///
/// The three mechanisms that were measured and rejected, and the wallpaper trap
/// that shapes `resolve()`, are in `docs/design/hiding-macos-furniture.md`.
public struct CaptureExclusions: Sendable, Equatable, Hashable, Codable {
    /// Whether the Dock should be kept out of the picture.
    public var hidesDock: Bool

    /// Whether the menu bar — and the status items in it — should be kept out.
    /// Measured: it takes the items with it and does not change `contentRect`.
    public var hidesMenuBar: Bool

    /// Whether the desktop widgets — the weather, the calendar, the battery ring —
    /// should be kept out.
    ///
    /// **Widgets are a row of small disclosures nobody meant to publish**: what is
    /// in somebody's calendar for the afternoon, where they are, what their
    /// battery is doing. A recording of the desktop shows all of it.
    ///
    /// Costs a window query, like the Dock, so it is part of `wantsAnything`.
    public var hidesDesktopWidgets: Bool

    /// Whether notification banners — and Notification Center itself — should be kept out.
    ///
    /// **A banner is the disclosure nobody chose to make**: a message's sender and first line,
    /// arriving mid-take over whatever was being demonstrated. Excluded from the capture rather
    /// than silenced — there is no public API to turn Focus on — so the person still sees it and
    /// the video does not. `docs/design/2026-09-30-before-and-during-a-take.md`.
    public var hidesNotifications: Bool

    public init(hidesDock: Bool = false, hidesMenuBar: Bool = false,
                hidesDesktopWidgets: Bool = false, hidesNotifications: Bool = false) {
        self.hidesDock = hidesDock
        self.hidesMenuBar = hidesMenuBar
        self.hidesDesktopWidgets = hidesDesktopWidgets
        self.hidesNotifications = hidesNotifications
    }

    /// Nothing hidden — what a display capture uses unless somebody asked otherwise.
    public static let none = CaptureExclusions()

    /// Whether anything needing a WINDOW LIST is being asked for, read before the
    /// shareable-content query so nothing is paid for a feature nobody wants.
    ///
    /// The menu bar is deliberately not counted: it is a property on the filter,
    /// not an entry in an exclusion list, and counting it would send `resolve()`
    /// enumerating every window on the machine for an answer it does not need.
    public var wantsAnything: Bool { hidesDock || hidesDesktopWidgets || hidesNotifications }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A missing key is "not asked for" rather than a failure: this type is stored beside
        // older projects that predate it, and the honest reading of a file written before the
        // switch existed is that the switch was off.
        hidesDock = try container.decodeIfPresent(Bool.self, forKey: .hidesDock) ?? false
        hidesMenuBar = try container.decodeIfPresent(Bool.self, forKey: .hidesMenuBar) ?? false
        hidesDesktopWidgets = try container
            .decodeIfPresent(Bool.self, forKey: .hidesDesktopWidgets) ?? false
        hidesNotifications = try container
            .decodeIfPresent(Bool.self, forKey: .hidesNotifications) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case hidesDock, hidesMenuBar, hidesDesktopWidgets, hidesNotifications
    }
}

// MARK: - Which window is the Dock

/// The one window that IS the Dock, told apart from the ten others its process
/// owns.
///
/// A free predicate over two plain values rather than a method on `SCWindow`,
/// because `SCWindow` has no public initialiser and this rule has to be testable:
/// getting it wrong does not fail loudly, it silently blanks the desktop picture
/// in somebody's recording.
public enum DockWindow {
    /// The Dock's bundle identifier. Matched on the identifier rather than the localised
    /// application name, for the reason `CaptureSource.thisApplication` gives about names.
    public static let bundleIdentifier = "com.apple.dock"

    /// The window level the Dock sits at — the system's own answer, not a literal.
    /// Measured as 20 on macOS 26, against wallpaper at -2147483624 and backdrops
    /// at -2147483622, so the separation is not marginal.
    public static var level: Int { Int(CGWindowLevelForKey(.dockWindow)) }

    /// Whether a window owned by `bundleIdentifier` at `windowLayer` is the Dock itself.
    ///
    /// Both halves are required. The identifier alone catches the wallpaper; the level alone
    /// would catch any other application that happens to place a window at the Dock's level,
    /// and excluding somebody else's window from their own recording is worse than leaving the
    /// Dock in it.
    public static func isTheDock(bundleIdentifier: String?, windowLayer: Int) -> Bool {
        bundleIdentifier == Self.bundleIdentifier && windowLayer == Self.level
    }
}

// MARK: - Which windows are the desktop widgets

/// The desktop widgets, told apart from the notification UI drawn by the same
/// process.
///
/// Measured on macOS 26, with three widgets on the desktop:
///
///     layer -2147483601   360×360   "即將到來"            the calendar
///     layer -2147483601   360×180   "天氣預報"            the weather
///     layer -2147483601   360×180   "狀態"                the battery
///     layer          21  1512×982   "Notification Center"
///
/// One process owns both, so excluding the application would take the
/// notification panel with the widgets. The two are separated by SIGN rather than
/// by that measured level: a widget sits below every ordinary window and the
/// panel sits above the Dock, and a rule written as `windowLayer < 0` survives
/// Apple moving the exact number — which they have no published constant for, so
/// pinning -2147483601 would be pinning a value nothing promises.
public enum DesktopWidgetWindow {
    /// The process that draws both the desktop widgets and Notification Center.
    public static let bundleIdentifier = "com.apple.notificationcenterui"

    /// Whether a window owned by `bundleIdentifier` at `windowLayer` is a desktop
    /// widget rather than the notification UI.
    ///
    /// Both halves are required, for `DockWindow.isTheDock`'s reason. The
    /// identifier alone would take the notification panel; the sign alone would
    /// catch any other application's desktop-level window, and excluding somebody
    /// else's window from their own recording is worse than leaving a widget in.
    public static func isADesktopWidget(bundleIdentifier: String?, windowLayer: Int) -> Bool {
        bundleIdentifier == Self.bundleIdentifier && windowLayer < 0
    }

    /// Whether one of this process's windows comes back into a capture that excluded the process.
    ///
    /// **Each switch decides only its own half**: excluding the application takes the widgets
    /// and the notification UI together, and what comes back is whichever half was not asked to
    /// be hidden. Asked of windows owned by `bundleIdentifier` only.
    public static func comesBack(windowLayer: Int, hidingWidgets: Bool,
                                 hidingNotifications: Bool) -> Bool {
        isADesktopWidget(bundleIdentifier: bundleIdentifier, windowLayer: windowLayer)
            ? !hidingWidgets : !hidingNotifications
    }
}

// MARK: - Resolving against live content

extension CaptureExclusions {
    /// What `CaptureSource.filter(excluding:excepting:)` needs, plus what happened.
    public struct Resolution: Sendable {
        /// Applications whose windows are kept out of the picture.
        public let applications: [SCRunningApplication]
        /// Windows of those applications that come back into it — everything the Dock owns
        /// except the Dock.
        public let exceptedWindows: [SCWindow]
        /// What was actually done. Never inferred from an empty list: an empty
        /// `applications` means "the Dock was not found" and also "nothing was asked for",
        /// and a diagnostic that cannot tell those apart is not a diagnostic.
        public let outcome: Outcome
    }

    /// Why the Dock is or is not being excluded. **A named value in every case**, including the
    /// ones where nothing happens, so a recording that still shows the Dock has a reason
    /// attached to it rather than a silence.
    public enum Outcome: String, Sendable, Equatable, Hashable {
        /// Nobody asked for anything to be hidden.
        case notAsked
        /// The Dock is being kept out of the picture.
        case dockExcluded
        /// The shareable content could not be read — no Screen Recording grant, most likely.
        /// The recording goes ahead with the Dock in it, which is the same picture the person
        /// would have had before this feature existed.
        case contentUnavailable
        /// The content was readable and the Dock was not in it. Vanishingly unlikely on a Mac
        /// with a Dock, and reported rather than folded into `contentUnavailable` because the
        /// two have different causes and only one of them is a permission problem.
        case dockNotRunning
        /// Desktop widgets were the only thing asked for, and they are being kept
        /// out. Named separately from `dockExcluded` so a recording that still
        /// shows the Dock cannot report that the Dock was excluded.
        case desktopWidgetsExcluded
        /// Notifications were asked for without the Dock or the widgets, and are being kept
        /// out. Its own name for `desktopWidgetsExcluded`'s reason.
        case notificationsExcluded
    }

    /// Resolves against the live window list.
    ///
    /// Needs the Screen Recording grant, which is not a new demand: a display
    /// capture cannot start without it, so by the time this runs the answer is
    /// already yes. Asked only when something was actually asked for.
    public func resolve() async -> Resolution {
        guard wantsAnything else {
            return Resolution(applications: [], exceptedWindows: [], outcome: .notAsked)
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false) else {
            return Resolution(applications: [], exceptedWindows: [], outcome: .contentUnavailable)
        }
        var applications: [SCRunningApplication] = []
        var kept: [SCWindow] = []
        var outcome = Outcome.notAsked

        if hidesDock {
            guard let dock = content.applications.first(where: {
                $0.bundleIdentifier == DockWindow.bundleIdentifier
            }) else {
                return Resolution(applications: [], exceptedWindows: [], outcome: .dockNotRunning)
            }
            applications.append(dock)
            // Everything the Dock owns EXCEPT the Dock — see the header on the
            // wallpaper.
            kept += content.windows.filter {
                $0.owningApplication?.bundleIdentifier == DockWindow.bundleIdentifier
                    && !DockWindow.isTheDock(bundleIdentifier: DockWindow.bundleIdentifier,
                                             windowLayer: $0.windowLayer)
            }
            outcome = .dockExcluded
        }

        if hidesDesktopWidgets || hidesNotifications {
            // Not a failure when the process is missing: a Mac with no widgets on
            // the desktop has nothing to hide, and the recording is exactly what
            // was asked for. Only the Dock's absence is reported, because a Mac
            // without a Dock is a Mac something is wrong with.
            if let notificationCenter = content.applications.first(where: {
                $0.bundleIdentifier == DesktopWidgetWindow.bundleIdentifier
            }) {
                // **By application, so a banner drawn after the filter is built is still out.**
                // What comes back is only the half that was not asked to be hidden — a person
                // demonstrating Notification Center with only the widgets hidden is still
                // demonstrating Notification Center. The excepted list is fixed when the filter
                // is built, so a NEW window of this process stays out either way.
                applications.append(notificationCenter)
                kept += content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == DesktopWidgetWindow.bundleIdentifier
                        && DesktopWidgetWindow.comesBack(windowLayer: $0.windowLayer,
                                                         hidingWidgets: hidesDesktopWidgets,
                                                         hidingNotifications: hidesNotifications)
                }
                if outcome == .notAsked {
                    outcome = hidesDesktopWidgets ? .desktopWidgetsExcluded : .notificationsExcluded
                }
            }
        }

        return Resolution(applications: applications, exceptedWindows: kept, outcome: outcome)
    }
}
