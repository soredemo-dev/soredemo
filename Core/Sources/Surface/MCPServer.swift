import Foundation

/// The surface as an MCP server over stdio: one JSON-RPC message in, at most one out.
///
/// **No SDK, by choice rather than by rule.** Rule 4 has admitted `modelcontextprotocol` since
/// 2026-11-08, and the package still holds zero dependencies because little is needed: a server
/// that offers tools answers
/// `initialize`, `ping`, `tools/list` and `tools/call`, and ignores notifications. The transport —
/// a line on stdin, a line on stdout — is the app entry point's; this type only maps a message to
/// its reply, so every rule below is tested without a process.
///
/// **The tools are the registry's verbs** (`Verb`), each run through `SurfaceCommand.answer`, the
/// same function the terminal calls. **Every tool is annotated read-only**, and that is not a hint
/// to be trusted but a fact the type enforces: there is no verb that writes.
///
/// Protocol: https://modelcontextprotocol.io/specification/2025-11-25 — lifecycle, tools, stdio.
public struct MCPServer: Sendable {
    /// Newest first. A client asking for one of these gets it; any other gets the newest, which
    /// is what the lifecycle's version negotiation asks a server to answer.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    let toolbox: any MCPToolbox
    let version: String
    let instructions: String

    public init(toolbox: any MCPToolbox, version: String, instructions: String = MCPServer.instructions) {
        self.toolbox = toolbox
        self.version = version
        self.instructions = instructions
    }

    /// The read-only server over a saved package — what `Soredemo mcp` runs on its own.
    public init(reader: any ProjectReading, hearing: any Hearing, version: String) {
        self.init(toolbox: ReadOnlyToolbox(reader: reader, hearing: hearing), version: version)
    }

    /// What the server tells the agent once, at `initialize`. Said here rather than left to each
    /// tool's description, because it is the one thing every call shares.
    public static let instructions = """
        Soredemo is a screen recorder that keeps an observation log beside each recording — the \
        steps a person took, where they clicked, why each click was or was not zoomed. These tools \
        read a saved .soredemo project and propose cuts. None of them changes a project: a \
        proposed cut is accepted, or kept, by a person in Soredemo's editor (the Cuts tab), and \
        nothing is ever published. Times are integer nanoseconds from the recording's start.
        """

    /// The reply to one line, or `nil` when the line is a notification, which is never answered.
    public func handle(_ line: String) async -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let message = object as? [String: Any] else {
            return Self.reply(id: NSNull(), error: (-32700, "Parse error: not a JSON-RPC object."))
        }
        let id = message["id"]
        guard message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            // A response from the client, or nonsense. Neither has anything to answer unless it
            // carries an id the client is waiting on.
            return id.map { Self.reply(id: $0, error: (-32600, "Invalid request: expected jsonrpc 2.0 and a method.")) }
        }
        // A notification has no id and is never answered — `notifications/initialized` included.
        guard let id else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize": return Self.reply(id: id, result: initialize(params))
        case "ping": return Self.reply(id: id, result: [:])
        case "tools/list": return Self.reply(id: id, result: ["tools": toolbox.tools.map(Self.listing)])
        case "tools/call": return await call(id: id, params)
        default: return Self.reply(id: id, error: (-32601, "Method not found: \(method)"))
        }
    }

    private func initialize(_ params: [String: Any]) -> [String: Any] {
        let asked = params["protocolVersion"] as? String
        let agreed = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
        return [
            "protocolVersion": agreed,
            // `listChanged: false`: the tools are this build's verbs and do not change while it runs.
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "soredemo", "title": "Soredemo", "version": version],
            "instructions": instructions,
        ]
    }

    // MARK: - tools

    /// A tool as `tools/list` carries it. All four hints, stated: a client decides from them
    /// whether to ask the person before a call, and an absent hint is read as the cautious default.
    /// An edit is not destructive — it is one undo step — and not idempotent: twice is two cuts.
    static func listing(_ tool: MCPTool) -> [String: Any] {
        [
            "name": tool.name,
            "title": tool.title,
            "description": tool.description,
            "inputSchema": (try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8))) ?? ["type": "object"],
            "annotations": ["readOnlyHint": tool.readOnly, "destructiveHint": false,
                            "idempotentHint": tool.readOnly, "openWorldHint": false],
        ]
    }

    private func call(id: Any, _ params: [String: Any]) async -> String {
        guard let name = params["name"] as? String else {
            return Self.reply(id: id, error: (-32602, "Invalid params: tools/call needs a tool name."))
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let argumentsJSON = (try? JSONSerialization.data(withJSONObject: arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        guard let result = await toolbox.call(name, argumentsJSON: argumentsJSON) else {
            // An unknown tool is a protocol error. A publish is named as such, so an agent does
            // not go looking for one under another spelling; an edit outside the panel likewise.
            let lowered = name.lowercased()
            let message: String
            if ["publish", "post", "share", "upload"].contains(where: lowered.contains) {
                message = "Unknown tool: \(name). Nothing publishes: a person does that, always."
            } else if Verb.refused.contains(where: lowered.contains) {
                message = "Unknown tool: \(name). Edits are made only by the agent in Soredemo's own panel, where a person is watching; this server reads."
            } else {
                message = "Unknown tool: \(name)."
            }
            return Self.reply(id: id, error: (-32602, message))
        }
        switch result {
        case .failure(let message, let code):
            return Self.reply(id: id, result: Self.toolError(message, code: code))
        case .success(let json):
            let structured = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [:]
            // The JSON as text too: the spec asks a server returning structured content to, for
            // clients that read only `content`.
            return Self.reply(id: id, result: ["content": [["type": "text", "text": json]],
                                               "structuredContent": structured, "isError": false])
        }
    }

    private static func toolError(_ message: String, code: String = "usage") -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true,
         "structuredContent": ["error": ["code": code, "message": message]]]
    }

    // MARK: - JSON-RPC

    /// One line, keys sorted, no embedded newline — stdio's framing forbids one.
    private static func line(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]) else {
            preconditionFailure("an MCP reply failed to serialise")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func reply(id: Any, result: [String: Any]) -> String {
        line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func reply(id: Any, error: (code: Int, message: String)) -> String {
        line(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
    }
}

extension Verb {
    /// The verb's MCP tool name: the same word, with underscores, which every client accepts.
    public var toolName: String { rawValue.replacingOccurrences(of: "-", with: "_") }

    /// For a client's tool list.
    public var title: String {
        switch self {
        case .verbs: "List verbs"
        case .status: "Project status"
        case .steps: "Recorded steps"
        case .explainFraming: "Explain the zooms"
        case .proposeCut: "Propose cuts"
        }
    }
}
