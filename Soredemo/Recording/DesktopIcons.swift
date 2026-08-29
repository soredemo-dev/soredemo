import AppKit
import Foundation

/// **Hides the icons on the desktop while a recording is running, and puts them back.**
///
/// The classic thing that ruins a demo: a clean product walkthrough with somebody's
/// `tax-return-final-2.pdf` sitting behind it. It is rare enough that there was nothing
/// open-source recorders beside this repo do, so there was nothing to read and this is designed
/// from the one mechanism macOS offers.
///
/// **There is exactly one mechanism and it is not an API.** `com.apple.finder`'s `CreateDesktop`
/// preference controls whether Finder DRAWS the desktop; Finder reads it once, at launch, so the
/// change only takes effect when Finder restarts. Searched for a newer route on 2026-08-27 and
/// there is none — every tool that does this, commercial or free, writes that key and restarts
/// Finder. The files never move: they stay in `~/Desktop`, and save dialogs, drag targets and
/// `~/Desktop/` path resolution all keep working. Only the drawing stops.
///
/// **This writes to another application's preferences and kills its process.** That is a heavier
/// thing than anything else this app does to a machine, and the whole design below is about the
/// one obligation it creates: the icons must come back. Every path out — a normal stop, a quit, a
/// crash, a power cut — has to end with the desktop as it was found.
///
/// ### Restoring the exact prior state, including "there was no key"
///
/// On the machine this was written on, `CreateDesktop` did not exist at all; the default is to
/// draw the desktop, and most Macs have never had the key written. So restoring by writing `true`
/// would be wrong in the ordinary case: it leaves behind a key that was not there before. It
/// LOOKS the same — the icons come back — which is what makes it the kind of trace that is never
/// noticed and never cleaned up.
///
/// So the prior value is read and stored before anything is written, and restoring puts back
/// exactly that: `true`, `false`, or absent. Measured: `absent → 0 → absent`, confirmed from
/// outside with `defaults read`, which reports the pair as not existing afterwards.
///
/// ### Why the restore is owed, and survives a crash
///
/// A one-shot "restore when the recording stops" is only correct when the recording stops. If the
/// app is killed mid-recording, or the machine loses power, the key stays written and the person
/// has a Mac with no desktop icons and no idea why. So the obligation is PERSISTED: writing the
/// key records that a restore is owed, along with what to restore to, and the app pays that debt
/// at launch before it does anything else. The flag is cleared only after the restore has
/// actually been performed — the ordering `WindowConfigurator`'s size flag got wrong, and it got
/// wrong in the direction that loses the work.
///
/// ### `SIGTERM`, not `terminate()` — measured, and the wrong one is worse than useless
///
/// `NSRunningApplication.terminate()` sends a polite `quit` Apple Event, Finder honours it as a
/// genuine quit, and **launchd does not bring it back**: measured, no Finder after six seconds,
/// on the machine this was written on. `kill(pid, SIGTERM)` — which is what `killall Finder`
/// sends — is an unclean exit as far as launchd is concerned, and Finder was back in 0.25 s.
///
/// Even so, nothing here relies on launchd being in that mood: if Finder has not come back within
/// `relaunchGrace`, this launches it explicitly. A person left with no Finder is a far worse
/// outcome than a redundant launch.
///
/// **What it costs, stated rather than discovered:** restarting Finder closes the Finder windows
/// that were open. There is no way around that — it is the same cost `killall Finder` has, and it
/// is why this is off by default and asked for rather than assumed.
///
/// ### There is a cheaper mechanism, it was measured, and it is not used here yet
///
/// Building the Dock switch turned up a route this had ruled out without trying: **excluding the
/// desktop from the CAPTURE rather than hiding it from the person**. Finder owns exactly one
/// window at `kCGDesktopIconWindowLevel` (-2147483603, 1512x982, the only Finder window reported
/// as on-screen), and a shot taken with that one window excluded — 2026-08-29, compared against a
/// shot taken without — has the desktop icon that was visible in the first one gone, and the
/// wallpaper untouched. No preference written, no Finder restarted, no restore owed.
///
/// It is not adopted here in the same change for one reason worth stating rather than leaving as
/// an omission: `SCContentFilter` offers exactly one exclusion list, this process must be on it
/// at APPLICATION granularity — the control bar is created after the filter is built — and so
/// excluding one Finder window means excluding the Finder application and naming its other
/// windows in `exceptingWindows`. Any Finder window opened AFTER the recording starts is then not
/// on that list and vanishes from the video. For the Dock that risk is negligible; for Finder,
/// during a demo, it is exactly the thing somebody would open. Solving it properly means
/// re-resolving the filter as windows appear, which is a change to how capture is driven and not
/// a change to this file.
///
/// So: measured, promising, and deliberately not taken yet. `CaptureExclusions` is where it would
/// go, and this note exists so the next person finds the measurement instead of the idea.
enum DesktopIcons {
    /// Finder's own preference domain and the key that decides whether it draws the desktop.
    private static let finderDomain = "com.apple.finder" as CFString
    private static let createDesktopKey = "CreateDesktop" as CFString
    private static let finderBundleID = "com.apple.finder"

    /// Whether a restore is owed. **Set before the write, cleared after the restore** — so a
    /// crash at any instant leaves the debt recorded rather than lost.
    private static let owedKey = "desktopIconsRestoreOwed"
    /// What to restore to: `"true"`, `"false"`, or `"absent"`. A string rather than a `Bool?`
    /// because `UserDefaults` cannot tell a stored `false` from a missing key, which is exactly
    /// the distinction this has to carry.
    private static let priorKey = "desktopIconsPriorValue"

    /// How long to wait for launchd before launching Finder directly. 0.25 s was measured; this
    /// is an order of magnitude more, because the only cost of waiting too long is a slower
    /// restore and the cost of not waiting long enough is launching a second Finder.
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
