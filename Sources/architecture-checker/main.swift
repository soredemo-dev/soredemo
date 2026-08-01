import Foundation

/// Enforces architecture rule 1: the package imports Foundation only, plus the
/// sibling targets it actually declares as dependencies in `Package.swift`.
///
/// The Swift compiler does NOT enforce this. A target with zero declared
/// dependencies may `import AppKit` and `import ScreenCaptureKit` and build
/// cleanly, because system frameworks are always on the search path. SwiftPM's
/// own check on *declared package edges* degrades to a warning on a warm
/// `.build`. This executable is what actually enforces the rule, on every build,
/// via the `ArchitectureCheck` build-tool plugin.
enum ArchitectureChecker {

    /// Permitted imports per target. Must match the dependency edges in Package.swift;
    /// changing an edge changes this table.
    static let allowedImports: [String: Set<String>] = [
        "Geometry": ["Foundation"],
        "Timeline": ["Foundation"],
        "Graph":    ["Foundation", "Geometry", "Timeline"],
        "Framing":  ["Foundation", "Geometry", "Graph", "Timeline"],
        "Variants": ["Foundation", "Geometry", "Graph", "Timeline", "Framing"],
        "Project":  ["Foundation", "Geometry", "Graph", "Timeline"],
    ]

    /// Declaration kinds permitted between `import` and the module name, as in
    /// `import class AppKit.NSColor`.
    static let importDeclarationKinds: Set<String> = [
        "typealias", "struct", "class", "enum", "protocol", "actor",
        "let", "var", "func", "macro",
    ]

    // MARK: - Lexical scan

    /// One frame of lexical context. Comments and strings are frames rather than
    /// flags because Swift block comments nest, raw-string delimiters carry a
    /// pound count, and string interpolation puts the scanner back into *code*.
    private enum Frame {
        case string(hashCount: Int, multiline: Bool)
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
    static func codeViewLines(of text: String) -> [String] {
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

            if c == "\n" {
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
                        let consumed = min(after + 1, chars.count) - i
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
                } else if c == "#" {
                    let n = hashRun(at: i)
                    if i + n < chars.count, chars[i + n] == "\"" {
                        let multiline = matches(tripleQuote, at: i + n)
                        stack.append(.string(hashCount: n, multiline: multiline))
                        let length = n + (multiline ? 3 : 1)
                        current += spaces(length)
                        i += length
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

    // MARK: - Import extraction

    struct Token {
        let text: String
        let line: Int
    }

    /// Whitespace-separated tokens of the code view, with 1-based line numbers.
    /// `;` is promoted to its own token so semicolon-joined statements separate.
    static func tokens(of lines: [String]) -> [Token] {
        var result: [Token] = []
        for (index, line) in lines.enumerated() {
            let separated = line.replacingOccurrences(of: ";", with: " ; ")
            for piece in separated.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                result.append(Token(text: String(piece), line: index + 1))
            }
        }
        return result
    }

    /// Every module the file imports, with the line its `import` keyword sits on.
    ///
    /// The scan is over TOKENS, not lines. `import` followed by a newline and then
    /// the module name is valid Swift — it typechecks and grants full access to the
    /// module's API (verified with `swiftc -typecheck`) — so any statement scan that
    /// stops at the end of a line lets `import\nAppKit` straight through.
    ///
    /// Nothing here special-cases the position of `import` within its declaration,
    /// which is what makes the SE-0409 access-level spellings (`public import`,
    /// `internal import`, `package import`, …) and any `@attribute` prefix fall out
    /// for free. `import` is a reserved word — it cannot appear as an identifier
    /// unless backticked, which yields a different token — and comment and string
    /// text has already been blanked, so a bare `import` token always starts an
    /// import declaration.
    static func importedModules(in lines: [String]) -> [(module: String, line: Int)] {
        let all = tokens(of: lines)
        var found: [(module: String, line: Int)] = []
        var i = 0
        while i < all.count {
            guard all[i].text == "import" else {
                i += 1
                continue
            }
            let line = all[i].line
            var j = i + 1
            while j < all.count, importDeclarationKinds.contains(all[j].text) { j += 1 }
            if j < all.count, all[j].text != ";" {
                // `import class AppKit.NSColor` -> AppKit; `import `Foundation`` -> Foundation
                let head = all[j].text.split(separator: ".").first.map(String.init) ?? all[j].text
                let module = head.replacingOccurrences(of: "`", with: "")
                if !module.isEmpty { found.append((module, line)) }
            }
            i = j + 1
        }
        return found
    }

    // MARK: - Driver

    static func value(of flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag),
              arguments.index(after: i) < arguments.endIndex
        else { return nil }
        return arguments[arguments.index(after: i)]
    }

    static func run(arguments: [String]) -> Int32 {
        guard let targetName = value(of: "--target-name", in: arguments),
              let sources = value(of: "--sources", in: arguments),
              let allowed = allowedImports[targetName] else {
            FileHandle.standardError.write(Data("error: bad arguments or unknown target\n".utf8))
            return 2
        }

        var failed = false
        func report(_ file: String, _ line: Int, _ message: String) {
            FileHandle.standardError.write(Data("\(file):\(line): error: \(message)\n".utf8))
            failed = true
        }

        let enumerator = FileManager.default.enumerator(atPath: sources)
        while let relative = enumerator?.nextObject() as? String {
            guard relative.hasSuffix(".swift") else { continue }
            let path = sources + "/" + relative
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

            for (module, line) in importedModules(in: codeViewLines(of: text))
            where !allowed.contains(module) {
                report(path, line,
                       "'\(module)' is not importable from \(targetName). Allowed: \(allowed.sorted().joined(separator: ", ")). See ARCHITECTURE.md D6.")
            }
        }

        guard !failed else { return 1 }

        // Stamp file, written ONLY on success. If a violating build left a stamp
        // behind, SwiftPM would see the output newer than the inputs and skip the
        // command on the next incremental build — a warm-build false green, which
        // is precisely the hole this checker exists to close.
        if let stamp = value(of: "--touch", in: arguments) {
            let url = URL(fileURLWithPath: stamp)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try Data("\(targetName) ok\n".utf8).write(to: url)
            } catch {
                FileHandle.standardError.write(
                    Data("error: could not write stamp \(stamp): \(error)\n".utf8))
                return 2
            }
        }
        return 0
    }
}

exit(ArchitectureChecker.run(arguments: CommandLine.arguments))
