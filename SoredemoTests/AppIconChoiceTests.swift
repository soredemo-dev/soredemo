import AppKit
import Testing
@testable import Soredemo

/// The icon a person can choose. Vermilion with its face window since 2026-10-26 — the bundle's
/// own — and the eyes on the body and the ink daruma the alternatives.
/// `docs/design/2026-10-26-a-character-not-a-logo.md`.
@Suite struct AppIconChoiceTests {
    @Test func vermilionIsTheDefaultAndAnUnknownChoiceIsVermilion() {
        #expect(AppIconChoice(storedValue: nil) == .vermilion)
        #expect(AppIconChoice(storedValue: "gold") == .vermilion)
        #expect(AppIconChoice(storedValue: "black") == .black)
        #expect(AppIconChoice(storedValue: "bare") == .bare)
    }

    /// Vermilion hands the Dock back to the bundle's own icon; each alternative names an image the
    /// catalog actually holds — a name with no image behind it would show the generic app icon.
    @MainActor @Test(arguments: [AppIconChoice.black, .bare])
    func eachAlternativeNamesAnImageTheAppHasAndVermilionNamesNone(_ choice: AppIconChoice) throws {
        #expect(AppIconChoice.vermilion.imageName == nil)
        let name = try #require(choice.imageName)
        let image = try #require(NSImage(named: name), "\(name) is not in the asset catalog")
        #expect(image.size.width >= 512)
    }
}
