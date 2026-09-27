import CheckerLexer
import Foundation

/// Enforces architecture rules 1, 2, 4 and 8, none of which the compiler or SwiftPM
/// enforces. Rule 1: a target may import only Foundation plus its declared siblings.
enum ArchitectureChecker {

    /// Always permitted, from every target.
    static let alwaysAllowed: Set<String> = ["Foundation"]

    /// Fallback allow-list, used only without `--allow`: the direct declared edges of
    /// `Package.swift`, never their transitive closure.
    static let declaredEdges: [String: Set<String>] = [
        "Geometry": [],
        "Timeline": [],
        "Graph":    ["Geometry", "Timeline"],
        "Framing":  ["Graph", "Geometry", "Project", "Timeline"],
        "Variants": ["Framing", "Timeline"],
        "Project":  ["Graph", "Geometry", "Timeline"],
        "Render":   ["Geometry", "Timeline", "Project"],
    ]

    /// Declaration kinds permitted in the `import class AppKit.NSColor` form.
    static let importDeclarationKinds: Set<String> = [
        "typealias", "struct", "class", "enum", "protocol", "actor",
        "let", "var", "func", "macro",
    ]

    /// Rule 2: CG geometry types banned package-wide; conversion belongs at the app
    /// boundary.
    static let bannedCGTypes = ["CGRect", "CGPoint", "CGSize", "CGFloat"]

    // MARK: - Lexical scan
    // The code view every rule scans lives in `CheckerLexer`, since a test target
    // cannot import an `executableTarget`.

    // MARK: - Import extraction

    struct Token {
        let text: String
        let line: Int
    }

    /// Tokens of the code view — maximal identifier runs — with 1-based line numbers.
    /// `;` is its own token so a module-less import cannot reach past it for a name.
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
                if character == "`" {
                    // A backtick terminates a token, and is kept so an escaped identifier
                    // stays distinct from the same-spelled keyword.
                    flush()
                    current.append(character)
                } else if SwiftSourceLexer.isIdentifierCharacter(character) {
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

    /// The module a token names, backticks stripped; a lone delimiter yields "".
    static func moduleName(of token: String) -> String {
        let head = token.split(separator: ".").first.map(String.init) ?? token
        return head.replacingOccurrences(of: "`", with: "")
    }

    /// Every module the file imports, with its `import` keyword's line. Scans tokens,
    /// not lines: a newline may separate keyword from name, and the keyword's position
    /// is not special-cased, so SE-0409 spellings work.
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
            // Skip declaration kinds and empty tokens, which would mask a real name.
            while j < all.count,
                  importDeclarationKinds.contains(all[j].text) || moduleName(of: all[j].text).isEmpty {
                j += 1
            }
            if j < all.count, all[j].text != ";" {
                let module = moduleName(of: all[j].text)
                if !module.isEmpty { found.append((module, line)) }
            }
            i = j + 1
        }
        return found
    }

    // MARK: - Rule 8: a validating initialiser under a synthesised `Decodable`
    // A violation is a type with a throwing, failable or `precondition`-bearing
    // initialiser, a `Codable`/`Decodable` conformance, and no explicit
    // `init(from decoder:)` — the synthesised decode skips every check. Conformance and
    // `init(from:)` may sit on an extension, so a type's text is its own plus every
    // extension's in the target.

    /// The types that violate rule 8 today: a literal list, never a predicate.
    /// Exemption is by name, so `Outer.Inner` matches either spelling.
    static let decodeValidationExemptTypes: Set<String> = [
        "Authorship",
        "HostInstant",
        // Not a violation: a conversion returning nil, stating no invariant.
        "Nanoseconds",
        "NormalizedFrame",
        "NormalizedPoint",
        "NormalizedSize",
        "PixelRect",
        "PointRect",
    ]

    /// Keywords introducing a braced declaration rule 8 reads; `protocol` is here for
    /// its conformance clause only.
    static let typeDeclarationKeywords: Set<String> =
        ["struct", "class", "enum", "actor", "protocol", "extension"]

    /// One declaration in one file.
    struct DeclarationSite {
        let keyword: String
        /// The simple name. For `extension Foo.Bar` this is `Bar`.
        let name: String
        /// Nesting-qualified, so a same-named type elsewhere is a different site.
        let qualifiedName: String
        /// Index into the scanned file list.
        let file: Int
        let line: Int
        /// Index of the keyword, used to find the enclosing declaration.
        let start: Int
        /// The conformance clause, between the name and the opening brace.
        let inheritance: Range<Int>
        /// Between the braces, exclusive.
        let body: Range<Int>
    }

    /// The maximal identifier run starting at `index`, and the index just past it.
    static func identifierRun(in chars: [Character], at index: Int) -> (text: String, end: Int) {
        var end = index
        while end < chars.count, SwiftSourceLexer.isIdentifierCharacter(chars[end]) { end += 1 }
        return (String(chars[index..<end]), end)
    }

    static func skippingWhitespace(in chars: [Character], from index: Int) -> Int {
        var i = index
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        return i
    }

    /// The delimiter closing the one at `openIndex`, or nil if the file ends first.
    /// Safe over the code view, where literals and comments are blanked.
    static func matchingDelimiter(in chars: [Character], openAt openIndex: Int,
                                  open: Character, close: Character) -> Int? {
        var depth = 0
        var i = openIndex
        while i < chars.count {
            if chars[i] == open { depth += 1 }
            if chars[i] == close {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    /// Every declaration in a code view, at any nesting depth.
    static func declarationSites(in chars: [Character], file: Int) -> [DeclarationSite] {
        var sites: [DeclarationSite] = []
        var previousToken = ""
        var line = 1
        var i = 0
        while i < chars.count {
            let character = chars[i]
            if character == "\n" {
                line += 1
                i += 1
                continue
            }
            guard SwiftSourceLexer.isIdentifierCharacter(character) else {
                i += 1
                continue
            }
            let (token, tokenEnd) = identifierRun(in: chars, at: i)
            // `import class AppKit.NSColor` is rule 1's business, not a declaration.
            if typeDeclarationKeywords.contains(token), previousToken != "import" {
                let nameStart = skippingWhitespace(in: chars, from: tokenEnd)
                let (spelled, nameEnd) = identifierRun(in: chars, at: nameStart)
                let rawName = spelled.replacingOccurrences(of: "`", with: "")
                if !rawName.isEmpty {
                    var scan = nameEnd
                    var open: Int?
                    // A declaration head runs to its `{`; `;`, `}` or a lone `=` mean it
                    // was not one. `==`, `>=`, `<=`, `!=` are `where` operators.
                    while scan < chars.count {
                        let c = chars[scan]
                        if c == "{" { open = scan; break }
                        if c == ";" || c == "}" { break }
                        if c == "=" {
                            let nextIsEquals = scan + 1 < chars.count && chars[scan + 1] == "="
                            let previous: Character? = scan > 0 ? chars[scan - 1] : nil
                            let isComparison = nextIsEquals
                                || previous.map { "=!<>".contains($0) } ?? false
                            if !isComparison { break }
                        }
                        scan += 1
                    }
                    if let open, let close = matchingDelimiter(in: chars, openAt: open,
                                                               open: "{", close: "}") {
                        // Discovery is outermost first, so the last match encloses.
                        let prefix = sites.reversed().first { $0.body.contains(i) }
                            .map { $0.qualifiedName + "." } ?? ""
                        sites.append(DeclarationSite(
                            keyword: token,
                            name: rawName.split(separator: ".").last.map(String.init) ?? rawName,
                            qualifiedName: prefix + rawName,
                            file: file, line: line, start: i,
                            inheritance: nameEnd..<open,
                            body: (open + 1)..<close))
                    }
                }
            }
            previousToken = token
            i = tokenEnd
        }
        return sites
    }

    /// The names an inheritance clause mentions, last dotted component only.
    /// Identifier runs, not substring, so `ExpressibleByCodableLiteral` is no
    /// conformance; a generic `<T: Codable>` counts.
    static func conformanceNames(in clause: String) -> Set<String> {
        let chars = Array(clause)
        var names: Set<String> = []
        var i = 0
        while i < chars.count {
            guard SwiftSourceLexer.isIdentifierCharacter(chars[i]) else {
                i += 1
                continue
            }
            let (run, end) = identifierRun(in: chars, at: i)
            if let last = run.split(separator: ".").last {
                names.insert(String(last).replacingOccurrences(of: "`", with: ""))
            }
            i = end
        }
        return names
    }

    /// One `init` in a scanned body; `self.init(…)` does not match, since `.` is an
    /// identifier character and makes it one token.
    struct InitialiserSignature {
        let throwing: Bool
        let failable: Bool
        /// `init(from decoder: any Decoder)` — label and type both.
        let decoder: Bool
    }

    static func initialiserSignatures(in chars: [Character]) -> [InitialiserSignature] {
        var found: [InitialiserSignature] = []
        var i = 0
        while i < chars.count {
            guard SwiftSourceLexer.isIdentifierCharacter(chars[i]) else {
                i += 1
                continue
            }
            let (token, tokenEnd) = identifierRun(in: chars, at: i)
            i = tokenEnd
            guard token == "init" else { continue }

            var cursor = skippingWhitespace(in: chars, from: tokenEnd)
            let failable = cursor < chars.count && (chars[cursor] == "?" || chars[cursor] == "!")
            if failable { cursor = skippingWhitespace(in: chars, from: cursor + 1) }
            // `init<T>(…)`: angle brackets skipped textually — they hold no `(`.
            if cursor < chars.count, chars[cursor] == "<" {
                while cursor < chars.count, chars[cursor] != ">" { cursor += 1 }
                cursor = skippingWhitespace(in: chars, from: min(cursor + 1, chars.count))
            }
            guard cursor < chars.count, chars[cursor] == "(",
                  let closeParen = matchingDelimiter(in: chars, openAt: cursor,
                                                     open: "(", close: ")") else { continue }

            // The first parameter, whole: up to the first top-level comma.
            var depth = 0
            var parameterEnd = closeParen
            var scan = cursor + 1
            while scan < closeParen {
                let c = chars[scan]
                if c == "(" || c == "[" || c == "<" { depth += 1 }
                if c == ")" || c == "]" || c == ">" { depth -= 1 }
                if c == ",", depth == 0 {
                    parameterEnd = scan
                    break
                }
                scan += 1
            }
            let parameter = String(chars[(cursor + 1)..<max(cursor + 1, parameterEnd)])

            // Both halves: label `from` and a type naming `Decoder`. `init(from data:
            // Data) throws` coexists with the synthesised decoder init.
            let labelStart = skippingWhitespace(in: chars, from: cursor + 1)
            let (label, _) = identifierRun(in: chars, at: labelStart)
            let decoder = label == "from" && conformanceNames(in: parameter).contains("Decoder")

            // Effects specifiers sit between `)` and `{`; `rethrows` does not count.
            var throwing = false
            var effects = closeParen + 1
            while effects < chars.count, chars[effects] != "{" {
                if SwiftSourceLexer.isIdentifierCharacter(chars[effects]) {
                    let (word, wordEnd) = identifierRun(in: chars, at: effects)
                    if word == "throws" { throwing = true }
                    effects = wordEnd
                } else {
                    effects += 1
                }
            }
            found.append(InitialiserSignature(throwing: throwing, failable: failable, decoder: decoder))
        }
        return found
    }

    struct DecodeValidationViolation {
        let type: String
        let file: Int
        let line: Int
        let reason: String
    }

    /// Rule 8 over a whole target: a type's declaration, its `Codable` extension and
    /// its decoder init may each be in a different file. Blind across targets.
    static func decodeValidationViolations(inFiles files: [[Character]]) -> [DecodeValidationViolation] {
        var sites: [DeclarationSite] = []
        for (index, chars) in files.enumerated() {
            sites += declarationSites(in: chars, file: index)
        }

        // `Codable`, `Decodable`, and every target protocol transitively inheriting one.
        var codable: Set<String> = ["Codable", "Decodable"]
        var protocolParents: [String: Set<String>] = [:]
        for site in sites where site.keyword == "protocol" {
            let clause = conformanceNames(in: String(files[site.file][site.inheritance]))
            protocolParents[site.name, default: []].formUnion(clause)
        }
        var widened = true
        while widened {
            widened = false
            for (name, parents) in protocolParents
            where !codable.contains(name) && !parents.isDisjoint(with: codable) {
                codable.insert(name)
                widened = true
            }
        }

        /// A declaration's text with nested bodies removed, so an inner type's
        /// validating initialiser is not read as the outer type's.
        func ownText(of site: DeclarationSite) -> String {
            let chars = files[site.file]
            let nested = sites.filter { $0.file == site.file && $0.body != site.body
                && site.body.lowerBound <= $0.body.lowerBound
                && $0.body.upperBound <= site.body.upperBound }
            var text = ""
            var cursor = site.body.lowerBound
            for inner in nested.sorted(by: { $0.body.lowerBound < $1.body.lowerBound })
            where inner.body.lowerBound >= cursor {
                text += String(chars[cursor..<inner.body.lowerBound])
                cursor = inner.body.upperBound
            }
            if cursor < site.body.upperBound { text += String(chars[cursor..<site.body.upperBound]) }
            return text
        }

        var violations: [DecodeValidationViolation] = []
        var alreadyReported: Set<String> = []
        for site in sites where site.keyword != "extension" && site.keyword != "protocol" {
            guard !alreadyReported.contains(site.qualifiedName) else { continue }

            let related = sites.filter { $0.qualifiedName == site.qualifiedName }
            // "\n;\n" so two chunks cannot weld into one token or one call.
            let text = related.map(ownText(of:)).joined(separator: "\n;\n")
            let clause = related.reduce(into: Set<String>()) {
                $0.formUnion(conformanceNames(in: String(files[$1.file][$1.inheritance])))
            }
            guard !clause.isDisjoint(with: codable) else { continue }

            let signatures = initialiserSignatures(in: Array(text))
            guard !signatures.contains(where: \.decoder) else { continue }

            var reasons: [String] = []
            if signatures.contains(where: \.throwing) { reasons.append("a throwing initialiser") }
            if signatures.contains(where: \.failable) { reasons.append("a failable initialiser") }
            if text.contains("precondition(") { reasons.append("a precondition") }
            guard !reasons.isEmpty else { continue }

            alreadyReported.insert(site.qualifiedName)
            violations.append(DecodeValidationViolation(
                type: site.qualifiedName,
                file: site.file,
                line: site.line,
                reason: reasons.joined(separator: " and ")))
        }
        return violations
    }

    // MARK: - Driver

    static func value(of flag: String, in arguments: [String]) -> String? {
        values(of: flag, in: arguments).first
    }

    /// Every value of a repeatable flag, in order; `--allow` repeats per dependency.
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

    // MARK: - Rules 2 and 4: substring, not tokens
    // Rule 1 is structural and needs the token stream; rules 2 and 4 are textual,
    // where substring catches strictly more. All three scan the code view.

    static func run(arguments: [String]) -> Int32 {
        var failed = false

        // Rule 8's exemption list switched off — stricter, never laxer — so a test can
        // ask the real binary which types still violate.
        let ignoringDecodeValidationExemptions =
            arguments.contains("--ignore-decode-validation-exemptions")

        // Headless mode disables rule 1's allow-list and rule 2's CG ban — the tier is
        // the conversion boundary — and bans frameworks needing a window or running app.
        let headlessMode = value(of: "--mode", in: arguments) == "headless"
        let banned = Set(values(of: "--ban", in: arguments))
        func report(_ file: String, _ line: Int, _ message: String) {
            FileHandle.standardError.write(Data("\(file):\(line): error: \(message)\n".utf8))
            failed = true
        }

        // Rule 4: no manifest may declare a package dependency, which keeps rule 1's
        // allow-list complete. Scans every `Package*.swift` — SwiftPM prefers a
        // versioned manifest over `Package.swift`.
        if let manifestDir = value(of: "--manifests", in: arguments) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: manifestDir))?.sorted() ?? []
            for name in names where name.hasPrefix("Package") && name.hasSuffix(".swift") {
                let path = manifestDir + "/" + name
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                for (index, line) in SwiftSourceLexer.codeViewLines(of: text).enumerated() where line.contains(".package(") {
                    report(path, index + 1,
                           "the package must declare no package dependencies. This is what keeps rule 1's import allow-list complete; see ARCHITECTURE.md D6.")
                }
            }
        }

        guard let targetName = value(of: "--target-name", in: arguments),
              let sources = value(of: "--sources", in: arguments) else {
            // A manifest-only invocation has nothing further to check.
            guard value(of: "--manifests", in: arguments) != nil else {
                return fail("usage: architecture-checker --target-name <name> --sources <dir> [--allow <module>]… [--mode headless --ban <module>…] [--manifests <dir>] [--touch <stamp>] [--ignore-decode-validation-exemptions]")
            }
            return failed ? 1 : 0
        }

        // The plugin always passes `--allow`, one per declared dependency; only hand or
        // test invocations fall back to the table, where an unknown target is fatal.
        let explicit = values(of: "--allow", in: arguments)
        var allowed: Set<String> = alwaysAllowed
        if headlessMode {
            // A deny-list mode with an empty deny-list is a vacuous pass.
            guard !banned.isEmpty else {
                return fail("--mode headless with no --ban: a guard that bans nothing is not a guard. Pass --ban AppKit --ban SwiftUI.")
            }
        } else if explicit.isEmpty {
            guard let edges = declaredEdges[targetName] else {
                return fail("unknown target '\(targetName)' and no --allow given. Known: \(declaredEdges.keys.sorted().joined(separator: ", ")). Add it to declaredEdges in architecture-checker, or pass --allow.")
            }
            allowed = edges.union(alwaysAllowed)
        } else {
            allowed = Set(explicit).union(alwaysAllowed)
        }

        // Every I/O failure below is a hard error: unreadable never means compliant.
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

        // Banked for rule 8, which cannot answer from one file.
        var rule8Paths: [String] = []
        var rule8Files: [[Character]] = []

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

            let lines = SwiftSourceLexer.codeViewLines(of: text)

            if headlessMode {
                for (module, line) in importedModules(in: lines) where banned.contains(module) {
                    report(path, line,
                           "'\(module)' may not be imported from \(targetName). This target's invariant is that `swift test` can run it on a developer machine with no window and no running app; \(module) is how that stops being true. See the Phase 3A-1 design, § 2.")
                }
            } else {
                for (module, line) in importedModules(in: lines)
                where !allowed.contains(module) {
                    report(path, line,
                           "'\(module)' is not importable from \(targetName). Allowed: \(allowed.sorted().joined(separator: ", ")). See ARCHITECTURE.md D6.")
                }
            }

            // Rule 2: CG geometry types banned package-wide, except in headless mode,
            // the conversion boundary. Plain `contains` is deliberate.
            if !headlessMode {
                for (index, line) in lines.enumerated() {
                    for banned in bannedCGTypes where line.contains(banned) {
                        report(path, index + 1,
                               "'\(banned)' may not appear in the package. Convert at the boundary; see ARCHITECTURE.md D3.")
                    }
                }
            }

            rule8Paths.append(path)
            rule8Files.append(Array(lines.joined(separator: "\n")))
        }

        guard swiftFileCount > 0 else {
            return fail("no .swift files under \(sources) for target \(targetName). A vacuous pass is not a pass.")
        }

        // Rule 8, target-wide: the three pieces may each be in a different file.
        for violation in decodeValidationViolations(inFiles: rule8Files)
        where ignoringDecodeValidationExemptions
            || !(decodeValidationExemptTypes.contains(violation.type)
                 || decodeValidationExemptTypes.contains(
                        violation.type.split(separator: ".").last.map(String.init) ?? violation.type)) {
            report(rule8Paths[violation.file], violation.line,
                   """
                   '\(violation.type)' has \(violation.reason) and a Codable/Decodable \
                   conformance, but no explicit 'init(from decoder:)'. The synthesised one \
                   assigns stored properties directly and never calls your initialiser, so \
                   the invariant holds everywhere except the path carrying untrusted input. \
                   Write 'init(from decoder: any Decoder) throws' and validate there — a \
                   precondition on decoded input is the wrong instrument, it turns a corrupt \
                   file into a crash. See ARCHITECTURE.md D6 rule 8 and the Phase 2 design \
                   doc's D2-14.
                   """)
        }

        guard !failed else { return 1 }

        // Stamp written only on success: one left by a violating build would make
        // SwiftPM skip the command on the next incremental build.
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
