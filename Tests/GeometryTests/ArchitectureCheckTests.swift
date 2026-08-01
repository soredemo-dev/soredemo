import Testing
import Foundation

/// …/Tests/GeometryTests/ArchitectureCheckTests.swift → the repository root.
let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The six library targets the plugin must be attached to.
let libraryModules = ["Geometry", "Timeline", "Graph", "Framing", "Variants", "Project"]

/// Launches the real built checker. Never reimplement the checking logic
/// in-process — that tests the test.
func launchChecker(targetName: String,
                   sourcesPath: String,
                   allow: [String] = []) throws -> (status: Int32, stderr: String) {
    let checker = repositoryRoot.appending(path: ".build/debug/architecture-checker")
    try #require(FileManager.default.fileExists(atPath: checker.path(percentEncoded: false)),
                 "architecture-checker not built at \(checker.path(percentEncoded: false))")

    let process = Process()
    process.executableURL = checker
    process.arguments = ["--target-name", targetName, "--sources", sourcesPath]
        + allow.flatMap { ["--allow", $0] }
    let err = Pipe()
    process.standardError = err
    try process.run()
    let data = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Runs the checker over a temporary fixture directory built by `populate`.
func runChecker(targetName: String = "Geometry",
                allow: [String] = [],
                populate: (URL) throws -> Void) throws -> (status: Int32, stderr: String) {
    let dir = URL(filePath: NSTemporaryDirectory())
        .appending(path: "arch-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try populate(dir)
    return try launchChecker(targetName: targetName,
                             sourcesPath: dir.path(percentEncoded: false),
                             allow: allow)
}

/// Runs the checker over a fixture directory holding one `Probe.swift`.
func runChecker(targetName: String = "Geometry",
                allow: [String] = [],
                source: String) throws -> (status: Int32, stderr: String) {
    try runChecker(targetName: targetName, allow: allow) { dir in
        try source.write(to: dir.appending(path: "Probe.swift"), atomically: true, encoding: .utf8)
    }
}

/// Rule 4 helper: writes the given manifest files into a fresh temp directory
/// and invokes the real built checker with `--manifests <dir>` alone — the
/// same shape a manifest-only invocation of the checker takes.
func runManifestChecker(files: [String: String]) throws -> (status: Int32, stderr: String) {
    let dir = URL(filePath: NSTemporaryDirectory())
        .appending(path: "arch-manifests-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for (name, contents) in files {
        try contents.write(to: dir.appending(path: name), atomically: true, encoding: .utf8)
    }

    let checker = repositoryRoot.appending(path: ".build/debug/architecture-checker")
    try #require(FileManager.default.fileExists(atPath: checker.path(percentEncoded: false)),
                 "architecture-checker not built at \(checker.path(percentEncoded: false))")

    let process = Process()
    process.executableURL = checker
    process.arguments = ["--manifests", dir.path(percentEncoded: false)]
    let err = Pipe()
    process.standardError = err
    try process.run()
    let data = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

let manifestWithoutDependency = """
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Fixture",
    targets: [
        .target(name: "Fixture"),
    ]
)
"""

let manifestWithDependency = """
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Fixture",
    dependencies: [.package(path: "/tmp/LocalDep")],
    targets: [
        .target(name: "Fixture"),
    ]
)
"""

// MARK: - must be REJECTED

@Test(arguments: [
    "import AppKit",
    "@preconcurrency import AppKit",
    "@testable import AppKit",
    "@_exported import AppKit",
    "@preconcurrency @_exported import AppKit",
    // SE-0409 access-level modifiers. These are the IDIOMATIC Swift 6 spellings,
    // pushed further by the InternalImportsByDefault upcoming feature, and a
    // naive attribute-only strip lets every one of them through.
    "public import AppKit",
    "internal import AppKit",
    "package import AppKit",
    "fileprivate import AppKit",
    "private import AppKit",
    "@preconcurrency public import AppKit",
    "import AppKit; import Foundation",
    "import Foundation; import AppKit",
    "import class AppKit.NSColor",
    "import\tAppKit",
    "import AppKit //trailing comment",
    "#if canImport(AppKit)\nimport AppKit\n#endif",
    "import ScreenCaptureKit",
])
func rejectsDisallowedImport(_ line: String) throws {
    let result = try runChecker(source: line)
    #expect(result.status == 1, "should reject: \(line)")
    #expect(!result.stderr.isEmpty)
}

/// Real code hidden behind a literal or comment construct that a line-local or
/// naive scanner mis-tracks. Each of these ends the literal/comment correctly,
/// so the trailing `import AppKit` is genuine code and must be caught.
@Test(arguments: [
    // A `//` inside a string literal must not start a comment.
    ##"let s = "//"; import AppKit"##,
    // Interpolation body is CODE; closing it must return to string state and then close.
    ##"let s = "\(Date())"; import AppKit"##,
    // Raw-string interpolation: the pound count in \#( must match the delimiter.
    ##"let s = #"\#(Date())"#; import AppKit"##,
    // In a raw string `\(` is literal text — no interpolation is opened, so the
    // string still closes at the first `"#`.
    ##"let s = #"a \(b) c"#; import AppKit"##,
    // Nested interpolation, nested parens.
    ##"let s = "\("\(Date())")"; import AppKit"##,
    // Multiline string: string state must survive newlines AND terminate.
    "let s = \"\"\"\nnot code\n\"\"\"\nimport AppKit",
    // A quote inside a line comment must not open string state for the rest of the file.
    "// he said \"hi\nimport AppKit",
    // Escaped backslash: the string DOES end at the following quote.
    ##"let s = "a \\"; import AppKit"##,
    // Raw multiline string, correctly closed.
    "let s = #\"\"\"\nnot code\n\"\"\"#\nimport AppKit",
])
func rejectsImportHiddenBehindLiterals(_ source: String) throws {
    let result = try runChecker(source: source)
    #expect(result.status == 1, "should reject: \(source)")
    #expect(!result.stderr.isEmpty)
}

/// Spellings NOT in the original evasion list, found by probing `swiftc -typecheck`
/// during Task 2. `import` + newline + module fully typechecks and grants access to
/// the module's API, so a line-local statement scan lets AppKit straight in.
@Test(arguments: [
    "import\nAppKit",
    "import\n\nAppKit",
    "import class\nAppKit.NSColor",
    "public import\nAppKit",
    "@preconcurrency\npublic import AppKit",
    "import `AppKit`",
])
func rejectsImportSpelledUnusually(_ source: String) throws {
    let result = try runChecker(source: source)
    #expect(result.status == 1, "should reject: \(source)")
    #expect(!result.stderr.isEmpty)
}

/// `file:line:` is the contract. A `\` line continuation inside a `"""` literal
/// must not swallow its newline, or every reported line after it drifts by one,
/// compounding with each continuation.
@Test func reportsAccurateLineNumberAfterStringLineContinuation() throws {
    let source = "let s = \"\"\"\na \\\nb\n\"\"\"\nimport AppKit"   // import is on line 5
    let result = try runChecker(source: source)
    #expect(result.status == 1)
    #expect(result.stderr.contains(":5: error:"),
            "line number drifted: \(result.stderr)")
}

/// The same contract for the regex frame. A guard that exists in one branch and
/// not its sibling is a guard that gets deleted by whoever tidies next, so both
/// branches are pinned.
@Test func reportsAccurateLineNumberAfterRegexLineContinuation() throws {
    let source = "public let r = #/\n  a\\\n  b\n/#\nimport AppKit"   // import is on line 5
    let result = try runChecker(source: source)
    #expect(result.status == 1)
    #expect(result.stderr.contains(":5: error:"),
            "line number drifted: \(result.stderr)")
}

/// Separators Swift accepts between `import` and the module name that a
/// space/tab/newline tokenizer does not. Each of these was verified to typecheck
/// under `swiftc` with `public func probeUse() -> NSColor { NSColor.red }`
/// appended — the module really is imported and its API resolves — while the
/// checker exited 0. Form feed is the dangerous one: invisible in every diff
/// viewer and on GitHub, and one `printf` to introduce.
///
/// The fix is not a longer separator list. Tokens are maximal *identifier* runs,
/// so every separator closes at once, including U+00A0 and whatever comes next.
@Test(arguments: [
    "import\u{000C}AppKit",             // FORM FEED
    "import\u{000B}AppKit",             // VERTICAL TAB
    "\u{000C}import AppKit",            // leading FORM FEED
    "public import\u{000C}AppKit",      // FORM FEED after the SE-0409 access level
    "import\u{00A0}AppKit",             // NO-BREAK SPACE (found in this round)
    "import\u{000D}AppKit",             // lone CARRIAGE RETURN
    "@_spi(A)@_spi(B)import AppKit",    // `)` terminates a token in Swift, so no space is needed
    "@available(macOS 26, *)\u{000C}import AppKit",
])
func rejectsImportBehindExoticSeparators(_ source: String) throws {
    let result = try runChecker(source: source)
    #expect(result.status == 1, "should reject: \(source.debugDescription)")
    #expect(!result.stderr.isEmpty)
}

/// Swift terminates the `import` keyword at a backtick, so no space is needed
/// before an escaped module name. Each of these typechecks clean — `NSColor`
/// resolves — and they are one keystroke from `import \`AppKit\``, which was
/// already caught. The backtick is in `isIdentifierCharacter` so that escaped
/// module names survive as one token; that is exactly what welded it to the
/// keyword, so the tokenizer has to flush at a backtick and keep it.
@Test(arguments: [
    "import`AppKit`",
    "public import`AppKit`",
    "@_spi(A)import`AppKit`",
    "@preconcurrency public import`ScreenCaptureKit`",
])
func rejectsBacktickGluedImport(_ source: String) throws {
    let result = try runChecker(source: source)
    #expect(result.status == 1, "should reject: \(source)")
    #expect(!result.stderr.isEmpty)
}

/// Sibling edges have the same hole — the allow-list is consulted with the same
/// token, so a bypass in the tokenizer is a bypass for F2 as well as F1.
@Test func rejectsBacktickGluedSiblingImport() throws {
    let result = try runChecker(targetName: "Framing", source: "import`Timeline`")
    #expect(result.status == 1, "Framing does not declare Timeline\nstderr: \(result.stderr)")
}

/// Lexical constructs in which a `"` is ORDINARY CONTENT, so a scanner that does
/// not model them opens a string frame on source that compiles clean.
///
/// SE-0451 raw identifiers (Swift 6.2; this toolchain is 6.4) and extended regex
/// literals `#/…/#` are both such constructs. `"""` inside either one is worse
/// than `"`: the frame it opens is MULTILINE, which the defensive force-close
/// deliberately declines to close, so it blanks the remainder of the file and the
/// import does not even need to share a line. `/*` inside a raw identifier does
/// the same through the block-comment frame.
///
/// Every one of these was verified to typecheck under `swiftc` with
/// `public func probeUse() -> NSColor { NSColor.red }` appended.
@Test(arguments: [
    ##"public let `a"b` = 1; import AppKit"##,
    "public let `a\"\"\"b` = 1\nimport AppKit",
    "public let `a/*b` = 1\nimport AppKit",
    "public let `a#\"b` = 1\nimport AppKit",
    ##"public let r = #/a"b/#; import AppKit"##,
    "public let r = #/a\"\"\"b/#\nimport AppKit",
    ##"public let r = ##/a"b/##; import AppKit"##,
    "public let r = #/\n  a\"\"\"b\n/#\nimport AppKit",
])
func rejectsImportHiddenBehindRawIdentifierOrRegex(_ source: String) throws {
    let result = try runChecker(source: source)
    #expect(result.status == 1, "should reject: \(source.debugDescription)")
    #expect(!result.stderr.isEmpty)
}

/// The same construction defeats the sibling-edge rule, not just the
/// Foundation-only rule — both consult the same token stream.
@Test func rejectsSiblingImportHiddenBehindRawIdentifier() throws {
    let result = try runChecker(targetName: "Framing",
                                source: "public let `a\"\"\"b` = 1\nimport Timeline")
    #expect(result.status == 1, "Framing does not declare Timeline\nstderr: \(result.stderr)")
}

/// Swift ends a `//` comment at a lone CR and compiles what follows. A scanner
/// that only ends line comments at LF blanks the import — and everything else up
/// to the next LF, so the blast radius is a whole line, not one token.
///
/// FF, VT, NEL, U+2028 and U+2029 do NOT end a Swift line comment (verified: the
/// import stays commented out and `NSColor` does not resolve), so they must stay
/// on the accepted side — see `acceptsLineCommentsThatDoNotEnd`.
@Test func rejectsImportAfterCarriageReturnInLineComment() throws {
    let result = try runChecker(source: "// note\u{000D}import AppKit")
    #expect(result.status == 1)
    #expect(result.stderr.contains("AppKit"))
}

// MARK: - must be ACCEPTED

@Test(arguments: [
    "import Foundation",
    // The same access-level forms on a LEGITIMATE module must not be false-positived —
    // a Swift 6 library author writes these routinely.
    "internal import Foundation",
    "public import Foundation",
    "// import AppKit",
    "/* import AppKit */",
    "import Foundation /* used for Date */",
    #"let s = "import AppKit is banned""#,
])
func acceptsLegitimateSource(_ line: String) throws {
    let result = try runChecker(source: line)
    #expect(result.status == 0, "should accept: \(line)\nstderr: \(result.stderr)")
}

/// String content and comment text are not code. None of these may be false-positived.
@Test(arguments: [
    // A raw string contains NO interpolation: `\(` is literal text.
    ##"let s = #"a \(b) c"#"##,
    // Multiline string content is content, across newlines.
    "let s = \"\"\"\nimport AppKit\n\"\"\"",
    // Swift block comments nest.
    "/* /* nested */ import AppKit */",
    ##"let s = #"import AppKit"#"##,
    // An escaped quote does not close the string.
    ##"let s = "a \" import AppKit""##,
    // Raw multiline string.
    "let s = #\"\"\"\nimport AppKit\n\"\"\"#",
    // Interpolation body is code, but a string literal *inside* it is still content.
    ##"let s = "\("import AppKit")""##,
])
func acceptsLiteralsAndComments(_ source: String) throws {
    let result = try runChecker(source: source)
    #expect(result.status == 0, "should accept: \(source)\nstderr: \(result.stderr)")
}

/// `import` appearing as something other than an import declaration, and a
/// legitimate module spelled unusually. Neither may be false-positived.
@Test(arguments: [
    "import `Foundation`",
    // A backtick-escaped `import` is an IDENTIFIER, not the keyword. Flushing the
    // token run at a backtick must not turn it back into one.
    "public let `import` = 1",
    "let `import` = 1; let `AppKit` = 2",
    "let importAppKit = 1",
    "let x = AppKitImporter()",
    "#if canImport(AppKit)\nimport Foundation\n#endif",
    "#if canImport( AppKit )\nimport Foundation\n#endif",
    "func doImport() { }",
])
func acceptsNonImportsThatLookLikeImports(_ source: String) throws {
    let result = try runChecker(source: source)
    #expect(result.status == 0, "should accept: \(source)\nstderr: \(result.stderr)")
}

/// Characters that are NOT line terminators for Swift: a `//` comment runs
/// straight through them, so the import stays commented out. Treating them as
/// newlines would both false-positive here and drift every reported line number
/// away from the compiler's.
@Test(arguments: [
    "// note\u{000C}import AppKit",     // FORM FEED
    "// note\u{000B}import AppKit",     // VERTICAL TAB
    "// note\u{0085}import AppKit",     // NEXT LINE
    "// note\u{2028}import AppKit",     // LINE SEPARATOR
    "// note\u{2029}import AppKit",     // PARAGRAPH SEPARATOR
])
func acceptsLineCommentsThatDoNotEnd(_ source: String) throws {
    let result = try runChecker(source: source)
    #expect(result.status == 0, "should accept: \(source.debugDescription)\nstderr: \(result.stderr)")
}

/// THE REASON THIS ROUND EXISTS. A raw identifier is one token and its interior
/// is not code; splitting it on its interior spaces reports
/// "'work' is not importable" for `` `does import work` ``.
///
/// This is not hypothetical. SE-0451 raw identifiers exist primarily so that test
/// names can be sentences, and this package is tested with Swift Testing — so a
/// suite about the import rule naturally contains names like
/// `` @Test func `rejects import AppKit`() ``. The measured trigger is: a raw
/// identifier containing `import` NOT at the start, followed by a word that is not
/// an allowed module. When `import` is first the round-2 backtick flush left the
/// delimiter attached and it passed — by luck, not by logic.
///
/// Regex literal content is not code either, and `#/import AppKit/#` is exactly
/// what a tool that greps for imports would contain.
@Test(arguments: [
    "public func `does import work`() -> Int { 1 }",
    "public func `test import handling`() {}",
    "public func `rejects import AppKit`() {}",
    "@Test func `allows a declared sibling import`() {}",
    "@Test func `rejects import ScreenCaptureKit from Geometry`() {}",
    "public let `import Foundation is allowed` = 1",
    "public let `a//b` = 1",
    "public let `a/*b` = 1",
    ##"public let `a"b` = 1"##,
    "public let `import AppKit` = 1",
    ##"public let r = #/import AppKit/#"##,
    ##"public let r = #/a"b/#"##,
    "public let r = #/\n  import AppKit\n/#",
])
func acceptsRawIdentifiersAndRegexLiterals(_ source: String) throws {
    let result = try runChecker(source: source)
    #expect(result.status == 0, "should accept: \(source.debugDescription)\nstderr: \(result.stderr)")
}

// MARK: - the allow-list is the manifest

/// Direct declared edges only. The transitive closure would let `Framing` import
/// `Timeline` and `Variants` import `Geometry` — undeclared edges that SwiftPM
/// itself degrades to a warning on a warm `.build`, so nothing else catches them.
@Test func rejectsTransitiveButUndeclaredEdge() throws {
    let framing = try runChecker(targetName: "Framing", source: "import Timeline")
    #expect(framing.status == 1, "Framing does not declare Timeline\nstderr: \(framing.stderr)")

    let variants = try runChecker(targetName: "Variants", source: "import Geometry")
    #expect(variants.status == 1, "Variants does not declare Geometry\nstderr: \(variants.stderr)")
}

/// Dependencies as declared in `Package.swift`, parsed from the manifest text so
/// this test cannot drift away from it.
func declaredDependencies(of module: String, inManifest manifest: String) throws -> Set<String> {
    let declaration = try #require(
        manifest.split(separator: "\n").first { $0.contains(".target(name: \"\(module)\"") },
        "no .target declaration for \(module) in Package.swift")
    guard let open = declaration.range(of: "dependencies: ["),
          let close = declaration[open.upperBound...].firstIndex(of: "]") else { return [] }
    return Set(declaration[open.upperBound..<close]
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
        .filter { !$0.isEmpty })
}

/// Every sibling pair, checked against what the manifest actually declares. This
/// is what stops the checker's fallback table from silently mirroring the wrong
/// graph — in a real build the plugin passes the edges from PluginContext, so
/// there is nothing to mirror at all.
@Test func fallbackAllowListMatchesManifestEdges() throws {
    let manifest = try String(contentsOf: repositoryRoot.appending(path: "Package.swift"),
                              encoding: .utf8)
    for module in libraryModules {
        let declared = try declaredDependencies(of: module, inManifest: manifest)
        for sibling in libraryModules where sibling != module {
            let result = try runChecker(targetName: module, source: "import \(sibling)")
            if declared.contains(sibling) {
                #expect(result.status == 0,
                        "\(module) declares \(sibling) but the checker rejected it\nstderr: \(result.stderr)")
            } else {
                #expect(result.status == 1,
                        "\(module) does NOT declare \(sibling), but the checker allowed it")
            }
        }
    }
}

/// What the plugin actually does: pass the declared edges on the command line.
@Test func explicitAllowFlagsOverrideTheFallbackTable() throws {
    let allowed = try runChecker(targetName: "Geometry", allow: ["Graph"], source: "import Graph")
    #expect(allowed.status == 0, "stderr: \(allowed.stderr)")

    let stillBanned = try runChecker(targetName: "Geometry", allow: ["Graph"], source: "import AppKit")
    #expect(stillBanned.status == 1)

    let foundationAlways = try runChecker(targetName: "Geometry", allow: ["Graph"],
                                          source: "import Foundation")
    #expect(foundationAlways.status == 0, "stderr: \(foundationAlways.stderr)")
}

/// Deleting `plugins: archCheck` from a target silently voids rule 1 for it —
/// no build failure, no diagnostic. This is the phase's largest silent-void risk.
///
/// Asserted against the RESOLVED manifest rather than its text, so it also catches
/// `archCheck` being redefined to `[]` and `archCheck` being repointed at some
/// other plugin — neither of which a grep for `plugins: archCheck` would notice.
/// A separate `--scratch-path` keeps this off the `.build` directory the enclosing
/// `swift test` is holding.
@Test func everyLibraryTargetUsesTheCheckerPluginInTheResolvedManifest() throws {
    let scratch = URL(filePath: NSTemporaryDirectory())
        .appending(path: "dump-\(ProcessInfo.processInfo.globallyUniqueString)")
    defer { try? FileManager.default.removeItem(at: scratch) }

    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = ["swift", "package", "dump-package",
                         "--scratch-path", scratch.path(percentEncoded: false)]
    process.currentDirectoryURL = repositoryRoot
    let out = Pipe()
    process.standardOutput = out
    // Drained, not buffered: a Pipe nobody reads blocks the child once it fills.
    // Harmless while the package has no dependencies; a latent hang the moment it does.
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "swift package dump-package failed")

    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let targets = try #require(root["targets"] as? [[String: Any]])

    // EVERY regular target, not a remembered list — a seventh target added without
    // the plugin is precisely the silent void this test exists to prevent. The six
    // known ones are asserted as a floor so the filter cannot quietly match nothing.
    let regular = targets.filter { $0["type"] as? String == "regular" }
    let regularNames = Set(regular.compactMap { $0["name"] as? String })
    #expect(regularNames.isSuperset(of: libraryModules),
            "expected at least \(libraryModules) among the regular targets, got \(regularNames.sorted())")

    for target in regular {
        let name = target["name"] as? String ?? "<unnamed>"
        let usages = target["pluginUsages"] as? [[String: Any]] ?? []
        let plugins = usages.compactMap { ($0["plugin"] as? [Any])?.first as? String }
        #expect(plugins.contains("ArchitectureCheck"),
                "regular target \(name) does not use the ArchitectureCheck plugin — rule 1 is void for it. pluginUsages: \(usages)")
    }

    // The checker's own target must NOT be checked: its source legitimately names
    // the banned modules.
    let checker = try #require(targets.first { $0["name"] as? String == "architecture-checker" })
    let checkerPlugins = (checker["pluginUsages"] as? [[String: Any]] ?? [])
        .compactMap { ($0["plugin"] as? [Any])?.first as? String }
    #expect(!checkerPlugins.contains("ArchitectureCheck"))
}

// MARK: - unreadable must never mean compliant

@Test func failsOnMissingSourcesDirectory() throws {
    let missing = URL(filePath: NSTemporaryDirectory())
        .appending(path: "arch-absent-\(ProcessInfo.processInfo.globallyUniqueString)")
    let result = try launchChecker(targetName: "Geometry",
                                   sourcesPath: missing.path(percentEncoded: false))
    #expect(result.status != 0, "a missing sources directory must not be a silent pass")
    #expect(!result.stderr.isEmpty)
}

@Test func failsOnSourcesDirectoryWithNoSwiftFiles() throws {
    let result = try runChecker { dir in
        try "not swift".write(to: dir.appending(path: "README.md"),
                              atomically: true, encoding: .utf8)
    }
    #expect(result.status != 0, "a vacuous pass is not a pass")
    #expect(!result.stderr.isEmpty)
}

@Test func failsOnUndecodableSwiftFile() throws {
    let result = try runChecker { dir in
        // 0xFF can never appear in valid UTF-8.
        try Data([0xFF, 0xFE, 0x00, 0xFF]).write(to: dir.appending(path: "Probe.swift"))
    }
    #expect(result.status != 0, "a file the checker cannot read is a file it cannot vouch for")
    #expect(!result.stderr.isEmpty)
}

@Test func failsOnUnreadableSwiftFile() throws {
    let result = try runChecker { dir in
        let file = dir.appending(path: "Probe.swift")
        try "import Foundation".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: file.path(percentEncoded: false))
    }
    #expect(result.status != 0)
    #expect(!result.stderr.isEmpty)
}

@Test func failsOnUnknownTargetWithNoAllowFlags() throws {
    let result = try runChecker(targetName: "NotATarget", source: "import Foundation")
    #expect(result.status == 2, "an unknown target must fail closed\nstderr: \(result.stderr)")
}

// MARK: - declared package edges

@Test func allowsDeclaredSiblingImports() throws {
    let result = try runChecker(targetName: "Graph", source: "import Geometry\nimport Timeline")
    #expect(result.status == 0)
}

@Test func rejectsSiblingNotDeclared() throws {
    // Geometry is a leaf; Graph is not among its allowed imports.
    let result = try runChecker(targetName: "Geometry", source: "import Graph")
    #expect(result.status == 1)
}

// MARK: - rule 2: CG geometry types banned from the package

@Test(arguments: [
    "public struct F { public let r: CGRect }",
    "let p = CGPoint(x: 0, y: 0)",
    "func f(_ s: CGSize) {}",
    "let w: CGFloat = 1",
    #"let s = "\(CGRect.zero)""#,           // interpolation is code
    ##"let s = #"\#(CGRect.zero)"#"##,      // raw interpolation is code
])
func rejectsCGType(_ line: String) throws {
    #expect(try runChecker(source: "import Foundation\n\(line)").status == 1)
}

@Test(arguments: [
    "// CGRect is converted at the boundary",
    "/* CGRect belongs in the app */",
    #"let s = "CGRect is banned""#,
    ##"let s = #"CGRect"#"##,
    "let s = \"\"\"\nmentions CGRect on line two\n\"\"\"",
])
func acceptsCGTypeMention(_ line: String) throws {
    let r = try runChecker(source: "import Foundation\n\(line)")
    #expect(r.status == 0, "should accept: \(line)\n\(r.stderr)")
}

// MARK: - rule 4: no manifest may declare a package dependency

@Test func rejectsDependencyInMainManifest() throws {
    #expect(try runManifestChecker(files: ["Package.swift": manifestWithDependency]).status == 1)
}

@Test func rejectsDependencyInVersionSpecificManifest() throws {
    // SwiftPM prefers Package@swift-6.4.swift. Verified: a dependency declared
    // there resolves and builds while Package.swift declares none.
    let result = try runManifestChecker(files: [
        "Package.swift": manifestWithoutDependency,
        "Package@swift-6.4.swift": manifestWithDependency,
    ])
    #expect(result.status == 1)
}

@Test func acceptsCleanManifests() throws {
    #expect(try runManifestChecker(files: ["Package.swift": manifestWithoutDependency]).status == 0)
}

@Test func acceptsPackageMentionInComment() throws {
    let clean = manifestWithoutDependency + "\n// no .package( entries here\n"
    #expect(try runManifestChecker(files: ["Package.swift": clean]).status == 0)
}
