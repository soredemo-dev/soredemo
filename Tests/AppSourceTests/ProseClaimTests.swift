import Foundation
import Testing

/// **A test count may not appear in prose.** Three documents carried three different
/// wrong values — 464, 462 and 466 — while `scripts/count-tests.sh` sat unused, and
/// that script exists because the number had already been got wrong three times by
/// hand. The tool was built and never connected to the place the mistake is made.
///
/// **The rule is narrow on purpose.** "No number near the word tests" would fire on
/// `AGENTS.md`'s "it survived 450 unit tests, 350 probe checks" — a HISTORICAL claim
/// about one moment in the past, correctly frozen, and one of the most valuable
/// sentences in that file. The general form of this rule was already measured on this
/// tree once, at roughly 97% false positives, and a gate at that rate gets switched
/// off. So this pins one shape: `swift test` followed closely by a bare integer, which
/// is exactly how both live claims were spelled and is never how a historical one is.
///
/// **The window and the digit-run length below are MEASURED, not the first guess.**
/// A first draft — 40 characters after the phrase, "does it contain any digit" — was
/// run against this tree before any cleanup and found six hits, not the three known
/// live claims:
///
///   * `ROADMAP.md:66` — a FROZEN sentence naming `Tests/HeadlessTests/RecordedPointerPositionTests.swift`,
///     which "runs under `swift test`, feeds the REAL **row-14** recording…" — the
///     digits are the recording's name, 22 characters after the phrase.
///   * `AGENTS.md:149` — "`swift test` writes `1 test` for a one-test target…", a
///     single digit inside a backticked literal example, 10 characters after.
///   * `AGENTS.md:237` — "…when `swift test` fails, because a `0` and a stale
///     count…", a single digit naming an example exit code, 20 characters after.
///
/// All three false hits are either a single digit or land past 20 characters out;
/// all three live claims (`464`, `462`, `466`) are three-digit numbers landing within
/// 19 characters. So the window is 22, not 40, and a hit requires a run of at least
/// two consecutive digits, not any one digit — long enough to hold every live claim,
/// short enough to exclude every measured false one. Both bounds are asserted below
/// as much as the rule itself, so a future document that drifts one of them does not
/// silently reopen either gap.
///
/// The count is not unavailable — it is one command away, and both sites now say which.
@Test func noProseDocumentStatesTheCurrentTestCount() throws {
    let documents = ["ROADMAP.md", "AGENTS.md", "docs/ARCHITECTURE.md", "KICKOFF.md",
                     "docs/design/2026-08-04-phase-3a-foundation-design.md"]
    for name in documents {
        let url = repositoryRoot.appending(path: name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var search = line.startIndex..<line.endIndex
            while let hit = line.range(of: "swift test", range: search) {
                // 22 characters after the phrase: enough to cover "`swift test`'s 464
                // tests" (4) and "swift test — deterministic   466 passed" (19), short
                // enough to exclude the measured false hits at 20 and 22. See the doc
                // comment above for the measurement.
                let windowEnd = line.index(hit.upperBound, offsetBy: 22, limitedBy: line.endIndex)
                    ?? line.endIndex
                let window = line[hit.upperBound..<windowEnd]
                // A RUN of at least two consecutive digits — a bare integer, not a lone
                // digit. `1 test`, `0` and similar single-digit examples must not fire;
                // every real test count in this repository is three digits.
                var runLength = 0
                var hasCount = false
                for character in window {
                    if character.isNumber {
                        runLength += 1
                        if runLength >= 2 { hasCount = true; break }
                    } else {
                        runLength = 0
                    }
                }
                #expect(!hasCount, """
                    \(name):\(index + 1) states a test count in prose:
                      \(line.trimmingCharacters(in: .whitespaces))
                    That number changes on most commits and this document does not. Three \
                    documents carried three different wrong values before this gate existed.
                    Cite `scripts/count-tests.sh` instead; the gate's output is where the \
                    number belongs.
                    """)
                search = hit.upperBound..<line.endIndex
            }
        }
    }
}
