/// The verbs an outside caller — a terminal, a script, an agent — can run against a project.
///
/// **One registry, every front end.** The CLI reads this list, and the MCP server in the next
/// stage will publish the same list as its tools, so a verb added here appears in both and a verb
/// missing here exists in neither. See `docs/design/2026-11-08-evidence-cut-and-the-agent-surface.md`.
///
/// **There is no verb that accepts, applies or publishes, and the type is why.** `Kind` has a
/// case for reading and a case for proposing; a verb that changes a project would need a third
/// case, and adding one is a change to this file that a reviewer cannot miss.
public enum Verb: String, CaseIterable, Sendable, Codable {
    case verbs
    case status
    case steps
    case explainFraming = "explain-framing"
    case proposeCut = "propose-cut"

    public enum Kind: String, Sendable, Codable {
        /// Says what the project holds. Changes nothing.
        case read
        /// Says what a producer would cut. **Changes nothing either**: a proposal is accepted by a
        /// person, in the editor.
        case propose
    }

    public var kind: Kind {
        switch self {
        case .verbs, .status, .steps, .explainFraming: .read
        case .proposeCut: .propose
        }
    }

    /// Whether the verb is run against a `.soredemo` package.
    public var takesProject: Bool { self != .verbs }

    /// One line, for the listing a caller reads to find out what exists.
    public var summary: String {
        switch self {
        case .verbs: "List the verbs, what kind each is, and how to call it."
        case .status: "The project's recording, its length, its steps, and how many cuts are pending."
        case .steps: "Each step — a press on a named element — with its number, label, application and span."
        case .explainFraming: "For each click, the zoom it got or the gate that refused it, by name."
        case .proposeCut: "The cuts the rules propose, with what bounded each. Nothing is applied: accept them in the editor."
        }
    }

    public var usage: String {
        takesProject ? "cli \(rawValue) <project.soredemo> [--json]" : "cli \(rawValue) [--json]"
    }

    /// Words a caller might reach for that name something no verb does, each with the reason.
    /// A refusal that says *why* is the difference between an agent that stops and one that
    /// retries with a different spelling.
    static let refused: Set<String> = ["accept", "apply", "cut", "publish", "post", "share", "upload", "edit", "save"]
}
