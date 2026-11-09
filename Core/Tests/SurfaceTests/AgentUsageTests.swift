import Foundation
import Testing
@testable import Surface

// How full the conversation is and how much of the account's windows are used, from both agents.
// **Written to the shape of recorded lines, with invented numbers**: Claude Code 2.1.318's
// `rate_limit_event`, `assistant.message.usage` and `result.modelUsage`, and Codex 0.167.0's
// `thread/tokenUsage/updated` and `account/rateLimits/updated`, each recorded 2026-11-09. The
// person's own usage is not committed.

@Suite struct ClaudeUsageTests {
    /// What fills the window is everything the request read: input, cache written, cache read.
    @Test func aResponsesContextIsEverythingItReadAndNotWhatItWrote() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":7,"cache_creation_input_tokens":2300,"cache_read_input_tokens":640,"output_tokens":4000}}}"#
        #expect(ClaudeStream.events(from: line) == [.contextUsage(usedTokens: 2947, windowTokens: nil), .text("ok")])
    }

    /// The window comes with the turn's end, for the model that did the work.
    @Test func theWindowIsTheMainModelsWithTheTurnsEnd() {
        let line = #"{"type":"result","is_error":false,"duration_ms":900,"session_id":"s","modelUsage":{"claude-haiku-4-5":{"inputTokens":10,"cacheReadInputTokens":0,"contextWindow":200000},"claude-opus-5-5":{"inputTokens":2,"cacheReadInputTokens":649,"cacheCreationInputTokens":2326,"contextWindow":1000000}}}"#
        #expect(ClaudeStream.events(from: line) == [.contextUsage(usedTokens: nil, windowTokens: 1_000_000),
                                                     .finished(isError: false, durationMilliseconds: 900, costUSD: nil, session: "s")])
    }

    /// Both windows the event carries, as a percentage, with when each resets.
    @Test func theAccountsWindowsAreReadAsPercentagesWithTheirResets() {
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1700600000,"rateLimitType":"seven_day","utilization":0.9,"unifiedWindows":{"five_hour":{"utilization":0.25,"resetsAt":1700000000,"status":"allowed"},"seven_day":{"utilization":0.9,"resetsAt":1700600000,"status":"allowed_warning","surpassedThreshold":0.75}}}}"#
        #expect(ClaudeStream.events(from: line) == [.limits([
            UsageWindow(minutes: 300, usedPercent: 25, resets: Date(timeIntervalSince1970: 1_700_000_000), limited: false),
            UsageWindow(minutes: 10080, usedPercent: 90, resets: Date(timeIntervalSince1970: 1_700_600_000), limited: false),
        ])])
    }

    @Test func aRefusedWindowIsMarkedLimited() {
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":1700000000,"status":"rejected"}}}}"#
        #expect(ClaudeStream.events(from: line) == [.limits([
            UsageWindow(minutes: 300, usedPercent: 100, resets: Date(timeIntervalSince1970: 1_700_000_000), limited: true)])])
    }

    /// An event naming only the window it warns about still says that one.
    @Test func anEventWithoutTheWindowListReadsItsOneWindow() {
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1700000000,"rateLimitType":"five_hour","utilization":0.5}}"#
        #expect(ClaudeStream.events(from: line) == [.limits([
            UsageWindow(minutes: 300, usedPercent: 50, resets: Date(timeIntervalSince1970: 1_700_000_000), limited: false)])])
    }

    /// No measurement is no measurement — never a 0 % that reads like room to spare.
    @Test func aWindowWithNoUtilizationIsLeftOutNotZero() {
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"resetsAt":1700000000,"status":"allowed"}}}}"#
        #expect(ClaudeStream.events(from: line).isEmpty)
        let nothingRead = #"{"type":"assistant","message":{"content":[],"usage":{"input_tokens":0,"output_tokens":3}}}"#
        #expect(ClaudeStream.events(from: nothingRead).isEmpty)
    }
}

@Suite struct CodexUsageTests {
    private let thread = "01a1bee4-dc66-7102-9a47-1e13366164b2"

    private func running() throws -> CodexSession {
        var codex = CodexSession(tools: [], instructions: "", workingDirectory: "/tmp/soredemo-agent")
        _ = codex.begin(message: "m", model: nil)
        _ = codex.receive(#"{"id":1,"result":{}}"#)
        _ = codex.receive(#"{"id":2,"result":{"thread":{"id":"\#(thread)"},"approvalPolicy":"untrusted","sandbox":{"type":"readOnly"}}}"#)
        _ = codex.receive(#"{"id":3,"result":{"turn":{"id":"t"}}}"#)
        return codex
    }

    /// The last request's total is the context now; the running total is the thread's spend.
    @Test func theContextIsTheLastRequestAgainstTheModelsWindow() throws {
        var codex = try running()
        let line = #"{"method":"thread/tokenUsage/updated","params":{"threadId":"\#(thread)","turnId":"t","tokenUsage":{"total":{"totalTokens":90000},"last":{"totalTokens":12000},"modelContextWindow":400000}}}"#
        #expect(codex.receive(line) == [.event(.contextUsage(usedTokens: 12000, windowTokens: 400_000))])
    }

    @Test func theAccountsWindowsAreReadWithTheirLengthAndReset() throws {
        var codex = try running()
        let line = #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1700000000},"secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1700600000},"rateLimitReachedType":null}}}"#
        #expect(codex.receive(line) == [.event(.limits([
            UsageWindow(minutes: 300, usedPercent: 40, resets: Date(timeIntervalSince1970: 1_700_000_000), limited: false),
            UsageWindow(minutes: 10080, usedPercent: 12, resets: Date(timeIntervalSince1970: 1_700_600_000), limited: false),
        ]))])
    }

    /// The reached type names no window (schema: `rate_limit_reached`, credits depleted…), so
    /// the full window is the limited one.
    @Test func aReachedLimitMarksTheFullWindow() throws {
        var codex = try running()
        let line = #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1700000000},"secondary":{"usedPercent":60,"windowDurationMins":10080,"resetsAt":1700600000},"rateLimitReachedType":"rate_limit_reached"}}}"#
        #expect(codex.receive(line) == [.event(.limits([
            UsageWindow(minutes: 300, usedPercent: 100, resets: Date(timeIntervalSince1970: 1_700_000_000), limited: true),
            UsageWindow(minutes: 10080, usedPercent: 60, resets: Date(timeIntervalSince1970: 1_700_600_000), limited: false)]))])
    }

    /// Refused with no window full — a workspace's credits used up — refuses the whole account.
    @Test func aRefusalWithNoFullWindowMarksEveryWindow() throws {
        var codex = try running()
        let line = #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1700000000},"rateLimitReachedType":"workspace_member_credits_depleted"}}}"#
        #expect(codex.receive(line) == [.event(.limits([
            UsageWindow(minutes: 300, usedPercent: 20, resets: Date(timeIntervalSince1970: 1_700_000_000), limited: true)]))])
    }

    /// Read when a turn begins, so a turn refused at once still shows the windows that refused it.
    @Test func theWindowsAreReadWhenATurnBeginsAndARefusalMarksThemAll() throws {
        var codex = CodexSession(tools: [], instructions: "", workingDirectory: "/tmp/soredemo-agent")
        _ = codex.begin(message: "m", model: nil)
        _ = codex.receive(#"{"id":1,"result":{}}"#)
        let started = codex.receive(#"{"id":2,"result":{"thread":{"id":"\#(thread)"},"approvalPolicy":"untrusted","sandbox":{"type":"readOnly"}}}"#)
        let read = started.compactMap { output -> Int? in
            guard case .send(let text) = output,
                  let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  message["method"] as? String == "account/rateLimits/read" else { return nil }
            return message["id"] as? Int
        }
        let id = try #require(read.first, "the windows are asked for with the turn")
        // `ordinaryUsageAllowed: false` is the account refused, whatever the percentages say.
        let reply = #"{"id":\#(id),"result":{"ordinaryUsageAllowed":false,"rateLimits":{"primary":{"usedPercent":97,"windowDurationMins":300,"resetsAt":1700000000},"rateLimitReachedType":null}}}"#
        #expect(codex.receive(reply) == [.event(.limits([
            UsageWindow(minutes: 300, usedPercent: 97, resets: Date(timeIntervalSince1970: 1_700_000_000), limited: true)]))])
    }

    @Test func aZeroOrMissingCountIsNoReading() throws {
        var codex = try running()
        let empty = #"{"method":"thread/tokenUsage/updated","params":{"threadId":"\#(thread)","tokenUsage":{"last":{"totalTokens":0},"modelContextWindow":400000}}}"#
        #expect(codex.receive(empty).isEmpty)
        let noWindow = #"{"method":"thread/tokenUsage/updated","params":{"threadId":"\#(thread)","tokenUsage":{"last":{"totalTokens":500}}}}"#
        #expect(codex.receive(noWindow) == [.event(.contextUsage(usedTokens: 500, windowTokens: nil))])
    }
}
