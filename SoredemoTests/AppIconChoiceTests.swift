import AppKit
import Testing
@testable import Soredemo

/// The icon a person can choose. `docs/design/2026-10-25-a-vermilion-icon.md`.
@Suite struct AppIconChoiceTests {
    @Test func blackIsTheDefaultAndAnUnknownChoiceIsBlack() {
        #expect(AppIconChoice(storedValue: nil) == .black)
        #expect(AppIconChoice(storedValue: "gold") == .black)
        #expect(AppIconChoice(storedValue: "vermilion") == .vermilion)
    }

    /// Black hands the Dock back to the bundle's own icon; vermilion names an image the catalog
    /// actually holds — a name with no image behind it would show the generic app icon.
    @MainActor @Test func vermilionNamesAnImageTheAppHasAndBlackNamesNone() throws {
        #expect(AppIconChoice.black.imageName == nil)
        let name = try #require(AppIconChoice.vermilion.imageName)
        let image = try #require(NSImage(named: name), "\(name) is not in the asset catalog")
        #expect(image.size.width >= 512)
    }
}
