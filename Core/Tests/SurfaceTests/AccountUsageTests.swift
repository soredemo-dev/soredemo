import Foundation
import Testing
@testable import Surface

// The plan's usage read with the panel's own agent's sign-in
// (`docs/design/2026-11-13-the-plan-usage-before-a-message.md`). Every input here is a literal;
// the Codex answer is the shape measured on 2026-11-13, its strings replaced.

@Suite struct AccountUsageTests {
    @Test func theSignInsAreReadFromWhereEachToolKeepsThem() {
        #expect(AccountUsage.claudeToken(fromKeychain: Data(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1}}"#.utf8)) == "tok")
        #expect(AccountUsage.claudeToken(fromKeychain: Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)) == nil)
        #expect(AccountUsage.claudeToken(fromKeychain: Data("not json".utf8)) == nil)
        let codex = AccountUsage.codexSignIn(fromAuthFile: Data(#"{"tokens":{"access_token":"t","account_id":"a"}}"#.utf8))
        #expect(codex?.token == "t" && codex?.accountID == "a")
        #expect(AccountUsage.codexSignIn(fromAuthFile: Data(#"{"OPENAI_API_KEY":"k"}"#.utf8)) == nil,
                "an API key is not a plan, and has no plan usage")
    }

    /// Codex's measured answer: percent 0–100, the window's length in seconds, reset in Unix seconds.
    @Test func codexsAnswerIsReadAsMeasured() throws {
        let answer = Data(#"{"rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":0,"limit_window_seconds":18000,"reset_at":1794519170},"secondary_window":{"used_percent":14,"limit_window_seconds":604800,"reset_at":1795055331}}}"#.utf8)
        let windows = try #require(AccountUsage.codexWindows(fromAnswer: answer))
        #expect(windows.map(\.minutes) == [300, 10080])
        #expect(windows.map(\.usedPercent) == [0, 14])
        #expect(windows[1].resets == Date(timeIntervalSince1970: 1795055331))
        #expect(!windows[1].limited)
        let reached = Data(#"{"rate_limit":{"limit_reached":true,"primary_window":{"used_percent":100,"limit_window_seconds":18000}}}"#.utf8)
        #expect(AccountUsage.codexWindows(fromAnswer: reached)?.first?.limited == true)
        let changed = Data(#"{"rate_limit":{"primary_window":{"used_percent":140,"limit_window_seconds":18000}}}"#.utf8)
        #expect(AccountUsage.codexWindows(fromAnswer: changed) == nil, "a format that changed reads as unreadable, not as 140 %")
    }

    /// Claude's answer is not measured (D6b-36): both names are read, and a value of at most 1 is a
    /// fraction as the stream's is. A reading outside 0–100 is refused, so a changed format shows as
    /// unreadable rather than as a wrong number.
    @Test func claudesAnswerIsReadEitherWayAndRefusedOutOfRange() throws {
        let fraction = Data(#"{"five_hour":{"utilization":0.25,"resets_at":"2026-11-13T05:00:00Z"},"seven_day":{"utilization":0.5}}"#.utf8)
        let windows = try #require(AccountUsage.claudeWindows(fromAnswer: fraction))
        #expect(windows.map(\.minutes) == [300, 10080])
        #expect(windows.map(\.usedPercent) == [25, 50])
        #expect(windows[0].resets == ISO8601DateFormatter().date(from: "2026-11-13T05:00:00Z"))
        let percent = Data(#"{"five_hour":{"used_percentage":40},"seven_day":{"utilization":72}}"#.utf8)
        #expect(AccountUsage.claudeWindows(fromAnswer: percent)?.map(\.usedPercent) == [40, 72])
        #expect(AccountUsage.claudeWindows(fromAnswer: Data(#"{"five_hour":{"utilization":250}}"#.utf8)) == nil)
        #expect(AccountUsage.claudeWindows(fromAnswer: Data("{}".utf8)) == nil, "nothing in it is not zero")
    }

    /// When to ask, as a function of the times involved — no clock in here.
    @Test func itAsksOnlyWhenOpenAndNotTooOften() {
        let minute: Int64 = 60_000_000_000
        var state = UsageRefresh()
        #expect(state.shouldAsk(now: 0, panelOpen: false) == false, "nobody is looking")
        #expect(state.shouldAsk(now: 0, panelOpen: true), "the panel just opened, and nothing has been read")
        state.answered(at: 0)
        #expect(!state.shouldAsk(now: 4 * minute, panelOpen: true), "under five minutes since an answer")
        #expect(!state.shouldAsk(now: 14 * minute, panelOpen: true), "under fifteen minutes since an answer")
        #expect(state.shouldAsk(now: 15 * minute, panelOpen: true))
        state.failed(at: 15 * minute)
        #expect(!state.shouldAsk(now: 15 * minute + minute / 4, panelOpen: true), "a failure waits thirty seconds")
        #expect(state.shouldAsk(now: 15 * minute + minute / 2, panelOpen: true))
        state.failed(at: 16 * minute)
        #expect(!state.shouldAsk(now: 16 * minute + minute / 2, panelOpen: true), "the second failure waits a minute")
        #expect(state.shouldAsk(now: 17 * minute, panelOpen: true))
        state.refused(at: 20 * minute, retryAfterSeconds: 600)
        #expect(!state.shouldAsk(now: 29 * minute, panelOpen: true), "a 429 waits for its Retry-After")
        #expect(state.shouldAsk(now: 30 * minute, panelOpen: true))
        state.answered(at: 31 * minute)
        state.failed(at: 50 * minute)
        #expect(state.shouldAsk(now: 50 * minute + minute / 2, panelOpen: true), "an answer resets the backoff")
    }

    /// A reading older than thirty minutes says so.
    @Test func aReadingOlderThanThirtyMinutesIsStale() {
        let minute: Int64 = 60_000_000_000
        var state = UsageRefresh()
        state.answered(at: 0)
        #expect(!state.isStale(now: 29 * minute))
        #expect(state.isStale(now: 31 * minute))
        #expect(UsageRefresh().isStale(now: 0) == false, "nothing read is not stale, it is absent")
    }
}
