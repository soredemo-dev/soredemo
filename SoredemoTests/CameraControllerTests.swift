import Testing
import Foundation
import Capture
import Render
@testable import Soredemo

/// **The camera's choice and its preferences, on their own** — step 2 of
/// `docs/design/2026-10-23-splitting-the-recording-coordinator.md`. No test here opens a camera:
/// every path that would is the `.off` side of it, and the device side is covered by probe § 17
/// and by a person choosing one.
@MainActor @Suite struct CameraControllerTests {
    private func suite() -> UserDefaults {
        let name = "soredemo-camera-\(ProcessInfo.processInfo.globallyUniqueString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aFirstLaunchRecordsNoCameraAtTheBestQualityInTheDefaultPlace() {
        let camera = CameraController(defaults: suite())
        #expect(camera.source == .off)
        #expect(!camera.wantsRecording)
        #expect(camera.quality == .best)
        #expect(camera.style == .default)
    }

    @Test func qualityAndPlacementSurviveARelaunch() {
        let defaults = suite()
        let first = CameraController(defaults: defaults)
        first.quality = .hd720
        let moved = CameraOverlayStyle.default.changing(isHidden: true)
        first.style = moved
        let second = CameraController(defaults: defaults)
        #expect(second.quality == .hd720)
        #expect(second.style == moved)
    }

    /// The names every installed copy stored them under — see `RecordingPreferencesTests`.
    @Test func theStoredNamesAreTheOnesEveryInstalledCopyUses() {
        #expect(CameraController.qualityKey == "cameraQuality")
        #expect(CameraController.styleKey == "cameraOverlayStyle")
    }

    /// Choosing no camera needs no permission and clears an earlier refusal.
    @Test func choosingNoCameraIsImmediateAndAsksNothing() {
        let camera = CameraController(defaults: suite())
        camera.choose(.off)
        #expect(camera.source == .off)
        #expect(!camera.wasRefused)
    }

    /// A problem is said through the owner, never swallowed. Wired the way the coordinator wires it.
    @Test func theCoordinatorHearsTheCamerasProblems() {
        let coordinator = RecordingCoordinator()
        coordinator.camera.onProblem("the camera is gone")
        #expect(coordinator.statusText.contains("the camera is gone"))
    }
}
