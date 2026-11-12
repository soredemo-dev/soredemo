import Foundation

/// One tool, declared once: what it is called, what it takes, and how each argument is checked.
/// **The input schema a client lists and the validation a call passes through are both read from
/// this declaration**, so the two cannot drift — they were two hand-written things until
/// 2026-11-12, a JSON string beside a `switch` that had to be kept in step by reading both.
public struct ToolSpec: Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let parameters: [ToolParameter]
    public let readOnly: Bool

    public init(_ name: String, title: String, description: String, readOnly: Bool,
                parameters: [ToolParameter] = []) {
        self.name = name
        self.title = title
        self.description = description
        self.readOnly = readOnly
        self.parameters = parameters
    }

    /// The tool as a client lists it.
    public var listing: MCPTool {
        MCPTool(name: name, title: title, description: description, inputSchema: inputSchema, readOnly: readOnly)
    }

    /// JSON Schema for the arguments, generated, with sorted keys so the bytes are stable.
    public var inputSchema: String {
        var properties: [String: Any] = [:]
        for parameter in parameters { properties[parameter.name] = parameter.schema }
        var schema: [String: Any] = ["type": "object", "additionalProperties": false, "properties": properties]
        let required = parameters.filter(\.required).map(\.name).sorted()
        if !required.isEmpty { schema["required"] = required }
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The arguments, each checked against its declaration, or the message the model reads to
    /// correct itself. **An argument the tool does not take is refused first**: a misspelt name
    /// would otherwise read as a missing one, and the message would point at the wrong thing.
    public func validate(argumentsJSON: String) -> Result<ToolArguments, MCPToolResultFailure> {
        let raw = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let known = Set(parameters.map(\.name))
        if let extra = raw.keys.sorted().first(where: { !known.contains($0) }) {
            return .failure(.init("Unexpected argument `\(extra)` for \(name)."))
        }
        var integers: [String: Int64] = [:]
        var strings: [String: String] = [:]
        for parameter in parameters {
            switch parameter.check(raw[parameter.name]) {
            case .failure(let failure): return .failure(failure)
            case .success(.integer(let value)?): integers[parameter.name] = value
            case .success(.string(let value)?): strings[parameter.name] = value
            case .success(nil): continue
            }
        }
        return .success(ToolArguments(integers: integers, strings: strings))
    }
}

/// One argument and its rule. The rule's refusal is written for the model, which reads it and
/// corrects the call — so it says what is wanted, not only what was wrong.
public struct ToolParameter: Sendable {
    public enum Kind: Sendable {
        /// A whole number at least `minimum`, if one is given.
        case integer(minimum: Int64?)
        /// Text, trimmed, at most `longest` characters, empty only when allowed.
        case string(longest: Int, allowsEmpty: Bool)
        /// Why — the undo step's name a person reads. Required, trimmed, at most `AgentTools.longestReason`.
        case reason
    }

    public let name: String
    public let description: String
    public let kind: Kind
    public let required: Bool
    /// What the model is told when the value is missing or of the wrong kind.
    public let invalid: String

    public init(_ name: String, _ kind: Kind, description: String, required: Bool = true, invalid: String? = nil) {
        self.name = name
        self.description = description
        self.kind = kind
        self.required = required
        self.invalid = invalid ?? "`\(name)` is required: \(description)"
    }

    /// The reason every edit carries, with the wording every edit tool shares.
    public static let reason = ToolParameter(
        "reason", .reason,
        description: "Why, in one short sentence a person will read as the undo step's name. Name the step or proposal it rests on.")

    enum Value { case integer(Int64), string(String) }

    var schema: [String: Any] {
        switch kind {
        case .integer: ["type": "integer", "description": description]
        case .string, .reason: ["type": "string", "description": description]
        }
    }

    func check(_ value: Any?) -> Result<Value?, MCPToolResultFailure> {
        switch kind {
        case .integer(let minimum):
            guard let number = value as? NSNumber, !CFNumberIsFloatType(number) else {
                return value == nil && !required ? .success(nil) : .failure(.init(invalid))
            }
            let integer = number.int64Value
            if let minimum, integer < minimum { return .failure(.init(invalid)) }
            return .success(.integer(integer))
        case .string(let longest, let allowsEmpty):
            guard let text = value as? String else {
                return value == nil && !required ? .success(nil) : .failure(.init(invalid))
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, !allowsEmpty { return .failure(.init(invalid)) }
            guard trimmed.count <= longest else {
                return .failure(.init("`\(name)` is \(trimmed.count) characters; keep it under \(longest)."))
            }
            return .success(.string(trimmed))
        case .reason:
            let text = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return .failure(.init("`reason` is required: one sentence a person will read as the undo step."))
            }
            guard text.count <= AgentTools.longestReason else {
                return .failure(.init("`reason` is \(text.count) characters; keep it under \(AgentTools.longestReason) — it is an undo step's name."))
            }
            return .success(.string(text))
        }
    }
}

/// Arguments that passed their declarations. A required one is always present, so reading it is
/// not a question the caller has to answer again.
public struct ToolArguments: Sendable {
    let integers: [String: Int64]
    let strings: [String: String]

    /// A required integer. **Asking for one that was not declared required is a programming error,
    /// and traps** rather than answering 0 — a default inside the legal range would let a missing
    /// argument read as a real one.
    public func integer(_ name: String) -> Int64 {
        guard let value = integers[name] else { preconditionFailure("`\(name)` was not declared as a required integer") }
        return value
    }

    /// A required string, trimmed. Traps on an undeclared name, for `integer`'s reason.
    public func string(_ name: String) -> String {
        guard let value = strings[name] else { preconditionFailure("`\(name)` was not declared as a required string") }
        return value
    }

    /// An optional string, `nil` when it was not given.
    public func optionalString(_ name: String) -> String? { strings[name] }
}
