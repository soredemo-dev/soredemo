import Testing
import Foundation
import Capture
@testable import Soredemo

/// **The recording switches, on their own.** Extracted from `RecordingCoordinator`
/// (`docs/design/2026-10-23-splitting-the-recording-coordinator.md`); each test uses its own
/// defaults suite, so nothing here touches a real person's settings.
@MainActor @Suite struct RecordingPreferencesTests {
    private func suite() -> UserDefaults {
        let name = "soredemo-prefs-\(ProcessInfo.processInfo.globallyUniqueString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// What a first launch gets. Three of these are not their type's zero — the countdown, the
    /// scrub sound and system audio — which is the defect `object(forKey:)` exists to avoid.
    @Test func aFirstLaunchGetsTheChosenDefaults() {
        let preferences = RecordingPreferences(defaults: suite())
        #expect(preferences.countdownSeconds == 3)
        #expect(preferences.frameRate == .sixty)
        #expect(preferences.scrubAudio)
        #expect(preferences.capturesSystemAudio)
        #expect(!preferences.hidesDesktopIcons && !preferences.hidesDock && !preferences.hidesMenuBar
                && !preferences.hidesDesktopWidgets && !preferences.hidesNotifications)
    }

    /// Every switch away from its default, written by one instance and read by the next.
    @Test func everySwitchSurvivesARelaunch() {
        let defaults = suite()
        let first = RecordingPreferences(defaults: defaults)
        first.countdownSeconds = 10
        first.frameRate = .thirty
        first.scrubAudio = false
        first.capturesSystemAudio = false
        first.hidesDesktopIcons = true
        first.hidesDock = true
        first.hidesMenuBar = true
        first.hidesDesktopWidgets = true
        first.hidesNotifications = true

        let second = RecordingPreferences(defaults: defaults)
        #expect(second.countdownSeconds == 10)
        #expect(second.frameRate == .thirty)
        #expect(!second.scrubAudio && !second.capturesSystemAudio)
        #expect(second.hidesDesktopIcons && second.hidesDock && second.hidesMenuBar
                && second.hidesDesktopWidgets && second.hidesNotifications)
    }

    /// **The stored names are a contract with every Mac this app has run on.** Renaming one is
    /// not an error anyone would see: the setting quietly goes back to its default. These are the
    /// names the coordinator wrote before the split.
    @Test func theStoredNamesAreTheOnesEveryInstalledCopyUses() {
        #expect(RecordingPreferences.countdownKey == "countdownSeconds")
        #expect(RecordingPreferences.frameRateKey == "captureFrameRate")
        #expect(RecordingPreferences.scrubAudioKey == "scrubAudio")
        #expect(RecordingPreferences.capturesSystemAudioKey == "capturesSystemAudio")
        #expect(RecordingPreferences.hidesDesktopIconsKey == "hidesDesktopIcons")
        #expect(RecordingPreferences.hidesDockKey == "hidesDock")
        #expect(RecordingPreferences.hidesMenuBarKey == "hidesMenuBar")
        #expect(RecordingPreferences.hidesDesktopWidgetsKey == "hidesDesktopWidgets")
        #expect(RecordingPreferences.hidesNotificationsKey == "hidesNotifications")
    }

    /// A stored rate that is not a rate falls back to the default rather than becoming a zero
    /// timescale. (Any rate from 1 to 1000 is legal — `CaptureFrameRate` comes from the hardware.)
    @Test func aStoredRateThatIsNotARateFallsBackToTheDefault() {
        let defaults = suite()
        defaults.set(0, forKey: RecordingPreferences.frameRateKey)
        #expect(RecordingPreferences(defaults: defaults).frameRate == .sixty)
    }

    /// **One place builds what a take leaves out**, and a picture uses the same — they were built
    /// twice, and a fifth switch added to one would have been missing from the other.
    @Test func theExclusionsAreTheSwitches() {
        let preferences = RecordingPreferences(defaults: suite())
        preferences.hidesDock = true
        preferences.hidesNotifications = true
        #expect(preferences.exclusions == CaptureExclusions(hidesDock: true, hidesMenuBar: false,
                                                            hidesDesktopWidgets: false,
                                                            hidesNotifications: true))
    }
}
