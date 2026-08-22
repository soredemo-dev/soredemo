import Foundation
import Testing

/// **A test count may not appear in prose.** Three documents carried three different wrong
/// values while `scripts/count-tests.sh` sat unused. The rule pins one shape — `swift test`
/// followed closely by a bare integer — because the general form measured ~97% false positives.
@Test func noProseDocumentStatesTheCurrentTestCount() throws {
    let documents = ["ROADMAP.md", "AGENTS.md", "docs/ARCHITECTURE.md",
                     "docs/design/2026-08-04-phase-3a-foundation-design.md"]
    // An unreadable document is a FAILURE, not a skip: one of the five paths is date-stamped,
    // so a rename would silently drop a document this gate exists to catch.
    var examined = 0
    for name in documents {
        let url = repositoryRoot.appending(path: name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("""
                \(name) could not be read as UTF-8 at \(url.path(percentEncoded: false)) — \
                treated as a failure, not a skip: a renamed or moved document must not \
                silently drop out of this gate's coverage.
                """)
            continue
        }
        examined += 1
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var search = line.startIndex..<line.endIndex
            while let hit = line.range(of: "swift test", range: search) {
                // 22 characters after the phrase: long enough to hold every live claim (the
                // furthest lands at 19), short enough to exclude the false hits at 20 and 22.
                let windowEnd = line.index(hit.upperBound, offsetBy: 22, limitedBy: line.endIndex)
                    ?? line.endIndex
                let window = line[hit.upperBound..<windowEnd]
                // A RUN of at least two consecutive digits, not a lone digit: single-digit
                // examples (`1 test`, `0`) must not fire, and every real count is three digits.
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
    #expect(examined == documents.count, """
        only \(examined) of \(documents.count) documents were examined — the rest could not \
        be read (see the recorded issue above naming which). "No prose document states the \
        current test count" is not established over a document this gate never opened.
        """)
}
