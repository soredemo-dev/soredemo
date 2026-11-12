import Testing
import Foundation
import Network
import Surface
import Timeline
import Framing
import Geometry
import Overlays
import Render
import Project
import Variants
import ImageIO
import CoreGraphics
@testable import Soredemo

// The agent panel's app half: the relay to the open editor, the live tools, and reverting a turn.
// A twenty-second recording; every bound is a literal.

private let second: Int64 = 1_000_000_000

/// A toolbox that answers one tool, so the relay is tested apart from the editor.
private struct EchoToolbox: MCPToolbox {
    var tools: [MCPTool] { [MCPTool(name: "echo", title: "Echo", description: "d", inputSchema: #"{"type":"object"}"#, readOnly: true)] }
    func call(_ name: String, argumentsJSON: String) async -> MCPToolResult? {
        name == "echo" ? .success(json: argumentsJSON) : nil
    }
}

/// One line to the relay's socket and the line that comes back.
private func exchange(_ line: String, socketPath: String) async throws -> String {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        let buffer = LineBuffer()
        nonisolated(unsafe) var resumed = false
        func finish(_ result: Result<String, any Error>) {
            guard !resumed else { return }
            resumed = true
            connection.cancel()
            continuation.resume(with: result)
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                if let error { finish(.failure(error)); return }
                if let reply = buffer.append(data ?? Data()).first { finish(.success(reply)); return }
                receive()
            }
        }
        connection.start(queue: .global())
        connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
        receive()
    }
}

@Test func theRelayAnswersMCPOnItsSocketAndOnlyThisUserCanOpenIt() async throws {
    let relay = try AgentRelay(toolbox: EchoToolbox(), version: "test", executable: "/bin/false")
    defer { relay.close() }
    let mode = try FileManager.default.attributesOfItem(atPath: relay.directory.path(percentEncoded: false))[.posixPermissions] as? Int
    #expect(mode == 0o700, "the socket's directory is this user's alone")

    let reply = try await exchange(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"a":1}}}"#,
                                   socketPath: relay.socketPath)
    #expect(reply.contains(#""structuredContent":{"a":1}"#))
}

@Test func theRelaysConfigStartsThisExecutableAsAPipeToTheSocket() throws {
    let relay = try AgentRelay(toolbox: EchoToolbox(), version: "test", executable: "/Applications/X.app/Contents/MacOS/X")
    defer { relay.close() }
    let config = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: relay.configPath))) as? [String: Any])
    let server = try #require((config["mcpServers"] as? [String: Any])?["soredemo"] as? [String: Any])
    #expect(server["command"] as? String == "/Applications/X.app/Contents/MacOS/X")
    #expect(server["args"] as? [String] == ["mcp", "--relay", relay.socketPath])
}

@Test func closingTheRelayRemovesItsDirectory() throws {
    let relay = try AgentRelay(toolbox: EchoToolbox(), version: "test", executable: "/bin/false")
    let directory = relay.directory.path(percentEncoded: false)
    relay.close()
    #expect(!FileManager.default.fileExists(atPath: directory))
}

/// The child side, run for real: this very executable started as `mcp --relay`, as `claude` starts
/// it. A line on its stdin reaches the relay and the relay's answer comes out on its stdout.
@Test func theRealExecutableAsARelayCarriesALineBothWays() async throws {
    let relay = try AgentRelay(toolbox: EchoToolbox(), version: "test", executable: "/bin/false")
    defer { relay.close() }
    let executable = try #require(Bundle.main.executableURL)
    let process = Process()
    process.executableURL = executable
    process.arguments = ["mcp", "--relay", relay.socketPath]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data((#"{"jsonrpc":"2.0","id":5,"method":"ping"}"# + "\n").utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(String(decoding: data, as: UTF8.self) == #"{"id":5,"jsonrpc":"2.0","result":{}}"# + "\n")
    #expect(process.terminationStatus == 0, "it exits when stdin closes")
}

// MARK: - the live tools and reverting a turn

@MainActor private func editor() -> EditorViewModel {
    let editor = EditorViewModel()
    editor.timeline.load(duration: 20)
    return editor
}

@Test @MainActor func aCutIsOneUndoStepNamedForTheAgentAndItsReason() {
    let editor = editor()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    var recorded: [AgentEditRecord] = []
    bridge.onEdit = { recorded.append($0) }
    let result = bridge.perform(.cutSpan(start: 4 * second, end: 14 * second, reason: "Nothing happens after step 1"))
    guard case .success(let json) = result else { Issue.record("\(result)"); return }
    #expect(json.contains(#""removedNanos":10000000000"#), "the agent is told what changed")
    #expect(editor.timeline.edit.outputDuration == Nanoseconds(10 * second))
    #expect(editor.timeline.undoStepName == "Claude Code: Nothing happens after step 1")
    #expect(recorded.map(\.kind) == [.cut(removed: Nanoseconds(10 * second))])
    #expect(recorded.first?.at == SourceTime(nanos: 14 * second),
            "\"show me\" goes to the first moment of the recording after the cut, which plays at 4 s")
}

@Test @MainActor func theAgentUndoesOnlyItsOwnLastEdit() {
    let editor = editor()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    _ = bridge.perform(.cutSpan(start: 4 * second, end: 6 * second, reason: "r"))
    editor.timeline.removeSourceRange(10 * second..<12 * second, named: "A person's cut")
    guard case .failure(_, let code) = bridge.perform(.undoLastAgentEdit) else {
        Issue.record("undid a person's edit"); return
    }
    #expect(code == "notYours")
    #expect(editor.timeline.edit.outputDuration == Nanoseconds(16 * second), "both cuts stand")
}

@Test @MainActor func aSeekIntoACutSpanIsRefused() {
    let editor = editor()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    _ = bridge.perform(.cutSpan(start: 4 * second, end: 6 * second, reason: "r"))
    guard case .failure(_, let code) = bridge.perform(.seek(5 * second)) else { Issue.record("sought into a cut"); return }
    #expect(code == "cut")
}

// The playhead is on the RECORDING's clock (`TimelineEditorModel.playhead`). Every test below
// cuts 2–4 s first, so after it the two clocks differ by two seconds — without the cut they agree,
// and a conversion done the wrong way round passes. This happened: three sites converted it and
// every test before these sat at the identity.

/// The agent asks for a moment on the recording's clock and the playhead goes to that moment.
@Test @MainActor func aSeekPutsThePlayheadAtThatMomentOfTheRecording() {
    let editor = editor()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    _ = bridge.perform(.cutSpan(start: 2 * second, end: 4 * second, reason: "r"))
    guard case .success(let json) = bridge.perform(.seek(8 * second)) else { Issue.record("refused"); return }
    #expect(editor.timeline.playhead.nanoseconds == Nanoseconds(8 * second), "not two seconds early")
    #expect(json.contains(#""playheadNanos":8000000000"#), "\(json)")
    #expect(json.contains(#""playsAtNanos":6000000000"#), "and where that moment plays in the edit: \(json)")
}

/// What the agent is told of the playhead is on the clock it reads every other time on.
@Test @MainActor func theStatusReportsThePlayheadOnTheRecordingsClock() {
    let editor = editor()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    _ = bridge.perform(.cutSpan(start: 2 * second, end: 4 * second, reason: "r"))
    editor.timeline.movePlayhead(to: SourceTime(Nanoseconds(8 * second)))
    guard case .success(let json) = bridge.perform(.status) else { Issue.record("no status"); return }
    #expect(json.contains(#""playheadNanos":8000000000"#), "\(json)")
}

/// The context that goes with a message: the playhead and the step it is in, both on the
/// recording's clock — the step is found by recording time, not by where it plays.
@Test @MainActor func theContextSentWithAMessageIsOnTheRecordingsClock() {
    let epoch = BootEpoch(id: UUID(uuidString: "7C2D3E4F-5061-4728-9ABC-DE0F1A2B3C4D")!)
    let anchor = EpochAnchor(epoch: epoch, hostTime: Nanoseconds(500 * second), wallClockUnixNanos: 0)
    func step(_ number: Int, at seconds: Int64, _ label: String) -> RecordedStep {
        let origin = HostInstant(epoch: epoch, hostTime: Nanoseconds(500 * second + seconds * second))
        return RecordedStep(origin: origin, end: origin, number: number, label: label, role: "AXButton", application: "Keynote",
                            frame: NormalizedFrame(origin: NormalizedPoint(x: 0.5, y: 0.5), size: NormalizedSize(width: 0.1, height: 0.1),
                                                   revision: GeometryRevision(id: 1)))
    }
    let context = AgentContextReader.context(playhead: SourceTime(nanos: 7 * second),
                                             steps: [step(1, at: 1, "Open"), step(2, at: 6, "Export"), step(3, at: 9, "Done")],
                                             anchor: anchor, duration: Nanoseconds(20 * second), plays: Nanoseconds(18 * second))
    #expect(context.playheadNanos == 7 * second)
    #expect(context.step?.number == 2, "7 s on the recording is in step 2, even though it plays at 5 s")
    #expect(context.playsNanos == 18 * second)
}

/// A turn reverts at once — and not over a person's later edit.
@Test @MainActor func aTurnRevertsAtOnceUnlessSomeoneEditedAfterIt() {
    let editor = editor()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    var records: [AgentEditRecord] = []
    bridge.onEdit = { records.append($0) }
    let mark = editor.timeline.historyDepth
    _ = bridge.perform(.cutSpan(start: 2 * second, end: 4 * second, reason: "one"))
    _ = bridge.perform(.cutSpan(start: 8 * second, end: 10 * second, reason: "two"))
    let turn = AgentPanelModel.Turn(id: 1, request: "tighten", items: records.map { .edit($0) }, running: false, checkpoint: mark)
    let panel = AgentPanelModel(providers: [ClaudeCodeProvider()])

    editor.timeline.removeSourceRange(15 * second..<16 * second, named: "A person's cut")
    #expect(panel.revert(turn, editor: editor) != nil, "a person's later edit is not undone with the turn")
    #expect(editor.timeline.edit.outputDuration == Nanoseconds(15 * second))

    editor.timeline.undo()
    #expect(panel.revert(turn, editor: editor) == nil)
    #expect(editor.timeline.edit.outputDuration == Nanoseconds(20 * second), "both of the turn's cuts are gone")
}

/// Two turns that gave the same reason: the name on top matches the earlier turn's last edit too,
/// so only the depth says the top belongs to the later turn — and reverting the earlier one must
/// not undo the later one's cut in its place.
@Test @MainActor func anEarlierTurnIsNotRevertedThroughALaterTurnWithTheSameReason() {
    let editor = editor()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    var records: [AgentEditRecord] = []
    bridge.onEdit = { records.append($0) }
    let firstMark = editor.timeline.historyDepth
    _ = bridge.perform(.cutSpan(start: 2 * second, end: 4 * second, reason: "Tighten the pause"))
    let first = AgentPanelModel.Turn(id: 1, request: "a", items: records.map { .edit($0) }, running: false, checkpoint: firstMark)
    records = []
    _ = bridge.perform(.cutSpan(start: 8 * second, end: 10 * second, reason: "Tighten the pause"))

    let panel = AgentPanelModel(providers: [ClaudeCodeProvider()])
    #expect(panel.revert(first, editor: editor) != nil)
    #expect(editor.timeline.edit.outputDuration == Nanoseconds(16 * second), "both cuts stand")
}

/// An agent that says what it is told to: the panel's own handling of a turn, with no CLI.
@MainActor
private final class ScriptedProvider: AgentProvider {
    let name: String
    let mark = "ClaudeMark"
    let markIsTemplate = false
    let events: [AgentEvent]
    private(set) var closed = 0

    init(name: String, events: [AgentEvent]) {
        self.name = name
        self.events = events
    }

    func models() async -> [AgentModel] { [AgentModel(id: "m", label: "M")] }
    func availability() async -> AgentAvailability { .ready(version: "1") }
    func run(message: String, session: String?, model: String?, tools: AgentTurnTools) -> AsyncStream<AgentEvent> {
        let events = events
        return AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
    func stop() {}
    func close() { closed += 1 }
}

/// A suite of its own, so choosing an agent in a test never touches the person's own settings.
private func scratchDefaults() -> UserDefaults {
    let defaults = UserDefaults(suiteName: "soredemo-tests-agent-panel")!
    defaults.removePersistentDomain(forName: "soredemo-tests-agent-panel")
    return defaults
}

@MainActor private func finish(_ panel: AgentPanelModel) async throws {
    var waited = 0
    while panel.isRunning, waited < 5_000 {
        try await Task.sleep(for: .milliseconds(10))
        waited += 10
    }
    #expect(!panel.isRunning, "the turn did not end within five seconds")
}

private let fiveHours = UsageWindow(minutes: 300, usedPercent: 34, resets: nil, limited: false)

/// What the agent reports of its usage is kept from turn to turn; a new conversation forgets how
/// full the old one was and keeps the account's windows, which are the same account's.
@Test @MainActor func theReportedUsageIsKeptAndANewConversationForgetsOnlyItsContext() async throws {
    let provider = ScriptedProvider(name: "A", events: [
        .started(session: "s", tools: [], model: nil),
        .contextUsage(usedTokens: 12_000, windowTokens: nil),
        .contextUsage(usedTokens: nil, windowTokens: 400_000),
        .limits([fiveHours]),
        .finished(isError: false, durationMilliseconds: 10, costUSD: nil, session: "s"),
    ])
    let panel = AgentPanelModel(providers: [provider], defaults: scratchDefaults())
    await panel.checkAvailability()
    panel.send("tighten", editor: editor(), context: nil)
    try await finish(panel)
    #expect(panel.usage.contextUsed == 12_000, "a window arriving later does not erase the count")
    #expect(panel.usage.contextPercent == 3)
    #expect(panel.usage.windows == [fiveHours])

    panel.startOver()
    #expect(panel.usage.contextUsed == nil)
    #expect(panel.usage.windows == [fiveHours])
    panel.close()
}

/// Another agent is a new conversation with nothing reported yet, and the choice is remembered.
@Test @MainActor func choosingAnotherAgentStartsCleanAndIsRemembered() async throws {
    let defaults = scratchDefaults()
    let first = ScriptedProvider(name: "A", events: [.limits([fiveHours]), .finished(isError: false, durationMilliseconds: 1, costUSD: nil, session: "s")])
    let second = ScriptedProvider(name: "B", events: [])
    let panel = AgentPanelModel(providers: [first, second], defaults: defaults)
    await panel.checkAvailability()
    panel.send("go", editor: editor(), context: nil)
    try await finish(panel)
    #expect(panel.usage.windows == [fiveHours])

    panel.choose(1)
    #expect(panel.providerName == "B")
    #expect(panel.usage == AgentPanelModel.Usage(), "B has reported nothing")
    #expect(first.closed > 0, "A's process and relay end with the switch")
    #expect(AgentPanelModel(providers: [first, second], defaults: defaults).providerName == "B")
    panel.close()
}

/// With the app gone, nothing answers at the socket; the relay child must exit rather than wait
/// there forever as an orphan — which a killed test run once left behind.
@Test func aRelayWithNothingAtTheSocketExitsInsteadOfWaiting() async throws {
    let executable = try #require(Bundle.main.executableURL)
    let process = Process()
    process.executableURL = executable
    process.arguments = ["mcp", "--relay", FileManager.default.temporaryDirectory.appending(path: "no-such-socket-\(ProcessInfo.processInfo.processIdentifier)").path(percentEncoded: false)]
    process.standardInput = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    var waited = 0
    while process.isRunning, waited < 5_000 {
        try await Task.sleep(for: .milliseconds(50))
        waited += 50
    }
    if process.isRunning { process.terminate() }
    #expect(waited < 5_000, "the relay child was still waiting after five seconds")
}

// MARK: - pinned notes

/// N pins a note; never while a field has the caret, and not with shift.
@Test func nPinsANoteButNotWhileTyping() {
    #expect(BareKeys.action(keyCode: 45, modifiers: .none, isTyping: false) == .pinNote)
    #expect(BareKeys.action(keyCode: 45, modifiers: .none, isTyping: true) == nil)
    #expect(BareKeys.action(keyCode: 45, modifiers: BareKeys.Modifiers(shift: true), isTyping: false) == nil)
}

@Test @MainActor func aNoteWithNoWordsIsNotPinnedAndSaysWhy() {
    let notes = NotesModel()
    notes.begin(at: Nanoseconds(3 * second), x: 0.5, y: 0.5)
    #expect(!notes.pin())
    #expect(notes.refusal != nil && notes.board.notes.isEmpty)
    notes.draft?.text = "Zoom tighter here"
    #expect(notes.pin())
    #expect(notes.board.notes.map(\.text) == ["Zoom tighter here"])
}

/// The agent reads the notes, resolves one with what it did, and the panel is told.
@Test @MainActor func theAgentResolvesANoteWithWhatItDid() throws {
    let editor = editor()
    editor.notes.begin(at: Nanoseconds(3 * second), x: 0.4, y: 0.6)
    editor.notes.draft?.text = "This pause drags"
    editor.notes.pin()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    var told: [PinnedNote] = []
    bridge.onNote = { told.append($0) }

    guard case .success(let listed) = bridge.perform(.notes) else { Issue.record("notes failed"); return }
    #expect(listed.contains(#""text":"This pause drags""#) && listed.contains(#""open":true"#))
    #expect(listed.contains(#""atNanos":3000000000"#))

    guard case .success = bridge.perform(.resolveNote(1, reason: "Cut 2.1 s of the pause")) else { Issue.record("resolve failed"); return }
    #expect(editor.notes.board.notes.first?.state == .addressed("Cut 2.1 s of the pause"))
    #expect(told.map(\.id) == [1])
    guard case .failure(_, let code) = bridge.perform(.skipNote(1, reason: "again")) else { Issue.record("resolved twice"); return }
    #expect(code == "noSuchNote", "a resolved note is not resolved again")
}

/// A saved project keeps its notes, the agent's resolutions included.
@Test @MainActor func notesSurviveSavingAndOpening() throws {
    let editor = editor()
    editor.notes.begin(at: Nanoseconds(3 * second), x: 0.4, y: 0.6)
    editor.notes.draft?.text = "Zoom tighter here"
    editor.notes.pin()
    editor.notes.resolve(1, as: .skipped("The zoom is already at its closest"))
    let reopened = EditorViewModel()
    reopened.timeline.load(duration: 20)
    #expect(reopened.restore(editor.currentEditState(hasCamera: false)).isEmpty)
    #expect(reopened.notes.board == editor.notes.board)
}

// MARK: - the agent's caption edits

/// Three lines, the second misheard, so a fix has a line to land on and lines to leave alone.
@MainActor private func captioned() -> EditorViewModel {
    let editor = editor()
    func cue(_ text: String, _ start: Int64) -> CaptionCue {
        CaptionCue(text: text, start: Nanoseconds(start * second), end: Nanoseconds((start + 2) * second))
    }
    editor.captions.restore(track: CaptionTrack(cues: [cue("First we sign in", 1),
                                                       cue("Now open Cubernades and pick a cluster", 4),
                                                       cue("Cubernades shows the pods", 8)]),
                            style: .default, burnsIn: false)
    return editor
}

/// A misheard name in one line is fixed as one edit named for the agent, and the panel is told
/// which line and where it is.
@Test @MainActor func aCaptionLineIsFixedWithinTheBoundAndRecordedAsTheAgents() {
    let editor = captioned()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    var recorded: [AgentEditRecord] = []
    bridge.onEdit = { recorded.append($0) }
    guard case .success(let json) = bridge.perform(.fixCaption(line: 2, text: "Now open Kubernetes and pick a cluster",
                                                               reason: "Kubernetes is the app in step 2")) else {
        Issue.record("refused"); return
    }
    #expect(editor.captions.track.cues.map(\.text) == ["First we sign in", "Now open Kubernetes and pick a cluster", "Cubernades shows the pods"])
    #expect(json.contains(#""linesChanged":[2]"#), "\(json)")
    #expect(recorded.first?.stepName == "Claude Code: Kubernetes is the app in step 2")
    #expect(recorded.first?.at == SourceTime(nanos: 4 * second), "\"show me\" goes to the line it changed")
}

/// A rewrite is refused with the numbers, and the line is left as it was.
@Test @MainActor func aRewriteOfACaptionLineIsRefusedWithWhatItWouldHaveChanged() {
    let editor = captioned()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    guard case .failure(let message, let code) = bridge.perform(.fixCaption(line: 2, text: "Next we deploy the service to production",
                                                                            reason: "Clearer")) else {
        Issue.record("a rewrite passed"); return
    }
    #expect(code == "tooMuch")
    #expect(message.contains("changes 7 of line 2's 7 words; one edit may change 3"), "\(message)")
    #expect(editor.captions.track.cues[1].text == "Now open Cubernades and pick a cluster")
    guard case .failure(_, let missing) = bridge.perform(.fixCaption(line: 4, text: "x", reason: "r")) else {
        Issue.record("line 4 of 3 was fixed"); return
    }
    #expect(missing == "noSuchLine")
}

/// A run replaced everywhere reaches every line that has it and joins the names list; and every
/// line it would change is held to the one-line bound, or it would be the way round it.
@Test @MainActor func aRunIsFixedEverywhereAndEachLineItChangesIsBounded() {
    let editor = captioned()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    guard case .failure(_, let code) = bridge.perform(.fixCaptionsEverywhere(find: "Cubernades shows the pods", replace: "We are done here now",
                                                                             reason: "r")) else {
        Issue.record("a whole line was replaced as a run"); return
    }
    #expect(code == "tooMuch")
    guard case .success = bridge.perform(.fixCaptionsEverywhere(find: "Cubernades", replace: "Kubernetes", reason: "Step 2's app")) else {
        Issue.record("refused"); return
    }
    #expect(editor.captions.track.cues.map(\.text).filter { $0.contains("Kubernetes") }.count == 2)
    #expect(editor.captions.spokenTerms == ["Kubernetes"], "kept for the next transcription")
}

/// A turn that fixed captions reverts at once — lines and names — and not over a person's later
/// edit to them.
@Test @MainActor func aTurnOfCaptionEditsRevertsAtOnceUnlessSomeoneEditedAfterIt() {
    let editor = captioned()
    let before = editor.captions.snapshot
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    var records: [AgentEditRecord] = []
    bridge.onEdit = { records.append($0) }
    _ = bridge.perform(.fixCaptionsEverywhere(find: "Cubernades", replace: "Kubernetes", reason: "one"))
    _ = bridge.perform(.fixCaption(line: 1, text: "First we log in", reason: "two"))
    #expect(records.count == 2)
    let turn = AgentPanelModel.Turn(id: 1, request: "fix", items: records.map { .edit($0) }, running: false,
                                    checkpoint: editor.timeline.historyDepth)
    let panel = AgentPanelModel(providers: [ClaudeCodeProvider()])

    editor.captions.setText("First we sign on", at: 0)
    #expect(panel.revert(turn, editor: editor) != nil, "a person's later edit is not undone with the turn")
    #expect(editor.captions.track.cues[0].text == "First we sign on")

    editor.captions.setText("First we log in", at: 0)
    #expect(panel.revert(turn, editor: editor) == nil)
    #expect(editor.captions.snapshot == before, "the lines and the names list, both")
}

/// The agent's own undo reaches a caption edit too — and only while it is still as it left it.
@Test @MainActor func theAgentUndoesItsOwnLastCaptionEdit() {
    let editor = captioned()
    let before = editor.captions.snapshot
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    _ = bridge.perform(.fixCaption(line: 2, text: "Now open Kubernetes and pick a cluster", reason: "r"))
    editor.captions.setText("Now open Kubernetes and pick a node", at: 1)
    guard case .failure(_, let code) = bridge.perform(.undoLastAgentEdit) else { Issue.record("undid a person's edit"); return }
    #expect(code == "notYours")
    editor.captions.setText("Now open Kubernetes and pick a cluster", at: 1)
    guard case .success = bridge.perform(.undoLastAgentEdit) else { Issue.record("refused its own"); return }
    #expect(editor.captions.snapshot == before)
}

/// The agent's shortest run replaced everywhere is a person's, held equal here because Surface,
/// which refuses it, cannot see Overlays, which defines it.
@Test func theAgentsShortestRunIsAPersons() {
    #expect(AgentTools.shortestRun == RunEdit.shortestRun)
}

// MARK: - the agent's changes to the look, the cursor and the sound

/// Only the fields given change, through the inspector's own setters, and the agent is told each
/// one it moved from what to what.
@Test @MainActor func aLookChangeMovesOnlyTheFieldsGivenAndSaysWhatMoved() {
    let editor = editor()
    let before = editor.look
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    var recorded: [AgentEditRecord] = []
    bridge.onEdit = { recorded.append($0) }
    guard case .success(let json) = bridge.perform(.setLook(.init(backgroundColor: "#112233", padding: 0.1),
                                                          reason: "Calmer for the landing page")) else {
        Issue.record("refused"); return
    }
    #expect(editor.stageStyle.style.background == .solid(red: Double(0x11) / 255, green: Double(0x22) / 255, blue: Double(0x33) / 255))
    #expect(editor.stageStyle.style.insetFraction == 0.1)
    #expect(editor.look.cursor == before.cursor && editor.look.audioMix == before.audioMix, "nothing else moved")
    #expect(json.contains(#""field":"padding""#) && json.contains(#""now":"colour #112233""#), "\(json)")
    if case .look(let changed, _, _)? = recorded.first?.kind {
        #expect(changed == ["background", "padding"])
    } else { Issue.record("not recorded as a look change") }
}

/// A refusal part-way leaves nothing half-done, and a change to what already is, is no step.
@Test @MainActor func aRefusedLookChangeLeavesTheLookAsItWas() {
    let editor = editor()
    let before = editor.look
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    guard case .failure(let message, _) = bridge.perform(.setLook(.init(backgroundPreset: "Neon", padding: 0.2), reason: "r")) else {
        Issue.record("an unknown preset passed"); return
    }
    #expect(message.contains("Charcoal"), "the refusal lists the presets: \(message)")
    #expect(editor.look == before)
    // Refused at the LAST field, after the padding had already been applied: it is put back.
    guard case .failure = bridge.perform(.setLook(.init(padding: 0.2, shape: "Match Recording"), reason: "r")) else {
        Issue.record("a shape this recording does not offer passed"); return
    }
    #expect(editor.look == before, "the padding applied before the refusal is put back")
    guard case .failure(_, let code) = bridge.perform(.setCursor(.init(size: before.cursor.scale), reason: "r")) else {
        Issue.record("a no-op was recorded"); return
    }
    #expect(code == "unchanged")
}

/// The cursor and the sound, through the same path.
@Test @MainActor func theCursorAndTheSoundAreChangedThroughTheInspectorsSetters() {
    let editor = editor()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    _ = bridge.perform(.setCursor(.init(size: 1.5, clickEffect: "pulse", color: "#FF0000", showsKeystrokes: false), reason: "r"))
    #expect(editor.stageStyle.cursor.scale == 1.5)
    #expect(editor.stageStyle.cursor.clickEffect == .pulse)
    #expect(editor.stageStyle.cursor.red == 1 && editor.stageStyle.cursor.green == 0)
    #expect(!editor.stageStyle.showsKeystrokes)
    _ = bridge.perform(.setAudio(.init(microphoneGain: 1.4, systemAudioMuted: true, targetLoudness: -16), reason: "r"))
    #expect(editor.audioMix.gain(for: .microphone) == 1.4)
    #expect(editor.audioMix.muted.contains(.systemAudio))
    #expect(editor.audioMix.targetLoudness == -16)
    guard case .failure(let message, _) = bridge.perform(.setAudio(.init(musicEnabled: true), reason: "r")) else {
        Issue.record("music turned on with no music"); return
    }
    #expect(message.contains("no music"))
}

/// A turn of look changes reverts at once, and not over a person's later change.
@Test @MainActor func aTurnOfLookChangesRevertsAtOnceUnlessSomeoneChangedItAfter() {
    let editor = editor()
    let before = editor.look
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    var records: [AgentEditRecord] = []
    bridge.onEdit = { records.append($0) }
    _ = bridge.perform(.setLook(.init(backgroundPreset: "Tide"), reason: "one"))
    _ = bridge.perform(.setCursor(.init(size: 2, showsKeystrokes: !before.showsKeystrokes), reason: "two"))
    let turn = AgentPanelModel.Turn(id: 1, request: "style it", items: records.map { .edit($0) }, running: false,
                                    checkpoint: editor.timeline.historyDepth)
    let panel = AgentPanelModel(providers: [ClaudeCodeProvider()])
    editor.stageStyle.setCornerRadius(30)
    #expect(panel.revert(turn, editor: editor) != nil, "a person's later change is not undone with the turn")
    #expect(editor.stageStyle.style.cornerRadius == 30)
    editor.stageStyle.setCornerRadius(before.style.cornerRadius)
    #expect(panel.revert(turn, editor: editor) == nil)
    #expect(editor.look == before)
}

/// The agent's own undo reaches a look change, only while it is as it left it.
@Test @MainActor func theAgentUndoesItsOwnLastLookChange() {
    let editor = editor()
    let before = editor.look
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    _ = bridge.perform(.setAudio(.init(microphoneGain: 2), reason: "r"))
    let left = editor.audioMix
    editor.audioMix = editor.audioMix.setting(.systemAudio, gain: 0.5)
    guard case .failure(_, let code) = bridge.perform(.undoLastAgentEdit) else { Issue.record("undid over a person"); return }
    #expect(code == "notYours")
    editor.audioMix = left
    guard case .success = bridge.perform(.undoLastAgentEdit) else { Issue.record("refused its own"); return }
    #expect(editor.look == before)
}

/// The option names the tools offer are the app's own, which Surface cannot see to check.
@Test func theAgentsOptionNamesAreTheAppsOwn() {
    #expect(AgentTools.clickEffects == CursorStyle.ClickEffect.allCases.map(\.rawValue))
    #expect(AgentTools.movements == PointerPath.Tuning.Movement.allCases.map(\.rawValue))
    #expect(AgentTools.cameraPaces == CameraPace.allCases.map(\.rawValue))
    #expect(Set(AgentTools.shapes) == Set(AspectVariant.all.map(\.name) + [AspectVariant.matchRecordingName]))
}

// MARK: - the agent's titles, chapters, marks, hidden regions and camera

/// A title the agent places at y = 0.1 from the TOP is stored 0.9 up from the bottom, which is
/// where the compositor draws a title near the top of the frame; and it reads back as 0.1.
@Test @MainActor func aTitleIsPlacedFromTheTopAndReadBackTheSameWay() throws {
    let editor = editor()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    guard case .success = bridge.perform(.overlay(.addTitle(.init(text: "Ship it", startNanos: 2 * second, seconds: 4, y: 0.1, bold: true)),
                                                   reason: "The hook")) else { Issue.record("refused"); return }
    let item = try #require(editor.texts.track.items.first)
    #expect(item.text == "Ship it")
    #expect(item.start == Nanoseconds(2 * second) && item.end == Nanoseconds(6 * second))
    #expect(abs(item.style.y - 0.9) < 1e-9, "0.1 down from the top is 0.9 up from the bottom")
    #expect(item.style.isBold)
    guard case .success(let json) = bridge.perform(.overlays) else { Issue.record("no overlays"); return }
    #expect(json.contains(#""y":0.1,"#) || json.contains(#""y":0.1}"#), "read back as written, not as 0.0999…: \(json)")
    #expect(json.contains(#""camera":null"#), "a recording with no camera reports none")
}

/// A hidden region keeps y from the top — its own type's convention — and a mark flips like a title.
@Test @MainActor func aHiddenRegionKeepsItsYAndAMarkFlipsIt() throws {
    let editor = editor()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    _ = bridge.perform(.overlay(.hideRegion(.init(startNanos: 0, endNanos: 5 * second, x: 0.1, y: 0.2, width: 0.3, height: 0.1)), reason: "An email"))
    let region = try #require(editor.redactions.track.items.first)
    #expect(region.region.y == 0.2 && region.end == Nanoseconds(5 * second))
    _ = bridge.perform(.overlay(.addMark(.init(shape: "arrow", fromX: 0.2, fromY: 0.25, toX: 0.6, toY: 0.5, startNanos: 0, seconds: 2)), reason: "r"))
    let mark = try #require(editor.annotations.track.items.first)
    #expect(mark.shape == .arrow && abs(mark.startY - 0.75) < 1e-9 && abs(mark.endY - 0.5) < 1e-9)
}

/// Chapters keep their pending suggestions through an agent's edit; an id that is not there is refused.
@Test @MainActor func aChapterIsAddedRenamedAndAMissingOneIsRefused() throws {
    let editor = editor()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    _ = bridge.perform(.overlay(.addChapter(atNanos: 4 * second, title: "Export"), reason: "r"))
    let chapter = try #require(editor.chapters.track.chapters.first)
    _ = bridge.perform(.overlay(.renameChapter(id: chapter.id, title: "Export to MP4"), reason: "r"))
    #expect(editor.chapters.track.chapters.first?.title == "Export to MP4")
    guard case .failure(let message, _) = bridge.perform(.overlay(.removeChapter(id: 99), reason: "r")) else {
        Issue.record("a missing chapter was removed"); return
    }
    #expect(message.contains("99"))
}

/// The camera is placed only where there is one.
@Test @MainActor func theCameraIsPlacedOnlyWhenThereIsOne() {
    let editor = editor()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    guard case .failure = bridge.perform(.overlay(.setCamera(.init(size: 0.3)), reason: "r")) else {
        Issue.record("placed a camera that is not there"); return
    }
    editor.hasCamera = true
    _ = bridge.perform(.overlay(.setCamera(.init(shape: "square", size: 0.3, y: 0.2)), reason: "r"))
    #expect(editor.cameraStyle.widthFraction == 0.3 && editor.cameraStyle.shape == .square)
    #expect(abs(editor.cameraStyle.y - 0.8) < 1e-9)
}

/// A turn that added titles and hid a region reverts as a whole.
@Test @MainActor func aTurnOfOverlayEditsRevertsAtOnce() {
    let editor = editor()
    let before = editor.look
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    var records: [AgentEditRecord] = []
    bridge.onEdit = { records.append($0) }
    _ = bridge.perform(.overlay(.addTitle(.init(text: "One")), reason: "r"))
    _ = bridge.perform(.overlay(.hideRegion(.init(startNanos: 0, endNanos: second, x: 0, y: 0, width: 0.1, height: 0.1)), reason: "r"))
    let turn = AgentPanelModel.Turn(id: 1, request: "dress it", items: records.map { .edit($0) }, running: false,
                                    checkpoint: editor.timeline.historyDepth)
    #expect(AgentPanelModel(providers: [ClaudeCodeProvider()]).revert(turn, editor: editor) == nil)
    #expect(editor.look == before)
}

/// The names the overlay tools offer are the app's own.
@Test func theOverlayOptionNamesAreTheAppsOwn() {
    #expect(Set(AgentTools.markShapes).isSubset(of: Set(AnnotationShape.allCases.map(\.rawValue))))
    #expect(AgentTools.cameraShapes == CameraOverlayStyle.Shape.allCases.map(\.rawValue))
}

// MARK: - the agent's zooms

/// A 20 s recording with two zooms, at 4–6 s and 12–14 s on a host clock starting at 500 s —
/// not at zero, so a zoom read on the host clock and one read on the recording's cannot agree by accident.
@MainActor private func zoomed() -> EditorViewModel {
    let editor = editor()
    let epoch = BootEpoch(id: UUID(uuidString: "5A5A5A5A-1B1B-4C4C-8D8D-2E2E2E2E2E2E")!)
    editor.timeline.setZoomAnchor(EpochAnchor(epoch: epoch, hostTime: Nanoseconds(500 * second), wallClockUnixNanos: 0))
    let target = FramingTarget(frame: NormalizedFrame(origin: NormalizedPoint(x: 0.3, y: 0.6), size: NormalizedSize(width: 0.05, height: 0.05),
                                                      revision: GeometryRevision(id: 1)), role: "AXButton")
    func at(_ s: Int64) -> HostInstant { HostInstant(epoch: epoch, hostTime: Nanoseconds((500 + s) * second)) }
    editor.timeline.setDerivedZooms([ZoomBlock(origin: at(4), start: at(4), end: at(6), target: target, zoom: 2),
                                     ZoomBlock(origin: at(12), start: at(12), end: at(14), target: target, zoom: 1.5)])
    return editor
}

/// Zooms are numbered in time and reported on the recording's clock.
@Test @MainActor func theZoomsAreNumberedInTimeOnTheRecordingsClock() {
    let bridge = AgentEditorBridge(editor: zoomed(), agentName: "Claude Code")
    guard case .success(let json) = bridge.perform(.zooms) else { Issue.record("no zooms"); return }
    #expect(json.contains(#""number":1"#) && json.contains(#""startNanos":4000000000"#), "\(json)")
    #expect(json.contains(#""number":2"#) && json.contains(#""startNanos":12000000000"#), "\(json)")
}

/// Turning one off is a timeline step named for the agent, and a turn of them reverts with its cuts.
@Test @MainActor func aZoomTurnedOffIsAStepNamedForTheAgentAndRevertsWithItsTurn() throws {
    let editor = zoomed()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    var records: [AgentEditRecord] = []
    bridge.onEdit = { records.append($0) }
    let mark = editor.timeline.historyDepth
    guard case .success = bridge.perform(.setZoom(2, on: false, reason: "Step 5 is already readable")) else { Issue.record("refused"); return }
    // The 12 s one, from `derivedZooms`: `zooms` leaves out a zoom once it is off.
    let second = try #require(editor.timeline.derivedZooms.max { $0.start.hostTime.rawValue < $1.start.hostTime.rawValue })
    #expect(editor.timeline.isZoomSuppressed(second.origin))
    #expect(editor.timeline.undoStepName == "Claude Code: Step 5 is already readable")
    _ = bridge.perform(.cutSpan(start: 1 * 1_000_000_000, end: 2 * 1_000_000_000, reason: "r"))
    let turn = AgentPanelModel.Turn(id: 1, request: "calmer", items: records.map { .edit($0) }, running: false, checkpoint: mark)
    #expect(AgentPanelModel(providers: [ClaudeCodeProvider()]).revert(turn, editor: editor) == nil)
    #expect(!editor.timeline.isZoomSuppressed(second.origin), "the zoom is back on")
    #expect(editor.timeline.historyDepth == mark)
    guard case .failure(_, let code) = bridge.perform(.setZoom(3, on: false, reason: "r")) else { Issue.record("zoom 3 of 2"); return }
    #expect(code == "noSuchZoom")
    guard case .failure(_, let same) = bridge.perform(.setZoom(1, on: true, reason: "r")) else { Issue.record("a no-op was recorded"); return }
    #expect(same == "unchanged")
}

/// **A zoom turned off keeps its number**, and can be turned back on by it. Numbering the list
/// of zooms that are ON renumbered everything after one the moment it went off — found while
/// writing these tests — and left the one turned off with no number at all.
@Test @MainActor func aZoomTurnedOffKeepsItsNumberAndCanBeTurnedBackOn() {
    let editor = zoomed()
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    _ = bridge.perform(.setZoom(1, on: false, reason: "r"))
    guard case .success(let json) = bridge.perform(.zooms) else { Issue.record("no zooms"); return }
    #expect(json.contains(#""number":2"#), "still two zooms: \(json)")
    guard case .success = bridge.perform(.setZoom(1, on: true, reason: "r")) else { Issue.record("could not turn zoom 1 back on"); return }
    #expect(editor.timeline.derivedZooms.allSatisfy { !editor.timeline.isZoomSuppressed($0.origin) })
}

// MARK: - pictures from the web

/// A real PNG, made here, so the check is run against bytes that are a picture.
private func png(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// What decodes is kept with its own kind; an SVG and a page are refused, each said for what it is.
@Test func aPictureIsCheckedByWhatItDecodesAs() {
    guard case .success(let picture) = PictureFetcher.check(png(width: 40, height: 20)) else { Issue.record("a PNG was refused"); return }
    #expect(picture.fileExtension == "png" && picture.width == 40 && picture.height == 20)
    guard case .failure(let svg) = PictureFetcher.check(Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)) else {
        Issue.record("an SVG passed"); return
    }
    #expect(svg.message.contains("SVG"))
    guard case .failure(let page) = PictureFetcher.check(Data("<html><body>Not found</body></html>".utf8)) else {
        Issue.record("a page passed"); return
    }
    #expect(page.message.contains("not a picture"))
}

/// A fetched picture becomes the background as one look change named for the agent, copied into
/// the package under the address's own name made safe; or is added to the pictures to place.
@Test @MainActor func aFetchedPictureBecomesTheBackgroundOrAPictureToPlace() async throws {
    let editor = editor()
    let package = FileManager.default.temporaryDirectory.appending(path: "import-\(ProcessInfo.processInfo.globallyUniqueString).soredemo")
    try FileManager.default.createDirectory(at: package.appending(path: "media"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: package) }
    editor.mediaURL = package.appending(path: "media").appending(path: "master-00.mov")
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    var records: [AgentEditRecord] = []
    bridge.onEdit = { records.append($0) }
    guard case .success(let picture) = PictureFetcher.check(png(width: 64, height: 64)) else { Issue.record("no picture"); return }
    editor.library.load(packageURL: package)
    guard case .success = await bridge.adopt(picture, from: "https://www.nthu.edu.tw/img/NTHU Logo.png", use: "background", reason: "The emblem") else {
        Issue.record("refused"); return
    }
    #expect(editor.stageStyle.style.background == .image(filename: "NTHU-Logo.png"))
    #expect(FileManager.default.fileExists(atPath: package.appending(path: "backgrounds/NTHU-Logo.png").path(percentEncoded: false)))
    #expect(records.contains { $0.stepName == "Claude Code: The emblem" })
    #expect(editor.library.library.items.first?.origin == .web(host: "www.nthu.edu.tw"), "it joins the library, with where it came from")
    guard case .success(let json) = await bridge.adopt(picture, from: "https://x.edu/seal.png", use: "picture", reason: "r") else {
        Issue.record("refused"); return
    }
    #expect(json.contains(#""picture":"seal.png""#))
    guard case .success = bridge.perform(.overlay(.addMark(.init(shape: "image", fromX: 0.7, fromY: 0.1, toX: 0.9, toY: 0.3,
                                                                    startNanos: 0, seconds: 5, picture: "seal.png")), reason: "r")) else {
        Issue.record("could not place it"); return
    }
    #expect(editor.annotations.track.items.first?.imageName == "seal.png")
    guard case .failure(let missing, _) = bridge.perform(.overlay(.addMark(.init(shape: "image", fromX: 0.7, fromY: 0.1, toX: 0.9, toY: 0.3,
                                                                                startNanos: 0, seconds: 5, picture: "nope.png")), reason: "r")) else {
        Issue.record("placed a picture that is not there"); return
    }
    #expect(missing.contains("import_image"))
}

/// The switch is remembered, on until the person turns it off.
@Test @MainActor func theWebSwitchIsOnByDefaultAndRemembered() {
    let defaults = UserDefaults(suiteName: "soredemo-web-\(ProcessInfo.processInfo.globallyUniqueString)")!
    #expect(AgentPanelModel(providers: [ClaudeCodeProvider()], defaults: defaults).webAccess)
    AgentPanelModel(providers: [ClaudeCodeProvider()], defaults: defaults).webAccess = false
    #expect(!AgentPanelModel(providers: [ClaudeCodeProvider()], defaults: defaults).webAccess)
}

/// A redirect is checked by the same rule before it is followed: a public page cannot send the
/// fetch to this Mac or its network. Run against the delegate itself, no network needed.
@Test func aRedirectToThisMacOrItsNetworkIsNotFollowed() async throws {
    let check = RedirectCheck()
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(with: URL(string: "https://example.com/a.png")!)
    let response = try #require(HTTPURLResponse(url: URL(string: "https://example.com/a.png")!, statusCode: 302, httpVersion: nil, headerFields: nil))
    func followed(_ target: String) async -> Bool {
        await withCheckedContinuation { continuation in
            check.urlSession(session, task: task, willPerformHTTPRedirection: response,
                             newRequest: URLRequest(url: URL(string: target)!)) { continuation.resume(returning: $0 != nil) }
        }
    }
    #expect(await followed("https://cdn.example.com/a.png"), "a public https address is followed")
    #expect(await !followed("https://192.168.1.1/admin"))
    #expect(await !followed("http://example.com/a.png"))
    #expect(await !followed("https://localhost/a.png"))
}

// MARK: - the plan's usage before a message

/// Off until asked: nothing is read and nothing is sent, and the strip offers the button.
@Test @MainActor func thePlansUsageIsNotReadUntilThePersonAsks() async {
    let defaults = UserDefaults(suiteName: "soredemo-usage-\(ProcessInfo.processInfo.globallyUniqueString)")!
    let panel = AgentPanelModel(providers: [ClaudeCodeProvider()], defaults: defaults)
    #expect(!panel.readsAccountUsage)
    await panel.refreshAccountUsage(panelOpen: true)
    #expect(panel.usage.note == nil && panel.usage.windows.isEmpty, "nothing was read")
    panel.readsAccountUsage = true
    #expect(AgentPanelModel(providers: [ClaudeCodeProvider()], defaults: defaults).readsAccountUsage, "asked once, remembered")
}

/// What the strip says when it could not read — never blank, so an empty strip is not taken for 0 %.
@Test func theStripSaysWhyThereIsNoReading() {
    #expect(AgentUsageStrip.say(.expired, provider: "Claude Code") != nil)
    #expect(AgentUsageStrip.say(.notSignedIn, provider: "Codex") != nil)
    #expect(AgentUsageStrip.say(.failed("x"), provider: "Codex") != nil)
    #expect(AgentUsageStrip.say(.refused(retryAfterSeconds: 60), provider: "Codex") == nil, "a 429 keeps what was shown")
}
