import AppKit

/// Which daruma the Dock shows: the black one the app ships with, or the vermilion one.
///
/// **The Dock only, while Soredemo is open.** macOS has no alternate-icon API for a Mac app, and
/// changing the icon of the app's own bundle writes into a signed bundle and breaks its signature,
/// so Finder and Launchpad keep the black daruma; Settings says so beside the choice.
/// `docs/design/2026-10-25-a-vermilion-icon.md`.
enum AppIconChoice: String, CaseIterable, Sendable {
    case black, vermilion

    static let defaultsKey = "appIcon"

    /// Anything unrecognised is black: the icon the bundle carries is what nobody chose against.
    init(storedValue: String?) {
        self = storedValue.flatMap(AppIconChoice.init(rawValue:)) ?? .black
    }

    var displayName: String {
        switch self {
        case .black: "Black"
        case .vermilion: "Vermilion"
        }
    }

    /// The image the Dock shows, drawn by `scripts/make-daruma-marks.swift`; `nil` hands the Dock
    /// back to the bundle's own icon.
    var imageName: String? {
        switch self {
        case .black: nil
        case .vermilion: "AppIconVermilion"
        }
    }

    @MainActor func apply() {
        NSApplication.shared.applicationIconImage = imageName.flatMap(NSImage.init(named:))
    }

    @MainActor static func applyStored() {
        AppIconChoice(storedValue: UserDefaults.standard.string(forKey: defaultsKey)).apply()
    }
}
