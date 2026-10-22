import Capture
import Foundation
import Observation

/// The recording switches a person sets once and keeps: how long to count down, how fast to
/// capture, what to leave out of the picture, whether to record the machine's own sound.
///
/// **Extracted from `RecordingCoordinator`**, which owned them beside the take itself — one
/// reason to change per type (`docs/design/2026-10-23-splitting-the-recording-coordinator.md`).
/// The coordinator holds one and reads it when a take starts; settings views bind to it.
/// `defaults` is passed in, so a test reads and writes its own suite and never a person's.
@Observable
final class RecordingPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` rather than `integer(forKey:)`: the latter answers 0 for a key that
        // has never been set, and 0 means "off" here — so a first launch would silently ship
        // with no countdown, which is the opposite of the default this chose.
        countdownSeconds = defaults.object(forKey: Self.countdownKey) as? Int ?? 3
        // Absent means off, which `bool(forKey:)` already answers — no `object(forKey:)` dance
        // is needed for a preference whose default is the same as its zero value.
        hidesDesktopIcons = defaults.bool(forKey: Self.hidesDesktopIconsKey)
        hidesDock = defaults.bool(forKey: Self.hidesDockKey)
        hidesMenuBar = defaults.bool(forKey: Self.hidesMenuBarKey)
        hidesDesktopWidgets = defaults.bool(forKey: Self.hidesDesktopWidgetsKey)
        hidesNotifications = defaults.bool(forKey: Self.hidesNotificationsKey)
        // **Defaults to ON, so `bool(forKey:)`'s zero is not the answer.** A key never written
        // answers `false`, which for a switch that should start on is the same silent defect
        // `countdownSeconds` documents.
        scrubAudio = defaults.object(forKey: Self.scrubAudioKey) as? Bool ?? true
        // `object(forKey:)` rather than `bool(forKey:)` for the same reason as every
        // switch above: `bool` reads a missing key as `false`, which would turn this
        // off for everybody who has ever run the app rather than defaulting it on.
        capturesSystemAudio = defaults.object(forKey: Self.capturesSystemAudioKey) as? Bool ?? true
        // Same reasoning as the countdown's default: `integer(forKey:)` answers 0 for a key
        // never set, and 0 is not a frame rate.
        frameRate = (defaults.object(forKey: Self.frameRateKey) as? Int)
            .flatMap(CaptureFrameRate.init(rawValue:)) ?? .sixty
    }

    /// What a take — or a picture — leaves out of the frame, from the switches below. **One
    /// place builds it**: it was built twice, at the take and at the picture, and a switch added
    /// to one would have been missing from the other.
    var exclusions: CaptureExclusions {
        CaptureExclusions(hidesDock: hidesDock, hidesMenuBar: hidesMenuBar,
                          hidesDesktopWidgets: hidesDesktopWidgets,
                          hidesNotifications: hidesNotifications)
    }

    /// The ceiling on capture frame delivery. Persisted, like the countdown: a preference rather
    /// than a per-recording decision.
    var frameRate: CaptureFrameRate {
        didSet { defaults.set(frameRate.rawValue, forKey: Self.frameRateKey) }
    }
    static let frameRateKey = "captureFrameRate"

    /// Seconds between choosing a target and the capture starting. Persisted, because it is a
    /// preference rather than a per-recording decision — a person who wants five seconds wants
    /// five seconds every time.
    var countdownSeconds: Int {
        didSet { defaults.set(countdownSeconds, forKey: Self.countdownKey) }
    }
    static let countdownKey = "countdownSeconds"

    /// The choices offered. Zero is "off" and is a legitimate answer — a person recording a
    /// window they have already arranged is not waiting three seconds for it.
    static let countdownChoices = [0, 3, 5, 10]

    /// Whether the desktop's icons are hidden for the duration of a recording.
    ///
    /// **Off by default, and it is the cost that decides that.** Restarting Finder closes the
    /// Finder windows somebody has open, which is a real interruption to make on their behalf
    /// without being asked. A person who wants a clean desktop in their demos asks once, in
    /// Settings, and gets it every time — the same shape as the countdown.
    var hidesDesktopIcons: Bool {
        didSet { defaults.set(hidesDesktopIcons, forKey: Self.hidesDesktopIconsKey) }
    }
    static let hidesDesktopIconsKey = "hidesDesktopIcons"

    /// Whether the Dock is kept out of the picture for the duration of a recording.
    ///
    /// **Off by default, but not for the reason its neighbour is.** Hiding the desktop icons
    /// restarts Finder and costs somebody their open windows, so it has to be asked for. This
    /// costs nothing at all — the Dock is excluded from the capture filter and the person's own
    /// Dock never moves — and it is still off, because a recording that silently omits part of
    /// the screen is not what somebody pressing Record expects to get. See `CaptureExclusions`
    /// for the three mechanisms that were measured and rejected before this one.
    var hidesDock: Bool {
        didSet { defaults.set(hidesDock, forKey: Self.hidesDockKey) }
    }
    static let hidesDockKey = "hidesDock"

    /// Whether the menu bar — and the twelve small things sitting in it — are kept out of the
    /// picture for the duration of a recording.
    ///
    /// **Off by default, and this is the one where that is arguable.** A menu bar says what time
    /// it is, how much battery is left, which network somebody is on, and through its extras
    /// which applications they run: for a recording that is going to be published, that is a row
    /// of small disclosures nobody meant to make. The case for hiding it by default is real.
    ///
    /// It is still off, for the same reason the other two are: a recording that silently omits
    /// part of the screen is not what pressing Record is understood to mean, and somebody
    /// demonstrating a menu is demonstrating the menu bar. Costs nothing when off — it is one
    /// property on the capture filter, not a query and not a change to the Mac.
    var hidesMenuBar: Bool {
        didSet { defaults.set(hidesMenuBar, forKey: Self.hidesMenuBarKey) }
    }
    static let hidesMenuBarKey = "hidesMenuBar"

    /// Whether the desktop widgets are kept out of the picture.
    ///
    /// **Off by default, like the other three, and for the same reason**: a
    /// recording that silently omits part of the screen is not what pressing
    /// Record is understood to mean. The case for ON is the strongest of the four
    /// — the widgets say what is in somebody's calendar this afternoon, where
    /// they are and what their battery is doing, which is a row of small
    /// disclosures nobody meant to publish — and it is still not enough to
    /// decide for them.
    var hidesDesktopWidgets: Bool {
        didSet {
            defaults.set(hidesDesktopWidgets, forKey: Self.hidesDesktopWidgetsKey)
        }
    }
    static let hidesDesktopWidgetsKey = "hidesDesktopWidgets"

    /// Whether notification banners, and Notification Center, are kept out of the picture.
    ///
    /// **Off by default, like the four above, and for their reason.** The case for ON is a
    /// message's sender and first line arriving mid-take; it is still a part of the screen, and
    /// somebody demonstrating a notification is demonstrating it. Nothing is silenced either
    /// way — there is no public API to turn Focus on — so the person still sees every banner.
    var hidesNotifications: Bool {
        didSet { defaults.set(hidesNotifications, forKey: Self.hidesNotificationsKey) }
    }
    static let hidesNotificationsKey = "hidesNotifications"

    /// Whether dragging the playhead plays the moment under it.
    ///
    /// **On by default, unlike the three recording switches above.** Those change what a
    /// recording CONTAINS, so a default that surprised somebody would be in their file. This
    /// changes only what the person editing hears, costs nothing when they are not dragging, and
    /// is the difference between finding a sentence and hunting for one.
    var scrubAudio: Bool {
        didSet { defaults.set(scrubAudio, forKey: Self.scrubAudioKey) }
    }
    static let scrubAudioKey = "scrubAudio"

    /// Whether the machine's own output — what the speakers are playing — is recorded.
    ///
    /// **On by default, and it has to be asked rather than assumed.** A demo of
    /// anything that makes a sound is worse without it, so on is the right
    /// default. But it used to be unconditional, which left no way to record a
    /// call, or a screen that pings, without the other side of it in the file —
    /// and muting afterwards is not the same act, because by then it is recorded.
    ///
    /// This app's own sound is already excluded (`excludesCurrentProcessAudio`),
    /// so the switch is about the rest of the machine.
    var capturesSystemAudio: Bool {
        didSet { defaults.set(capturesSystemAudio, forKey: Self.capturesSystemAudioKey) }
    }
    static let capturesSystemAudioKey = "capturesSystemAudio"

    // **Every preference key is `internal`, not `private`, and the reason is compatibility
    // rather than testing convenience.** A persisted key is part of what the app promises across
    // versions: rename one and every existing user's preference silently reverts to its default
    // on the next launch, with nothing to see and nothing to report. Two of the four were
    // already internal and two were private, which was inconsistency rather than design —
    // nothing outside this file named any of them. They are named now by
    // `scripts/cross-boundary-digest-probe.swift` § 17, which asserts that setting each
    // preference writes the string below, so a rename is a red check instead of a quiet reset.
    //
    // `hidesDesktopIcons` was internal from the start and still went unpinned until the Dock
    // switch was added beside it — the probe named four keys and there were five. Both are
    // pinned now.
}
