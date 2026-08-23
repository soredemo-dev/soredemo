import Foundation

/// Which language the interface is in.
///
/// **How the system's language is detected: `Bundle.preferredLocalizations(from:forPreferences:)`.**
/// Not `Locale.current.languageCode`, which answers a question nobody asked — it is the language
/// of the person's FORMATTING, and on a Mac set to English with Traditional Chinese second it
/// returns `en` while the person reads Chinese first among what an app offers. Apple's matcher
/// takes the app's own list and the person's ordered preferences and does the work that makes
/// `zh-Hant` match `zh-Hant-TW`, `zh-TW` and `zh-Hant-HK`, and `pt` match `pt-BR`. a native editor
/// and a Swift recorder both use exactly this call; it is the answer.
///
/// **An override, because a match is not always what someone wants.** A person whose Mac is in
/// English but who would rather read the app in Chinese — or the reverse, which is common among
/// developers — has no way to say so through the system, since macOS's per-app language list only
/// offers what the app ships. This is that list.
enum AppLanguage: Hashable, Sendable {
    case system
    case fixed(String)

    static let defaultsKey = "appLanguage"
    /// The key macOS itself reads to decide an application's language. Writing it is how a
    /// per-app override is expressed on this platform — it is what System Settings' own
    /// per-app language list writes, in the app's own defaults domain.
    static let appleLanguagesKey = "AppleLanguages"

    var identifier: String? {
        switch self {
        case .system: nil
        case .fixed(let value): value
        }
    }

    /// The language's own name — a list of languages is read in the languages themselves.
    var displayName: String {
        switch self {
        case .system:
            return String(localized: "This Mac's language")
        case .fixed(let value):
            let locale = Locale(identifier: value)
            return locale.localizedString(forIdentifier: value)
                ?? Locale.current.localizedString(forIdentifier: value)
                ?? value
        }
    }

    /// What this app ships, from the bundle rather than from a list written twice.
    ///
    /// `Base` is excluded: it is the development language's storage, not a language a person
    /// chooses, and offering it would offer the same thing as English under a different name.
    static var available: [AppLanguage] {
        [.system] + Bundle.main.localizations
            .filter { $0 != "Base" }
            .sorted()
            .map(AppLanguage.fixed)
    }

    /// What the interface is in right now — the override if there is one, otherwise the match.
    static var resolved: String {
        if case .fixed(let value)? = stored, Bundle.main.localizations.contains(value) {
            return value
        }
        return Bundle.preferredLocalizations(
            from: Bundle.main.localizations.filter { $0 != "Base" },
            forPreferences: Locale.preferredLanguages).first ?? "en"
    }

    static var stored: AppLanguage? {
        guard let value = UserDefaults.standard.string(forKey: defaultsKey), !value.isEmpty
        else { return .system }
        return .fixed(value)
    }

    /// **Takes effect on the next launch, and the UI says so rather than pretending.**
    /// `AppleLanguages` is read once when the process starts and the whole bundle's string
    /// tables are resolved from it; swapping them under a running app would leave every view
    /// that had already been built in the old language. a native editor carries a `requiresRestart`
    /// for the same reason.
    static func choose(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        switch language {
        case .system:
            defaults.removeObject(forKey: defaultsKey)
            defaults.removeObject(forKey: appleLanguagesKey)
        case .fixed(let value):
            defaults.set(value, forKey: defaultsKey)
            defaults.set([value], forKey: appleLanguagesKey)
        }
    }
}
