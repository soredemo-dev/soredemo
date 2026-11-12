import Foundation

/// The tools the agent in Soredemo's own panel holds: the reads, over the **open** editor, and the
/// edits. Declared once as `ToolSpec`s — the schema a client lists and the checks a call passes are
/// both read from the declaration — and validated here, so every rule about what an agent may ask
/// for is a unit test; the app only performs a request that has already passed.
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
    public static let captions = "captions"
    public static let fixCaption = "fix_caption"
    public static let fixCaptionsEverywhere = "fix_captions_everywhere"
    public static let useOnScreenSpelling = "use_on_screen_spelling"

    /// Shortest span an agent may cut: under this a cut is a slip of the arithmetic, not an edit.
    public static let shortestCut: Int64 = 100_000_000
    /// Longest reason kept: it is an undo step's name, read in a menu.
    public static let longestReason = 160
    /// Longest caption line an agent may write: two lines of a caption, generously.
    public static let longestCaption = 200
    /// Longest run replaced everywhere: a name or a phrase, not a sentence.
    public static let longestRun = 80
    /// Shortest run replaced everywhere — the same as a person's "Fix them too", for its reason:
    /// replacing every "a" is a change nobody can predict. `Overlays.RunEdit.shortestRun` is the
    /// person's half; Surface does not see Overlays, so the two are held equal by a test.
    public static let shortestRun = 2

    private static let noteID = ToolParameter("id", .integer(minimum: 1), description: "The note's id, from notes.",
                                              invalid: "`id` must be a note's id from notes.")
    private static let nanosInvalid = "`startNanos` and `endNanos` must be integers, nanoseconds on the recording's clock."

    public static let specs: [ToolSpec] = editSpecs + lookSpecs + overlaySpecs + zoomSpecs

    static let editSpecs: [ToolSpec] = [
        ToolSpec(status, title: "Project status",
                 description: "The open recording: its length, what still plays, its steps, the playhead, and how many cuts are pending.",
                 readOnly: true),
        ToolSpec(steps, title: "Recorded steps",
                 description: "Each step — a press on a named element — with its number, label, application and span on the recording's clock.",
                 readOnly: true),
        ToolSpec(proposeCut, title: "Pending cut proposals",
                 description: "The cuts the rules propose for the open recording (dead air), each with an id, the span it removes, and what bounded it. Accept one with accept_proposal.",
                 readOnly: true),
        ToolSpec(cutSpan, title: "Cut a span",
                 description: "Remove a span of the recording from the edit, now, as one undo step. Prefer cut_step or accept_proposal when one fits.",
                 readOnly: false,
                 parameters: [ToolParameter("startNanos", .integer(minimum: nil), description: "Start, nanoseconds on the recording's clock.", invalid: nanosInvalid),
                              ToolParameter("endNanos", .integer(minimum: nil), description: "End, nanoseconds on the recording's clock.", invalid: nanosInvalid),
                              .reason]),
        ToolSpec(cutStep, title: "Cut a step",
                 description: "Remove one whole step — a second before its press to a second before the next — as one undo step.",
                 readOnly: false,
                 parameters: [ToolParameter("step", .integer(minimum: 1), description: "The step's number, from steps.",
                                            invalid: "`step` must be a step number from steps."),
                              .reason]),
        ToolSpec(acceptProposal, title: "Accept a proposed cut",
                 description: "Make one of propose_cut's proposals, by its id, as one undo step.",
                 readOnly: false,
                 parameters: [ToolParameter("id", .string(longest: 200, allowsEmpty: false), description: "The proposal's id, from propose_cut.",
                                            invalid: "`id` is required: a proposal's id from propose_cut."),
                              .reason]),
        ToolSpec(seek, title: "Move the playhead",
                 description: "Move the playhead so the person sees the moment you are talking about. Changes no edit.",
                 readOnly: true,
                 parameters: [ToolParameter("atNanos", .integer(minimum: nil), description: "Nanoseconds on the recording's clock.",
                                            invalid: "`atNanos` must be an integer.")]),
        ToolSpec(undoLastAgentEdit, title: "Undo your last edit",
                 description: "Undo the most recent edit, only if it was yours and nothing was edited after it.",
                 readOnly: false),
        ToolSpec(notes, title: "Pinned notes",
                 description: "The notes the person pinned on the recording: each with its id, its time on the recording's clock, the step it falls in, the point on the picture if any, its words, and whether it is still open.",
                 readOnly: true),
        ToolSpec(resolveNote, title: "Mark a note addressed",
                 description: "Mark an open note addressed, after you have made the edit it asks for. Say what you did; the person reads it beside their note.",
                 readOnly: false, parameters: [noteID, .reason]),
        ToolSpec(skipNote, title: "Leave a note open",
                 description: "Leave an open note as it is because you cannot or should not do what it asks, and say why. It stays for the person.",
                 readOnly: false, parameters: [noteID, .reason]),
        ToolSpec(captions, title: "Captions",
                 description: "The caption lines, numbered from 1, each with its span on the recording's clock, its text, and the word the recogniser was least sure of when it was unsure; the names list; and the corrections the screen suggests — words on screen during the recording that are close to something misheard, each with an id and where it came from.",
                 readOnly: true),
        ToolSpec(fixCaption, title: "Fix a caption line",
                 description: "Replace one line's text, keeping its timing, as one undo step. For a word or name the recogniser misheard: one edit may change at most a third of the line's words (at least two; a Chinese or Japanese character counts as a word). Never rewrite what was said. For the same fix in many lines use fix_captions_everywhere.",
                 readOnly: false,
                 parameters: [ToolParameter("line", .integer(minimum: 1), description: "The line's number, from captions.",
                                            invalid: "`line` must be a line number from captions."),
                              ToolParameter("text", .string(longest: longestCaption, allowsEmpty: false),
                                            description: "The line's whole new text.",
                                            invalid: "`text` is required: the line's whole new text. This tool does not delete a line; tell the person which one to delete."),
                              .reason]),
        ToolSpec(fixCaptionsEverywhere, title: "Fix a run in every line",
                 description: "Replace a run of text in every caption line that has it, and add the replacement to the names list so transcribing again keeps it — one undo step. The same bound as fix_caption applies to every line it changes.",
                 readOnly: false,
                 parameters: [ToolParameter("find", .string(longest: longestRun, allowsEmpty: false), description: "The run as the captions have it now.",
                                            invalid: "`find` is required: the run as the captions have it now."),
                              ToolParameter("replace", .string(longest: longestRun, allowsEmpty: false), description: "What it should be.",
                                            invalid: "`replace` is required: what the run should be."),
                              .reason]),
        ToolSpec(useOnScreenSpelling, title: "Use an on-screen spelling",
                 description: "Accept one of the corrections captions suggests from the screen, by its id: the spelling replaces the misheard run in every line it is in and joins the names list, as one undo step.",
                 readOnly: false,
                 parameters: [ToolParameter("id", .string(longest: 200, allowsEmpty: false), description: "The suggestion's id, from captions.",
                                            invalid: "`id` is required: a suggestion's id from captions."),
                              .reason]),
    ]

    /// The tools as a client lists them.
    public static var definitions: [MCPTool] { specs.map(\.listing) }

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
        case captions
        case fixCaption(line: Int, text: String, reason: String)
        case fixCaptionsEverywhere(find: String, replace: String, reason: String)
        case useOnScreenSpelling(id: String, reason: String)
        case look
        case setLook(LookChange, reason: String)
        case setCursor(CursorChange, reason: String)
        case setAudio(AudioChange, reason: String)
        case overlays
        case overlay(OverlayEdit, reason: String)
        case zooms
        case setZoom(Int, on: Bool, reason: String)
    }

    /// The request a call makes, or the message the model reads to correct itself. `nil` for a
    /// name that is not one of these tools. `duration` is the recording's length, the one bound a
    /// span is checked against; whether a step or a proposal exists is the editor's to say.
    public static func request(_ name: String, argumentsJSON: String, duration: Int64) -> Result<Request, MCPToolResultFailure>? {
        guard let spec = specs.first(where: { $0.name == name }) else { return nil }
        let arguments: ToolArguments
        switch spec.validate(argumentsJSON: argumentsJSON) {
        case .failure(let failure): return .failure(failure)
        case .success(let checked): arguments = checked
        }
        if let answer = lookRequest(name, arguments) { return answer }
        if let answer = overlayRequest(name, arguments, duration: duration) { return answer }
        if name == "zooms" { return .success(.zooms) }
        if name == "set_zoom" {
            return .success(.setZoom(Int(arguments.integer("zoom")), on: arguments.bool("on"), reason: arguments.string("reason")))
        }
        switch name {
        case status: return .success(.status)
        case steps: return .success(.steps)
        case proposeCut: return .success(.proposeCut)
        case undoLastAgentEdit: return .success(.undoLastAgentEdit)
        case notes: return .success(.notes)
        case resolveNote:
            return .success(.resolveNote(Int(arguments.integer("id")), reason: arguments.string("reason")))
        case skipNote:
            return .success(.skipNote(Int(arguments.integer("id")), reason: arguments.string("reason")))
        case seek:
            let at = arguments.integer("atNanos")
            guard (0...duration).contains(at) else {
                return .failure(.init("`atNanos` \(at) is outside the recording, 0…\(duration)."))
            }
            return .success(.seek(at))
        case cutSpan:
            let start = arguments.integer("startNanos"), end = arguments.integer("endNanos")
            guard start >= 0, end <= duration else {
                return .failure(.init("\(start)…\(end) runs outside the recording, 0…\(duration)."))
            }
            guard end - start >= shortestCut else {
                return .failure(.init("\(start)…\(end) is \(end - start) ns; the shortest cut is \(shortestCut) ns (0.1 s). Check the arithmetic."))
            }
            return .success(.cutSpan(start: start, end: end, reason: arguments.string("reason")))
        case cutStep:
            return .success(.cutStep(Int(arguments.integer("step")), reason: arguments.string("reason")))
        case acceptProposal:
            return .success(.acceptProposal(id: arguments.string("id"), reason: arguments.string("reason")))
        case captions:
            return .success(.captions)
        case fixCaption:
            return .success(.fixCaption(line: Int(arguments.integer("line")), text: arguments.string("text"),
                                        reason: arguments.string("reason")))
        case fixCaptionsEverywhere:
            let find = arguments.string("find"), replace = arguments.string("replace")
            guard find.count >= shortestRun else {
                return .failure(.init("`find` is \(find.count) character\(find.count == 1 ? "" : "s"); the shortest run replaced everywhere is \(shortestRun)."))
            }
            guard find != replace else {
                return .failure(.init("`find` and `replace` are the same; nothing would change."))
            }
            return .success(.fixCaptionsEverywhere(find: find, replace: replace, reason: arguments.string("reason")))
        case useOnScreenSpelling:
            return .success(.useOnScreenSpelling(id: arguments.string("id"), reason: arguments.string("reason")))
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

extension AgentTools {
    /// The zooms the clicks produced, and turning one off or on. Moving one in time is the
    /// person's, on the timeline, for now: a turned-off zoom is a decision a reason can carry,
    /// and a nudge of a few frames is judged by eye.
    static let zoomSpecs: [ToolSpec] = [
        ToolSpec("zooms", title: "The zooms",
                 description: "Each zoom the clicks produced, numbered from 1 in time order: its span on the recording's clock, how far it goes in, the step it belongs to, and whether it is on.",
                 readOnly: true),
        ToolSpec("set_zoom", title: "Turn a zoom off or on",
                 description: "Turn one zoom off, so the camera stays wide through that click, or back on — as one undo step.",
                 readOnly: false,
                 parameters: [ToolParameter("zoom", .integer(minimum: 1), description: "The zoom's number, from zooms.",
                                            invalid: "`zoom` must be a zoom's number from zooms."),
                              ToolParameter("on", .boolean, description: "true for on, false for off."),
                              .reason]),
    ]
}
