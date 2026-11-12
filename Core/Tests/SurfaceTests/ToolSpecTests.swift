import Foundation
import Testing
@testable import Surface

// One declaration per tool: the schema a client lists and the checks a call passes are both read
// from it. These tests hold the two together.

private func schema(_ spec: ToolSpec) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(spec.inputSchema.utf8)) as? [String: Any])
}

/// A value that passes a parameter's own check, for building a call that is valid but for one thing.
private func sample(_ parameter: ToolParameter) -> Any {
    switch parameter.kind {
    case .integer(let minimum): return max(minimum ?? 1, 1)
    case .string: return "x"
    case .reason: return "Because step 2 says so"
    }
}

/// The message a call is refused with, or `nil` when it passes.
private func refusal(_ spec: ToolSpec, _ arguments: String) -> String? {
    if case .failure(let failure) = spec.validate(argumentsJSON: arguments) { return failure.message }
    return nil
}

private func json(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

@Suite struct ToolSpecTests {
    @Test func theSchemaListsEveryParameterWithItsTypeAndWhichAreRequired() throws {
        let spec = ToolSpec("t", title: "T", description: "d", readOnly: false, parameters: [
            ToolParameter("count", .integer(minimum: 1), description: "How many."),
            ToolParameter("note", .string(longest: 10, allowsEmpty: true), description: "A note.", required: false),
            .reason,
        ])
        let listed = try schema(spec)
        #expect(listed["type"] as? String == "object")
        #expect(listed["additionalProperties"] as? Bool == false)
        #expect(listed["required"] as? [String] == ["count", "reason"])
        let properties = try #require(listed["properties"] as? [String: [String: Any]])
        #expect(properties["count"]?["type"] as? String == "integer")
        #expect(properties["note"]?["type"] as? String == "string")
        #expect(properties["reason"]?["type"] as? String == "string")
    }

    @Test func aStringIsTrimmedBoundedAndEmptyOnlyWhereAllowed() {
        let spec = ToolSpec("t", title: "T", description: "d", readOnly: false, parameters: [
            ToolParameter("text", .string(longest: 5, allowsEmpty: false), description: "Words.", invalid: "`text` is required."),
            ToolParameter("replace", .string(longest: 5, allowsEmpty: true), description: "Words."),
        ])
        guard case .success(let arguments) = spec.validate(argumentsJSON: #"{"text":"  hi  ","replace":"   "}"#) else {
            Issue.record("a valid call was refused"); return
        }
        #expect(arguments.string("text") == "hi")
        #expect(arguments.string("replace") == "", "an allowed empty string is kept as empty")
        #expect(refusal(spec, #"{"text":"   ","replace":"a"}"#) == "`text` is required.")
        #expect(refusal(spec, #"{"text":"toolong","replace":"a"}"#) == "`text` is 7 characters; keep it under 5.")
    }

    /// **The single source, checked over every tool the agent holds**: whatever the schema calls
    /// required, the validation refuses a call without — and accepts the call with it.
    @Test(arguments: AgentTools.specs.map(\.name))
    func whatTheSchemaCallsRequiredTheValidationRequires(tool: String) throws {
        let spec = try #require(AgentTools.specs.first { $0.name == tool })
        let required = try schema(spec)["required"] as? [String] ?? []
        #expect(required == spec.parameters.filter(\.required).map(\.name).sorted())
        var full: [String: Any] = [:]
        for parameter in spec.parameters { full[parameter.name] = sample(parameter) }
        if case .failure(let failure) = spec.validate(argumentsJSON: json(full)) {
            Issue.record("\(tool): a call with every argument was refused — \(failure.message)")
        }
        for name in required {
            var missing = full
            missing[name] = nil
            guard case .failure = spec.validate(argumentsJSON: json(missing)) else {
                Issue.record("\(tool): the schema requires `\(name)` and a call without it passed"); continue
            }
        }
    }
}
