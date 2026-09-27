import AppKit

/// Light, dark, or whatever the system is. **Applied once, to the application**, so every window,
/// sheet and menu agrees without each view being told — and the three surfaces that must stay dark
/// whatever this says (`docs/design/2026-09-27-light-and-dark.md`) keep their own pins.
enum Appearance: String, CaseIterable, Sendable {
    case system, light, dark

    static let defaultsKey = "appearance"

    /// Anything unrecognised is `.system`: a stored value this build does not know is not a
    /// decision this build can honour, and following the system is what nobody chose against.
    init(storedValue: String?) {
        self = storedValue.flatMap(Appearance.init(rawValue:)) ?? .system
    }

    var displayName: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` hands the choice back to the system.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    @MainActor func apply() {
        NSApplication.shared.appearance = appearanceName.flatMap(NSAppearance.init(named:))
    }

    @MainActor static func applyStored() {
        Appearance(storedValue: UserDefaults.standard.string(forKey: defaultsKey)).apply()
    }
}
