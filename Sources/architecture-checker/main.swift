import CheckerLexer
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

    /// Rule 2: CG geometry types banned from the whole package. The app boundary
    /// is where AppKit/CoreGraphics geometry gets converted to and from this
    /// package's own types (ARCHITECTURE.md D3). Phase 2 will tempt this
    /// constantly — `CGEvent`, `CGDisplayBounds` and AX frames are all `CGRect`
    /// underneath, and the conversion belongs at the app boundary, not in here.
    static let bannedCGTypes = ["CGRect", "CGPoint", "CGSize", "CGFloat"]

    // MARK: - Lexical scan
    //
    // `codeViewLines(of:)` — the code view every text-reading rule below scans —
    // and the `isIdentifierCharacter` predicate it shares with `tokens(of:)` now
    // live in the `CheckerLexer` target, so that checks written outside this
    // executable can ask the same question. A test target cannot import an
    // `executableTarget`, and `Tests/AppSourceTests` needs exactly this view to
    // enforce the app-side allow-lists the plugin cannot reach.

    // MARK: - Import extraction

    struct Token {
        let text: String
        let line: Int
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
                if character == "`" {
                    // Swift TERMINATES a token at a backtick: `import`AppKit`` is
                    // the keyword followed by the escaped identifier `AppKit`, and
                    // it typechecks. Backtick is in
                    // `SwiftSourceLexer.isIdentifierCharacter` so an
                    // escaped module name survives as one token — which is exactly
                    // what would weld it to the keyword. So it both closes the run
                    // before it and opens the run after it, and is retained so that
                    // `import` (the escaped identifier) stays distinguishable from
                    // `import` (the keyword).
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

    /// The module a token names: `AppKit.NSColor` -> AppKit, `` `Foundation` `` ->
    /// Foundation, a lone delimiter -> "".
    static func moduleName(of token: String) -> String {
        let head = token.split(separator: ".").first.map(String.init) ?? token
        return head.replacingOccurrences(of: "`", with: "")
    }

    /// Every module the file imports, with the line its `import` keyword sits on.
    ///
    /// The scan is over TOKENS, not lines. `import` followed by a newline and then
    /// the module name is valid Swift — it typechecks and grants full access to the
    /// module's API (verified with `swiftc -typecheck`) — so any statement scan that
    /// stops at the end of a line lets `import\nAppKit` straight through.
    ///
    /// Tokens are maximal identifier runs, so no whitespace or punctuation glued to
    /// the keyword can hide it — see `SwiftSourceLexer.isIdentifierCharacter`.
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
            // Skip declaration kinds, and any token that strips to nothing (a lone
            // delimiter). Consuming an empty token as "the module name" would let
            // the real one past.
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

    // MARK: - Rules 2 and 4: substring, not tokens — deliberately
    //
    // Rules 2 and 4 below scan `SwiftSourceLexer.codeViewLines` with plain
    // `String.contains`,
    // rather than going through `tokens(of:)` the way rule 1 does. That is not
    // an inconsistency to unify away; it falls out of the two rules asking
    // different KINDS of question.
    //
    // Rule 1 asks "is this an import **declaration**?" — a structural question:
    // whether a keyword sits at the head of a statement, followed by a module
    // name, possibly through access-level and attribute prefixes. Answering
    // that needs the token stream, because the answer depends on grammatical
    // position, not on which characters appear.
    //
    // Rule 2 asks "does this **name** appear?" — a purely textual question. For
    // a textual question, substring is the STRONGER mechanism, not a weaker
    // stand-in for tokens: `contains("CGRect")` matches `` `CGRect` `` — a
    // backtick-escaped identifier that resolves to the exact same declaration
    // as the bare identifier — while token equality would not, because
    // `tokens(of:)` keeps the backticks as part of the token's text (see the
    // backtick-flush note there). Moving rule 2 onto the token stream would
    // narrow what it catches, not simplify it. Rule 4 is the same question
    // about `.package(` in a manifest, for the same reason, with the added
    // fact that `Package.Dependency` has no public initialiser — `.package(`
    // is the only spelling that can ever appear, so there is no grammatical
    // position left to be structural about.
    //
    // Both still scan the code view, not the raw file text, so comment and
    // string CONTENT — where `CGRect` or `.package(` may legitimately be
    // mentioned in prose — does not fire. That part rules 1, 2 and 4 share.

    static func run(arguments: [String]) -> Int32 {
        var failed = false
        func report(_ file: String, _ line: Int, _ message: String) {
            FileHandle.standardError.write(Data("\(file):\(line): error: \(message)\n".utf8))
            failed = true
        }

        // Rule 4: no manifest may declare a package dependency. Runs ahead of,
        // and independently of, the --target-name/--sources requirement below,
        // because manifest health belongs to the package as a whole rather
        // than to any one target. SwiftPM honours `Package@swift-6.4.swift` in
        // preference to `Package.swift` — verified: a dependency declared
        // there resolves and builds while `Package.swift` declares none — so
        // EVERY `Package*.swift` in the manifest directory is scanned, not
        // just `Package.swift`.
        //
        // Rule 4 is what keeps rule 1 honest: rule 1's allow-list is complete
        // only because the package has zero package dependencies to smuggle
        // an unlisted module in through.
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
            // A manifest-only invocation — as issued by tests, and in principle
            // usable standalone — has nothing further to check.
            guard value(of: "--manifests", in: arguments) != nil else {
                return fail("usage: architecture-checker --target-name <name> --sources <dir> [--allow <module>]… [--manifests <dir>] [--touch <stamp>]")
            }
            return failed ? 1 : 0
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

            for (module, line) in importedModules(in: lines)
            where !allowed.contains(module) {
                report(path, line,
                       "'\(module)' is not importable from \(targetName). Allowed: \(allowed.sorted().joined(separator: ", ")). See ARCHITECTURE.md D6.")
            }

            // Rule 2: CG geometry types banned anywhere in the package. See the
            // "substring, not tokens" note above this function for why a plain
            // `contains` over the code view is deliberate here.
            for (index, line) in lines.enumerated() {
                for banned in bannedCGTypes where line.contains(banned) {
                    report(path, index + 1,
                           "'\(banned)' may not appear in the package. Convert at the boundary; see ARCHITECTURE.md D3.")
                }
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
