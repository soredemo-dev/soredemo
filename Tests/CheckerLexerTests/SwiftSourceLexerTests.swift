import CheckerLexer
import Foundation
import Testing

// MARK: - why this file exists
//
// `SwiftSourceLexer.codeViewLines` is the product of four rounds of
// evasion-closing on `ArchitectureCheck` rule 1, and until this file it had
// **only ever been tested out of process** — by running the built
// `architecture-checker` binary over a fixture directory and reading its exit
// status (`Tests/GeometryTests/ArchitectureCheckTests.swift`). That is a good
// end-to-end test and a poor unit test: it can only observe "the checker
// rejected this", never "the code view of this line was *that*". Extracting the
// lexer into its own target is what makes the direct question askable, and an
// extraction with nothing exercising it is an unverified move.
//
// Every case below is one of the forms the design doc records as having defeated
// an earlier design, or one of the distinctions its doc comment claims. The doc
// comment is treated as the specification: these tests check the code against
// it, not the reverse.
//
// The two INVARIANTS are asserted first, because most of the specific cases
// depend on them and a regression in either silently misreports every line
// number and column the checker prints.

/// The code view has exactly as many lines as the source, always. A scanner that
/// loses or gains a line reports `file:line:` positions that do not exist, and
/// the error drifts further with every subsequent literal — `file:line:` is the
/// contract with whoever has to fix the violation.
@Test(arguments: [
    "let a = 1\nlet b = 2\n",
    "let s = \"\"\"\nabc\n\"\"\"\nlet t = 3\n",
    "let s = \"\"\"\nline \\\ncontinued\n\"\"\"\n",
    "// note\rimport Foundation\n",
    "let a = 1\r\nlet b = 2\r\n",
    "let r = #/a\nb/#\nlet c = 3\n",
    "/* a\nb\nc */ let d = 4\n",
    "",
])
func theCodeViewHasOneLinePerSourceLine(source: String) {
    // Computed independently of the lexer, from Swift's OWN two line terminators:
    // `\r\n` counts once (it is normalised before the scan, exactly as Swift does)
    // and a lone `\r` counts as one on its own.
    let expected = source.replacingOccurrences(of: "\r\n", with: "\n")
        .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
        .count
    #expect(SwiftSourceLexer.codeViewLines(of: source).count == expected,
            "line count drifted for \(String(reflecting: source))")
}

/// Blanking preserves column count, so a reported column still indexes the
/// source. Checked per line, not in total: two errors that cancel would pass a
/// total.
@Test(arguments: [
    "let a = 1 // trailing",
    "let a = 1 /* mid */ let b = 2",
    "let s = \"content\"",
    "let s = #\"raw \\(notInterpolation)\"#",
    "let r = #/pattern\"with quote/#",
    "let s = \"a \\(b) c\"",
    "let `raw \" identifier` = 1",
])
func blankingPreservesColumnCount(line: String) {
    let view = SwiftSourceLexer.codeViewLines(of: line)
    #expect(view.count == 1)
    #expect(view.first?.count == line.count,
            "column drift: \(String(reflecting: line)) -> \(String(reflecting: view.first ?? ""))")
}

// MARK: - comments

@Test func lineCommentContentIsBlanked() {
    let view = SwiftSourceLexer.codeViewLines(of: "let a = 1 // CGRect here\nlet b = 2\n")
    #expect(view[0] == "let a = 1               ")
    #expect(view[1] == "let b = 2")
}

/// Swift block comments NEST, so the first `*/` does not necessarily close one.
/// A non-nesting scanner reads `still */ let b = 2` as code — and, worse, an
/// unbalanced one keeps blanking to end of file.
@Test func blockCommentsNest() {
    let view = SwiftSourceLexer.codeViewLines(of: "let a = 1 /* CGRect /* CGPoint */ still */ let b = 2\n")
    #expect(view[0] == "let a = 1                                  let b = 2")
    #expect(!view[0].contains("CGRect"))
    #expect(!view[0].contains("still"))
}

@Test func aBlockCommentSpansLinesWithoutLosingAny() {
    let view = SwiftSourceLexer.codeViewLines(of: "/* CGRect\nCGPoint\n*/ let d = 4\n")
    #expect(view.count == 4)
    #expect(view[0].allSatisfy { $0 == " " })
    #expect(view[1].allSatisfy { $0 == " " })
    #expect(view[2] == "   let d = 4")     // `*/` blanked, the space after it kept
}

// MARK: - strings

@Test func stringContentIsBlanked() {
    #expect(SwiftSourceLexer.codeViewLines(of: "let s = \"CGRect\"\n")[0] == "let s =         ")
}

@Test func multiLineStringContentIsBlankedAcrossEveryLine() {
    let view = SwiftSourceLexer.codeViewLines(of: "let s = \"\"\"\nCGRect\nUUID()\n\"\"\"\nlet t = 3\n")
    #expect(view.count == 6)
    for index in 0...3 {
        #expect(!view[index].contains("CGRect") && !view[index].contains("UUID"))
    }
    // and the file resumes as CODE afterwards — a `"""` that never closes would
    // blank the rest of the file, which is known gap #5.
    #expect(view[4] == "let t = 3")
}

/// Interpolation puts the scanner back into CODE. This is why the frame stack
/// exists rather than a boolean: `"\(CGRect.zero)"` really does name `CGRect`
/// in a way the compiler resolves, so blanking it would let a violation through.
@Test func interpolationBodiesSurviveAsCode() {
    let view = SwiftSourceLexer.codeViewLines(of: "let s = \"a \\(CGRect.zero) b\"\n")
    #expect(view[0].contains("CGRect.zero"))
    #expect(!view[0].contains("a"))     // the literal text around it is gone
}

/// The mirror image, and the reason the escape must carry the delimiter's exact
/// pound count: inside `#"…"#` the sequence `\(` is ORDINARY TEXT, not an
/// interpolation. Reading it as one would put the scanner into code inside a
/// string and blank the wrong half of every line after it.
@Test func backslashParenInARawStringIsLiteralText() {
    let view = SwiftSourceLexer.codeViewLines(of: "let s = #\"a \\(CGRect) b\"#\n")
    #expect(view[0] == "let s =                  ")
    #expect(!view[0].contains("CGRect"))
}

/// …and a raw string WITH the matching pound count does interpolate.
@Test func hashBackslashParenInARawStringIsInterpolation() {
    let view = SwiftSourceLexer.codeViewLines(of: "let s = #\"a \\#(CGRect.zero) b\"#\n")
    #expect(view[0].contains("CGRect.zero"))
}

/// A stray unterminated single-line string must not blank the rest of the file:
/// a single-line literal cannot span a newline, so the newline closes it.
@Test func anUnterminatedSingleLineStringDoesNotBlankTheFile() {
    let view = SwiftSourceLexer.codeViewLines(of: "let s = \"oops\nimport AppKit\n")
    #expect(view[1] == "import AppKit")
}

// MARK: - raw identifiers (SE-0451) — round 3

/// The round-3 defect, and the one that makes this the most important case here:
/// a `"` inside `` `…` `` is ordinary content. Treating it as a string opener
/// blanked the remainder of the file, on source that compiles — so a real
/// `import AppKit` two lines down went invisible.
/// The assertion is on the LINE ITSELF, not merely on the line after it. Deleting
/// the raw-identifier branch entirely still leaves the following line intact,
/// because the newline defensively closes the single-line string frame the quote
/// wrongly opened — so a next-line assertion passes under a mutation that removes
/// the whole feature, and would have been a test in name only. What actually
/// changes is the rest of THIS line.
@Test func aQuoteInsideARawIdentifierDoesNotOpenAString() {
    let view = SwiftSourceLexer.codeViewLines(of: "let `a\"b` = 1\nimport AppKit\n")
    #expect(view[0] == "let `a_b` = 1", "the quote inside `…` blanked the rest of its own line")
    #expect(view[1] == "import AppKit", "the quote inside `…` swallowed the rest of the file")
}

/// Nor do the comment openers. Same reasoning, different opener.
@Test(arguments: ["`a//b`", "`a/*b`", "`a#\"b`"])
func commentAndRawStringOpenersInsideARawIdentifierAreContent(identifier: String) {
    let view = SwiftSourceLexer.codeViewLines(of: "let \(identifier) = 1\nimport AppKit\n")
    #expect(view[1] == "import AppKit", "\(identifier) swallowed the rest of the file")
}

/// The interior is normalised, not blanked, and it stays ONE token: that is what
/// stops `` @Test func `rejects import AppKit`() `` — an ordinary Swift Testing
/// name — from splitting into a bare `import` keyword and a stray module name.
/// Round 3 existed because that false positive was blocking real work.
@Test func aRawIdentifierIsNormalisedIntoASingleToken() {
    let view = SwiftSourceLexer.codeViewLines(of: "@Test func `rejects import AppKit`() {}\n")
    #expect(view[0].contains("`rejects_import_AppKit`"))
    #expect(!view[0].contains(" import "), "the raw identifier split into a bare `import` keyword")
}

/// Identifier characters survive; a raw identifier that names a module really is
/// still that module, because `` import `Foundation` `` must resolve.
@Test func anEscapedModuleNameSurvivesTheCodeView() {
    #expect(SwiftSourceLexer.codeViewLines(of: "import `Foundation`\n")[0] == "import `Foundation`")
}

// MARK: - extended regex literals (#/…/#), Swift 5.7

/// A `"` inside `#/…/#` is ordinary content and the literal may span newlines,
/// so it has to be a frame. This one was absent for several releases and was
/// found by an audit, not by the language moving.
@Test func aQuoteInsideAnExtendedRegexLiteralDoesNotOpenAString() {
    let view = SwiftSourceLexer.codeViewLines(of: "let r = #/CGRect\"/#\nimport AppKit\n")
    #expect(view[0] == "let r =            ")
    #expect(!view[0].contains("CGRect"))
    #expect(view[1] == "import AppKit")
}

@Test func anExtendedRegexLiteralMaySpanLines() {
    let view = SwiftSourceLexer.codeViewLines(of: "let r = #/a\nCGRect\nb/#\nlet c = 3\n")
    #expect(view.count == 5)
    #expect(!view[1].contains("CGRect"))
    #expect(view[3] == "let c = 3")
}

/// `#` that is not a literal delimiter stays code: `#if`, `#expect`, `#filePath`.
@Test(arguments: ["#if canImport(AppKit)", "#expect(x == 1)", "#sourceLocation()"])
func poundDirectivesStayCode(line: String) {
    #expect(SwiftSourceLexer.codeViewLines(of: line)[0] == line)
}

// MARK: - line terminators: exactly LF and CR, and nothing else

/// Swift ends a `//` comment at a bare `\r` and compiles what follows, and its
/// diagnostics count the CR as a line — both verified with `swiftc -typecheck`
/// when the rule was written. Treating CR as content would blank from the CR to
/// the next LF, hiding a real import (known gap #3, closed in round 2).
@Test func aLoneCarriageReturnEndsALineComment() {
    let view = SwiftSourceLexer.codeViewLines(of: "// note\rimport AppKit\n")
    #expect(view.count == 3)
    #expect(view[1] == "import AppKit")
}

@Test func crlfCountsAsOneLineBreak() {
    let view = SwiftSourceLexer.codeViewLines(of: "let a = 1\r\nlet b = 2\r\n")
    #expect(view == ["let a = 1", "let b = 2", ""])
}

/// The other half of the rule, and the half that is easy to get wrong by being
/// generous: FF, VT, NEL, U+2028 and U+2029 are NOT line terminators for Swift.
/// A `//` comment runs straight through all of them. Treating any as a newline
/// would (a) un-blank text that is really still commented out, and (b) drift
/// every subsequent line number away from the compiler's.
@Test(arguments: [
    ("form feed", "\u{0C}"),
    ("vertical tab", "\u{0B}"),
    ("NEL", "\u{85}"),
    ("line separator U+2028", "\u{2028}"),
    ("paragraph separator U+2029", "\u{2029}"),
])
func nonTerminatorsDoNotEndALineComment(name: String, character: String) {
    let source = "// note\(character)import AppKit\nlet x = 1\n"
    let view = SwiftSourceLexer.codeViewLines(of: source)
    #expect(view.count == 3, "\(name) was treated as a line break")
    #expect(!view[0].contains("import"), "\(name) let commented-out text back into the code view")
    #expect(view[1] == "let x = 1", "\(name) shifted the following line numbers")
}

// MARK: - the negative direction

/// The view must not invent code either. Plain code passes through untouched —
/// a lexer that mangled it would turn every rule into a false-positive machine,
/// which the design doc calls the serious failure.
@Test(arguments: [
    "import Foundation",
    "public struct PixelRect: Sendable { public let width: Int }",
    "let quotient = a / b",
    "func doImport() {}",
    "public let `import` = 1",
])
func ordinaryCodePassesThroughUnchanged(line: String) {
    #expect(SwiftSourceLexer.codeViewLines(of: line)[0] == line)
}

// MARK: - the identifier predicate

/// The predicate is defined by what an identifier CONTAINS, never by what
/// separates identifiers — enumerating separators is what let
/// `@_spi(A)@_spi(B)import AppKit` glue `)` to the keyword and go invisible.
/// These are the four non-alphanumeric members, each settled by name in the doc
/// comment, plus a sample of what must stay out.
@Test func theIdentifierPredicateAdmitsExactlyTheFourNamedNonAlphanumerics() {
    for character: Character in ["_", "$", "`", ".", "a", "Z", "0", "é", "字"] {
        #expect(SwiftSourceLexer.isIdentifierCharacter(character), "\(character) must be admitted")
    }
    for character: Character in [" ", "\t", "\n", "\r", "(", ")", ";", "@", "-", "\u{00A0}", "\u{0C}"] {
        #expect(!SwiftSourceLexer.isIdentifierCharacter(character), "\(character.unicodeScalars.first!) must be excluded")
    }
}
