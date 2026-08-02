import Testing
import Foundation
import CheckerLexer

/// `VerificationStep.given(_:)` records the setup a run happened under, and
/// **nothing asserts it**. That makes it the one place in the harness where a
/// step could park something it measured and did not want to check — and the
/// abuse would pass, and print, and look exactly like the rows beside it.
///
/// **The rule is positional, deliberately, and not a whitelist of labels.** A
/// permitted-name list is an open set: every genuinely new source of
/// provenance is a good reason to widen it, and after enough good reasons it
/// permits everything. That is `AGENTS.md`'s "a hand-written list rots by
/// omission" one scope over. Position cannot be widened by argument.
///
/// **The boundary is the step's own `expect` call.** Configuration is known
/// before a run; a measured result does not exist until after it. `expect`
/// declares what the run must produce and is by construction written before
/// the run — so anything a step wants to state after `expect` is a result, and
/// a result belongs in an assertion.
///
/// **Why this is a scan and not a ledger entry.** The criterion is whether a
/// violation announces itself. This one does not: it passes and prints. Waiting
/// for the first abuse is waiting for someone to happen to look — and this
/// project has already measured what that costs. Spike B's step 2 kept its four
/// assertions inside a `print` block the harness could not read; the step
/// passed, and what eventually found it was a migration, not the guard.
enum GivenPosition {

    /// A `given` that sits at or after its step's first `expect`.
    struct Violation: Equatable {
        let function: String
        let givenLine: Int
        let expectLine: Int
    }

    /// Pure, so this rule's own regression case is executable rather than
    /// described — the same reason `VerificationStep.verdict` is pure.
    ///
    /// `lines` is a code view: comments and string contents already blanked, so
    /// prose mentioning `given(` cannot trip it.
    static func violations(in lines: [String], file: String) -> [Violation] {
        var currentFunction = "(top level)"
        var expectLineOf: [String: Int] = [:]
        var givens: [(function: String, line: Int)] = []

        for (index, line) in lines.enumerated() {
            let number = index + 1
            if let name = functionName(in: line) { currentFunction = name }
            if line.contains(".given(") { givens.append((currentFunction, number)) }
            if line.contains(".expect(") && expectLineOf[currentFunction] == nil {
                expectLineOf[currentFunction] = number
            }
        }

        return givens.compactMap { given in
            // A `given` in a step that never calls `expect` is not a violation
            // of THIS rule — the guard's own undischarged-expectation check is
            // what covers a step that declares nothing, and two rules reporting
            // one fault reads as two faults.
            guard let expectLine = expectLineOf[given.function], given.line >= expectLine else {
                return nil
            }
            return Violation(function: "\(file):\(given.function)",
                             givenLine: given.line, expectLine: expectLine)
        }
    }

    private static func functionName(in line: String) -> String? {
        guard let range = line.range(of: "func ") else { return nil }
        let rest = line[range.upperBound...]
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }
}

/// Every `.swift` file under `spikes/`, including the shared harness.
///
/// Empty is a FAILURE, not a vacuous pass — the same reason `appSourceFiles()`
/// requires a non-empty result.
func spikeSourceFiles() throws -> [URL] {
    let directory = repositoryRoot.appending(path: "spikes")
    let enumerator = try #require(
        FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil),
        "cannot enumerate \(directory.path(percentEncoded: false))")
    var files: [URL] = []
    while let url = enumerator.nextObject() as? URL {
        if url.pathExtension == "swift" { files.append(url) }
    }
    try #require(!files.isEmpty,
                 "no spike sources found at \(directory.path(percentEncoded: false)) — this scan would pass vacuously")
    return files.sorted { $0.path < $1.path }
}

@Test func theGivenBlockCannotHoldAMeasuredResult() throws {
    let files = try spikeSourceFiles()
    var violations: [GivenPosition.Violation] = []
    var givensSeen = 0

    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = SwiftSourceLexer.codeViewLines(of: text)
        givensSeen += lines.filter { $0.contains(".given(") }.count
        violations += GivenPosition.violations(in: lines, file: file.lastPathComponent)
    }

    // Without this the scan passes on a repository that has stopped using
    // `given` at all, or on one where the call spelling changed — the vacuous
    // pass this project guards against everywhere else.
    #expect(givensSeen > 0,
            "no `given(` call was found in any spike source, so this scan asserted nothing")

    #expect(violations.isEmpty,
            """
            a `given` row appears at or after its step's `expect`:
            \(violations.map { "  \($0.function): given at line \($0.givenLine), expect at line \($0.expectLine)" }
                .joined(separator: "\n"))
            `given` records the setup a run happened under and nothing asserts it. After `expect`, \
            the value is a RESULT, and a result that a step does not want to check is the one \
            thing this block must not be able to hold.
            """)
}

/// The rule's own regression case.
///
/// **There is no historical violation to replay, and that is stated rather
/// than left to be inferred.** The `given` block is two days old and the
/// migration that created it placed every row before its `expect`. So the
/// fixture below is synthetic — written to be the abuse, not found being it.
/// A guard whose failure case exists only in prose is the shape this project
/// has recorded ten times; a synthetic case is weaker than a historical one
/// and much stronger than none.
@Test func theGivenPositionRuleCatchesAMeasuredResultParkedAsSetup() {
    let abuse = [
        "@MainActor",
        "static func aStepThatCheats() {",
        "    var step = VerificationStep(name: \"x\")",
        "    step.expect([.init(\"a\", \"a thing\", \"1\")])",
        "    let measured = runTheThing()",
        "    step.given([(\"what we measured\", \"\\(measured)\")])",
        "    step.check(\"a\", \"a thing\", true)",
        "}",
    ]
    let caught = GivenPosition.violations(in: abuse, file: "fixture.swift")
    #expect(caught == [GivenPosition.Violation(function: "fixture.swift:aStepThatCheats",
                                               givenLine: 6, expectLine: 4)],
            "the scan did not name the given that follows expect: \(caught)")

    // And the positive control: the same step with the row where it belongs
    // must NOT be reported, or the rule is simply always failing.
    let honest = [
        "static func anHonestStep() {",
        "    step.given([(\"depth cap\", \"30\")])",
        "    step.expect([.init(\"a\", \"a thing\", \"1\")])",
        "}",
    ]
    #expect(GivenPosition.violations(in: honest, file: "fixture.swift").isEmpty,
            "a given placed before expect was reported as a violation")
}
