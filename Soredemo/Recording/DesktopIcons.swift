import AppKit
import Foundation

/// Hides the desktop's icons while a recording runs, and puts them back.
///
/// **This writes to Finder's preferences and restarts it**, which is heavier than anything else
/// this app does to a machine — and the whole design is about the one obligation that creates:
/// the icons must come back. The debt is persisted before the write and cleared only after the
/// restore, so a crash at any instant leaves it recorded rather than lost, and `restore()` is
/// called when a recording stops, when the app quits, and at launch.
///
/// The files never move. Only the drawing stops.
///
/// **What it costs, stated rather than discovered:** restarting Finder closes the Finder windows
/// somebody has open. That is why this is off by default and asked for.
///
/// See `docs/design/hiding-macos-furniture.md` for the measurements — why `SIGTERM` and not
/// `terminate()`, why the restore has to be able to put back "there was no key", and the cheaper
/// capture-filter mechanism that is measured, promising, and deliberately not taken yet.
enum DesktopIcons {
    /// Finder's own preference domain and the key that decides whether it draws the desktop.
    private static let finderDomain = "com.apple.finder" as CFString
    private static let createDesktopKey = "CreateDesktop" as CFString
    private static let finderBundleID = "com.apple.finder"

    /// Whether a restore is owed. Set before the write, cleared after the restore.
    private static let owedKey = "desktopIconsRestoreOwed"
    /// What to restore to: `"true"`, `"false"`, or `"absent"`. A string rather than a `Bool?`
    /// because `UserDefaults` cannot tell a stored `false` from a missing key, which is exactly
    /// the distinction this has to carry.
    private static let priorKey = "desktopIconsPriorValue"

    /// How long to wait for launchd before launching Finder directly. 0.25 s was measured;
    /// this is an order of magnitude more, because waiting too long costs a slower restore and
    /// not waiting long enough costs a second Finder.
    static let relaunchGrace: TimeInterval = 4

    /// Whether the desktop is drawing icons right now, as Finder's preference says. `true` when
    /// the key is absent, which is macOS's own default.
    static var areVisible: Bool {
        guard let value = CFPreferencesCopyAppValue(createDesktopKey, finderDomain) else {
            return true
        }
        return (value as? NSNumber)?.boolValue ?? true
    }

    /// Whether this app owes the desktop a restore — a recording that ended badly, or one that
    /// is running now.
    static var restoreIsOwed: Bool { UserDefaults.standard.bool(forKey: owedKey) }

    /// Hides the icons, recording what to put back.
    ///
    /// Does nothing if a restore is already owed: two hides in a row would overwrite the prior
    /// value with the value THIS app wrote, and the real prior state would be lost forever.
    static func hide() {
        guard !restoreIsOwed else { return }
        let prior: String
        if let value = CFPreferencesCopyAppValue(createDesktopKey, finderDomain) {
            prior = ((value as? NSNumber)?.boolValue ?? true) ? "true" : "false"
        } else {
            prior = "absent"
        }
        // **The debt is recorded before the write that creates it.** The other order leaves a
        // window in which the icons are hidden and nothing knows it owes a restore.
        UserDefaults.standard.set(prior, forKey: priorKey)
        UserDefaults.standard.set(true, forKey: owedKey)

        CFPreferencesSetAppValue(createDesktopKey, false as CFBoolean, finderDomain)
        CFPreferencesAppSynchronize(finderDomain)
        restartFinder()
    }

    /// Puts the desktop back exactly as it was found, if this app owes that. Safe to call when
    /// nothing is owed, and safe to call twice.
    ///
    /// Called at three moments, which between them cover every way a recording can end: when one
    /// stops, when the app quits, and at launch — the last being the one that pays for a crash.
    static func restore() {
        guard restoreIsOwed else { return }
        switch UserDefaults.standard.string(forKey: priorKey) {
        case "true":
            CFPreferencesSetAppValue(createDesktopKey, true as CFBoolean, finderDomain)
        case "false":
            CFPreferencesSetAppValue(createDesktopKey, false as CFBoolean, finderDomain)
        default:
            // "absent", and also anything unreadable. **Deleting is the right answer for a value
            // this app cannot interpret**: the key is one this app wrote, macOS's own default is
            // to draw the desktop, and leaving an uninterpretable value in place would leave the
            // icons hidden — the one outcome this whole type exists to prevent.
            CFPreferencesSetAppValue(createDesktopKey, nil, finderDomain)
        }
        CFPreferencesAppSynchronize(finderDomain)
        restartFinder()
        // **Cleared last.** If anything above fails, the debt survives and the next launch tries
        // again; clearing first would forget an obligation that had not been met.
        UserDefaults.standard.removeObject(forKey: owedKey)
        UserDefaults.standard.removeObject(forKey: priorKey)
    }

    /// Restarts Finder so it re-reads the preference, and makes sure it comes back.
    private static func restartFinder() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleID)
        let previousIDs = Set(running.map(\.processIdentifier))
        for application in running { kill(application.processIdentifier, SIGTERM) }

        // **A deadline, not a sleep.** Blocking the main actor for four seconds would freeze the
        // app at the exact moment a person has just pressed Record. This checks later and does
        // nothing if launchd has already done the job.
        DispatchQueue.main.asyncAfter(deadline: .now() + relaunchGrace) {
            let now = NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleID)
            guard now.allSatisfy({ previousIDs.contains($0.processIdentifier) }) else { return }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderBundleID)
            else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            // **Not activated.** Finder coming back is housekeeping; stealing focus during a
            // recording would put Finder in the recording.
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        }
    }
}
