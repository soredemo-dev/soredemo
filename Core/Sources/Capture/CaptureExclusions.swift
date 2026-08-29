// `@unsafe` because `@preconcurrency` suppresses the concurrency checking that would otherwise
// catch a data race across this import — required by `.strictMemorySafety()`. The same mark
// `CaptureSource.swift` carries, for the same reason: `SCWindow` and `SCRunningApplication` are
// only ever read here, never mutated, and every use is on one task.
@preconcurrency @unsafe import ScreenCaptureKit
import CoreGraphics
import Foundation

/// **Keeps the Dock out of a recording without touching the person's Dock.**
///
/// Asked for as "dock可以隱藏嗎" alongside the desktop-icon switch, which is the natural place to
/// look for it: the Dock is the other piece of macOS furniture that sits in front of whatever is
/// being demonstrated, and a walkthrough with somebody's forty-icon Dock across the bottom reads
/// as a screenshot of a desk rather than of a product.
///
/// ### The mechanism, and the three that were measured and rejected
///
/// The obvious route is the one every blog post gives — `com.apple.dock`'s `autohide`
/// preference — and it is wrong here for a reason that only shows up when it is measured.
/// Measured on 2026-08-29:
///
///  1. **`defaults write com.apple.dock autohide -bool true` alone does nothing.** The Dock does
///     not watch that key. `NSScreen.main`'s usable height was 105 pt short of the full frame
///     before the write, after the write, and after writing it back — three identical readings.
///     The pref route therefore also needs the Dock killed and relaunched, which is the same
///     heavy machinery `DesktopIcons` carries for Finder: a preference belonging to another
///     application, a process killed, and a restore owed across crashes.
///  2. **`System Events`' `set autohide of dock preferences to true` DOES work, live, with no
///     relaunch** — the Dock's pid was unchanged through `false → true → false`. But it needs an
///     Apple Events automation grant, one more permission dialog on top of Screen Recording, and
///     a person who declines it gets a switch that silently does nothing. It also persists into
///     `com.apple.dock` (`defaults read` reported `1` afterwards), so it owes a restore too.
///  3. Both of the above **change the person's Mac** to change a video. The Dock is gone from
///     their screen for the whole take, and if the app dies mid-recording it stays gone.
///
/// What this does instead: the Dock is **excluded from the capture filter**. Nothing about the
/// machine changes. The Dock stays exactly where it was, the person can still click it during the
/// recording, and it is simply not in the picture. No preference is written, no process is
/// killed, no permission is asked for, and there is no restore to owe — so there is no state that
/// a crash can strand.
///
/// ### Why the Dock's APPLICATION is excluded and then most of it put back
///
/// `SCContentFilter` has no initialiser that excludes a list of applications AND a list of
/// windows; it offers `excludingApplications:exceptingWindows:`, where the second argument names
/// windows to keep DESPITE the first. This process's own windows must be excluded by application
/// — the floating control bar is created when capture starts, after the filter is built, so a
/// window list taken at filter time would not contain it, and a recorder that records its own
/// control strip has happened here before. So the Dock has to be excluded the same way.
///
/// **Excluding the whole Dock application would risk the wallpaper.** Measured: `com.apple.dock`
/// owns eleven windows on this machine, and five of them are titled `Wallpaper-<UUID>` — the
/// desktop picture is drawn by the Dock process. Four more are `Fullscreen Backdrop`. Exactly one
/// is the Dock itself. So every window of the Dock EXCEPT that one is named in `exceptingWindows`
/// and comes back into the picture.
///
/// Both were shot and looked at rather than reasoned about. Excluding the application alone
/// happened to keep the wallpaper on this machine — `com.apple.wallpaper.agent` owns an
/// "Offscreen Wallpaper Window" that appears to be what actually renders — but that is luck, not
/// design, and a dynamic or aerial wallpaper may well come from the Dock's own windows. The
/// belt-and-braces version was shot too, and it is the one shipped: Dock gone, wallpaper intact.
///
/// **What it costs:** a window of the Dock created AFTER the filter is built is not in the
/// excepted list, so it would be excluded with the rest of the Dock. In practice that means a
/// full-screen backdrop created mid-recording. The exposure is small because the filter is
/// rebuilt for every segment, and because on the machine this was measured on the wallpaper does
/// not come from the Dock at all — losing it needs both of those to be false at once.
///
/// A **window** capture needs none of this: `SCContentFilter(desktopIndependentWindow:)` captures
/// one window and nothing overlapping it, so the Dock is excluded by construction. The switch is
/// a no-op there, and says so rather than pretending to act.
public struct CaptureExclusions: Sendable, Equatable, Hashable, Codable {
    /// Whether the Dock should be kept out of the picture.
    public var hidesDock: Bool

    public init(hidesDock: Bool = false) {
        self.hidesDock = hidesDock
    }

    /// Nothing hidden — what a display capture uses unless somebody asked otherwise.
    public static let none = CaptureExclusions()

    /// Whether anything at all is being asked for. Read before the shareable-content query, so a
    /// person who wants nothing hidden pays nothing for the feature.
    public var wantsAnything: Bool { hidesDock }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A missing key is "not asked for" rather than a failure: this type is stored beside
        // older projects that predate it, and the honest reading of a file written before the
        // switch existed is that the switch was off.
        hidesDock = try container.decodeIfPresent(Bool.self, forKey: .hidesDock) ?? false
    }

    private enum CodingKeys: String, CodingKey { case hidesDock }
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
