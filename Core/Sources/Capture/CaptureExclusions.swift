// `@unsafe` because `@preconcurrency` suppresses the concurrency checking that would otherwise
// catch a data race across this import — required by `.strictMemorySafety()`. The same mark
// `CaptureSource.swift` carries, for the same reason: `SCWindow` and `SCRunningApplication` are
// only ever read here, never mutated, and every use is on one task.
@preconcurrency @unsafe import ScreenCaptureKit
import CoreGraphics
import Foundation

/// What macOS furniture is kept out of a recording: the Dock, the menu bar.
///
/// Nothing here changes the machine. The Dock and the menu bar are excluded from the CAPTURE, so
/// they stay where they are, keep working while somebody records, and are simply not in the
/// picture — no preference written, no process killed, no permission asked for, and no restore
/// owed. A **window** capture needs none of it: `SCContentFilter(desktopIndependentWindow:)`
/// excludes both by construction.
///
/// `resolve()` turns this into the arguments `CaptureSource.filter` wants. It costs nothing when
/// nothing is asked for.
///
/// See `docs/design/hiding-macos-furniture.md` for the three mechanisms that were measured and
/// rejected, and for the wallpaper trap that shapes `resolve()`.
public struct CaptureExclusions: Sendable, Equatable, Hashable, Codable {
    /// Whether the Dock should be kept out of the picture.
    public var hidesDock: Bool

    /// Whether the menu bar — and the twelve status items in it — should be kept out.
    ///
    /// **Not part of `wantsAnything`.** This is a property on the filter rather than an entry in
    /// an exclusion list, so it needs no window list and must not send `resolve()` looking for
    /// one. Measured: it takes the menu bar's items with it and does not change `contentRect`.
    public var hidesMenuBar: Bool

    public init(hidesDock: Bool = false, hidesMenuBar: Bool = false) {
        self.hidesDock = hidesDock
        self.hidesMenuBar = hidesMenuBar
    }

    /// Nothing hidden — what a display capture uses unless somebody asked otherwise.
    public static let none = CaptureExclusions()

    /// Whether anything needing a WINDOW LIST is being asked for. Read before the
    /// shareable-content query, so a person who wants nothing hidden pays nothing for the feature.
    ///
    /// **The menu bar is deliberately not counted here.** It is a property on the filter, not an
    /// entry in an exclusion list, so hiding it costs no query — and counting it would make
    /// `resolve()` go and enumerate every window on the machine to answer a question that does
    /// not need the answer.
    public var wantsAnything: Bool { hidesDock }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A missing key is "not asked for" rather than a failure: this type is stored beside
        // older projects that predate it, and the honest reading of a file written before the
        // switch existed is that the switch was off.
        hidesDock = try container.decodeIfPresent(Bool.self, forKey: .hidesDock) ?? false
        hidesMenuBar = try container.decodeIfPresent(Bool.self, forKey: .hidesMenuBar) ?? false
    }

    private enum CodingKeys: String, CodingKey { case hidesDock, hidesMenuBar }
}

// MARK: - Which window is the Dock

/// **The one window that IS the Dock**, told apart from the ten others its process owns.
///
/// Kept as a free predicate over two plain values rather than a method on `SCWindow` so that it
/// can be tested. `SCWindow` has no public initialiser — a rule that says "exclude the Dock" and
/// is only exercised against the live Dock is a rule nobody can show is right, and the wallpaper
/// windows are the case that matters: getting this wrong does not fail loudly, it silently blanks
/// the desktop picture in somebody's recording.
public enum DockWindow {
    /// The Dock's bundle identifier. Matched on the identifier rather than the localised
    /// application name, for the reason `CaptureSource.thisApplication` gives about names.
    public static let bundleIdentifier = "com.apple.dock"

    /// The window level the Dock sits at. `CGWindowLevelForKey(.dockWindow)` rather than the
    /// literal, because it is the system's own answer; measured as 20 on macOS 26, and the five
    /// wallpaper windows sit at -2147483624 and the four backdrops at -2147483622, so the
    /// separation is not marginal.
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
    }

    /// Resolves against the live window list.
    ///
    /// **`SCShareableContent.current`, which needs the Screen Recording grant** — unlike
    /// `CaptureSource.thisApplication`'s `currentProcess`, this has to see another application's
    /// windows. That is not a new demand: a display capture cannot start without the grant
    /// anyway, so by the time this runs the answer is already yes.
    ///
    /// Asked only when something was actually asked for. A person with the switch off pays for
    /// no query at all.
    public func resolve() async -> Resolution {
        guard wantsAnything else {
            return Resolution(applications: [], exceptedWindows: [], outcome: .notAsked)
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false) else {
            return Resolution(applications: [], exceptedWindows: [], outcome: .contentUnavailable)
        }
        guard let dock = content.applications.first(where: {
            $0.bundleIdentifier == DockWindow.bundleIdentifier
        }) else {
            return Resolution(applications: [], exceptedWindows: [], outcome: .dockNotRunning)
        }
        // Everything the Dock owns EXCEPT the Dock — see the header on the wallpaper.
        let kept = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == DockWindow.bundleIdentifier
                && !DockWindow.isTheDock(bundleIdentifier: DockWindow.bundleIdentifier,
                                         windowLayer: $0.windowLayer)
        }
        return Resolution(applications: [dock], exceptedWindows: kept, outcome: .dockExcluded)
    }
}
