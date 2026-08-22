import CheckerLexer
import Foundation
import Testing

// MARK: - why this file exists
//
// `SwiftSourceLexer.codeViewLines` was previously tested only out of process, through the
// `architecture-checker` binary's exit status — which can observe "the checker rejected this",
// never "the code view of this line was *that*". Its own doc comment is the specification here.
// The two INVARIANTS come first: most of the specific cases below depend on them.

/// The code view always has exactly as many lines as the source: `file:line:` is the contract
/// with whoever has to fix a violation, and a lost or gained line makes every later position
/// name somewhere that does not exist.
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
    // Computed independently of the lexer, from Swift's own two terminators: `\r\n` counts once,
    // a lone `\r` counts as one.
    let expected = source.replacingOccurrences(of: "\r\n", with: "\n")
        .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
        .count
    #expect(SwiftSourceLexer.codeViewLines(of: source).count == expected,
            "line count drifted for \(String(reflecting: source))")
}

/// Blanking preserves column count, so a reported column still indexes the source. Checked per
/// line, not in total: two errors that cancel would pass a total.
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

/// Swift block comments NEST, so the first `*/` does not necessarily close one; a non-nesting
/// scanner reads the tail as code, or keeps blanking to end of file.
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
    // The file resumes as CODE afterwards: a `"""` that never closes would blank the rest.
    #expect(view[4] == "let t = 3")
}

/// Interpolation puts the scanner back into CODE — why the frame stack exists rather than a
/// boolean: `"\(CGRect.zero)"` really names `CGRect`, so blanking it would hide a violation.
@Test func interpolationBodiesSurviveAsCode() {
    let view = SwiftSourceLexer.codeViewLines(of: "let s = \"a \\(CGRect.zero) b\"\n")
    #expect(view[0].contains("CGRect.zero"))
    #expect(!view[0].contains("a"))     // the literal text around it is gone
}

/// The `.paren` frame: a `)` closing a nested call must pop the paren, not the interpolation.
/// The only test that distinguishes it — disabling the push leaves every other one green — and
/// without it a banned name after a nested call becomes invisible to every rule.
@Test func aNestedCallInsideAnInterpolationDoesNotEndTheInterpolation() {
    let view = SwiftSourceLexer.codeViewLines(of: "let s = \"w=\\(round(scale) + CGRect.zero.width)\"\n")
    #expect(view[0] == "let s =      round(scale) + CGRect.zero.width  ")
    #expect(view[0].contains("CGRect"),
            "the nested call's `)` ended the interpolation and hid real code")
}

/// The same mechanism at depth: three closing parens in a row, all belonging to the call.
@Test func nestedParenthesesInsideAnInterpolationBalanceToAnyDepth() {
    #expect(SwiftSourceLexer.codeViewLines(of: "let s = \"\\(f(g(h(1)))) tail\"\n")[0]
            == "let s =    f(g(h(1)))       ")
}

/// Why the escape must carry the delimiter's exact pound count: inside `#"…"#` the sequence `\(`
/// is ORDINARY TEXT, and reading it as interpolation blanks the wrong half of every later line.
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

/// An unterminated single-line string must not blank the rest of the file: such a literal cannot
/// span a newline, so the newline closes it.
@Test func anUnterminatedSingleLineStringDoesNotBlankTheFile() {
    let view = SwiftSourceLexer.codeViewLines(of: "let s = \"oops\nimport AppKit\n")
    #expect(view[1] == "import AppKit")
}

// MARK: - raw identifiers (SE-0451)

/// A `"` inside `` `…` `` is ordinary content; treating it as a string opener blanked the rest of
/// the file on source that compiles. The assertion on THIS line is the load-bearing one: deleting
/// the raw-identifier branch still leaves the next line intact, so a next-line check alone passes.
@Test func aQuoteInsideARawIdentifierDoesNotOpenAString() {
    let view = SwiftSourceLexer.codeViewLines(of: "let `a\"b` = 1\nimport AppKit\n")
    #expect(view[0] == "let `a_b` = 1", "the quote inside `…` blanked the rest of its own line")
    #expect(view[1] == "import AppKit", "the quote inside `…` swallowed the rest of the file")
}

/// Nor do the comment and raw-string openers, asserted on the line itself for the same reason:
/// with the raw-identifier branch disabled, only `/*` survives a newline, so a next-line check
/// would pass vacuously for two of these three fixtures.
@Test(arguments: ["`a//b`", "`a/*b`", "`a#\"b`"])
func commentAndRawStringOpenersInsideARawIdentifierAreContent(identifier: String) {
    let view = SwiftSourceLexer.codeViewLines(of: "let \(identifier) = 1\nimport AppKit\n")
    // Each opener is two non-identifier characters, so all three normalise to the same interior.
    #expect(view[0] == "let `a__b` = 1", "\(identifier) blanked the rest of its own line")
    #expect(view[1] == "import AppKit", "\(identifier) swallowed the rest of the file")
}

/// The interior is normalised, not blanked, and stays ONE token — that is what stops an ordinary
/// Swift Testing name like `` `rejects import AppKit` `` from splitting into a bare `import`
/// keyword and a stray module name, a false positive that blocked real work.
@Test func aRawIdentifierIsNormalisedIntoASingleToken() {
    let view = SwiftSourceLexer.codeViewLines(of: "@Test func `rejects import AppKit`() {}\n")
    #expect(view[0].contains("`rejects_import_AppKit`"))
    #expect(!view[0].contains(" import "), "the raw identifier split into a bare `import` keyword")
}

/// Identifier characters survive: `` import `Foundation` `` must still resolve as that module.
@Test func anEscapedModuleNameSurvivesTheCodeView() {
    #expect(SwiftSourceLexer.codeViewLines(of: "import `Foundation`\n")[0] == "import `Foundation`")
}

// MARK: - extended regex literals (#/…/#), Swift 5.7

/// A `"` inside `#/…/#` is ordinary content and the literal may span newlines, so it has to be
/// its own frame.
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

/// Swift ends a `//` comment at a bare `\r` and counts the CR as a line; treating CR as content
/// would blank from there to the next LF and hide a real import.
@Test func aLoneCarriageReturnEndsALineComment() {
    let view = SwiftSourceLexer.codeViewLines(of: "// note\rimport AppKit\n")
    #expect(view.count == 3)
    #expect(view[1] == "import AppKit")
}

@Test func crlfCountsAsOneLineBreak() {
    let view = SwiftSourceLexer.codeViewLines(of: "let a = 1\r\nlet b = 2\r\n")
    #expect(view == ["let a = 1", "let b = 2", ""])
}

/// The other half of the rule: FF, VT, NEL, U+2028 and U+2029 are NOT line terminators for Swift,
/// so a `//` comment runs through them. Treating any as a newline un-blanks commented-out text
/// and drifts every later line number away from the compiler's.
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

/// The view must not invent code either: plain code passes through untouched, or every rule
/// becomes a false-positive machine.
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

/// The predicate is defined by what an identifier CONTAINS, never by what separates identifiers —
/// enumerating separators is what let `@_spi(A)@_spi(B)import AppKit` glue `)` to the keyword and
/// go invisible. The four non-alphanumeric members, plus a sample of what must stay out.
@Test func theIdentifierPredicateAdmitsExactlyTheFourNamedNonAlphanumerics() {
    for character: Character in ["_", "$", "`", ".", "a", "Z", "0", "é", "字"] {
        #expect(SwiftSourceLexer.isIdentifierCharacter(character), "\(character) must be admitted")
    }
    for character: Character in [" ", "\t", "\n", "\r", "(", ")", ";", "@", "-", "\u{00A0}", "\u{0C}"] {
        #expect(!SwiftSourceLexer.isIdentifierCharacter(character), "\(character.unicodeScalars.first!) must be excluded")
    }
}
