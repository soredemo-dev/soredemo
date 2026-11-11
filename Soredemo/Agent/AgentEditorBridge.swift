import Compositing
import Foundation
import Framing
import Surface
import Timeline

/// One edit the panel's agent made, as the panel lists it under the turn that made it.
struct AgentEditRecord: Identifiable, Equatable {
    /// Counted by the bridge, not minted: the app reads no ambient value (`AppSourceTests`).
    let id: Int
    /// The undo step's name, exactly as recorded — how "revert this turn" knows it is still on top.
    let stepName: String
    let reason: String
    /// Where it was, for "show me": the first moment of the recording after the cut — on the
    /// recording's clock, which is the playhead's, so nothing converts it.
    let at: SourceTime
    /// How much shorter the edit plays because of it.
    let removed: Nanoseconds
}

/// The live tools, performed against the open editor. **Every request has already passed
/// `AgentTools.request`**; this only looks things up — a step, a proposal — and does them, each
/// edit as one undo step named for the agent and its reason.
@MainActor
final class AgentEditorBridge {
    private let editor: EditorViewModel
    /// The agent's name, the prefix of every undo step it records.
    let agentName: String
    /// Called with each edit, so the panel can list it under the turn.
    var onEdit: (AgentEditRecord) -> Void = { _ in }
    /// Called with each note the agent resolves or leaves open, with what it said.
    var onNote: (PinnedNote) -> Void = { _ in }
    private var lastEdit: AgentEditRecord?
    private var editsMade = 0

    init(editor: EditorViewModel, agentName: String) {
        self.editor = editor
        self.agentName = agentName
    }

    private var anchor: EpochAnchor? { editor.steps.anchor }
    private var duration: Int64 { editor.timeline.duration?.rawValue ?? 0 }

    /// The toolbox the relay serves, calling back here on the main actor.
    nonisolated func toolbox() -> LiveToolbox { LiveToolbox(bridge: self) }

    func recordingDuration() -> Int64 { duration }

    func perform(_ request: AgentTools.Request) -> MCPToolResult {
        switch request {
        case .status: return status()
        case .steps: return steps()
        case .proposeCut: return proposals()
        case .seek(let at):
            // The playhead is on the recording's clock, the clock `at` is on; where that moment
            // plays in the edit is reported beside it, and a moment that no longer plays is refused.
            let moment = SourceTime(nanos: at)
            guard let output = editor.timeline.edit.outputTime(atSource: moment) else {
                return .failure(message: "\(at) ns has been cut from the edit, so the playhead cannot go there.", code: "cut")
            }
            editor.timeline.movePlayhead(to: moment)
            return .success(json: #"{"playheadNanos":\#(at),"playsAtNanos":\#(output.rawValue)}"#)
        case .cutSpan(let start, let end, let reason):
            return cut(start..<end, reason: reason)
        case .cutStep(let number, let reason):
            guard let anchor, let removal = GoalCut.removal(ofStep: number, in: editor.steps.steps) else {
                return .failure(message: "There is no step \(number). Read steps for the numbers.", code: "noSuchStep")
            }
            let start = removal.start.rawValue - anchor.hostTime.rawValue
            return cut(start..<(start + removal.duration.rawValue), reason: reason)
        case .acceptProposal(let id, let reason):
            guard let row = listing()?.rows.first(where: { Self.id(of: $0.proposal) == id }) else {
                return .failure(message: "No pending proposal has the id \(id). Read propose_cut for the current ones.", code: "noSuchProposal")
            }
            return record(reason: reason, source: row.source) { name in editor.timeline.acceptCut(row, named: name) }
        case .notes:
            return notes()
        case .resolveNote(let id, let reason):
            return resolve(id, as: .addressed(reason))
        case .skipNote(let id, let reason):
            return resolve(id, as: .skipped(reason))
        case .undoLastAgentEdit:
            guard let last = lastEdit, editor.timeline.undoStepName == last.stepName else {
                return .failure(message: "The last edit is not yours, or something was edited after it; nothing was undone.", code: "notYours")
            }
            editor.timeline.undo()
            lastEdit = nil
            return .success(json: #"{"undone":true}"#)
        }
    }

    // MARK: - reads

    private func status() -> MCPToolResult {
        let edit = editor.timeline.edit
        let pending = listing()?.rows.count ?? 0
        return json([
            "recordingNanos": duration, "playsNanos": edit.outputDuration.rawValue,
            "playheadNanos": editor.timeline.playhead.rawValue,
            "steps": editor.steps.steps.count, "pendingProposals": pending,
        ])
    }

    private func steps() -> MCPToolResult {
        guard let anchor else { return .failure(message: "This recording has no observation log, so it has no steps.", code: "noObservationLog") }
        return json(["steps": editor.steps.steps.map { step in
            [
                "number": step.number, "label": step.label, "application": step.application ?? NSNull(),
                "startNanos": step.origin.hostTime.rawValue - anchor.hostTime.rawValue,
                "endNanos": step.end.hostTime.rawValue - anchor.hostTime.rawValue,
            ] as [String: Any]
        }])
    }

    private func proposals() -> MCPToolResult {
        guard let listing = listing() else {
            return .failure(message: "This recording has no observation log, so nothing is proposed.", code: "noObservationLog")
        }
        return json(["proposals": listing.rows.map { row in
            [
                "id": Self.id(of: row.proposal), "reason": row.proposal.reason.rawValue,
                "removesStartNanos": row.source.lowerBound, "removesEndNanos": row.source.upperBound,
                "duringStep": row.proposal.duringStep ?? NSNull(),
                "partlyCutAlready": row.survival == .partly,
            ] as [String: Any]
        }, "alreadyCut": listing.alreadyCut, "kept": listing.dismissed])
    }

    private func notes() -> MCPToolResult {
        let anchored = anchor.map { editor.notes.board.anchored(to: editor.steps.steps, anchor: $0) }
            ?? editor.notes.board.notes.map { ($0, nil) }
        return json(["notes": anchored.map { note, step in
            var row: [String: Any] = ["id": note.id, "atNanos": note.at.rawValue, "text": note.text,
                                      "open": note.isOpen]
            if let x = note.x, let y = note.y { row["x"] = x; row["y"] = y }
            if let step { row["step"] = step.number; row["stepLabel"] = step.label }
            switch note.state {
            case .open: break
            case .addressed(let how): row["addressed"] = how
            case .skipped(let why): row["skipped"] = why
            }
            return row
        }])
    }

    private func resolve(_ id: Int, as state: PinnedNote.State) -> MCPToolResult {
        guard editor.notes.resolve(id, as: state),
              let note = editor.notes.board.notes.first(where: { $0.id == id }) else {
            return .failure(message: "No open note has the id \(id). Read notes for the open ones.", code: "noSuchNote")
        }
        onNote(note)
        return .success(json: #"{"resolved":\#(id)}"#)
    }

    private func listing() -> CutReview.Listing? {
        editor.cuts.listing(edit: editor.timeline.edit, dismissed: editor.timeline.dismissedCuts)
    }

    /// A proposal's id an agent can pass back: its reason and the instant its quiet began.
    static func id(of proposal: CutProposal) -> String {
        "\(proposal.key.reason.rawValue)@\(proposal.key.quietStart.hostTime.rawValue)"
    }

    // MARK: - edits

    private func cut(_ range: Range<Int64>, reason: String) -> MCPToolResult {
        guard editor.timeline.edit.survival(ofSource: range) != .gone else {
            return .failure(message: "\(range.lowerBound)…\(range.upperBound) is already cut; nothing changed.", code: "alreadyCut")
        }
        return record(reason: reason, source: range) { name in editor.timeline.removeSourceRange(range, named: name) }
    }

    /// Performs one edit under the agent's name and reports what changed.
    private func record(reason: String, source: Range<Int64>, _ edit: (String) -> Void) -> MCPToolResult {
        let name = "\(agentName): \(reason)"
        let before = editor.timeline.edit.outputDuration.rawValue
        edit(name)
        let after = editor.timeline.edit.outputDuration.rawValue
        let at = SourceTime(nanos: source.upperBound)
        editsMade += 1
        let entry = AgentEditRecord(id: editsMade, stepName: name, reason: reason, at: at, removed: Nanoseconds(before - after))
        lastEdit = entry
        onEdit(entry)
        // What changed, so the agent's next step starts from the timeline as it is now.
        return json(["undoStep": name, "playedNanosBefore": before, "playsNanosNow": after,
                     "removedNanos": before - after])
    }

    private func json(_ object: [String: Any]) -> MCPToolResult {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return .failure(message: "The answer could not be encoded.", code: "internal")
        }
        return .success(json: String(decoding: data, as: UTF8.self))
    }
}

/// The relay's toolbox: `AgentTools`' rules, then the bridge, on the main actor.
struct LiveToolbox: MCPToolbox {
    let bridge: AgentEditorBridge

    nonisolated var tools: [MCPTool] { AgentTools.definitions }

    nonisolated func call(_ name: String, argumentsJSON: String) async -> MCPToolResult? {
        let duration = await bridge.recordingDuration()
        guard let request = AgentTools.request(name, argumentsJSON: argumentsJSON, duration: duration) else { return nil }
        switch request {
        case .failure(let failure): return .failure(message: failure.message, code: "usage")
        case .success(let request): return await bridge.perform(request)
        }
    }
}
