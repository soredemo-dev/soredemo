import Foundation

/// The tools the agent in Soredemo's own panel holds: the reads, over the **open** editor, and the
/// edits. Defined here and validated here, so every rule about what an agent may ask for is a unit
/// test; the app only performs a request that has already passed.
///
/// **Times are nanoseconds on the recording's clock**, the clock `steps` and `propose_cut` report
/// in, so an agent can pass a span it read straight back. Every edit needs a `reason`, which
/// becomes the undo step's name a person reads.
public enum AgentTools {
    public static let status = "status"
    public static let steps = "steps"
    public static let proposeCut = "propose_cut"
    public static let cutSpan = "cut_span"
    public static let cutStep = "cut_step"
    public static let acceptProposal = "accept_proposal"
    public static let seek = "seek"
    public static let undoLastAgentEdit = "undo_last_agent_edit"
    public static let notes = "notes"
    public static let resolveNote = "resolve_note"
    public static let skipNote = "skip_note"

    /// Shortest span an agent may cut: under this a cut is a slip of the arithmetic, not an edit.
    public static let shortestCut: Int64 = 100_000_000
    /// Longest reason kept: it is an undo step's name, read in a menu.
    public static let longestReason = 160

    private static let none = #"{"additionalProperties":false,"properties":{},"type":"object"}"#
    private static let reason = #""reason":{"description":"Why, in one short sentence a person will read as the undo step's name. Name the step or proposal it rests on.","type":"string"}"#

    public static let definitions: [MCPTool] = [
        MCPTool(name: status, title: "Project status",
                description: "The open recording: its length, what still plays, its steps, the playhead, and how many cuts are pending.",
                inputSchema: none, readOnly: true),
        MCPTool(name: steps, title: "Recorded steps",
                description: "Each step — a press on a named element — with its number, label, application and span on the recording's clock.",
                inputSchema: none, readOnly: true),
        MCPTool(name: proposeCut, title: "Pending cut proposals",
                description: "The cuts the rules propose for the open recording (dead air), each with an id, the span it removes, and what bounded it. Accept one with accept_proposal.",
                inputSchema: none, readOnly: true),
        MCPTool(name: cutSpan, title: "Cut a span",
                description: "Remove a span of the recording from the edit, now, as one undo step. Prefer cut_step or accept_proposal when one fits.",
                inputSchema: #"{"additionalProperties":false,"properties":{"endNanos":{"description":"End, nanoseconds on the recording's clock.","type":"integer"},"#
                    + reason + #","startNanos":{"description":"Start, nanoseconds on the recording's clock.","type":"integer"}},"required":["startNanos","endNanos","reason"],"type":"object"}"#,
                readOnly: false),
        MCPTool(name: cutStep, title: "Cut a step",
                description: "Remove one whole step — a second before its press to a second before the next — as one undo step.",
                inputSchema: #"{"additionalProperties":false,"properties":{"#
                    + reason + #","step":{"description":"The step's number, from steps.","type":"integer"}},"required":["step","reason"],"type":"object"}"#,
                readOnly: false),
        MCPTool(name: acceptProposal, title: "Accept a proposed cut",
                description: "Make one of propose_cut's proposals, by its id, as one undo step.",
                inputSchema: #"{"additionalProperties":false,"properties":{"id":{"description":"The proposal's id, from propose_cut.","type":"string"},"#
                    + reason + #"},"required":["id","reason"],"type":"object"}"#,
                readOnly: false),
        MCPTool(name: seek, title: "Move the playhead",
                description: "Move the playhead so the person sees the moment you are talking about. Changes no edit.",
                inputSchema: #"{"additionalProperties":false,"properties":{"atNanos":{"description":"Nanoseconds on the recording's clock.","type":"integer"}},"required":["atNanos"],"type":"object"}"#,
                readOnly: true),
        MCPTool(name: undoLastAgentEdit, title: "Undo your last edit",
                description: "Undo the most recent edit, only if it was yours and nothing was edited after it.",
                inputSchema: none, readOnly: false),
        MCPTool(name: notes, title: "Pinned notes",
                description: "The notes the person pinned on the recording: each with its id, its time on the recording's clock, the step it falls in, the point on the picture if any, its words, and whether it is still open.",
                inputSchema: none, readOnly: true),
        MCPTool(name: resolveNote, title: "Mark a note addressed",
                description: "Mark an open note addressed, after you have made the edit it asks for. Say what you did; the person reads it beside their note.",
                inputSchema: #"{"additionalProperties":false,"properties":{"id":{"description":"The note's id, from notes.","type":"integer"},"#
                    + reason + #"},"required":["id","reason"],"type":"object"}"#,
                readOnly: false),
        MCPTool(name: skipNote, title: "Leave a note open",
                description: "Leave an open note as it is because you cannot or should not do what it asks, and say why. It stays for the person.",
                inputSchema: #"{"additionalProperties":false,"properties":{"id":{"description":"The note's id, from notes.","type":"integer"},"#
                    + reason + #"},"required":["id","reason"],"type":"object"}"#,
                readOnly: false),
    ]

    /// A request that passed every check. What the app performs.
    public enum Request: Equatable, Sendable {
        case status, steps, proposeCut, undoLastAgentEdit
        case cutSpan(start: Int64, end: Int64, reason: String)
        case cutStep(Int, reason: String)
        case acceptProposal(id: String, reason: String)
        case seek(Int64)
        case notes
        case resolveNote(Int, reason: String)
        case skipNote(Int, reason: String)
    }

    /// The request a call makes, or the message the model reads to correct itself. `nil` for a
    /// name that is not one of these tools. `duration` is the recording's length, the one bound a
    /// span is checked against; whether a step or a proposal exists is the editor's to say.
    public static func request(_ name: String, argumentsJSON: String, duration: Int64) -> Result<Request, MCPToolResultFailure>? {
        guard let tool = definitions.first(where: { $0.name == name }) else { return nil }
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let allowed = Set((try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8)) as? [String: Any])
            .flatMap { $0["properties"] as? [String: Any] }?.keys.map { $0 } ?? [])
        if let extra = arguments.keys.sorted().first(where: { !allowed.contains($0) }) {
            return .failure(.init("Unexpected argument `\(extra)` for \(name)."))
        }
        func integer(_ key: String) -> Int64? {
            (arguments[key] as? NSNumber).flatMap { CFNumberIsFloatType($0) ? nil : $0.int64Value }
        }
        func why() -> Result<String, MCPToolResultFailure> {
            let text = (arguments["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .failure(.init("`reason` is required: one sentence a person will read as the undo step.")) }
            guard text.count <= longestReason else {
                return .failure(.init("`reason` is \(text.count) characters; keep it under \(longestReason) — it is an undo step's name."))
            }
            return .success(text)
        }
        switch name {
        case status: return .success(.status)
        case steps: return .success(.steps)
        case proposeCut: return .success(.proposeCut)
        case undoLastAgentEdit: return .success(.undoLastAgentEdit)
        case notes: return .success(.notes)
        case resolveNote, skipNote:
            guard let id = integer("id"), id > 0, id <= Int64(Int.max) else {
                return .failure(.init("`id` must be a note's id from notes."))
            }
            return why().map { name == resolveNote ? .resolveNote(Int(id), reason: $0) : .skipNote(Int(id), reason: $0) }
        case seek:
            guard let at = integer("atNanos") else { return .failure(.init("`atNanos` must be an integer.")) }
            guard (0...duration).contains(at) else {
                return .failure(.init("`atNanos` \(at) is outside the recording, 0…\(duration)."))
            }
            return .success(.seek(at))
        case cutSpan:
            guard let start = integer("startNanos"), let end = integer("endNanos") else {
                return .failure(.init("`startNanos` and `endNanos` must be integers, nanoseconds on the recording's clock."))
            }
            guard start >= 0, end <= duration else {
                return .failure(.init("\(start)…\(end) runs outside the recording, 0…\(duration)."))
            }
            guard end - start >= shortestCut else {
                return .failure(.init("\(start)…\(end) is \(end - start) ns; the shortest cut is \(shortestCut) ns (0.1 s). Check the arithmetic."))
            }
            return why().map { .cutSpan(start: start, end: end, reason: $0) }
        case cutStep:
            guard let step = integer("step"), step > 0, step <= Int64(Int.max) else {
                return .failure(.init("`step` must be a step number from steps."))
            }
            return why().map { .cutStep(Int(step), reason: $0) }
        case acceptProposal:
            guard let id = arguments["id"] as? String, !id.isEmpty else {
                return .failure(.init("`id` is required: a proposal's id from propose_cut."))
            }
            return why().map { .acceptProposal(id: id, reason: $0) }
        default:
            return nil
        }
    }
}

/// A tool's failure message, as a value a `Result` can carry.
public struct MCPToolResultFailure: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
