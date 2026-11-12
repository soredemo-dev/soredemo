import Foundation
import Security
import Surface

/// Reads the plan's usage with the sign-in the panel's own agent uses
/// (`docs/design/2026-11-13-the-plan-usage-before-a-message.md`).
///
/// **The token is read, used for one request to its own provider, and dropped.** It is never
/// stored, logged, shown or put in a message — every failure below says what happened without it.
/// The two addresses are `AccountUsage`'s; this file names no other host.
enum AccountUsageReader {
    enum Outcome: Equatable, Sendable {
        case windows([UsageWindow])
        /// No sign-in where the panel's agent keeps one.
        case notSignedIn
        /// The provider refused the sign-in: for Claude Code, a token it renews when it next runs.
        case expired
        /// A `429`, with its `Retry-After` in seconds.
        case refused(retryAfterSeconds: Int64)
        case failed(String)
    }

    static func read(provider: String) async -> Outcome {
        switch provider {
        case "Claude Code":
            guard let data = claudeKeychainItem(), let token = AccountUsage.claudeToken(fromKeychain: data) else { return .notSignedIn }
            return await request(AccountUsage.claudeEndpoint, headers: ["Authorization": "Bearer \(token)",
                                                                       "anthropic-beta": "oauth-2025-04-20"],
                                 parse: AccountUsage.claudeWindows(fromAnswer:))
        case "Codex":
            let file = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".codex/auth.json")
            guard let data = try? Data(contentsOf: file), let signIn = AccountUsage.codexSignIn(fromAuthFile: data) else {
                return .notSignedIn
            }
            var headers = ["Authorization": "Bearer \(signIn.token)"]
            if let account = signIn.accountID { headers["ChatGPT-Account-Id"] = account }
            return await request(AccountUsage.codexEndpoint, headers: headers, parse: AccountUsage.codexWindows(fromAnswer:))
        default:
            return .notSignedIn
        }
    }

    /// Claude Code's keychain item for its DEFAULT configuration — the one the panel's `claude`
    /// uses, since it is started without `CLAUDE_CONFIG_DIR`. macOS asks the person the first time.
    private static func claudeKeychainItem() -> Data? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                      kSecAttrService: AccountUsage.claudeKeychainService,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func request(_ address: String, headers: [String: String],
                                parse: (Data) -> [UsageWindow]?) async -> Outcome {
        guard let url = URL(string: address) else { return .failed("The address could not be formed.") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("Soredemo", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            return .failed(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            return parse(data).map(Outcome.windows) ?? .failed("The answer could not be read.")
        case 401, 403:
            return .expired
        case 429:
            let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap { Int64($0) } ?? 600
            return .refused(retryAfterSeconds: after)
        default:
            return .failed("The provider answered \(status).")
        }
    }
}
