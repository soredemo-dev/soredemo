import Foundation

/// A plan's usage, read with the sign-in the panel's own agent uses
/// (`docs/design/2026-11-13-the-plan-usage-before-a-message.md`). Parsing only: the app reads the
/// keychain and the file and makes the request. **No token passes through here into anything
/// that keeps it** — each function returns it or a number and nothing else.
public enum AccountUsage {
    public static let claudeKeychainService = "Claude Code-credentials"
    public static let claudeEndpoint = "https://api.anthropic.com/api/oauth/usage"
    public static let codexEndpoint = "https://chatgpt.com/backend-api/wham/usage"
    /// The only hosts a usage request goes to. The app's network test admits the file that makes
    /// the requests only while it names no other.
    public static let hosts = ["api.anthropic.com", "chatgpt.com"]

    /// The Claude Code sign-in from its keychain item, or `nil`.
    public static func claudeToken(fromKeychain data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (object["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String,
              !token.isEmpty else { return nil }
        return token
    }

    /// Codex's ChatGPT sign-in from `auth.json`, or `nil` — including for an API key, which is not
    /// a plan and has no plan windows.
    public static func codexSignIn(fromAuthFile data: Data) -> (token: String, accountID: String?)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        return (token, tokens["account_id"] as? String)
    }

    /// Codex's windows, as measured: `used_percent` 0–100, `limit_window_seconds`, `reset_at`.
    /// `nil` when there are none, or a reading is out of range — never an empty or a zero answer.
    public static func codexWindows(fromAnswer data: Data) -> [UsageWindow]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = object["rate_limit"] as? [String: Any] else { return nil }
        let reached = limits["limit_reached"] as? Bool == true
        var windows: [UsageWindow] = []
        for key in ["primary_window", "secondary_window"] {
            guard let window = limits[key] as? [String: Any] else { continue }
            guard let used = (window["used_percent"] as? NSNumber)?.doubleValue, (0...100).contains(used),
                  let seconds = (window["limit_window_seconds"] as? NSNumber)?.intValue, seconds > 0 else { return nil }
            windows.append(UsageWindow(minutes: seconds / 60, usedPercent: used,
                                       resets: UsageWindow.resets(atEpochSeconds: window["reset_at"]),
                                       limited: reached && used >= 100))
        }
        return windows.isEmpty ? nil : windows.sorted { $0.minutes < $1.minutes }
    }

    /// Claude's windows. **Not measured** (D6b-36): `utilization` or `used_percentage`, a value of at
    /// most 1 read as a fraction as the stream's is; anything outside 0–100 refuses the answer.
    public static func claudeWindows(fromAnswer data: Data) -> [UsageWindow]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var windows: [UsageWindow] = []
        for (key, minutes) in [("five_hour", 300), ("seven_day", 10080)] {
            guard let window = object[key] as? [String: Any] else { continue }
            guard let raw = ((window["utilization"] ?? window["used_percentage"]) as? NSNumber)?.doubleValue,
                  raw >= 0 else { return nil }
            let percent = raw <= 1 ? raw * 100 : raw
            guard percent <= 100 else { return nil }
            let resets = (window["resets_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                ?? UsageWindow.resets(atEpochSeconds: window["resets_at"])
            windows.append(UsageWindow(minutes: minutes, usedPercent: percent, resets: resets, limited: percent >= 100))
        }
        return windows.isEmpty ? nil : windows
    }
}

/// When to ask the provider, as a function of the times involved — monotonic nanoseconds the app
/// supplies, so no clock is read here. A reading from the agent's own stream counts as an answer.
public struct UsageRefresh: Sendable, Equatable {
    public static let interval: Int64 = 15 * 60_000_000_000
    public static let firstBackoff: Int64 = 30_000_000_000
    public static let staleAfter: Int64 = 30 * 60_000_000_000

    private var lastAnswer: Int64?
    private var lastFailure: Int64?
    private var failures = 0
    private var retryAt: Int64?

    public init() {}

    public func shouldAsk(now: Int64, panelOpen: Bool) -> Bool {
        guard panelOpen else { return false }
        if let retryAt, now < retryAt { return false }
        if let lastFailure, now < lastFailure + backoff { return false }
        if let lastAnswer, now < lastAnswer + Self.interval { return false }
        return true
    }

    /// Thirty seconds after the first failure, doubling, at most the interval.
    private var backoff: Int64 {
        min(Self.firstBackoff << Int64(max(failures - 1, 0)), Self.interval)
    }

    public mutating func answered(at now: Int64) {
        lastAnswer = now
        lastFailure = nil
        failures = 0
        retryAt = nil
    }

    public mutating func failed(at now: Int64) {
        lastFailure = now
        failures += 1
    }

    /// A `429`: nothing is asked again until `Retry-After` has passed.
    public mutating func refused(at now: Int64, retryAfterSeconds: Int64) {
        failed(at: now)
        retryAt = now + retryAfterSeconds * 1_000_000_000
    }

    /// Whether the reading on show is older than thirty minutes. Nothing read is not stale.
    public func isStale(now: Int64) -> Bool {
        guard let lastAnswer else { return false }
        return now - lastAnswer > Self.staleAfter
    }
}
