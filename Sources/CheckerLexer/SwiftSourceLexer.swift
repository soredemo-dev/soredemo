import Foundation

/// The lexical layer of `Plugins/ArchitectureCheck`, extracted so that checks
/// written *outside* the plugin can ask the same question the plugin asks.
///
/// The plugin attaches to SwiftPM targets, so it cannot see the Xcode app target
/// at all. The app-side allow-lists (`Tests/AppSourceTests`) therefore have to be
/// package tests — and a test that rolled its own "is this line code?" scan would
/// start at round zero of an evasion-closing exercise this code has already been
/// through four rounds of. One code view, two callers.
///
/// The type is deliberately NOT named `CheckerLexer`: no type in this project may
/// share its module's name.
///
/// This target keeps to `import Foundation` **by hand**. It is the one library
/// target the `ArchitectureCheck` plugin is not attached to, because attaching it
/// would close a dependency cycle — see the comment on the target in
/// `Package.swift`.
public enum SwiftSourceLexer {

    /// One frame of lexical context. Comments and strings are frames rather than
    /// flags because Swift block comments nest, raw-string delimiters carry a
    /// pound count, and string interpolation puts the scanner back into *code*.
    private enum Frame {
        case string(hashCount: Int, multiline: Bool)
        case regex(hashCount: Int)
        case interpolation
        case paren
        case lineComment
        case blockComment

        var isString: Bool {
            if case .string = self { return true }
            return false
        }
    }

    /// One pass over the whole file, returning each line with comments and string
    /// CONTENT blanked, but interpolation bodies preserved as code.
    ///
    /// The scan is file-scoped, not line-local, because `"""` string state must
    /// survive newlines. Blanking preserves column count so reported lines still
    /// line up with the source.
    ///
    /// Handles: `//`, nested `/* */`; plain, multiline and raw strings with any
    /// pound count; `\(…)` and `\#(…)` interpolation nested to any depth; and the
    /// fact that in a raw string `\(` is literal text, not an interpolation.
    ///
    /// A lone CR is a line terminator, not ordinary code: Swift ends a `//` comment
    /// at a bare `\r` and compiles what follows, and its diagnostics count the CR as
    /// a line (both verified with `swiftc -typecheck`). Treating it as content would
    /// blank every character from the CR to the next LF. Note that FF, VT, NEL,
    /// U+2028 and U+2029 are NOT line terminators for Swift — a `//` comment
    /// continues straight through them — so they must not be treated as newlines
    /// here either, or line numbers would drift from the compiler's.
    ///
    /// Known limitation: `#sourceLocation` remapping is not honoured, so reported
    /// line numbers are physical, not remapped.
    public static func codeViewLines(of text: String) -> [String] {
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        var lines: [String] = []
        var current = ""
        var stack: [Frame] = []
        var i = 0

        func spaces(_ n: Int) -> String { String(repeating: " ", count: n) }

        /// Number of consecutive `#` starting at `index`.
        func hashRun(at index: Int) -> Int {
            var n = 0
            while index + n < chars.count, chars[index + n] == "#" { n += 1 }
            return n
        }

        func matches(_ literal: [Character], at index: Int) -> Bool {
            guard index + literal.count <= chars.count else { return false }
            for (offset, expected) in literal.enumerated() where chars[index + offset] != expected {
                return false
            }
            return true
        }

        let tripleQuote: [Character] = ["\"", "\"", "\""]

        while i < chars.count {
            let c = chars[i]

            if c == "\n" || c == "\r" {     // a lone CR ends a // comment in Swift
                lines.append(current)
                current = ""
                if case .some(.lineComment) = stack.last { stack.removeLast() }
                // Defensive: an unterminated single-line string cannot span a
                // newline. Close it (and anything nested above it) so a stray
                // quote never blanks the remainder of the file.
                while let index = stack.lastIndex(where: { $0.isString }) {
                    guard case .string(_, let multiline) = stack[index], !multiline else { break }
                    stack.removeSubrange(index...)
                }
                i += 1
                continue
            }

            switch stack.last {

            case .some(.lineComment):
                current.append(" ")
                i += 1

            case .some(.blockComment):
                if c == "/", matches(["*"], at: i + 1) {
                    stack.append(.blockComment)     // Swift block comments nest.
                    current += spaces(2)
                    i += 2
                } else if c == "*", matches(["/"], at: i + 1) {
                    stack.removeLast()
                    current += spaces(2)
                    i += 2
                } else {
                    current.append(" ")
                    i += 1
                }

            case .some(.regex(let hashCount)):
                // Extended regex literal `#/…/#`. A `"` inside one is ordinary
                // content, and `#/…/#` may span newlines, so it must be a frame.
                if c == "/", hashRun(at: i + 1) >= hashCount {
                    stack.removeLast()
                    current += spaces(1 + hashCount)
                    i += 1 + hashCount
                } else if c == "\\" {
                    // Same guard as the string branch below, for the same reason:
                    // consuming the newline here would stop it reaching the
                    // line-break branch, and every reported line number after it
                    // would be off by one, compounding. `file:line:` is the contract.
                    var end = min(i + 2, chars.count)
                    if i + 1 < chars.count, chars[i + 1] == "\n" || chars[i + 1] == "\r" {
                        end = i + 1
                    }
                    let consumed = end - i
                    current += spaces(consumed)
                    i += consumed
                } else {
                    current.append(" ")
                    i += 1
                }

            case .some(.string(let hashCount, let multiline)):
                if multiline, matches(tripleQuote, at: i), hashRun(at: i + 3) >= hashCount {
                    stack.removeLast()
                    current += spaces(3 + hashCount)
                    i += 3 + hashCount
                } else if !multiline, c == "\"", hashRun(at: i + 1) >= hashCount {
                    stack.removeLast()
                    current += spaces(1 + hashCount)
                    i += 1 + hashCount
                } else if c == "\\", hashRun(at: i + 1) == hashCount {
                    // An escape must carry exactly the delimiter's pound count.
                    // In `#"a \(b) c"#` the run is 0 ≠ 1, so `\(` is literal text.
                    let after = i + 1 + hashCount
                    if after < chars.count, chars[after] == "(" {
                        stack.append(.interpolation)    // body is CODE
                        current += spaces(2 + hashCount)
                        i = after + 1
                    } else {
                        // `\` + newline is a line continuation inside a `"""`
                        // literal. Consuming the newline here would stop it
                        // reaching the line-break branch, and every reported line
                        // number after it would be off by one, compounding.
                        var end = min(after + 1, chars.count)
                        if after < chars.count, chars[after] == "\n" || chars[after] == "\r" {
                            end = after
                        }
                        let consumed = end - i
                        current += spaces(consumed)
                        i += consumed
                    }
                } else {
                    current.append(" ")
                    i += 1
                }

            // Code: nothing on the stack, or an interpolation/paren above a string.
            case .none, .some(.interpolation), .some(.paren):
                if c == "/", matches(["/"], at: i + 1) {
                    stack.append(.lineComment)
                    current += spaces(2)
                    i += 2
                } else if c == "/", matches(["*"], at: i + 1) {
                    stack.append(.blockComment)
                    current += spaces(2)
                    i += 2
                } else if c == "`" {
                    // SE-0451 raw identifier. Inside `…` a quote, a `#"`, a `//`
                    // and a `/*` are all ORDINARY CONTENT, so none of them may open
                    // a frame. The span is bounded and unambiguous: a raw identifier
                    // cannot contain a backtick, a backslash, CR or LF.
                    //
                    // The interior is not blanked, because the escaped form is how a
                    // module may legitimately be named — `import `Foundation`` must
                    // still resolve to Foundation. Identifier characters are kept and
                    // everything else is mapped to `_`, so the whole span survives as
                    // ONE token: that is what stops `` `does import work` `` from
                    // splitting into a bare `import` keyword and a stray `work`.
                    if let close = chars[(i + 1)...].firstIndex(where: { $0 == "`" || $0 == "\n" || $0 == "\r" }),
                       chars[close] == "`" {
                        current.append("`")
                        for character in chars[(i + 1)..<close] {
                            current.append(isIdentifierCharacter(character) ? character : "_")
                        }
                        current.append("`")
                        i = close + 1
                    } else {
                        // Unterminated: not a raw identifier, and not compilable
                        // Swift. Blank just this character and carry on in code, so
                        // nothing downstream is hidden.
                        current.append(" ")
                        i += 1
                    }
                } else if c == "#" {
                    let n = hashRun(at: i)
                    if i + n < chars.count, chars[i + n] == "\"" {
                        let multiline = matches(tripleQuote, at: i + n)
                        stack.append(.string(hashCount: n, multiline: multiline))
                        let length = n + (multiline ? 3 : 1)
                        current += spaces(length)
                        i += length
                    } else if n >= 1, i + n < chars.count, chars[i + n] == "/" {
                        // Extended regex literal `#/…/#`. Quotes inside one are
                        // ordinary content, and it may span newlines, so it is a
                        // frame. Bare `/…/` is deliberately NOT modelled: it is
                        // ambiguous with division, and Swift itself rejects a quote
                        // inside one (`let r = /a"b/` is `error: unterminated string
                        // literal`), so it cannot hide code from a build that compiles.
                        stack.append(.regex(hashCount: n))
                        current += spaces(n + 1)
                        i += n + 1
                    } else {
                        current += String(repeating: "#", count: n)   // #if, #expect, …
                        i += n
                    }
                } else if c == "\"" {
                    let multiline = matches(tripleQuote, at: i)
                    stack.append(.string(hashCount: 0, multiline: multiline))
                    let length = multiline ? 3 : 1
                    current += spaces(length)
                    i += length
                } else if c == "(" {
                    stack.append(.paren)
                    current.append("(")
                    i += 1
                } else if c == ")" {
                    switch stack.last {
                    case .some(.paren):
                        stack.removeLast()
                        current.append(")")
                    case .some(.interpolation):
                        stack.removeLast()          // back into string content
                        current.append(" ")
                    default:
                        current.append(")")
                    }
                    i += 1
                } else {
                    current.append(c)
                    i += 1
                }
            }
        }

        lines.append(current)
        return lines
    }

    /// A character that can appear inside an identifier — plus `.` so that
    /// `AppKit.NSColor` stays one token, and a backtick so that an escaped module
    /// name does too.
    ///
    /// Lives here rather than beside `tokens(of:)` in `architecture-checker`
    /// because the raw-identifier branch of `codeViewLines` needs it too: the span
    /// between backticks is normalised through this predicate so it survives as one
    /// token. Both callers must agree on what an identifier character is, and there
    /// is exactly one definition.
    ///
    /// The set is defined by what an identifier CONTAINS, never by what separates
    /// identifiers. Enumerating separators is a losing game: Swift accepts space,
    /// tab, newline, CR, form feed, vertical tab and U+00A0 between `import` and the
    /// module name — every one of those verified to typecheck — and it also ends a
    /// token at any punctuation, so `@_spi(A)@_spi(B)import AppKit` glues `)` to the
    /// keyword. Any separator missed by an enumeration welds itself to `import`,
    /// the token stops comparing equal, and the declaration goes invisible.
    /// Inverting the test closes that whole family at once, including the members
    /// nobody has thought of yet.
    ///
    /// Note what inverting does NOT buy: a character in this set that Swift treats
    /// as a token TERMINATOR produces a miss, not a false positive. Merging is only
    /// safe for characters Swift also merges. Of the four added beyond letters and
    /// digits, `_` and `$` do merge in Swift (`import$AppKit` diagnoses as one
    /// unknown identifier), and `.` makes the source invalid outright — but the
    /// backtick terminates, so `tokens(of:)` handles it explicitly rather than
    /// leaning on this predicate. See the flush in `tokens(of:)`.
    ///
    /// Those four are settled by name. **The rest of the predicate is not.**
    /// `isLetter` and `isNumber` are General_Category tests, whereas Swift's
    /// identifier set is an explicit UAX#31-derived list of ranges with holes, so
    /// the two disagree in both directions on some code points. The disagreements
    /// found so far are all in the false-positive direction — a character Swift
    /// admits and this predicate rejects merely splits a token, which can only add
    /// rejections (`public let 🚀import = 1` is rejected for exactly this reason).
    /// That is an empirical result from sweeping 128 ASCII code points and 22
    /// Unicode oddities, not a structural guarantee. The SEPARATOR direction was
    /// closed by construction; the MEMBERSHIP direction rests on the sweep.
    public static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character == "$" || character == "`" || character == "."
            || character.isLetter || character.isNumber
    }
}
