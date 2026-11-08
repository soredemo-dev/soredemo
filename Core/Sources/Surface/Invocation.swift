/// One parsed call: which verb, against which project, in which format.
///
/// **Hand-written, not Swift Argument Parser**, because architecture rule 4 holds every manifest
/// at zero dependencies, and five verbs with one flag cost less than the rule would.
public struct Invocation: Equatable, Sendable {
    public let verb: Verb
    /// The project's path as given; `nil` for a verb that takes none.
    public let project: String?
    /// One JSON envelope per line on stdout, instead of text for a person.
    public let json: Bool

    /// Why a call could not be parsed. Each case names what was wrong, so the message can say
    /// exactly that rather than printing the usage and leaving the caller to work out which part.
    public enum Problem: Error, Equatable, Sendable {
        case noVerb
        case unknownVerb(String)
        /// A word for something no verb does — accept, apply, publish — with that said plainly.
        case refusedVerb(String)
        case unknownFlag(String)
        case missingProject(Verb)
        case unexpectedArgument(String)
    }

    /// Parses what came after `cli`. `--json` may stand anywhere; everything else is positional.
    public static func parse(_ arguments: [String]) -> Result<Invocation, Problem> {
        var json = false
        var positional: [String] = []
        for argument in arguments {
            if argument == "--json" {
                json = true
            } else if argument == "--help" || argument == "-h" {
                positional.insert("verbs", at: 0)
            } else if argument.hasPrefix("-") {
                return .failure(.unknownFlag(argument))
            } else {
                positional.append(argument)
            }
        }
        guard let word = positional.first else { return .failure(.noVerb) }
        let rest = positional.dropFirst()
        guard let verb = Verb(rawValue: word.lowercased() == "help" ? "verbs" : word) else {
            return .failure(Verb.refused.contains(word.lowercased()) ? .refusedVerb(word) : .unknownVerb(word))
        }
        if verb.takesProject {
            guard let project = rest.first else { return .failure(.missingProject(verb)) }
            if let extra = rest.dropFirst().first { return .failure(.unexpectedArgument(extra)) }
            return .success(Invocation(verb: verb, project: project, json: json))
        }
        if let extra = rest.first { return .failure(.unexpectedArgument(extra)) }
        return .success(Invocation(verb: verb, project: nil, json: json))
    }
}

extension Invocation.Problem {
    /// What went wrong, for the person or agent reading stderr.
    public var message: String {
        switch self {
        case .noVerb:
            "No verb given. Run `cli verbs` to list them."
        case .unknownVerb(let word):
            "There is no verb `\(word)`. Run `cli verbs` to list them."
        case .refusedVerb(let word):
            "There is no verb `\(word)`, and there will not be one: this surface reads and proposes. Accepting a cut, changing a project or publishing is done by a person, in the editor."
        case .unknownFlag(let flag):
            "Unknown flag `\(flag)`. The only flag is `--json`."
        case .missingProject(let verb):
            "`\(verb.rawValue)` needs a project: \(verb.usage)"
        case .unexpectedArgument(let argument):
            "Unexpected argument `\(argument)`."
        }
    }
}
