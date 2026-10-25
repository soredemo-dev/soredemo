import Testing
import Foundation
import Capture
@testable import Soredemo

/// The panel's one way in: a remembered target, then Record or Screenshot.
/// `docs/design/2026-10-25-the-panel-and-a-daruma-that-answers.md`, "Building option two".
@MainActor @Suite struct CaptureEntryTests {
    private func suite() -> UserDefaults {
        let name = "soredemo-target-\(ProcessInfo.processInfo.globallyUniqueString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let phone = MobileScreen.Source(uniqueID: "device-1", name: "Test iPhone", family: .iPhone)

    @Test func theTargetIsTheScreenUntilChosenAndThenSurvivesARelaunch() {
        let defaults = suite()
        #expect(RecordingPreferences(defaults: defaults).captureTarget == .screen)
        let first = RecordingPreferences(defaults: defaults)
        first.captureTarget = .area
        #expect(RecordingPreferences(defaults: defaults).captureTarget == .area)
    }

    /// The producer-value rule: a value written where the preference reads wins over its default,
    /// and a value this build does not know is the default rather than a crash.
    @Test func aStoredTargetWinsAndAnUnknownOneIsTheScreen() {
        let defaults = suite()
        defaults.set("window", forKey: RecordingPreferences.captureTargetKey)
        #expect(RecordingPreferences(defaults: defaults).captureTarget == .window)
        defaults.set("phone", forKey: RecordingPreferences.captureTargetKey)
        #expect(RecordingPreferences(defaults: defaults).captureTarget == .screen)
    }

    @Test(arguments: [RecordingCoordinator.CapturePurpose.take, .picture])
    func eachTargetHasItsOwnDoorForEitherPurpose(_ purpose: RecordingCoordinator.CapturePurpose) {
        #expect(CaptureEntry.for(target: .screen, device: nil, purpose: purpose) == .displayPicker)
        #expect(CaptureEntry.for(target: .window, device: nil, purpose: purpose) == .pointAtWindow)
        #expect(CaptureEntry.for(target: .area, device: nil, purpose: purpose) == .dragArea)
    }

    /// **Choosing another target abandons a start that is still picking.** Two cards showed an
    /// edge at once — the one chosen and the one whose picker was still up — seen by the owner on
    /// 2026-10-25. Choosing the card that is already picking leaves it be.
    @Test func choosingAnotherTargetCancelsAStartStillPicking() {
        #expect(CaptureEntry.cancelsPending(.region, choosing: .screen))
        #expect(CaptureEntry.cancelsPending(.windowsOnly, choosing: .area))
        #expect(CaptureEntry.cancelsPending(.displaysOnly, choosing: .window))
        #expect(!CaptureEntry.cancelsPending(.region, choosing: .area))
        #expect(!CaptureEntry.cancelsPending(.displaysOnly, choosing: .screen))
        #expect(!CaptureEntry.cancelsPending(nil, choosing: .screen))
    }

    /// A chosen device outranks the remembered card, and has no picture to take.
    @Test func aChosenDeviceIsRecordedAndCannotBePhotographed() {
        #expect(CaptureEntry.for(target: .area, device: phone, purpose: .take) == .device(phone))
        #expect(CaptureEntry.for(target: .area, device: phone, purpose: .picture) == nil)
    }
}

/// Choosing goes through the coordinator, so the panel and the notch share one choice.
@MainActor @Suite struct CaptureChoiceTests {
    private func coordinator() -> RecordingCoordinator {
        let name = "soredemo-choice-\(ProcessInfo.processInfo.globallyUniqueString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return RecordingCoordinator(preferences: RecordingPreferences(defaults: defaults))
    }

    private let phone = MobileScreen.Source(uniqueID: "device-1", name: "Test iPhone", family: .iPhone)

    @Test func choosingATargetRemembersItAndSetsADeviceAside() {
        let coordinator = coordinator()
        coordinator.choose(device: phone)
        #expect(coordinator.isChosen(device: phone) && !coordinator.isChosen(.screen))
        coordinator.choose(.window)
        #expect(coordinator.preferences.captureTarget == .window)
        #expect(coordinator.isChosen(.window) && !coordinator.isChosen(device: phone))
    }
}
