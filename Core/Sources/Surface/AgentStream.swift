import Foundation

/// What an agent said and did during one turn, in a form the panel draws — **independent of which
/// agent**. A provider turns its own wire format into these; the panel never reads a wire format.
public enum AgentEvent: Equatable, Sendable {
    /// The session began: its id (to resume the next turn), the tools it can call, its model.
    case started(session: String, tools: [String], model: String?)
    /// Text arriving as it is written.
    case textDelta(String)
    /// A finished block of text, which replaces what its deltas built.
    case text(String)
    /// The model's reasoning arriving as it thinks — shown while it runs, folded when it is done.
    case thinkingDelta(String)
    /// A finished block of reasoning, which replaces what its deltas built.
    case thinking(String)
    /// A tool call begun; its arguments are still arriving.
    case toolStarted(id: String, name: String)
    /// A tool call with its whole input, as JSON.
    case toolCalled(id: String, name: String, input: String)
    /// A tool call's result: whether it failed, and its text.
    case toolFinished(id: String, isError: Bool, output: String)
    /// The turn ended. Cost is what the provider reports it would be at API prices; under a
    /// subscription login nothing extra is charged — `started` does not say which, and the panel
    /// must not present this number as a bill.
    case finished(isError: Bool, durationMilliseconds: Int?, costUSD: Double?, session: String?)
    /// The provider could not run at all, in its own words.
    case failed(String)
    /// How full the conversation is: tokens the last request read, and the model's window.
    /// `nil` is "not said here" — a provider reports the two at different moments.
    case contextUsage(usedTokens: Int?, windowTokens: Int?)
    /// The person's account windows as the provider last reported them.
    case limits([UsageWindow])
}

/// A model the person's agent can be asked to use, as its own picker names it.
public struct AgentModel: Equatable, Hashable, Sendable {
    /// What the agent is told: `opus`, `gpt-6.1-sol`.
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// One of the person's account windows — five hours, a week — as their agent's provider reports
/// it. **Reported, never estimated**: a window the provider did not measure is left out rather
/// than shown as 0 %, which would read as room to spare.
public struct UsageWindow: Equatable, Sendable {
    /// The window's length: 300 is five hours, 10080 a week.
    public let minutes: Int
    /// How much of it is used, 0–100, as reported and unclamped.
    public let usedPercent: Double
    /// When it starts over, from the provider's own epoch seconds — not a clock read here.
    public let resets: Date?
    /// The provider says requests in this window are being refused now.
    public let limited: Bool

    public init(minutes: Int, usedPercent: Double, resets: Date?, limited: Bool) {
        self.minutes = minutes
        self.usedPercent = usedPercent
        self.resets = resets
        self.limited = limited
    }

    /// A reset as the provider states it, in seconds since 1970.
    static func resets(atEpochSeconds value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }
}

/// Claude Code's `--output-format stream-json`, one line at a time.
///
/// **Read against a recorded session, not against documentation**:
/// `Tests/SurfaceTests/Fixtures/claude-code-2.1.318-steps.jsonl` is a real run of Claude Code
/// 2.1.318 calling Soredemo's `steps` tool, with personal paths replaced. A line this does not
/// recognise yields nothing rather than an error — the format grows (hooks, rate-limit notices,
/// status lines) and a panel that stopped at the first unknown line would stop working on the
/// next release.
public enum ClaudeStream {
    /// The prefix Claude Code gives a tool from an MCP server named `soredemo`.
    public static let toolPrefix = "mcp__soredemo__"

    public static func events(from line: String) -> [AgentEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        switch type {
        case "system":
            guard object["subtype"] as? String == "init", let session = object["session_id"] as? String else { return [] }
            return [.started(session: session, tools: object["tools"] as? [String] ?? [],
                             model: object["model"] as? String)]
        case "stream_event":
            return streamed(object["event"] as? [String: Any] ?? [:])
        case "assistant":
            let message = object["message"] as? [String: Any] ?? [:]
            let content = message["content"] as? [[String: Any]] ?? []
            return contextRead(message["usage"]) + content.compactMap { block in
                switch block["type"] as? String {
                case "text": (block["text"] as? String).map(AgentEvent.text)
                case "thinking": (block["thinking"] as? String).map(AgentEvent.thinking)
                case "tool_use":
                    (block["id"] as? String).flatMap { id in
                        (block["name"] as? String).map { .toolCalled(id: id, name: $0, input: json(block["input"])) }
                    }
                default: nil
                }
            }
        case "user":
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { block in
                guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
                return .toolFinished(id: id, isError: block["is_error"] as? Bool ?? false, output: text(of: block["content"]))
            }
        case "rate_limit_event":
            let windows = limits(object["rate_limit_info"] as? [String: Any] ?? [:])
            return windows.isEmpty ? [] : [.limits(windows)]
        case "result":
            return contextWindow(object["modelUsage"]) + [.finished(isError: object["is_error"] as? Bool ?? false,
                              durationMilliseconds: object["duration_ms"] as? Int,
                              costUSD: object["total_cost_usd"] as? Double,
                              session: object["session_id"] as? String)]
        default:
            return []
        }
    }

    /// Everything a request read is what fills the window: its input, the cache it wrote and the
    /// cache it read. What it wrote out is not in the window until the next request reads it.
    private static func contextRead(_ usage: Any?) -> [AgentEvent] {
        guard let usage = usage as? [String: Any] else { return [] }
        let read = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            .reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
        return read > 0 ? [.contextUsage(usedTokens: read, windowTokens: nil)] : []
    }

    /// The window of the model that read the most — the one the conversation is with, rather than
    /// a smaller model it used for something on the side.
    private static func contextWindow(_ modelUsage: Any?) -> [AgentEvent] {
        let models = (modelUsage as? [String: [String: Any]] ?? [:]).values
        func read(_ model: [String: Any]) -> Int {
            ["inputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"].reduce(0) { $0 + ((model[$1] as? NSNumber)?.intValue ?? 0) }
        }
        guard let main = models.max(by: { read($0) < read($1) }),
              let window = (main["contextWindow"] as? NSNumber)?.intValue, window > 0 else { return [] }
        return [.contextUsage(usedTokens: nil, windowTokens: window)]
    }

    /// The windows a `rate_limit_event` reports. Claude Code 2.1.318 lists them under
    /// `unifiedWindows`; an event without that list states the one window it is about.
    private static let windowMinutes = ["five_hour": 300, "seven_day": 10080]

    private static func limits(_ info: [String: Any]) -> [UsageWindow] {
        let listed = info["unifiedWindows"] as? [String: [String: Any]]
            ?? (info["rateLimitType"] as? String).map { [$0: info] } ?? [:]
        return listed.compactMap { name, window -> UsageWindow? in
            guard let minutes = windowMinutes[name],
                  let used = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(minutes: minutes, usedPercent: used * 100,
                               resets: UsageWindow.resets(atEpochSeconds: window["resetsAt"]),
                               limited: window["status"] as? String == "rejected")
        }.sorted { $0.minutes < $1.minutes }
    }

    /// A tool's name without the server's prefix — what a person reads in the panel.
    public static func shortName(_ name: String) -> String {
        name.hasPrefix(toolPrefix) ? String(name.dropFirst(toolPrefix.count)) : name
    }

    private static func streamed(_ event: [String: Any]) -> [AgentEvent] {
        switch event["type"] as? String {
        case "content_block_start":
            let block = event["content_block"] as? [String: Any] ?? [:]
            guard block["type"] as? String == "tool_use", let id = block["id"] as? String,
                  let name = block["name"] as? String else { return [] }
            return [.toolStarted(id: id, name: name)]
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any] ?? [:]
            switch delta["type"] as? String {
            case "text_delta": return (delta["text"] as? String).map { [.textDelta($0)] } ?? []
            case "thinking_delta": return (delta["thinking"] as? String).map { [.thinkingDelta($0)] } ?? []
            default: return []
            }
        default:
            return []
        }
    }

    /// A tool result's content is a string, or a list of typed blocks; either reads as its text.
    private static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func json(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
