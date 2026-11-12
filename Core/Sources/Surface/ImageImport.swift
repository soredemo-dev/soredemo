import Foundation

/// What `import_image` may fetch and the name it saves under, decided before anything is fetched
/// (`docs/design/2026-11-13-the-agent-may-search-the-web.md`). **The agent names the address;
/// Soredemo fetches it** — so every rule about which addresses are the web lives here, as a pure
/// function a test can hold to each case.
public enum ImageImport {
    /// The most a picture may be. Read with a limit, never trusted from a header.
    public static let largestBytes = 20 * 1024 * 1024
    /// The longest side a decoded picture may have.
    public static let largestSide = 12_000

    /// Why `address` is not a public https site, or `nil` when it is.
    ///
    /// **A name, not an address.** An IP literal is refused outright rather than classified as
    /// public or private: the classification is the part a page would try to fool, and a site a
    /// person would put in a video has a name.
    public static func refusal(for address: String) -> String? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false)?.lowercased() ?? (scheme == "file" ? "" : nil)
        else { return "That is not an address." }
        guard scheme == "https" else { return "Only an https address can be imported; this is \(scheme)." }
        guard url.user == nil, url.password == nil else { return "That address carries a name and password; give one without." }
        if let port = url.port, port != 443 { return "That address names a port, \(port); give one on the usual https port." }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !bare.isEmpty else { return "That is not an address." }
        if bare == "localhost" || bare.hasSuffix(".localhost") { return "\(bare) is this Mac, not the web." }
        if bare.hasSuffix(".local") || bare.hasSuffix(".internal") || bare.hasSuffix(".lan") || !bare.contains(".") && !bare.contains(":") {
            return "\(bare) is on this network, not the web."
        }
        let isIPv4 = bare.split(separator: ".").count == 4 && bare.split(separator: ".").allSatisfy { UInt8($0) != nil }
        if isIPv4 || bare.contains(":") {
            let shown = bare.contains(":") ? "[\(bare)]" : bare
            return "\(shown) is an address, not a site's name; give the page's own address."
        }
        return nil
    }

    /// The name a fetched picture is saved under: the last part of the address, decoded, with
    /// anything but letters, digits, `-` and `_` turned into `-`, and the extension of what it
    /// DECODED as — a file called `.jpeg` that is a PNG is saved as `.png`.
    public static func filename(for address: String, decodedAs fileExtension: String) -> String {
        let path = URL(string: address)?.path(percentEncoded: false) ?? ""
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        let stem = last.contains(".") ? String(last[..<last.lastIndex(of: ".")!]) : last
        var safe = ""
        for character in stem {
            if character.isLetter || character.isNumber || character == "_" { safe.append(character) }
            else if safe.last != "-" { safe.append("-") }
        }
        let trimmed = safe.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(trimmed.isEmpty ? "imported" : String(trimmed.prefix(60)))." + fileExtension.lowercased()
    }
}
