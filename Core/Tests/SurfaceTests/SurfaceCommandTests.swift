import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Framing
@testable import Surface

// The surface an outside caller runs: parsing, the envelope, exit statuses, and what each verb
// answers. `docs/design/2026-11-08-evidence-cut-and-the-agent-surface.md`, "The surface".
//
// **The recording is anchored at 100 s**, so an offset reported without subtracting the anchor
// would read 100 s late. Steps at 104 s and 115 s in a twenty-second recording; one click framed,
// one refused.

private let epoch = BootEpoch(id: UUID(uuidString: "5C11CE11-0000-4000-8000-0000000000B1")!)
private let second: Int64 = 1_000_000_000
private let anchor = EpochAnchor(epoch: epoch, hostTime: Nanoseconds(100 * second), wallClockUnixNanos: 0)
private let log = OpenedProject.Log(url: URL(fileURLWithPath: "/fixture/observations/segment-00.jsonl"),
                                    anchor: anchor, duration: Nanoseconds(20 * second))

private func at(_ seconds: Int64) -> HostInstant { HostInstant(epoch: epoch, hostTime: Nanoseconds(seconds * second)) }

private struct FixtureReader: ProjectReading {
    var hasLog = true
    var dismissed: Set<CutProposal.Key> = []
    var opens = true

    struct CannotOpen: Error, CustomStringConvertible { var description: String { "no such package" } }

    func open(_ path: String) throws -> OpenedProject {
        guard opens else { throw CannotOpen() }
        return OpenedProject(package: URL(fileURLWithPath: path), name: "demo.soredemo", mediaFilename: "master-00.mov",
                             log: hasLog ? log : nil, edit: nil, dismissed: dismissed)
    }

    func take(of log: OpenedProject.Log, speech: [Range<Int64>]) throws -> TakeActivity {
        try TakeActivity(
            recording: HostRange(epoch: epoch, start: Nanoseconds(100 * second), duration: Nanoseconds(20 * second)),
            steps: [RecordedStep(origin: at(104), end: at(115), number: 1, label: "Export", role: "AXButton",
                                 application: "Keynote", frame: nil),
                    RecordedStep(origin: at(115), end: at(120), number: 2, label: "Done", role: "AXButton",
                                 application: "Keynote", frame: nil)],
            pointer: [], buttons: [], shortcuts: [],
            speech: speech.map { HostRange(epoch: epoch, start: Nanoseconds(100 * second + $0.lowerBound),
                                           duration: Nanoseconds($0.upperBound - $0.lowerBound)) },
            unobserved: [])
    }

    func framing(of log: OpenedProject.Log) throws -> FramingPlan {
        FramingPlan(entries: [
            .init(instant: at(104), decision: .framed(FramingTarget(
                frame: NormalizedFrame(origin: NormalizedPoint(x: 0.2, y: 0.2), size: NormalizedSize(width: 0.1, height: 0.1),
                                       revision: GeometryRevision(id: 1)), role: "AXButton"))),
            .init(instant: at(115), decision: .rejected(.hitTestReturnedNothing)),
        ])
    }
}

private struct FixedHearing: Hearing {
    let heard: Heard
    func heard(in project: OpenedProject) async -> Heard { heard }
}

private let deaf = FixedHearing(heard: .nothing("fixture"))

private func run(_ arguments: [String], reader: FixtureReader = FixtureReader(),
                 hearing: FixedHearing = deaf) async -> SurfaceCommand.Output {
    await SurfaceCommand.run(arguments, reader: reader, hearing: hearing)
}

/// The stdout of a `--json` call, decoded as a dictionary — the shape a caller sees.
private func json(_ output: SurfaceCommand.Output) throws -> [String: Any] {
    try #require(output.stdout.hasSuffix("\n") && output.stdout.dropLast().contains("\n") == false,
                 "one envelope, one line: \(output.stdout)")
    return try #require(try JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
}

// MARK: - parsing

@Suite struct InvocationTests {
    @Test func aVerbAProjectAndTheFlagAnywhere() {
        #expect(Invocation.parse(["--json", "steps", "a.soredemo"])
                == .success(Invocation(verb: .steps, project: "a.soredemo", json: true)))
        #expect(Invocation.parse(["steps", "a.soredemo"])
                == .success(Invocation(verb: .steps, project: "a.soredemo", json: false)))
    }

    @Test func helpIsTheVerbListing() {
        #expect(Invocation.parse(["--help"]) == .success(Invocation(verb: .verbs, project: nil, json: false)))
        #expect(Invocation.parse(["help"]) == .success(Invocation(verb: .verbs, project: nil, json: false)))
    }

    @Test func eachWayToCallItWronglyIsNamed() {
        #expect(Invocation.parse([]) == .failure(.noVerb))
        #expect(Invocation.parse(["stpes", "a"]) == .failure(.unknownVerb("stpes")))
        #expect(Invocation.parse(["steps", "a", "--verbose"]) == .failure(.unknownFlag("--verbose")))
        #expect(Invocation.parse(["steps"]) == .failure(.missingProject(.steps)))
        #expect(Invocation.parse(["steps", "a", "b"]) == .failure(.unexpectedArgument("b")))
        #expect(Invocation.parse(["verbs", "a"]) == .failure(.unexpectedArgument("a")))
    }

    /// A word for what no verb does is refused with the reason, so a caller stops looking.
    @Test func acceptingIsRefusedByNameAndSaysWhoAccepts() {
        #expect(Invocation.parse(["accept", "a"]) == .failure(.refusedVerb("accept")))
        #expect(Invocation.Problem.refusedVerb("accept").message.contains("by a person, in the editor"))
    }

    /// The registry's whole promise, held against its own list: no verb is spelled like a
    /// write, and every verb is a read or a proposal.
    @Test func noVerbAcceptsAppliesOrPublishes() {
        #expect(Verb.allCases.allSatisfy { !Verb.refused.contains($0.rawValue) })
        #expect(Set(Verb.allCases.map(\.kind)).isSubset(of: [.read, .propose]))
    }
}

// MARK: - the envelope and the exit status

@Suite struct SurfaceEnvelopeTests {
    @Test func aSuccessIsOneSortedLineWithTheSchemaVersion() async throws {
        let output = await run(["steps", "demo.soredemo", "--json"])
        #expect(output.exitCode == 0 && output.stderr.isEmpty)
        let envelope = try json(output)
        #expect(envelope["schemaVersion"] as? Int == 1)
        #expect(envelope["verb"] as? String == "steps")
        #expect(envelope["ok"] as? Bool == true)
        #expect(output.stdout.hasPrefix(#"{"ok":true,"result":"#), "keys sorted, so two runs are byte-comparable")
    }

    @Test func aCallMadeWronglyExits64AndStillAnswersInJSON() async throws {
        let output = await run(["accept", "demo.soredemo", "--json"])
        #expect(output.exitCode == 64)
        let envelope = try json(output)
        #expect(envelope["ok"] as? Bool == false)
        #expect((envelope["error"] as? [String: Any])?["code"] as? String == "usage")
        #expect(output.stderr.contains("in the editor"), "and a person watching reads why")
    }

    @Test func aProjectThatCannotBeOpenedExits66() async throws {
        let output = await run(["status", "missing.soredemo"], reader: FixtureReader(opens: false))
        #expect(output.exitCode == 66)
        #expect(output.stdout.isEmpty, "text mode prints nothing to stdout on failure")
        #expect(output.stderr.contains("no such package"))
    }

    @Test func aVerbThatNeedsTheLogExits65WithoutOne() async throws {
        let output = await run(["steps", "demo.soredemo", "--json"], reader: FixtureReader(hasLog: false))
        #expect(output.exitCode == 65)
        #expect((try json(output)["error"] as? [String: Any])?["code"] as? String == "noObservationLog")
    }
}

// MARK: - what the verbs answer

@Suite struct SurfaceVerbTests {
    @Test func stepsAreOnTheRecordingsOwnClock() async throws {
        let result = try #require(try json(await run(["steps", "demo.soredemo", "--json"]))["result"] as? [String: Any])
        let steps = try #require(result["steps"] as? [[String: Any]])
        #expect(steps.map { $0["label"] as? String } == ["Export", "Done"])
        let spans = steps.compactMap { $0["span"] as? [String: Int64] }
        #expect(spans == [["startNanos": 4 * second, "endNanos": 15 * second],
                          ["startNanos": 15 * second, "endNanos": 20 * second]])
    }

    @Test func eachClickSaysWhetherItWasFramedAndWhyNot() async throws {
        let result = try #require(try json(await run(["explain-framing", "demo.soredemo", "--json"]))["result"] as? [String: Any])
        let clicks = try #require(result["clicks"] as? [[String: Any]])
        #expect(clicks.map { $0["framed"] as? Bool } == [true, false])
        #expect(clicks.last?["refusedBecause"] as? String == "hitTestReturnedNothing")
        #expect(clicks.first?["atNanos"] as? Int64 == 4 * second)
    }

    /// The proposals are the editor's: the same three removals the Cuts tab lists, never applied.
    @Test func proposalsAreListedAndNothingIsApplied() async throws {
        let result = try #require(try json(await run(["propose-cut", "demo.soredemo", "--json"]))["result"] as? [String: Any])
        let rows = try #require(result["proposals"] as? [[String: Any]])
        #expect(rows.compactMap { $0["removes"] as? [String: Int64] } == [
            ["startNanos": 0, "endNanos": 3_500_000_000],
            ["startNanos": 4_500_000_000, "endNanos": 14_500_000_000],
            ["startNanos": 15_500_000_000, "endNanos": 20 * second]])
        #expect(result["applied"] as? Bool == false)
        #expect(result["hearing"] as? String == "nothing")
        #expect(rows[1]["openedBy"] as? [String: AnyHashable] == ["kind": "press", "step": 1])
    }

    @Test func aPauseSomeoneTalksThroughIsNotProposed() async throws {
        let hearing = FixedHearing(heard: .sound([6 * second..<8 * second]))
        let result = try #require(try json(await run(["propose-cut", "demo.soredemo", "--json"], hearing: hearing))["result"] as? [String: Any])
        let removes = (result["proposals"] as? [[String: Any]])?.compactMap { $0["removes"] as? [String: Int64] }
        #expect(removes == [["startNanos": 0, "endNanos": 3_500_000_000],
                            ["startNanos": 4_500_000_000, "endNanos": 5_500_000_000],
                            ["startNanos": 8_500_000_000, "endNanos": 14_500_000_000],
                            ["startNanos": 15_500_000_000, "endNanos": 20 * second]],
                "the talking from 6 s to 8 s splits the middle pause in two")
        #expect(result["hearing"] as? String == "sound")
    }

    /// A person's "no", saved in the project, holds in the terminal too.
    @Test func aKeptPauseIsNotProposedAgain() async throws {
        let key = CutProposal.Key(reason: .deadAir, quietStart: at(104))
        let result = try #require(try json(await run(["propose-cut", "demo.soredemo", "--json"],
                                                     reader: FixtureReader(dismissed: [key])))["result"] as? [String: Any])
        #expect((result["proposals"] as? [[String: Any]])?.count == 2)
        #expect(result["dismissed"] as? Int == 1)
    }

    @Test func statusCountsWhatTheOtherVerbsList() async throws {
        let result = try #require(try json(await run(["status", "demo.soredemo", "--json"]))["result"] as? [String: Any])
        #expect(result["steps"] as? Int == 2)
        #expect(result["clicks"] as? Int == 2 && result["framedClicks"] as? Int == 1)
        #expect(result["durationNanos"] as? Int64 == 20 * second)
        #expect(result["durationFrom"] as? String == "observationLogTrailer", "says which length it used")
        #expect((result["proposals"] as? [String: Int])?["pending"] == 3)
    }

    @Test func statusWithoutALogSaysSoRatherThanZero() async throws {
        let result = try #require(try json(await run(["status", "demo.soredemo", "--json"],
                                                     reader: FixtureReader(hasLog: false)))["result"] as? [String: Any])
        #expect(result["steps"] == nil, "absent, not 0: nobody counted")
        #expect(result["observationLog"] == nil)
    }

    @Test func theListingNamesEveryVerbAndSaysNoneAccepts() async throws {
        let result = try #require(try json(await run(["verbs", "--json"]))["result"] as? [String: Any])
        #expect((result["verbs"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
                == Verb.allCases.map(\.rawValue))
        #expect((result["note"] as? String)?.contains("None accepts") == true)
    }

    @Test func secondsAreRoundedToATenthWithoutFloatingPointFormatting() {
        #expect(Text.seconds(9_250_000_000) == "9.3s")
        #expect(Text.seconds(40_000_000) == "0.0s")
        #expect(Text.seconds(20 * second) == "20.0s")
    }
}

// MARK: - MCP over stdio

private let server = MCPServer(reader: FixtureReader(), hearing: deaf, version: "0.1.0")

/// One request through the server, its reply decoded.
private func send(_ request: [String: Any], to server: MCPServer = server) async throws -> [String: Any] {
    let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
    let reply = try #require(await server.handle(line), "a request with an id is always answered")
    #expect(!reply.contains("\n"), "stdio frames by newline, so a reply must not contain one")
    return try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
}

private func call(_ tool: String, _ arguments: [String: Any], server: MCPServer = server) async throws -> [String: Any] {
    try #require(try await send(["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                 "params": ["name": tool, "arguments": arguments]], to: server)["result"] as? [String: Any])
}

@Suite struct MCPServerTests {
    @Test func aSupportedVersionIsAgreedAndAnUnknownOneGetsTheNewest() async throws {
        let agreed = try #require(try await send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                  "params": ["protocolVersion": "2025-06-18"]])["result"] as? [String: Any])
        #expect(agreed["protocolVersion"] as? String == "2025-06-18")
        let other = try #require(try await send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                 "params": ["protocolVersion": "1999-01-01"]])["result"] as? [String: Any])
        #expect(other["protocolVersion"] as? String == MCPServer.protocolVersions[0])
        #expect((other["serverInfo"] as? [String: Any])?["name"] as? String == "soredemo")
        #expect((other["instructions"] as? String)?.contains("by a person in Soredemo's editor") == true)
        #expect((other["capabilities"] as? [String: Any])?["tools"] != nil)
    }

    @Test func aNotificationIsNeverAnswered() async {
        #expect(await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test func aStringIdIsEchoedAsAString() async throws {
        let reply = try await send(["jsonrpc": "2.0", "id": "abc", "method": "ping"])
        #expect(reply["id"] as? String == "abc")
        #expect((reply["result"] as? [String: Any])?.isEmpty == true)
    }

    /// Every verb that takes a project is a tool, and every tool says it reads and changes nothing.
    @Test func theToolsAreTheRegistrysVerbsAndAllAreReadOnly() async throws {
        let result = try #require(try await send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["status", "steps", "explain_framing", "propose_cut"])
        for tool in tools {
            let hints = try #require(tool["annotations"] as? [String: Bool])
            #expect(hints == ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false])
            #expect((tool["inputSchema"] as? [String: Any])?["required"] as? [String] == ["project"])
        }
    }

    @Test func aCallReturnsTheVerbsAnswerAsStructuredContentAndAsText() async throws {
        let result = try await call("steps", ["project": "demo.soredemo"])
        #expect(result["isError"] as? Bool == false)
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect((structured["steps"] as? [[String: Any]])?.compactMap { $0["label"] as? String } == ["Export", "Done"])
        let text = try #require(((result["content"] as? [[String: Any]])?.first)?["text"] as? String)
        let fromText = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(NSDictionary(dictionary: fromText).isEqual(to: structured), "the text is the same JSON")
    }

    /// The same function as the terminal, so the same answer.
    @Test func aToolAndTheTerminalAgree() async throws {
        let structured = try #require(try await call("propose_cut", ["project": "demo.soredemo"])["structuredContent"] as? [String: Any])
        let terminal = try #require(try json(await run(["propose-cut", "demo.soredemo", "--json"]))["result"] as? [String: Any])
        #expect(NSDictionary(dictionary: structured).isEqual(to: terminal))
    }

    /// Input validation is the model's to fix, so it comes back as a tool error it can read.
    @Test func aMissingOrExtraArgumentIsAToolErrorTheModelCanRead() async throws {
        #expect(try await call("steps", [:])["isError"] as? Bool == true)
        let extra = try await call("steps", ["project": "demo.soredemo", "apply": true])
        #expect(extra["isError"] as? Bool == true)
        #expect((((extra["content"] as? [[String: Any]])?.first)?["text"] as? String)?.contains("`apply`") == true)
    }

    @Test func aVerbThatFailsSaysWhyAsAToolError() async throws {
        let noLog = MCPServer(reader: FixtureReader(hasLog: false), hearing: deaf, version: "0.1.0")
        let result = try await call("steps", ["project": "demo.soredemo"], server: noLog)
        #expect(result["isError"] as? Bool == true)
        #expect(((result["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String
                == "noObservationLog")
    }

    @Test func aToolThatWouldWriteIsRefusedByNameAsAProtocolError() async throws {
        let reply = try await send(["jsonrpc": "2.0", "id": 9, "method": "tools/call",
                                    "params": ["name": "accept_cut", "arguments": ["project": "x"]]])
        let error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32602)
        #expect((error["message"] as? String)?.contains("only by the agent in Soredemo's own panel, where a person is watching") == true)
        // And a publish is refused as one, whatever is being watched.
        let publish = try await send(["jsonrpc": "2.0", "id": 10, "method": "tools/call",
                                      "params": ["name": "publish_post", "arguments": [:] as [String: Any]]])
        #expect(((publish["error"] as? [String: Any])?["message"] as? String)?.contains("Nothing publishes") == true)
    }

    @Test func malformedInputAndUnknownMethodsGetTheirJSONRPCCodes() async throws {
        let parse = try #require(await server.handle("{not json"))
        #expect(parse.contains(#""code":-32700"#) && parse.contains(#""id":null"#))
        let unknown = try await send(["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
    }
}
