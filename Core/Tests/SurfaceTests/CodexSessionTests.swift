import Foundation
import Testing
@testable import Surface

// The person's Codex through `codex app-server`, read from a RECORDED session: Codex 0.167.0
// asked to call Soredemo's `steps` tool, 2026-11-09, started with exactly the switches below.
// Personal paths replaced; the account, usage and moderation lines removed. Lines the host sent
// are recorded as {"sent": …}; every expected value below is read from that file.

private func fixture() throws -> [[String: Any]] {
    let url = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "Fixtures/codex-0.167.0-steps.jsonl")
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    try #require(lines.count > 20, "the recorded session read as \(lines.count) lines — the fixture is missing")
    return lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
}

/// What Codex wrote, one line each, in order.
private func serverLines() throws -> [String] {
    try fixture().filter { $0["sent"] == nil }.map(line)
}

private func line(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
}

private func object(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
}

private let steps = MCPTool(name: "steps", title: "Recorded steps", description: "The recording's steps.",
                            inputSchema: #"{"additionalProperties":false,"properties":{},"type":"object"}"#, readOnly: true)

private func session(webAccess: Bool = false) -> CodexSession {
    CodexSession(tools: [steps], instructions: "You are inside Soredemo.", workingDirectory: "/tmp/soredemo-agent",
                 webAccess: webAccess)
}

private let thread = "01a1bee4-dc66-7102-9a47-1e13366164b2"
private let turn = "01a1bee4-dca5-79c2-aa05-3de3f879b79d"

/// The whole recorded turn, replayed through a session, every output in order.
private func replay() throws -> [CodexSession.Output] {
    var codex = session()
    var outputs = codex.begin(message: "Call soredemo_steps, then say in one line how many steps there are.", model: nil)
    for text in try serverLines() { outputs += codex.receive(text) }
    return outputs
}

private func sent(_ outputs: [CodexSession.Output]) -> [[String: Any]] {
    outputs.compactMap { if case .send(let text) = $0 { object(text) } else { nil } }
}

private func events(_ outputs: [CodexSession.Output]) -> [AgentEvent] {
    outputs.compactMap { if case .event(let event) = $0 { event } else { nil } }
}

/// A session past the handshake, with the recorded thread and turn running.
private func running(webAccess: Bool = false) throws -> CodexSession {
    var codex = session(webAccess: webAccess)
    _ = codex.begin(message: "m", model: nil)
    for text in try serverLines().prefix(while: { !$0.contains(#""method":"item/started""#) }) {
        _ = codex.receive(text)
    }
    return codex
}

private func itemStarted(_ item: [String: Any]) -> String {
    line(["method": "item/started", "params": ["threadId": thread, "turnId": turn, "item": item]])
}

@Suite struct CodexArgumentsTests {
    /// Every server the person configured is closed by name, from the listing read at start.
    @Test func everyListedServerIsClosedByName() throws {
        let names = try #require(CodexAppServer.serverNames(fromListing:
            #"[{"name":"computer-use","enabled":false},{"name":"node_repl","enabled":true}]"#))
        #expect(names == ["computer-use", "node_repl"])
        let arguments = CodexAppServer.serverArguments(closing: names)
        #expect(arguments.contains(#"mcp_servers={"computer-use"={enabled=false},"node_repl"={enabled=false}}"#))
        #expect(arguments.last == "app-server", "every switch comes before the subcommand")
    }

    /// The switches the measurement needed, each one: plugins brought computer use back with
    /// `computer_use` off, and the person's hooks ran with nothing else closing them.
    @Test func theSwitchesTheMeasurementNeededAreAllThere() {
        let arguments = CodexAppServer.serverArguments(closing: [])
        for key in ["features.plugins=false", "features.apps=false", #"web_search="disabled""#] {
            #expect(arguments.contains(key), "\(key)")
        }
        for feature in ["shell_tool", "unified_exec", "browser_use", "computer_use", "in_app_browser",
                        "multi_agent", "remote_plugin", "hooks"] {
            let index = arguments.firstIndex(of: feature)
            #expect(index.map { arguments[$0 - 1] == "--disable" } == true, "\(feature) is disabled")
        }
        #expect(!arguments.contains { $0.contains("bypass") || $0 == "--yolo" || $0.contains("danger") })
    }

    /// The listing is read under the same switches, so a plugin's servers are not in it.
    @Test func theListingIsReadUnderTheSameClosingSwitches() {
        #expect(CodexAppServer.listingArguments.suffix(3) == ["mcp", "list", "--json"])
        #expect(CodexAppServer.listingArguments.contains("features.plugins=false"))
    }

    /// A listing that cannot be read is no listing — never "no servers", which is a legal answer.
    @Test func anUnreadableListingIsNotAnEmptyOne() {
        #expect(CodexAppServer.serverNames(fromListing: "[]") == [])
        #expect(CodexAppServer.serverNames(fromListing: "Error: config.toml is invalid") == nil)
        #expect(CodexAppServer.serverNames(fromListing: #"{"servers":[]}"#) == nil)
        #expect(CodexAppServer.serverNames(fromListing: #"[{"name":"a"},{"enabled":true}]"#) == nil,
                "a server with no name cannot be closed by name")
    }

    /// A name is written as a TOML string, so a quote in it cannot end the table early.
    @Test func aServerNameCannotBreakOutOfItsKey() {
        let arguments = CodexAppServer.serverArguments(closing: [#"x"={enabled=true},"y"#])
        #expect(arguments.contains(#"mcp_servers={"x\"={enabled=true},\"y"={enabled=false}}"#))
    }
}

@Suite struct CodexSessionTests {
    /// The host's side of the recorded session, in order, as the session writes it.
    @Test func theHandshakeIsInitializeThenTheThreadThenTheTurn() throws {
        let methods = sent(try replay()).map { $0["method"] as? String ?? "reply" }
        #expect(methods == ["initialize", "initialized", "thread/start", "turn/start", "account/rateLimits/read"],
                "the tool call is answered by the provider, not the session")
    }

    /// Every field that decides what Codex may do is stated on the thread, so the person's
    /// config.toml cannot loosen it.
    @Test func theThreadIsReadOnlyUntrustedEphemeralAndHoldsOnlySoredemosTools() throws {
        let start = try #require(sent(try replay()).first { $0["method"] as? String == "thread/start" })
        let params = try #require(start["params"] as? [String: Any])
        #expect(params["approvalPolicy"] as? String == "untrusted")
        #expect(params["sandbox"] as? String == "read-only")
        #expect(params["ephemeral"] as? Bool == true)
        #expect(params["cwd"] as? String == "/tmp/soredemo-agent")
        #expect(params["developerInstructions"] as? String == "You are inside Soredemo.")
        let tools = try #require(params["dynamicTools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["soredemo_steps"])
        #expect(tools.first?["inputSchema"] is [String: Any], "the schema goes as an object, not as text")
    }

    @Test func theSessionStartsWithTheThreadSoredemosToolsAndTheModel() throws {
        #expect(events(try replay()).first == .started(session: thread, tools: ["steps"], model: "gpt-6.1-sol"))
    }

    /// The recorded tool call: shown started with its input, asked of the provider, then finished.
    @Test func aToolCallIsShownAskedOfTheProviderAndFinished() throws {
        let outputs = try replay()
        let id = "exec-09b0b587-7947-4bf0-8911-07245609121c"
        let started = try #require(outputs.firstIndex(of: .event(.toolStarted(id: id, name: "steps"))))
        let called = try #require(outputs.firstIndex(of: .event(.toolCalled(id: id, name: "steps", input: "{}"))))
        let asked = try #require(outputs.firstIndex(of: .callTool(.number(0), name: "steps", argumentsJSON: "{}")))
        let finished = try #require(outputs.firstIndex(of: .event(.toolFinished(id: id, isError: false,
            output: #"{"steps":[{"number":1,"label":"Export"},{"number":2,"label":"Done"}]}"#))))
        #expect(started < called && called < asked && asked < finished)
    }

    @Test func theTextStreamsAndEachMessageEndsWhole() throws {
        let all = events(try replay())
        let deltas = all.compactMap { if case .textDelta(let text) = $0 { text } else { nil } }
        #expect(deltas.joined() == "I’ll check the recording’s steps.There are 2 steps.")
        #expect(all.filter { if case .text = $0 { true } else { false } }
                == [.text("I’ll check the recording’s steps."), .text("There are 2 steps.")])
    }

    @Test func theTurnEndsWithItsDurationAndNoCostThenTheStreamEnds() throws {
        let outputs = try replay()
        #expect(outputs.suffix(2) == [.event(.finished(isError: false, durationMilliseconds: 6000, costUSD: nil, session: thread)),
                                      .turnEnded])
    }

    /// The next message is a turn on the same thread; a new conversation is a new thread.
    @Test func aSecondMessageIsATurnOnTheSameThread() throws {
        var codex = session()
        _ = codex.begin(message: "first", model: nil)
        for text in try serverLines() { _ = codex.receive(text) }
        let next = sent(codex.begin(message: "second", model: "gpt-6.1"))
        #expect(next.map { $0["method"] as? String } == ["turn/start", "account/rateLimits/read"])
        let params = try #require(next.first?["params"] as? [String: Any])
        #expect(params["threadId"] as? String == thread)
        #expect(params["model"] as? String == "gpt-6.1")
        #expect(params["approvalPolicy"] as? String == "untrusted", "stated again on every turn")

        _ = codex.receive(line(["method": "turn/completed", "params": ["threadId": thread, "turn": ["id": "t2", "status": "completed"]]]))
        var same = codex
        #expect(sent(same.begin(message: "third", model: nil)).map { $0["method"] as? String } == ["turn/start", "account/rateLimits/read"])
        var fresh = codex
        fresh.newThread()
        #expect(sent(fresh.begin(message: "third", model: nil)).map { $0["method"] as? String } == ["thread/start"])
    }

    @Test func aMessageWhileATurnRunsSendsNothing() throws {
        var codex = try running()
        #expect(codex.begin(message: "again", model: nil).isEmpty)
    }
}

@Suite struct CodexHostRefusalTests {
    /// **The claim checked against the thing**: the thread's own reply says what it runs under,
    /// and anything but read-only and untrusted stops before a turn is sent.
    @Test func aThreadThatIsNotReadOnlyIsRefusedBeforeAnyTurn() throws {
        var codex = session()
        var outputs = codex.begin(message: "m", model: nil)
        outputs += codex.receive(#"{"id":1,"result":{}}"#)
        outputs += codex.receive(line(["id": 2, "result": [
            "thread": ["id": thread], "model": "gpt-6.1-sol",
            "approvalPolicy": "never", "sandbox": ["type": "workspaceWrite", "networkAccess": true]]]))
        #expect(!sent(outputs).contains { $0["method"] as? String == "turn/start" })
        let failure = events(outputs).compactMap { if case .failed(let text) = $0 { text } else { nil } }.first
        #expect(failure?.contains("workspaceWrite") == true && failure?.contains("never") == true,
                "the refusal says what was measured: \(failure ?? "nothing")")
        #expect(outputs.last == .turnEnded)
    }

    /// Anything but the few kinds a Soredemo turn is made of interrupts the turn, and says which.
    @Test func aToolThatIsNotSoredemosInterruptsTheTurnAndIsNamed() throws {
        for (item, named) in [
            (["type": "mcpToolCall", "id": "c1", "server": "cua_repl", "tool": "js", "status": "inProgress"], "cua_repl: js"),
            (["type": "commandExecution", "id": "c2", "command": "ls ~", "status": "inProgress"], "a shell command"),
            (["type": "fileChange", "id": "c3", "changes": [], "status": "inProgress"], "a file change"),
            (["type": "webSearch", "id": "c4", "query": "q"], "web search"),
            (["type": "dynamicToolCall", "id": "c5", "tool": "publish_post", "status": "inProgress"], "publish_post"),
            // Soredemo's prefix on a name that is not one of its tools is still not its tool.
            (["type": "dynamicToolCall", "id": "c7", "tool": "soredemo_publish_post", "status": "inProgress"], "soredemo_publish_post"),
            (["type": "collabAgentToolCall", "id": "c6", "tool": "spawn", "status": "inProgress"], "collabAgentToolCall"),
        ] as [([String: Any], String)] {
            var codex = try running()
            let outputs = codex.receive(itemStarted(item))
            let interrupt = sent(outputs).first { $0["method"] as? String == "turn/interrupt" }
            #expect((interrupt?["params"] as? [String: String]) == ["threadId": thread, "turnId": turn], "\(named)")
            let failure = events(outputs).compactMap { if case .failed(let text) = $0 { text } else { nil } }.first
            #expect(failure?.contains(named) == true, "\(named): \(failure ?? "no failure")")
            // A second foreign item in the same turn does not interrupt twice.
            #expect(sent(codex.receive(itemStarted(item))).isEmpty)
        }
    }

    /// What a Soredemo turn is made of passes untouched — or every turn would be stopped.
    @Test func theKindsASoredemoTurnIsMadeOfPass() throws {
        for item in [
            ["type": "userMessage", "id": "u"], ["type": "agentMessage", "id": "a", "text": ""],
            ["type": "reasoning", "id": "r", "summary": [], "content": []], ["type": "plan", "id": "p", "text": ""],
            ["type": "contextCompaction", "id": "k"],
            ["type": "mcpToolCall", "id": "l", "server": "codex", "tool": "list_mcp_resources", "status": "inProgress", "arguments": [:]],
        ] as [[String: Any]] {
            var codex = try running()
            let outputs = codex.receive(itemStarted(item))
            #expect(sent(outputs).isEmpty, "\(item["type"]!)")
            #expect(!events(outputs).contains { if case .failed = $0 { true } else { false } }, "\(item["type"]!)")
        }
    }

    /// Every request Codex can send gets an answer that grants nothing; one this host does not
    /// know is refused rather than left waiting.
    @Test func everyRequestIsAnsweredAndNoneGrantsAnything() throws {
        let cases: [(String, [String: Any])] = [
            ("item/commandExecution/requestApproval", ["result": ["decision": "cancel"]]),
            ("item/fileChange/requestApproval", ["result": ["decision": "cancel"]]),
            ("mcpServer/elicitation/request", ["result": ["action": "decline", "content": NSNull()]]),
            ("item/permissions/requestApproval", ["result": ["permissions": [String: Any](), "scope": "turn", "strictAutoReview": true]]),
            ("applyPatchApproval", ["result": ["decision": "abort"]]),
            ("execCommandApproval", ["result": ["decision": "abort"]]),
        ]
        for (method, expected) in cases {
            var codex = try running()
            let reply = try #require(sent(codex.receive(line(["method": method, "id": 7, "params": [:]]))).first, "\(method)")
            #expect(reply["id"] as? Int == 7)
            #expect(NSDictionary(dictionary: reply["result"] as? [String: Any] ?? [:])
                    .isEqual(to: expected["result"] as? [String: Any] ?? [:]), "\(method): \(reply)")
        }
        for method in ["item/tool/requestUserInput", "account/chatgptAuthTokens/refresh", "attestation/generate", "something/new"] {
            var codex = try running()
            let reply = try #require(sent(codex.receive(line(["method": method, "id": "r9", "params": [:]]))).first, "\(method)")
            #expect(reply["id"] as? String == "r9")
            #expect(reply["error"] != nil && reply["result"] == nil, "\(method) is refused")
        }
    }

    /// A call to a tool that is not Soredemo's is answered as a failure, never passed on.
    @Test(arguments: ["publish_post", "soredemo_publish_post"])
    func aCallToAToolThatIsNotOursIsAFailureNotACall(_ name: String) throws {
        var codex = try running()
        let outputs = codex.receive(line(["method": "item/tool/call", "id": 3,
                                          "params": ["threadId": thread, "turnId": turn, "callId": "x", "tool": name, "arguments": [:]]]))
        #expect(!outputs.contains { if case .callTool = $0 { true } else { false } })
        let reply = try #require(sent(outputs).first?["result"] as? [String: Any])
        #expect(reply["success"] as? Bool == false)
    }

    @Test func aToolsAnswerIsItsTextWithWhetherItSucceeded() {
        let ok = object(CodexSession.reply(to: .number(4), with: .success(json: #"{"a":1}"#)))
        #expect(ok["id"] as? Int == 4)
        #expect((ok["result"] as? [String: Any])?["success"] as? Bool == true)
        #expect(((ok["result"] as? [String: Any])?["contentItems"] as? [[String: String]]) == [["type": "inputText", "text": #"{"a":1}"#]])
        let failed = object(CodexSession.reply(to: .text("q"), with: .failure(message: "No step 9.", code: "usage")))
        #expect(failed["id"] as? String == "q")
        #expect((failed["result"] as? [String: Any])?["success"] as? Bool == false)
    }

    /// Stop is an interrupt of the running turn; with nothing running there is nothing to send.
    @Test func stopInterruptsTheRunningTurnAndOnlyIt() throws {
        var codex = try running()
        #expect(sent(codex.interrupt()).map { $0["method"] as? String } == ["turn/interrupt"])
        var idle = session()
        #expect(idle.interrupt().isEmpty)
    }

    /// Stop pressed before Codex has said which turn it started: the interrupt goes as soon as it does.
    @Test func stopBeforeTheTurnHasAnIdIsSentWhenItGetsOne() throws {
        var codex = session()
        _ = codex.begin(message: "m", model: nil)
        let lines = try serverLines()
        let beforeTurn = lines.prefix { !$0.hasPrefix(#"{"id":3"#) }
        for text in beforeTurn { _ = codex.receive(text) }
        #expect(sent(codex.interrupt()).isEmpty, "no turn id yet")
        let turnReply = try #require(lines.first { $0.hasPrefix(#"{"id":3"#) })
        #expect(sent(codex.receive(turnReply)).map { $0["method"] as? String } == ["turn/interrupt"])
    }

    /// Codex says a turn's error twice — as an `error` and again as the failed turn — and the
    /// panel says it once. Measured 2026-11-09 on a usage-limited account.
    @Test func anErrorRepeatedByTheTurnsEndIsSaidOnce() throws {
        var codex = try running()
        let error = line(["method": "error", "params": ["threadId": thread, "turnId": turn, "willRetry": false,
                                                        "error": ["message": "You've hit your usage limit."]]])
        var outputs = codex.receive(error)
        outputs += codex.receive(line(["method": "turn/completed", "params": ["threadId": thread, "turn": [
            "id": turn, "status": "failed", "durationMs": 900, "error": ["message": "You've hit your usage limit."]]]]))
        #expect(events(outputs).filter { if case .failed = $0 { true } else { false } } == [.failed("You've hit your usage limit.")])
    }

    @Test func aFailedTurnSaysWhyAndEndsAsAnError() throws {
        var codex = try running()
        let outputs = codex.receive(line(["method": "turn/completed", "params": ["threadId": thread, "turn": [
            "id": turn, "status": "failed", "durationMs": 900, "error": ["message": "You've hit your usage limit."]]]]))
        #expect(outputs == [.event(.failed("You've hit your usage limit.")),
                            .event(.finished(isError: true, durationMilliseconds: 900, costUSD: nil, session: thread)),
                            .turnEnded])
    }

    /// The process ending mid-turn ends the turn; the next message starts Codex from the handshake.
    @Test func theProcessEndingEndsTheTurnAndTheNextMessageStartsOver() throws {
        var codex = try running()
        #expect(codex.processEnded(reason: "exit 1") == [.event(.failed("Codex stopped (exit 1).")), .turnEnded])
        #expect(sent(codex.begin(message: "m", model: nil)).map { $0["method"] as? String } == ["initialize"])
    }

    /// Another thread's events — a subagent, a second client — are not this turn's.
    @Test func anotherThreadsEventsAreIgnored() throws {
        var codex = try running()
        let outputs = codex.receive(line(["method": "item/agentMessage/delta",
                                          "params": ["threadId": "other", "turnId": "t", "itemId": "i", "delta": "hi"]]))
        #expect(outputs.isEmpty)
    }
}

@Suite struct CodexModelListTests {
    /// The models the person's own `/model` picker lists, in its order; hidden ones are not offered.
    @Test func theModelsAreTheCachesListedOnesInItsOrder() {
        let cache = #"{"models":[{"slug":"b","display_name":"Model B","visibility":"list","priority":2},{"slug":"hidden","display_name":"H","visibility":"hide","priority":0},{"slug":"a","display_name":"Model A","visibility":"list","priority":1},{"slug":"c","visibility":"list"}]}"#
        #expect(CodexAppServer.models(fromCache: Data(cache.utf8)) == [
            AgentModel(id: "a", label: "Model A"), AgentModel(id: "b", label: "Model B"), AgentModel(id: "c", label: "c")])
    }

    /// No cache is no list — the picker then offers only the person's default.
    @Test func anUnreadableCacheIsNoModels() {
        #expect(CodexAppServer.models(fromCache: Data("nope".utf8)).isEmpty)
        #expect(CodexAppServer.models(fromCache: Data(#"{"models":[{"display_name":"no slug"}]}"#.utf8)).isEmpty)
    }

    /// **The web is a switch, and both settings are what they say.** Off, Codex's search is
    /// disabled at the server and a search in a turn still interrupts it; on, it is live and a
    /// search passes and is shown — while every other foreign kind still interrupts.
    @Test func webSearchIsOpenedOnlyByTheSwitch() throws {
        #expect(CodexAppServer.serverArguments(closing: [], webAccess: false).contains(#"web_search="disabled""#))
        let open = CodexAppServer.serverArguments(closing: [], webAccess: true)
        #expect(open.contains(#"web_search="live""#) && !open.contains(#"web_search="disabled""#))
        for feature in ["shell_tool", "unified_exec", "computer_use"] {
            #expect(open.firstIndex(of: feature).map { open[$0 - 1] == "--disable" } == true, "\(feature) stays closed with the web open")
        }
        var codex = try running(webAccess: true)
        let outputs = codex.receive(itemStarted(["type": "webSearch", "id": "w1", "query": "NTHU emblem png"]))
        #expect(sent(outputs).isEmpty, "no interrupt")
        #expect(events(outputs).contains(.toolStarted(id: "w1", name: "web_search")))
        var shut = try running(webAccess: false)
        #expect(sent(shut.receive(itemStarted(["type": "webSearch", "id": "w1", "query": "q"]))).contains { $0["method"] as? String == "turn/interrupt" })
        var shell = try running(webAccess: true)
        #expect(sent(shell.receive(itemStarted(["type": "commandExecution", "id": "c", "command": "ls", "status": "inProgress"])))
                .contains { $0["method"] as? String == "turn/interrupt" }, "a shell is still not the web")
    }
}
