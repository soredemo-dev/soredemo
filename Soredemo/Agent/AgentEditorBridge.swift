import Compositing
import Foundation
import Framing
import Overlays
import Project
import Surface
import Timeline

/// One edit the panel's agent made, as the panel lists it under the turn that made it.
struct AgentEditRecord: Identifiable, Equatable {
    /// Counted by the bridge, not minted: the app reads no ambient value (`AppSourceTests`).
    let id: Int
    /// The undo step's name, exactly as recorded — how "revert this turn" knows it is still on top.
    let stepName: String
    let reason: String
    /// Where it was, for "show me" — on the recording's clock, which is the playhead's, so nothing
    /// converts it. After a cut, the first moment after it; after a caption edit, the first line
    /// it changed.
    let at: SourceTime
    let kind: Kind

    enum Kind: Equatable {
        /// A cut, and how much shorter the edit plays because of it.
        case cut(removed: Nanoseconds)
        /// A zoom turned on or off, by its number.
        case zoom(number: Int, on: Bool)
        /// A caption edit: the lines it changed, numbered from one, and the captions either side
        /// of it — what a revert checks is still there, and what it puts back.
        case caption(lines: [Int], before: CaptionsModel.Snapshot, after: CaptionsModel.Snapshot)
        /// A change to the look, the cursor or the sound: the fields it changed, and the look
        /// either side of it.
        case look(changed: [String], before: EditorLook, after: EditorLook)
    }

    var isCut: Bool { if case .cut = kind { true } else { false } }
    /// A step on the TIMELINE's history — a cut or a zoom — which a revert undoes there.
    var isTimelineStep: Bool {
        switch kind {
        case .cut, .zoom: true
        case .caption, .look: false
        }
    }
}

/// The live tools, performed against the open editor. **Every request has already passed
/// `AgentTools.request`**; this only looks things up — a step, a proposal — and does them, each
/// edit as one undo step named for the agent and its reason.
@MainActor
final class AgentEditorBridge {
    let editor: EditorViewModel
    /// The agent's name, the prefix of every undo step it records.
    let agentName: String
    /// Called with each edit, so the panel can list it under the turn.
    var onEdit: (AgentEditRecord) -> Void = { _ in }
    /// Called with each note the agent resolves or leaves open, with what it said.
    var onNote: (PinnedNote) -> Void = { _ in }
    var lastEdit: AgentEditRecord?
    var editsMade = 0

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
        case .captions:
            return captions()
        case .fixCaption(let line, let text, let reason):
            return fixCaption(line, to: text, reason: reason)
        case .fixCaptionsEverywhere(let find, let replace, let reason):
            return fixEverywhere(find, with: replace, reason: reason)
        case .useOnScreenSpelling(let id, let reason):
            guard let suggestion = editor.captions.suggestions.first(where: { $0.id == id }) else {
                return .failure(message: "No suggestion has the id \(id). Read captions for the current ones.", code: "noSuchSuggestion")
            }
            return recordCaption(reason: reason) { name in editor.captions.accept(suggestion, named: name) }
        case .look:
            return lookReport()
        case .setLook(let change, let reason):
            return setLook(change, reason: reason)
        case .setCursor(let change, let reason):
            return setCursor(change, reason: reason)
        case .setAudio(let change, let reason):
            return setAudio(change, reason: reason)
        case .overlays:
            return overlaysReport()
        case .overlay(let edit, let reason):
            return performOverlay(edit, reason: reason)
        case .importImage:
            // Asynchronous, so the toolbox calls `importImage` itself; never reached.
            return .failure(message: "A picture is imported through the toolbox.", code: "internal")
        case .library:
            return libraryReport()
        case .searchLibrary(let query):
            return searchLibrary(query)
        case .zooms:
            return zoomsReport()
        case .setZoom(let number, let on, let reason):
            return setZoom(number, on: on, reason: reason)
        case .undoLastAgentEdit:
            let notYours = MCPToolResult.failure(message: "The last edit is not yours, or something was edited after it; nothing was undone.", code: "notYours")
            guard let last = lastEdit else { return notYours }
            switch last.kind {
            case .cut, .zoom:
                guard editor.timeline.undoStepName == last.stepName else { return notYours }
                editor.timeline.undo()
            case .caption(_, let before, let after):
                // The captions' undo is the window's, not the timeline's, so "still on top" is
                // asked of the captions themselves: exactly as this edit left them.
                guard editor.captions.snapshot == after else { return notYours }
                editor.captions.restore(before, named: String(localized: "Undo \(last.stepName)"))
            case .look(_, let before, let after):
                guard editor.look == after else { return notYours }
                editor.restoreLook(before)
            }
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

    /// The lines as the agent edits them — numbered from one, as `fix_caption` takes them — the
    /// names list, and what the screen suggests.
    private func captions() -> MCPToolResult {
        let model = editor.captions
        return json([
            "lines": model.track.cues.enumerated().map { index, cue in
                var row: [String: Any] = ["line": index + 1, "text": cue.text,
                                          "startNanos": cue.start.rawValue, "endNanos": cue.end.rawValue]
                if let word = cue.leastCertainWord { row["leastCertainWord"] = word.text }
                return row
            },
            "names": model.spokenTerms,
            "suggestions": model.suggestions.map { suggestion in
                let origin: [String: Any] = switch suggestion.origin {
                case .pressedLabel(let step): ["pressedInStep": step]
                case .application(let step): ["applicationInStep": step]
                }
                return ["id": suggestion.id, "was": suggestion.was, "now": suggestion.now,
                        "lines": suggestion.lines.map { $0 + 1 }, "from": origin] as [String: Any]
            },
        ])
    }

    /// How a line over the bound is refused: what it would have changed, the limit, and the tool
    /// to use instead. Measured, so the agent can correct the call rather than guess.
    private static func tooMuch(_ change: CaptionEditBound.Change, line: Int) -> MCPToolResult {
        .failure(message: "That changes \(change.changed) of line \(line)'s \(change.length) words; one edit may change \(change.allowed). Change only the misheard run — never rewrite what was said — or use fix_captions_everywhere for one run in many lines.",
                 code: "tooMuch")
    }

    private func fixCaption(_ line: Int, to text: String, reason: String) -> MCPToolResult {
        let cues = editor.captions.track.cues
        guard cues.indices.contains(line - 1) else {
            return .failure(message: "There is no line \(line); there are \(cues.count). Read captions for the numbers.", code: "noSuchLine")
        }
        let before = cues[line - 1].text
        guard before != text else {
            return .failure(message: "Line \(line) already reads that; nothing changed.", code: "unchanged")
        }
        let change = CaptionEditBound.change(from: before, to: text)
        guard change.isWithinBound else { return Self.tooMuch(change, line: line) }
        return recordCaption(reason: reason) { name in editor.captions.replaceText(at: line - 1, with: text, named: name) }
    }

    /// **Every line it would change is held to the same bound as one line**, or a phrase replaced
    /// everywhere would be a way round `fix_caption`'s limit.
    private func fixEverywhere(_ find: String, with replace: String, reason: String) -> MCPToolResult {
        let cues = editor.captions.track.cues
        let hits = cues.indices.filter { cues[$0].text.contains(find) }
        guard !hits.isEmpty else {
            return .failure(message: "No line contains \(find). Read captions for the text as it is now.", code: "noSuchRun")
        }
        for index in hits {
            let change = CaptionEditBound.change(from: cues[index].text,
                                                 to: cues[index].text.replacingOccurrences(of: find, with: replace))
            guard change.isWithinBound else { return Self.tooMuch(change, line: index + 1) }
        }
        return recordCaption(reason: reason) { name in editor.captions.replaceEverywhere(find, with: replace, named: name) }
    }

    /// Every zoom the clicks produced, switched off or not, in time order — numbered from one as
    /// `set_zoom` takes them. **`derivedZooms`, not `zooms`**: `zooms` leaves out the ones turned
    /// off, so numbering it renumbers everything after a zoom the moment it is turned off, and the
    /// one turned off can no longer be named to turn it back on. Each is shown as adjusted, where
    /// a person moved it.
    private var orderedZooms: [ZoomBlock] {
        let adjusted = editor.timeline.zooms
        return editor.timeline.derivedZooms
            .map { derived in adjusted.first { $0.origin == derived.origin } ?? derived }
            .sorted { $0.start.hostTime.rawValue < $1.start.hostTime.rawValue }
    }

    private func zoomsReport() -> MCPToolResult {
        json(["zooms": orderedZooms.enumerated().map { index, block in
            var row: [String: Any] = ["number": index + 1, "zoom": block.zoom,
                                      "on": !editor.timeline.isZoomSuppressed(block.origin)]
            if let start = editor.timeline.offset(of: block.start), let end = editor.timeline.offset(of: block.end) {
                row["startNanos"] = start.rawValue
                row["endNanos"] = end.rawValue
            }
            if let step = editor.steps.steps.last(where: { $0.origin.hostTime.rawValue <= block.origin.hostTime.rawValue }) {
                row["step"] = step.number
            }
            return row
        }])
    }

    private func setZoom(_ number: Int, on: Bool, reason: String) -> MCPToolResult {
        let zooms = orderedZooms
        guard zooms.indices.contains(number - 1) else {
            return .failure(message: "There is no zoom \(number); there are \(zooms.count). Read zooms for the numbers.", code: "noSuchZoom")
        }
        let origin = zooms[number - 1].origin
        guard editor.timeline.isZoomSuppressed(origin) == on else {
            return .failure(message: "Zoom \(number) is already \(on ? "on" : "off"); nothing changed.", code: "unchanged")
        }
        let name = "\(agentName): \(reason)"
        editor.timeline.setZoomSuppressed(origin, !on, named: name)
        editsMade += 1
        let entry = AgentEditRecord(id: editsMade, stepName: name, reason: reason,
                                    at: SourceTime(editor.timeline.offset(of: zooms[number - 1].start) ?? Nanoseconds(0)),
                                    kind: .zoom(number: number, on: on))
        lastEdit = entry
        onEdit(entry)
        return json(["undoStep": name, "zoom": number, "on": on])
    }

    private func libraryReport() -> MCPToolResult {
        var items: [[String: Any]] = [["id": LibraryModel.recordingID, "kind": "recording", "name": "This recording",
                                       "durationNanos": duration, "steps": editor.steps.steps.count]]
        for item in editor.library.library.items {
            var row: [String: Any] = ["id": item.id, "kind": item.kind.rawValue, "name": item.name, "file": item.filename]
            if let d = item.durationNanos { row["durationNanos"] = d }
            if let w = item.width, let h = item.height { row["width"] = w; row["height"] = h }
            switch item.origin {
            case .recorded: row["from"] = "recorded"
            case .imported(let original): row["from"] = "imported"; row["originalName"] = original
            case .web(let host): row["from"] = "web"; row["host"] = host
            }
            items.append(row)
        }
        return json(["items": items])
    }

    /// The hits, best first, at most 30, each with its evidence.
    private func searchLibrary(_ query: String) -> MCPToolResult {
        let index = editor.library.index(steps: editor.steps.steps, anchorHostNanos: anchor?.hostTime.rawValue,
                                         captions: editor.captions.track)
        let hits = LibrarySearch.search(query, in: index).prefix(30)
        return json(["query": query, "hits": hits.map { hit -> [String: Any] in
            var row: [String: Any] = ["item": hit.itemID, "text": hit.text]
            switch hit.field {
            case .stepLabel(let step): row["field"] = "pressedLabel"; row["step"] = step
            case .application(let step): row["field"] = "application"; row["step"] = step
            case .spoken: row["field"] = "spoken"
            case .pictureText: row["field"] = "textOnPicture"
            case .name: row["field"] = "name"
            }
            if let start = hit.startNanos { row["startNanos"] = start }
            if let end = hit.endNanos { row["endNanos"] = end }
            return row
        }])
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
        let entry = AgentEditRecord(id: editsMade, stepName: name, reason: reason, at: at,
                                    kind: .cut(removed: Nanoseconds(before - after)))
        lastEdit = entry
        onEdit(entry)
        // What changed, so the agent's next step starts from the timeline as it is now.
        return json(["undoStep": name, "playedNanosBefore": before, "playsNanosNow": after,
                     "removedNanos": before - after])
    }

    /// Performs one caption edit under the agent's name and reports which lines it changed.
    private func recordCaption(reason: String, _ edit: (String) -> Void) -> MCPToolResult {
        let name = "\(agentName): \(reason)"
        let before = editor.captions.snapshot
        edit(name)
        let after = editor.captions.snapshot
        let changed = zip(before.track.cues, after.track.cues).enumerated()
            .filter { $0.element.0.text != $0.element.1.text }.map(\.offset)
        guard let first = changed.first else {
            return .failure(message: "Nothing in the captions changed.", code: "unchanged")
        }
        editsMade += 1
        let entry = AgentEditRecord(id: editsMade, stepName: name, reason: reason,
                                    at: SourceTime(after.track.cues[first].start),
                                    kind: .caption(lines: changed.map { $0 + 1 }, before: before, after: after))
        lastEdit = entry
        onEdit(entry)
        return json(["undoStep": name, "linesChanged": changed.map { $0 + 1 },
                     "names": after.terms])
    }

    /// Performs one change to the look under the agent's name, and reports each field it moved
    /// from what to what — so the agent's next step starts from the look as it is now.
    func recordLook(reason: String, _ edit: () -> String?) -> MCPToolResult {
        let name = "\(agentName): \(reason)"
        let before = editor.look
        if let refusal = edit() {
            // A refusal part-way leaves nothing half-done: what was applied is put back.
            editor.restoreLook(before)
            return .failure(message: refusal, code: "usage")
        }
        let after = editor.look
        let changed = EditorLook.differences(before, after)
        guard !changed.isEmpty else {
            return .failure(message: "That is how it already is; nothing changed.", code: "unchanged")
        }
        editsMade += 1
        let entry = AgentEditRecord(id: editsMade, stepName: name, reason: reason, at: editor.timeline.playhead,
                                    kind: .look(changed: changed.map(\.field), before: before, after: after))
        lastEdit = entry
        onEdit(entry)
        return json(["undoStep": name, "changed": changed.map { ["field": $0.field, "was": $0.was, "now": $0.now] }])
    }

    func json(_ object: [String: Any]) -> MCPToolResult {
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
        // Fetched off the main actor, then applied on it: a slow site must not stall the editor.
        case .success(.importImage(let url, let use, let reason)): return await bridge.importImage(url, use: use, reason: reason)
        case .success(let request): return await bridge.perform(request)
        }
    }
}
