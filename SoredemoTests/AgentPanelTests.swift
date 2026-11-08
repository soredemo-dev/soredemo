import Testing
import Foundation
import Network
import Surface
import Timeline
import Framing
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
    #expect(recorded.map(\.removed) == [Nanoseconds(10 * second)])
    #expect(recorded.first?.at == Nanoseconds(4 * second), "the jump lands where the cut now is")
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
    let panel = AgentPanelModel(provider: ClaudeCodeProvider())

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

    let panel = AgentPanelModel(provider: ClaudeCodeProvider())
    #expect(panel.revert(first, editor: editor) != nil)
    #expect(editor.timeline.edit.outputDuration == Nanoseconds(16 * second), "both cuts stand")
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
