import AppKit

/// A version as a list of numbers: "v1.2.3" is [1, 2, 3], and "1.2" equals "1.2.0".
///
/// **Numbers, not text**: "1.10" sorts before "1.9" as a string and is the newer release.
struct ReleaseVersion: Comparable {
    let parts: [Int]
    /// As the release wrote it, less a leading "v": what a person is shown. Comparison uses
    /// `parts`, where 1.2 and 1.2.0 are equal; the page says 1.2.0, so that is what is said.
    let text: String

    init?(_ text: String) {
        let trimmed = text.hasPrefix("v") || text.hasPrefix("V") ? String(text.dropFirst()) : text
        let fields = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { Int($0) }
        guard !fields.isEmpty, numbers.count == fields.count, numbers.allSatisfy({ $0 >= 0 }) else {
            return nil
        }
        // Trailing zeros carry nothing: 1.2 and 1.2.0 are one version.
        var parts = numbers
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        self.parts = parts
        self.text = trimmed
    }

    static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool { lhs.parts == rhs.parts }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = index < lhs.parts.count ? lhs.parts[index] : 0
            let b = index < rhs.parts.count ? rhs.parts[index] : 0
            if a != b { return a < b }
        }
        return false
    }
}

/// What a check found. See `2026-09-27-asking-whether-there-is-a-newer-release.md`.
enum UpdateVerdict: Equatable {
    case upToDate
    case available(version: String, page: URL)
    case noReleaseYet
    case unreadable

    /// Where releases live. The response names a page; it is followed only if it is under here.
    static let releasesPath = "/soredemo-dev/soredemo/releases/"

    /// The verdict for a response to `releases/latest`, given this build's version. Every field
    /// of the response is untrusted: it was written by whoever controls the release.
    static func from(status: Int, body: Data, current: String) -> UpdateVerdict {
        if status == 404 { return .noReleaseYet }
        guard status == 200, let installed = ReleaseVersion(current),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let tag = object["tag_name"] as? String, let latest = ReleaseVersion(tag),
              let pageText = object["html_url"] as? String,
              let page = URL(string: pageText), page.scheme == "https", page.host == "github.com",
              page.path.hasPrefix(releasesPath) else {
            return .unreadable
        }
        return latest > installed ? .available(version: latest.text, page: page) : .upToDate
    }
}

/// Asks GitHub for the latest release and says what it found. **The only app file that talks to
/// a network** — `noOtherAppSourceTalksToANetwork` holds that — and it runs only when a person
/// chose it, from the menu or by turning on the check at launch.
@MainActor
enum UpdateChecker {
    /// Off unless a person turns it on: see the design document for what the request sends.
    static let checksAtLaunchKey = "checksForUpdatesAtLaunch"
    static let latestRelease = URL(string: "https://api.github.com/repos/soredemo-dev/soredemo/releases/latest")

    static var checksAtLaunch: Bool { UserDefaults.standard.bool(forKey: checksAtLaunchKey) }

    /// `userInitiated` decides what is said: a person who asked hears every answer; a check at
    /// launch speaks only when there is something to install.
    static func check(userInitiated: Bool) async {
        let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var verdict = UpdateVerdict.unreadable
        if let url = latestRelease {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            // Ephemeral: no cookies, no cache, nothing written to disk by asking.
            let session = URLSession(configuration: .ephemeral)
            if let (body, response) = try? await session.data(for: request) {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                verdict = UpdateVerdict.from(status: status, body: body, current: installed)
            }
            session.finishTasksAndInvalidate()
        }
        present(verdict, installed: installed, userInitiated: userInitiated)
    }

    private static func present(_ verdict: UpdateVerdict, installed: String, userInitiated: Bool) {
        let alert = NSAlert()
        switch verdict {
        case .available(let version, let page):
            alert.messageText = String(localized: "Soredemo \(version) is available")
            alert.informativeText = String(localized: "You have \(installed). The release page has the download and what changed. If you installed Soredemo with Homebrew, run brew upgrade --cask soredemo instead.")
            alert.addButton(withTitle: String(localized: "Open the Release Page"))
            alert.addButton(withTitle: String(localized: "Later"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
            return
        case .upToDate:
            guard userInitiated else { return }
            alert.messageText = String(localized: "Soredemo \(installed) is the latest version")
        case .noReleaseYet:
            guard userInitiated else { return }
            alert.messageText = String(localized: "No release has been published yet")
        case .unreadable:
            guard userInitiated else { return }
            alert.messageText = String(localized: "Could not check for updates")
            alert.informativeText = String(localized: "GitHub could not be reached, or its answer could not be read. Nothing was changed.")
        }
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
