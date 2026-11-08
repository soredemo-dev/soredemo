import Foundation

/// The surface as an MCP server over stdio: one JSON-RPC message in, at most one out.
///
/// **No SDK** (architecture rule 4), and little is needed: a server that offers tools answers
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

    let reader: any ProjectReading
    let hearing: any Hearing
    let version: String

    public init(reader: any ProjectReading, hearing: any Hearing, version: String) {
        self.reader = reader
        self.hearing = hearing
        self.version = version
    }

    /// What the server tells the agent once, at `initialize`. Said here rather than left to each
    /// tool's description, because it is the one thing every call shares.
    static let instructions = """
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
        case "tools/list": return Self.reply(id: id, result: ["tools": Self.tools])
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
            "instructions": Self.instructions,
        ]
    }

    // MARK: - tools

    /// Each verb that takes a project, as a tool. `verbs` is not one: `tools/list` is that listing.
    static var tools: [[String: Any]] {
        Verb.allCases.filter(\.takesProject).map { verb in
            [
                "name": verb.toolName,
                "title": verb.title,
                "description": verb.summary,
                "inputSchema": [
                    "type": "object",
                    "properties": ["project": ["type": "string",
                                               "description": "Path to a saved .soredemo project package."]],
                    "required": ["project"],
                    "additionalProperties": false,
                ] as [String: Any],
                // All four, stated: an agent's client decides whether to ask the person before a
                // call from these, and an absent hint is read as the cautious default.
                "annotations": ["readOnlyHint": true, "destructiveHint": false,
                                "idempotentHint": true, "openWorldHint": false],
            ]
        }
    }

    private func call(id: Any, _ params: [String: Any]) async -> String {
        guard let name = params["name"] as? String else {
            return Self.reply(id: id, error: (-32602, "Invalid params: tools/call needs a tool name."))
        }
        guard let verb = Verb.allCases.first(where: { $0.takesProject && $0.toolName == name }) else {
            // An unknown tool is a protocol error. A write — accept, publish — is named as such,
            // so an agent does not go looking for one under another spelling.
            let refused = Verb.refused.contains(where: { name.lowercased().contains($0) })
            return Self.reply(id: id, error: (-32602, refused
                ? "Unknown tool: \(name). No tool accepts, applies or publishes; a person does that in Soredemo's editor."
                : "Unknown tool: \(name)."))
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        // Input validation is a tool execution error, not a protocol one, so the model sees it
        // and can correct itself.
        if let extra = arguments.keys.sorted().first(where: { $0 != "project" }) {
            return Self.reply(id: id, result: Self.toolError("Unexpected argument `\(extra)`; the only one is `project`."))
        }
        guard let project = arguments["project"] as? String, !project.isEmpty else {
            return Self.reply(id: id, result: Self.toolError("`project` is required: the path to a .soredemo package."))
        }
        let answer = await SurfaceCommand.answer(verb, project: project, reader: reader, hearing: hearing)
        if let failure = answer.failure {
            return Self.reply(id: id, result: Self.toolError(failure.message, code: failure.code.rawValue))
        }
        let resultJSON = answer.resultJSON ?? "{}"
        let structured = (try? JSONSerialization.jsonObject(with: Data(resultJSON.utf8))) ?? [:]
        // The JSON as text too: the spec asks a server returning structured content to, for
        // clients that read only `content`.
        return Self.reply(id: id, result: ["content": [["type": "text", "text": resultJSON]],
                                           "structuredContent": structured, "isError": false])
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
