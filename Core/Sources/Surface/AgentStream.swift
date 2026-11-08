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
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { block in
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
        case "result":
            return [.finished(isError: object["is_error"] as? Bool ?? false,
                              durationMilliseconds: object["duration_ms"] as? Int,
                              costUSD: object["total_cost_usd"] as? Double,
                              session: object["session_id"] as? String)]
        default:
            return []
        }
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
