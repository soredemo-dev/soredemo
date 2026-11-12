import Foundation

/// How the person's Codex is started so that it holds Soredemo's tools and nothing else.
///
/// **Measured, not documented** — `docs/research/agent-native-designs.md`, "Codex, measured", and
/// the design document's "Codex, as designed". Turning `computer_use` off left computer use
/// reachable through a plugin and through MCP servers the person had configured with another app;
/// the person's own hooks ran in the session; Codex's code mode is how dynamic tools are called,
/// so it stays on. Each switch below is one of those findings.
public enum CodexAppServer {
    /// The prefix Soredemo's tools carry on the wire, so they cannot collide with Codex's own.
    public static let toolPrefix = "soredemo_"

    /// Switched off with `--disable`.
    public static let closedFeatures = ["shell_tool", "unified_exec", "browser_use", "computer_use",
                                        "in_app_browser", "multi_agent", "remote_plugin", "hooks"]

    /// Set as configuration: plugins and apps are how computer use and connected services came back
    /// with `computer_use` off, and web search is a setting rather than a feature.
    static let closingConfiguration = closing(webAccess: false)

    /// The configuration with web search opened or not — the one switch the panel offers
    /// (`docs/design/2026-11-13-the-agent-may-search-the-web.md`). Everything else stays closed.
    static func closing(webAccess: Bool) -> [String] {
        ["-c", "features.plugins=false", "-c", "features.apps=false",
         "-c", webAccess ? #"web_search="live""# : #"web_search="disabled""#]
    }

    /// The listing of the person's MCP servers, read **under the same switches**, so a plugin's
    /// servers — closed by `features.plugins=false` — do not appear in it.
    public static var listingArguments: [String] { closingConfiguration + ["mcp", "list", "--json"] }

    /// The servers' names, or `nil` when the listing cannot be read. **Never `[]` for a failure**:
    /// no servers is a legal answer, and starting Codex on a misread listing would leave every
    /// server it failed to name switched on.
    public static func serverNames(fromListing text: String) -> [String]? {
        guard let entries = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any] else { return nil }
        var names: [String] = []
        for entry in entries {
            guard let name = (entry as? [String: Any])?["name"] as? String, !name.isEmpty else { return nil }
            names.append(name)
        }
        return names
    }

    /// The arguments that start the server with every listed MCP server switched off by name.
    /// The names come from the listing, never from a list written here: a list of what we close
    /// rots by omission, and the server it omits is the one that stays on.
    public static func serverArguments(closing servers: [String], webAccess: Bool = false) -> [String] {
        let entries = servers.map { "\(tomlString($0))={enabled=false}" }.joined(separator: ",")
        return closing(webAccess: webAccess)
            + ["-c", "mcp_servers={\(entries)}"]
            + closedFeatures.flatMap { ["--disable", $0] }
            + ["app-server"]
    }

    /// The models the person's Codex lists in its own `/model` picker, read from the cache it
    /// keeps (`~/.codex/models_cache.json`) — no request of our own, and the panel offers what the
    /// person's account can use. Hidden models are left out; order is the cache's `priority`.
    public static func models(fromCache data: Data) -> [AgentModel] {
        let entries = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["models"] as? [[String: Any]] ?? []
        return entries.enumerated()
            .compactMap { index, entry -> (AgentModel, Int)? in
                guard let slug = entry["slug"] as? String, !slug.isEmpty,
                      entry["visibility"] as? String ?? "list" == "list" else { return nil }
                let label = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug
                return (AgentModel(id: slug, label: label), (entry["priority"] as? Int) ?? Int.max - entries.count + index)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// A TOML basic string. JSON's string escapes are TOML's, once `/` is left unescaped.
    static func tomlString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// One conversation with `codex app-server`, as a value: lines in, lines and events out.
///
/// **Every rule about what Codex may do in Soredemo is here, where a test can reach it**; the
/// provider in the app only moves lines between this and the process, and runs the tool calls
/// this hands it. Read against a recorded session of Codex 0.167.0
/// (`Tests/SurfaceTests/Fixtures/codex-0.167.0-steps.jsonl`).
///
/// The host is the **second** line of defence. The first is `CodexAppServer.serverArguments`:
/// a call that asks nothing completes before any check here could see it, so what is reachable
/// must already be closed. What this adds: every request is answered without granting anything,
/// the thread's own report of its sandbox is checked before a turn is sent, and anything a turn
/// starts that is not one of the few kinds a Soredemo turn is made of interrupts it.
public struct CodexSession: Sendable {
    /// A JSON-RPC id, as Codex sent it: it numbers its own requests from 0.
    public enum RequestID: Equatable, Sendable {
        case number(Int)
        case text(String)
    }

    public enum Output: Equatable, Sendable {
        /// A line to write to the server.
        case send(String)
        /// Something for the panel.
        case event(AgentEvent)
        /// Run one of Soredemo's tools, then send `CodexSession.reply(to:with:)`.
        case callTool(RequestID, name: String, argumentsJSON: String)
        /// The turn is over; the panel's stream for it ends.
        case turnEnded
    }

    /// The only tools Codex's own toolset may contribute: listing MCP resources, read-only, and
    /// empty here because every server is off. Codex calls them when it looks around.
    static let codexReadOnlyTools: Set<String> = ["list_mcp_resources", "list_mcp_resource_templates"]

    /// The kinds of item a Soredemo turn is made of, apart from tool calls, which are checked by
    /// name. **A list of what passes, so a kind Codex adds tomorrow interrupts the turn** — loud,
    /// and named in the panel — rather than running unseen.
    static let passingKinds: Set<String> = ["userMessage", "agentMessage", "reasoning", "plan", "contextCompaction"]

    private enum Purpose { case initialize, threadStart, turnStart, interrupt, limits }

    private let tools: [MCPTool]
    private let instructions: String
    private let workingDirectory: String
    /// Whether a web search in a turn is the person's choice rather than a foreign item.
    private let webAccess: Bool

    private var initialized = false
    private var thread: String?
    private var turn: String?
    private var running = false
    private var pending: (message: String, model: String?)?
    private var interruptWanted = false
    private var stoppedForeign = false
    /// What this turn has already said went wrong: Codex states one error twice.
    private var said: Set<String> = []
    private var counted = 0
    private var waiting: [Int: Purpose] = [:]

    public init(tools: [MCPTool], instructions: String, workingDirectory: String, webAccess: Bool = false) {
        self.webAccess = webAccess
        self.tools = tools
        self.instructions = instructions
        self.workingDirectory = workingDirectory
    }

    /// Starts a turn: the handshake first if this is the first, a thread if there is none.
    /// Nothing while a turn runs — the panel sends one message at a time.
    public mutating func begin(message: String, model: String?) -> [Output] {
        guard !running else { return [] }
        running = true
        interruptWanted = false
        stoppedForeign = false
        said = []
        pending = (message, model)
        if !initialized {
            return [request("initialize", ["clientInfo": ["name": "soredemo", "version": "1"],
                                           "capabilities": ["experimentalApi": true]], .initialize)]
        }
        return thread == nil ? [threadStart()] : startTurn()
    }

    /// The next message starts a new thread. Between turns only.
    public mutating func newThread() {
        guard !running else { return }
        thread = nil
    }

    /// Stop: interrupt the running turn — now, or as soon as Codex says which turn it is.
    public mutating func interrupt() -> [Output] {
        guard running else { return [] }
        guard let thread, let turn else {
            interruptWanted = true
            return []
        }
        return [request("turn/interrupt", ["threadId": thread, "turnId": turn], .interrupt)]
    }

    /// The process is gone. The turn ends, and the next message starts from the handshake.
    public mutating func processEnded(reason: String) -> [Output] {
        let wasRunning = running
        initialized = false
        thread = nil
        turn = nil
        running = false
        pending = nil
        waiting = [:]
        return wasRunning ? [.event(.failed("Codex stopped (\(reason)).")), .turnEnded] : []
    }

    /// A tool's answer, as the reply to Codex's `item/tool/call`.
    public static func reply(to id: RequestID, with result: MCPToolResult) -> String {
        let (text, success): (String, Bool) = switch result {
        case .success(let json): (json, true)
        case .failure(let message, _): (message, false)
        }
        return line(["id": id.json, "result": ["contentItems": [["type": "inputText", "text": text]], "success": success]])
    }

    /// One line from the server.
    public mutating func receive(_ text: String) -> [Output] {
        guard let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [] }
        let method = message["method"] as? String
        let id = RequestID(message["id"])
        let params = message["params"] as? [String: Any] ?? [:]
        switch (method, id) {
        case (let method?, let id?): return answer(method, id: id, params: params)
        case (let method?, nil): return notified(method, params)
        case (nil, .number(let number)?): return responded(number, message)
        default: return []
        }
    }

    // MARK: - what Codex asks

    private func answer(_ method: String, id: RequestID, params: [String: Any]) -> [Output] {
        let result: [String: Any]
        switch method {
        case "item/tool/call":
            let name = params["tool"] as? String ?? ""
            if let tool = ownTool(name) {
                return [.callTool(id, name: tool, argumentsJSON: Self.json(params["arguments"]))]
            }
            return [.send(Self.reply(to: id, with: .failure(message: "There is no tool named \(name) here.", code: "usage")))]
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            // `cancel` declines and ends the turn; the item that asked has already stopped it.
            result = ["decision": "cancel"]
        case "mcpServer/elicitation/request":
            result = ["action": "decline", "content": NSNull()]
        case "item/permissions/requestApproval":
            result = ["permissions": [String: Any](), "scope": "turn", "strictAutoReview": true]
        case "applyPatchApproval", "execCommandApproval":
            result = ["decision": "abort"]
        case "item/tool/requestUserInput":
            return [refuse(id, "Soredemo cannot ask the person in the middle of a turn. End the turn with your question instead.")]
        default:
            return [refuse(id, "Soredemo does not answer \(method).")]
        }
        return [.send(Self.line(["id": id.json, "result": result]))]
    }

    private func refuse(_ id: RequestID, _ message: String) -> Output {
        .send(Self.line(["id": id.json, "error": ["code": -32000, "message": message]]))
    }

    // MARK: - what Codex reports

    private mutating func notified(_ method: String, _ params: [String: Any]) -> [Output] {
        if let other = params["threadId"] as? String, other != thread { return [] }
        switch method {
        case "item/agentMessage/delta":
            return (params["delta"] as? String).map { [.event(.textDelta($0))] } ?? []
        case "item/reasoning/summaryTextDelta":
            return (params["delta"] as? String).map { [.event(.thinkingDelta($0))] } ?? []
        case "item/started":
            return started(params["item"] as? [String: Any] ?? [:], turn: params["turnId"] as? String)
        case "item/completed":
            return completed(params["item"] as? [String: Any] ?? [:])
        case "turn/completed":
            return turnCompleted(params["turn"] as? [String: Any] ?? [:])
        case "thread/tokenUsage/updated":
            // `last` is the request just made, which is the context now; `total` is the thread's
            // running spend, which is not.
            let usage = params["tokenUsage"] as? [String: Any] ?? [:]
            guard let used = ((usage["last"] as? [String: Any])?["totalTokens"] as? NSNumber)?.intValue, used > 0 else { return [] }
            let window = (usage["modelContextWindow"] as? NSNumber)?.intValue
            return [.event(.contextUsage(usedTokens: used, windowTokens: window.flatMap { $0 > 0 ? $0 : nil }))]
        case "account/rateLimits/updated":
            return Self.limits(params["rateLimits"] as? [String: Any] ?? [:], refused: false)
        case "error":
            guard params["willRetry"] as? Bool != true,
                  let text = (params["error"] as? [String: Any])?["message"] as? String else { return [] }
            return fail(text)
        default:
            return []
        }
    }

    private mutating func started(_ item: [String: Any], turn itemTurn: String?) -> [Output] {
        let kind = item["type"] as? String ?? ""
        let id = item["id"] as? String ?? ""
        if Self.passingKinds.contains(kind) { return [] }
        // Shown as a tool, so the panel lists it beside Soredemo's — the person sees it searched.
        if kind == "webSearch", webAccess {
            return [.event(.toolStarted(id: id, name: "web_search")),
                    .event(.toolCalled(id: id, name: "web_search", input: Self.json(["query": item["query"] ?? ""])))]
        }
        if kind == "dynamicToolCall", let tool = ownTool(item["tool"] as? String ?? "") {
            return [.event(.toolStarted(id: id, name: tool)),
                    .event(.toolCalled(id: id, name: tool, input: Self.json(item["arguments"])))]
        }
        if kind == "mcpToolCall", item["server"] as? String == "codex",
           let tool = item["tool"] as? String, Self.codexReadOnlyTools.contains(tool) {
            return [.event(.toolStarted(id: id, name: tool)),
                    .event(.toolCalled(id: id, name: tool, input: Self.json(item["arguments"])))]
        }
        return stopForeign(Self.describe(item), turn: itemTurn)
    }

    /// The account's windows from a rate-limit snapshot — the notification's and the read's are
    /// the same shape. `refused` is the read's `ordinaryUsageAllowed: false`, which the schema
    /// says to believe over the percentages.
    static func limits(_ snapshot: [String: Any], refused alsoRefused: Bool) -> [Output] {
        let measured = ["primary", "secondary"].compactMap { key -> (minutes: Int, used: Double, resets: Date?)? in
            guard let window = snapshot[key] as? [String: Any],
                  let used = (window["usedPercent"] as? NSNumber)?.doubleValue,
                  let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue else { return nil }
            return (minutes, used, UsageWindow.resets(atEpochSeconds: window["resetsAt"]))
        }
        // `rateLimitReachedType` says THAT requests are refused (`rate_limit_reached`, a
        // workspace's credits used up) and not which window — so a full window is the one,
        // and with none full the whole account is refused.
        let refused = alsoRefused || snapshot["rateLimitReachedType"] is String
        let anyFull = measured.contains { $0.used >= 100 }
        let windows = measured.map {
            UsageWindow(minutes: $0.minutes, usedPercent: $0.used, resets: $0.resets,
                        limited: refused && (!anyFull || $0.used >= 100))
        }
        return windows.isEmpty ? [] : [.event(.limits(windows))]
    }

    /// A failure, once per turn however many times Codex states it.
    private mutating func fail(_ text: String) -> [Output] {
        guard said.insert(text).inserted else { return [] }
        return [.event(.failed(text))]
    }

    private mutating func stopForeign(_ what: String, turn itemTurn: String?) -> [Output] {
        guard !stoppedForeign else { return [] }
        stoppedForeign = true
        var outputs: [Output] = [.event(.failed("Codex began to use \(what), which is not one of Soredemo's tools, so Soredemo stopped the turn."))]
        if let thread, let target = itemTurn ?? turn {
            outputs.append(request("turn/interrupt", ["threadId": thread, "turnId": target], .interrupt))
        } else {
            interruptWanted = true
        }
        return outputs
    }

    private func completed(_ item: [String: Any]) -> [Output] {
        let id = item["id"] as? String ?? ""
        switch item["type"] as? String {
        case "agentMessage":
            let text = item["text"] as? String ?? ""
            return text.isEmpty ? [] : [.event(.text(text))]
        case "reasoning":
            let summary = (item["summary"] as? [String] ?? []).joined(separator: "\n")
            let text = summary.isEmpty ? (item["content"] as? [String] ?? []).joined(separator: "\n") : summary
            return text.isEmpty ? [] : [.event(.thinking(text))]
        case "dynamicToolCall":
            guard ownTool(item["tool"] as? String ?? "") != nil else { return [] }
            let output = (item["contentItems"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            let failed = item["success"] as? Bool != true || item["status"] as? String == "failed"
            return [.event(.toolFinished(id: id, isError: failed, output: output))]
        case "webSearch":
            guard webAccess else { return [] }
            return [.event(.toolFinished(id: id, isError: false, output: item["query"] as? String ?? ""))]
        case "mcpToolCall":
            guard item["server"] as? String == "codex", Self.codexReadOnlyTools.contains(item["tool"] as? String ?? "") else { return [] }
            let content = (item["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return [.event(.toolFinished(id: id, isError: item["status"] as? String == "failed",
                                         output: content.compactMap { $0["text"] as? String }.joined(separator: "\n")))]
        default:
            return []
        }
    }

    private mutating func turnCompleted(_ finished: [String: Any]) -> [Output] {
        guard running else { return [] }
        if let mine = turn, let id = finished["id"] as? String, id != mine { return [] }
        let failed = finished["status"] as? String == "failed"
        var outputs: [Output] = []
        if failed {
            outputs += fail((finished["error"] as? [String: Any])?["message"] as? String ?? "Codex ended the turn with an error.")
        }
        outputs.append(.event(.finished(isError: failed || stoppedForeign,
                                        durationMilliseconds: finished["durationMs"] as? Int,
                                        costUSD: nil, session: thread)))
        return outputs + endTurn()
    }

    private mutating func endTurn() -> [Output] {
        running = false
        turn = nil
        pending = nil
        interruptWanted = false
        return [.turnEnded]
    }

    // MARK: - replies to our requests

    private mutating func responded(_ number: Int, _ message: [String: Any]) -> [Output] {
        guard let purpose = waiting.removeValue(forKey: number) else { return [] }
        let result = message["result"] as? [String: Any] ?? [:]
        if let error = message["error"] as? [String: Any] {
            // Neither an interrupt nor a windows read that fails stops the turn.
            guard purpose != .interrupt, purpose != .limits else { return [] }
            let text = error["message"] as? String ?? "no message"
            return [.event(.failed("Codex refused to start the turn: \(text)"))] + endTurn()
        }
        switch purpose {
        case .initialize:
            initialized = true
            let ready = Output.send(Self.line(["method": "initialized"]))
            return [ready] + (thread == nil ? [threadStart()] : startTurn())
        case .threadStart:
            let sandbox = (result["sandbox"] as? [String: Any])?["type"] as? String ?? "none reported"
            let approval = result["approvalPolicy"] as? String ?? "none reported"
            guard sandbox == "readOnly", approval == "untrusted" else {
                return [.event(.failed("Codex started the thread with sandbox \(sandbox) and approval policy \(approval). Soredemo runs it only read-only and untrusted, so nothing was sent."))] + endTurn()
            }
            guard let id = (result["thread"] as? [String: Any])?["id"] as? String else {
                return [.event(.failed("Codex started a thread without an id."))] + endTurn()
            }
            thread = id
            return [.event(.started(session: id, tools: tools.map(\.name), model: result["model"] as? String))] + startTurn()
        case .turnStart:
            turn = (result["turn"] as? [String: Any])?["id"] as? String
            if interruptWanted { interruptWanted = false; return interrupt() }
            return []
        case .interrupt:
            return []
        case .limits:
            return Self.limits(result["rateLimits"] as? [String: Any] ?? [:],
                               refused: result["ordinaryUsageAllowed"] as? Bool == false)
        }
    }

    // MARK: - messages

    private mutating func threadStart() -> Output {
        let dynamicTools: [[String: Any]] = tools.map { tool in
            ["type": "function", "name": CodexAppServer.toolPrefix + tool.name, "description": tool.description,
             "inputSchema": (try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8))) ?? [String: Any]()]
        }
        return request("thread/start", ["approvalPolicy": "untrusted", "sandbox": "read-only", "ephemeral": true,
                                        "cwd": workingDirectory, "developerInstructions": instructions,
                                        "dynamicTools": dynamicTools], .threadStart)
    }

    /// The turn, and the account's windows read beside it — so a turn the account refuses at
    /// once still shows the windows that refused it, where the notification would not come.
    private mutating func startTurn() -> [Output] {
        [turnStart(), request("account/rateLimits/read", ["excludeResetCreditDetails": true], .limits)]
    }

    private mutating func turnStart() -> Output {
        var params: [String: Any] = ["threadId": thread ?? "", "approvalPolicy": "untrusted",
                                     "input": [["type": "text", "text": pending?.message ?? ""]]]
        if let model = pending?.model { params["model"] = model }
        return request("turn/start", params, .turnStart)
    }

    private mutating func request(_ method: String, _ params: [String: Any], _ purpose: Purpose) -> Output {
        counted += 1
        waiting[counted] = purpose
        return .send(Self.line(["id": counted, "method": method, "params": params]))
    }

    /// Soredemo's tool behind a wire name, or `nil` for any other name.
    private func ownTool(_ wireName: String) -> String? {
        guard wireName.hasPrefix(CodexAppServer.toolPrefix) else { return nil }
        let name = String(wireName.dropFirst(CodexAppServer.toolPrefix.count))
        return tools.contains { $0.name == name } ? name : nil
    }

    /// What a person reads for an item that is not Soredemo's.
    static func describe(_ item: [String: Any]) -> String {
        switch item["type"] as? String ?? "" {
        case "mcpToolCall": "\(item["server"] as? String ?? "?"): \(item["tool"] as? String ?? "?")"
        case "commandExecution": "a shell command"
        case "fileChange": "a file change"
        case "webSearch": "web search"
        case "dynamicToolCall": "a tool named \(item["tool"] as? String ?? "?")"
        case let kind: "an item of kind \(kind)"
        }
    }

    static func line(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func json(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension CodexSession.RequestID {
    /// `nil` for a message with no id — a notification.
    init?(_ value: Any?) {
        switch value {
        case let number as NSNumber where !CFNumberIsFloatType(number): self = .number(number.intValue)
        case let text as String: self = .text(text)
        default: return nil
        }
    }

    var json: Any {
        switch self {
        case .number(let number): number
        case .text(let text): text
        }
    }
}
