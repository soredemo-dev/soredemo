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
    case .number(let minimum, _): return minimum
    case .boolean: return true
    case .choice(let options): return options[0]
    case .color: return "#1A2B3C"
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

    /// A number is held to its range and the refusal says the range; an integer passes as a
    /// number; anything else is refused with what was wanted.
    @Test func aNumberIsInItsRangeAndTheRefusalSaysTheRange() {
        let spec = ToolSpec("t", title: "T", description: "d", readOnly: false, parameters: [
            ToolParameter("size", .number(minimum: 0.5, maximum: 3), description: "How big.", required: false),
        ])
        guard case .success(let a) = spec.validate(argumentsJSON: #"{"size":2}"#) else { Issue.record("refused 2"); return }
        #expect(a.optionalNumber("size") == 2)
        #expect(refusal(spec, #"{"size":3.5}"#) == "`size` is 3.5; it goes from 0.5 to 3.")
        #expect(refusal(spec, #"{"size":"big"}"#) == "`size` must be a number from 0.5 to 3.")
        #expect(refusal(spec, #"{"size":true}"#) == "`size` must be a number from 0.5 to 3.",
                "a JSON true is an NSNumber of 1, and would pass the range")
        guard case .success(let none) = spec.validate(argumentsJSON: "{}") else { Issue.record("refused nothing"); return }
        #expect(none.optionalNumber("size") == nil, "an optional number not given is absent, not zero")
    }

    /// A boolean is a JSON boolean — not 1, not "yes" — and a choice is one of its options.
    @Test func aBooleanIsABooleanAndAChoiceIsOneOfItsOptions() {
        let spec = ToolSpec("t", title: "T", description: "d", readOnly: false, parameters: [
            ToolParameter("hide", .boolean, description: "Hide it.", required: false),
            ToolParameter("pace", .choice(["gentle", "standard", "snappy"]), description: "How fast.", required: false),
        ])
        guard case .success(let a) = spec.validate(argumentsJSON: #"{"hide":false,"pace":"snappy"}"#) else { Issue.record("refused"); return }
        #expect(a.optionalBool("hide") == false)
        #expect(a.optionalString("pace") == "snappy")
        #expect(refusal(spec, #"{"hide":1}"#) == "`hide` must be true or false.")
        #expect(refusal(spec, #"{"pace":"brisk"}"#) == "`pace` must be one of: gentle, standard, snappy.")
    }

    /// A colour is six hex digits after a hash, given back upper-case.
    @Test func aColourIsSixHexDigitsAfterAHash() {
        let spec = ToolSpec("t", title: "T", description: "d", readOnly: false, parameters: [
            ToolParameter("color", .color, description: "A colour.", required: false),
        ])
        guard case .success(let a) = spec.validate(argumentsJSON: ##"{"color":" #a1b2c3 "}"##) else { Issue.record("refused"); return }
        #expect(a.optionalString("color") == "#A1B2C3")
        #expect(refusal(spec, #"{"color":"red"}"#) == "`color` must be a colour written #RRGGBB.")
        #expect(refusal(spec, ##"{"color":"#12345"}"##) == "`color` must be a colour written #RRGGBB.")
        #expect(refusal(spec, ##"{"color":"#GGGGGG"}"##) == "`color` must be a colour written #RRGGBB.",
                "seven characters with a hash are not yet a colour")
    }

    /// What the schema says of each kind: a range, an enumeration, a pattern.
    @Test func theSchemaCarriesRangesOptionsAndPatterns() throws {
        let spec = ToolSpec("t", title: "T", description: "d", readOnly: false, parameters: [
            ToolParameter("size", .number(minimum: 0.5, maximum: 3), description: "d", required: false),
            ToolParameter("pace", .choice(["a", "b"]), description: "d", required: false),
            ToolParameter("color", .color, description: "d", required: false),
            ToolParameter("hide", .boolean, description: "d", required: false),
        ])
        let properties = try #require(try schema(spec)["properties"] as? [String: [String: Any]])
        #expect(properties["size"]?["type"] as? String == "number")
        #expect(properties["size"]?["minimum"] as? Double == 0.5)
        #expect(properties["size"]?["maximum"] as? Double == 3)
        #expect(properties["pace"]?["enum"] as? [String] == ["a", "b"])
        #expect(properties["color"]?["pattern"] as? String == "^#[0-9A-Fa-f]{6}$")
        #expect(properties["hide"]?["type"] as? String == "boolean")
    }
}
