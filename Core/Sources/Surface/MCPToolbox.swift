import Foundation

/// One tool as a client lists it. **Read-only is a property of the tool, stated**, because the
/// in-app toolbox holds tools that edit and a client decides from these hints whether to ask.
public struct MCPTool: Sendable, Equatable {
    public let name: String
    public let title: String
    public let description: String
    /// The input's JSON Schema, as JSON text.
    public let inputSchema: String
    public let readOnly: Bool

    public init(name: String, title: String, description: String, inputSchema: String, readOnly: Bool) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
    }
}

/// A tool's answer: a JSON object, or a message the model reads and can correct itself from.
public enum MCPToolResult: Sendable, Equatable {
    case success(json: String)
    case failure(message: String, code: String)
}

/// What an MCP server offers. **Two exist, and the protocol is what lets one server serve both**:
/// `ReadOnlyToolbox`, over a saved package, for a terminal or any outside client — nobody is
/// watching, so nothing writes; and the app's live toolbox, for the agent a person is watching in
/// the panel, which reads and edits the open editor. The JSON-RPC around them is one code path.
public protocol MCPToolbox: Sendable {
    var tools: [MCPTool] { get }
    /// `nil` when no tool has this name — a protocol error, not a tool's failure.
    func call(_ name: String, argumentsJSON: String) async -> MCPToolResult?
}

/// The registry's verbs over a saved package: read and propose, never write.
public struct ReadOnlyToolbox: MCPToolbox {
    let reader: any ProjectReading
    let hearing: any Hearing

    public init(reader: any ProjectReading, hearing: any Hearing) {
        self.reader = reader
        self.hearing = hearing
    }

    static let projectSchema = #"{"additionalProperties":false,"properties":{"project":{"description":"Path to a saved .soredemo project package.","type":"string"}},"required":["project"],"type":"object"}"#

    /// Each verb that takes a project, as a tool. `verbs` is not one: `tools/list` is that listing.
    public var tools: [MCPTool] {
        Verb.allCases.filter(\.takesProject).map {
            MCPTool(name: $0.toolName, title: $0.title, description: $0.summary,
                    inputSchema: Self.projectSchema, readOnly: true)
        }
    }

    public func call(_ name: String, argumentsJSON: String) async -> MCPToolResult? {
        guard let verb = Verb.allCases.first(where: { $0.takesProject && $0.toolName == name }) else { return nil }
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        // Input validation is a tool execution error, not a protocol one, so the model sees it
        // and can correct itself.
        if let extra = arguments.keys.sorted().first(where: { $0 != "project" }) {
            return .failure(message: "Unexpected argument `\(extra)`; the only one is `project`.", code: "usage")
        }
        guard let project = arguments["project"] as? String, !project.isEmpty else {
            return .failure(message: "`project` is required: the path to a .soredemo package.", code: "usage")
        }
        let answer = await SurfaceCommand.answer(verb, project: project, reader: reader, hearing: hearing)
        if let failure = answer.failure { return .failure(message: failure.message, code: failure.code.rawValue) }
        return .success(json: answer.resultJSON ?? "{}")
    }
}
