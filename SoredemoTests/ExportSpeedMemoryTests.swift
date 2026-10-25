import Foundation
import Testing
@testable import Soredemo

/// What this Mac remembers of its last export, per kind. In a suite of its own, never a
/// person's defaults.
@MainActor @Suite struct ExportSpeedMemoryTests {
    private func suite() -> UserDefaults {
        let name = "ExportSpeedMemoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aFinishedExportIsRememberedForItsKindAndNoOther() throws {
        let memory = ExportSpeedMemory(defaults: suite())
        #expect(memory.pixelsPerSecond(for: "hevc") == nil, "nothing exported yet is no rate")
        memory.remember(frames: 600, width: 3024, height: 1964, seconds: 8.07, codec: "hevc")
        let rate = try #require(memory.pixelsPerSecond(for: "hevc"))
        #expect(abs(rate - 600.0 * 3024 * 1964 / 8.07) < 1)
        #expect(memory.pixelsPerSecond(for: "proRes") == nil, "ProRes runs on another engine")
    }

    /// An export that measured nothing leaves the last good rate where it was.
    @Test func aMeasurementOfNothingDoesNotReplaceARate() throws {
        let memory = ExportSpeedMemory(defaults: suite())
        memory.remember(frames: 600, width: 3024, height: 1964, seconds: 8.07, codec: "h264")
        memory.remember(frames: 0, width: 3024, height: 1964, seconds: 0.01, codec: "h264")
        let rate = try #require(memory.pixelsPerSecond(for: "h264"))
        #expect(abs(rate - 600.0 * 3024 * 1964 / 8.07) < 1)
    }
}
