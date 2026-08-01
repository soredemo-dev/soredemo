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

    /// Always permitted, from every target.
    static let alwaysAllowed: Set<String> = ["Foundation"]

    /// Fallback allow-list, used only when the tool is invoked WITHOUT `--allow`
    /// (by hand, or by a test). In a real build the `ArchitectureCheck` plugin
    /// passes one `--allow` per declared dependency read straight out of
    /// `PluginContext`, so the allow-list *is* the manifest by construction and
    /// this table is not consulted.
    ///
    /// These are the DIRECT declared edges of `Package.swift`, not their transitive
    /// closure. Allowing the closure would let `Framing` import `Timeline` and
    /// `Variants` import `Geometry` — undeclared edges that SwiftPM itself only
    /// warns about on a warm `.build`, so nothing else would catch them.
    static let declaredEdges: [String: Set<String>] = [
        "Geometry": [],
        "Timeline": [],
        "Graph":    ["Geometry", "Timeline"],
        "Framing":  ["Graph", "Geometry"],
        "Variants": ["Framing", "Timeline"],
        "Project":  ["Graph", "Geometry", "Timeline"],
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

    /// A character that can appear inside an identifier — plus `.` so that
    /// `AppKit.NSColor` stays one token, and a backtick so that an escaped module
    /// name does too.
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
    static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character == "$" || character == "`" || character == "."
            || character.isLetter || character.isNumber
    }

    /// Tokens of the code view — maximal identifier runs — with 1-based line
    /// numbers. `;` is emitted as its own token so an import with no module name
    /// does not reach across a statement boundary for one.
    static func tokens(of lines: [String]) -> [Token] {
        var result: [Token] = []
        for (index, line) in lines.enumerated() {
            var current = ""
            func flush() {
                if !current.isEmpty {
                    result.append(Token(text: current, line: index + 1))
                    current = ""
                }
            }
            for character in line {
                if isIdentifierCharacter(character) {
                    current.append(character)
                } else {
                    flush()
                    if character == ";" { result.append(Token(text: ";", line: index + 1)) }
                }
            }
            flush()
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
    /// Tokens are maximal identifier runs, so no whitespace or punctuation glued to
    /// the keyword can hide it — see `isIdentifierCharacter`.
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
        values(of: flag, in: arguments).first
    }

    /// Every value of a repeatable flag, in order. `--allow` is repeated once per
    /// declared dependency.
    static func values(of flag: String, in arguments: [String]) -> [String] {
        var found: [String] = []
        var i = arguments.startIndex
        while i < arguments.endIndex {
            if arguments[i] == flag, arguments.index(after: i) < arguments.endIndex {
                found.append(arguments[arguments.index(after: i)])
                i = arguments.index(i, offsetBy: 2)
            } else {
                i = arguments.index(after: i)
            }
        }
        return found
    }

    static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        return 2
    }

    static func run(arguments: [String]) -> Int32 {
        guard let targetName = value(of: "--target-name", in: arguments),
              let sources = value(of: "--sources", in: arguments) else {
            return fail("usage: architecture-checker --target-name <name> --sources <dir> [--allow <module>]… [--touch <stamp>]")
        }

        // The plugin always passes `--allow`, one per declared dependency, so the
        // allow-list is the manifest. Only a hand or test invocation falls back to
        // the table — and an unknown target there is a hard error, never a pass.
        let explicit = values(of: "--allow", in: arguments)
        let allowed: Set<String>
        if explicit.isEmpty {
            guard let edges = declaredEdges[targetName] else {
                return fail("unknown target '\(targetName)' and no --allow given. Known: \(declaredEdges.keys.sorted().joined(separator: ", ")). Add it to declaredEdges in architecture-checker, or pass --allow.")
            }
            allowed = edges.union(alwaysAllowed)
        } else {
            allowed = Set(explicit).union(alwaysAllowed)
        }

        // Every I/O failure below is a hard error. For a tool whose premise is that
        // it cannot be bypassed, "unreadable" must never mean "compliant" — a silent
        // pass on a missing directory or an undecodable file is a bypass with extra
        // steps.
        let isDirectory: Bool
        do {
            isDirectory = try URL(fileURLWithPath: sources)
                .resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
        } catch {
            return fail("sources directory does not exist or cannot be read: \(sources) (\(error.localizedDescription))")
        }
        guard isDirectory else {
            return fail("sources path is not a directory: \(sources)")
        }
        guard let enumerator = FileManager.default.enumerator(atPath: sources) else {
            return fail("cannot enumerate sources directory: \(sources)")
        }

        var failed = false
        func report(_ file: String, _ line: Int, _ message: String) {
            FileHandle.standardError.write(Data("\(file):\(line): error: \(message)\n".utf8))
            failed = true
        }

        var swiftFileCount = 0
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".swift") else { continue }
            swiftFileCount += 1
            let path = sources + "/" + relative
            let text: String
            do {
                text = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                return fail("cannot read \(path) as UTF-8: \(error.localizedDescription). A file this checker cannot read is a file it cannot vouch for.")
            }

            for (module, line) in importedModules(in: codeViewLines(of: text))
            where !allowed.contains(module) {
                report(path, line,
                       "'\(module)' is not importable from \(targetName). Allowed: \(allowed.sorted().joined(separator: ", ")). See ARCHITECTURE.md D6.")
            }
        }

        guard swiftFileCount > 0 else {
            return fail("no .swift files under \(sources) for target \(targetName). A vacuous pass is not a pass.")
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
