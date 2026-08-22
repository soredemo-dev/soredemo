import Foundation

/// The lexical layer of `Plugins/ArchitectureCheck`, extracted so checks outside the plugin ask
/// the same question. Its imports are kept to `Foundation` by hand: this is the one library
/// target the plugin is not attached to, since attaching it would close a dependency cycle.
public enum SwiftSourceLexer {

    /// One frame of lexical context. Frames rather than flags: block comments nest, raw strings
    /// carry a pound count, and interpolation puts the scanner back into code.
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

    /// One pass over the whole file, returning each line with comments and string content blanked
    /// to spaces (preserving column count) but interpolation bodies kept as code. File-scoped
    /// because `"""` state survives newlines. A lone CR terminates a line, as in Swift; FF, VT,
    /// NEL, U+2028 and U+2029 do not. `#sourceLocation` is not honoured.
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
                // A single-line string cannot span a newline; close it and anything above it
                // so a stray quote never blanks the rest of the file.
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
                // Extended regex `#/…/#`: a `"` inside is content and it may span newlines.
                if c == "/", hashRun(at: i + 1) >= hashCount {
                    stack.removeLast()
                    current += spaces(1 + hashCount)
                    i += 1 + hashCount
                } else if c == "\\" {
                    // The newline must reach the line-break branch, or line numbers drift.
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
                    // An escape carries exactly the delimiter's pound count, so in a raw
                    // string `\(` is literal text, not interpolation.
                    let after = i + 1 + hashCount
                    if after < chars.count, chars[after] == "(" {
                        stack.append(.interpolation)    // body is CODE
                        current += spaces(2 + hashCount)
                        i = after + 1
                    } else {
                        // `\` + newline is a continuation; the newline must still reach the
                        // line-break branch or line numbers drift.
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
                    // SE-0451 raw identifier: inside backticks a quote, `#"`, `//` and `/*` open
                    // no frame. The interior is kept so an escaped module name still resolves;
                    // non-identifier characters map to `_` so the span stays one token.
                    if let close = chars[(i + 1)...].firstIndex(where: { $0 == "`" || $0 == "\n" || $0 == "\r" }),
                       chars[close] == "`" {
                        current.append("`")
                        for character in chars[(i + 1)..<close] {
                            current.append(isIdentifierCharacter(character) ? character : "_")
                        }
                        current.append("`")
                        i = close + 1
                    } else {
                        // Unterminated, so not compilable Swift: blank this character only.
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
                        // Extended regex `#/…/#`. Bare `/…/` is not modelled: it is ambiguous
                        // with division and Swift rejects a quote inside one, so it hides nothing.
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

    /// A character that can appear inside an identifier, plus `.` so `AppKit.NSColor` stays one
    /// token and a backtick so an escaped module name does too. The one definition this file and
    /// `architecture-checker`'s `tokens(of:)` must agree on.
    ///
    /// Defined by what an identifier contains, never by what separates them: enumerating
    /// separators misses members and welds them onto the preceding token. `isLetter`/`isNumber`
    /// differ from Swift's UAX#31 set only by splitting tokens, which can add rejections, never
    /// misses.
    public static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character == "$" || character == "`" || character == "."
            || character.isLetter || character.isNumber
    }
}
