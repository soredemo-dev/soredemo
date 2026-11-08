import Foundation
import Testing
@testable import Surface

// Claude Code's stream-json, read from a RECORDED session: Claude Code 2.1.318 asked to call
// Soredemo's `steps` tool on a fixture project, 2026-11-08, personal paths replaced and the
// owner's own hook lines removed. Every expected value below is read from that file.

private func fixture() throws -> [String] {
    let url = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "Fixtures/claude-code-2.1.318-steps.jsonl")
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    try #require(lines.count > 10, "the recorded session read as \(lines.count) lines — the fixture is missing")
    return lines
}

private func allEvents() throws -> [AgentEvent] {
    try fixture().flatMap(ClaudeStream.events(from:))
}

@Suite struct AgentStreamTests {
    @Test func theSessionStartsWithItsIdItsToolsAndItsModel() throws {
        guard case .started(let session, let tools, let model) = try #require(try allEvents().first) else {
            Issue.record("the first event is not the session's start")
            return
        }
        #expect(session == "e39db8d7-ecfc-4c74-861c-de80404c10a3")
        #expect(tools == ["mcp__soredemo__explain_framing", "mcp__soredemo__propose_cut",
                          "mcp__soredemo__status", "mcp__soredemo__steps"],
                "with --tools \"\" the session holds Soredemo's tools and nothing else")
        #expect(model == "claude-opus-5-5")
    }

    @Test func aToolCallArrivesStartedThenWholeThenFinished() throws {
        let events = try allEvents()
        let id = "toolu_01USe6N7p7wuWbQ52YkhArFi"
        let started = events.firstIndex(of: .toolStarted(id: id, name: "mcp__soredemo__steps"))
        let called = events.firstIndex { if case .toolCalled(id, "mcp__soredemo__steps", let input) = $0 {
            return input == #"{"project":"/tmp/demo.soredemo"}"# }; return false }
        let finished = events.firstIndex { if case .toolFinished(id, false, let output) = $0 {
            return output.hasPrefix(#"{"steps":[{"application":"Keynote","label":"Export""#) }; return false }
        let (s, c, f) = (try #require(started), try #require(called), try #require(finished))
        #expect(s < c && c < f, "started, then whole, then its result")
    }

    /// The deltas build exactly the text the finished block then states.
    @Test func textDeltasAddUpToTheFinishedText() throws {
        let events = try allEvents()
        let streamed = events.compactMap { if case .textDelta(let t) = $0 { return t }; return nil }.joined()
        let finished = events.compactMap { if case .text(let t) = $0 { return t }; return nil }
        #expect(finished == [#"The project has 2 steps: pressing "Export" in Keynote, then pressing "Done"."#])
        #expect(streamed == finished.first)
    }

    @Test func theTurnEndsWithItsDurationItsSessionAndAnAPIPriceEstimate() throws {
        guard case .finished(let isError, let duration, let cost, let session) = try #require(try allEvents().last) else {
            Issue.record("the last event is not the turn's end")
            return
        }
        #expect(!isError)
        #expect(duration == 5035)
        #expect(cost.map { abs($0 - 0.0391446) < 0.0000001 } == true)
        #expect(session == "e39db8d7-ecfc-4c74-861c-de80404c10a3", "the id the next turn resumes")
    }

    /// The format grows; a line not understood is skipped, never fatal.
    @Test func aLineNotUnderstoodYieldsNothing() {
        #expect(ClaudeStream.events(from: #"{"type":"rate_limit_event","whatever":1}"#).isEmpty)
        #expect(ClaudeStream.events(from: "not json").isEmpty)
        #expect(ClaudeStream.events(from: #"{"type":"system","subtype":"hook_started"}"#).isEmpty)
    }

    @Test func aToolResultThatFailedSaysSo() {
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":[{"type":"text","text":"no log"}]}]}}"#
        #expect(ClaudeStream.events(from: line) == [.toolFinished(id: "t1", isError: true, output: "no log")])
    }

    @Test func aToolsNameIsShownWithoutItsServerPrefix() {
        #expect(ClaudeStream.shortName("mcp__soredemo__propose_cut") == "propose_cut")
        #expect(ClaudeStream.shortName("Bash") == "Bash", "a name without the prefix is left alone")
    }

    /// Reasoning, when the model thinks. **Not in the recorded session** — the run that made the
    /// fixture did not think — so these lines are written to the Messages API's documented shape:
    /// a `thinking` content block, `thinking_delta` deltas. Labelled as written, not recorded.
    @Test func reasoningArrivesAsThinkingDeltasThenAWholeBlock() {
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Step 4 is idle"}}}"#
        let whole = #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"Step 4 is idle for 9 s.","signature":"x"},{"type":"text","text":"Done."}]}}"#
        #expect(ClaudeStream.events(from: delta) == [.thinkingDelta("Step 4 is idle")])
        #expect(ClaudeStream.events(from: whole) == [.thinking("Step 4 is idle for 9 s."), .text("Done.")])
    }
}
