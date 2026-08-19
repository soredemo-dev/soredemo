import Testing
import Foundation
import CheckerLexer

/// …/Tests/GeometryTests/ArchitectureCheckTests.swift → the repository root.
let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The seven library targets the plugin must be attached to.
let libraryModules = ["Geometry", "Timeline", "Graph", "Framing", "Variants", "Project", "Render"]

/// Launches the real built checker; never reimplement the checking logic in-process.
func launchChecker(targetName: String,
                   sourcesPath: String,
                   allow: [String] = [],
                   additionalArguments: [String] = []) throws -> (status: Int32, stderr: String) {
    let checker = repositoryRoot.appending(path: ".build/debug/architecture-checker")
    try #require(FileManager.default.fileExists(atPath: checker.path(percentEncoded: false)),
                 "architecture-checker not built at \(checker.path(percentEncoded: false))")

    let process = Process()
    process.executableURL = checker
    process.arguments = ["--target-name", targetName, "--sources", sourcesPath]
        + allow.flatMap { ["--allow", $0] } + additionalArguments
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
                additionalArguments: [String] = [],
                populate: (URL) throws -> Void) throws -> (status: Int32, stderr: String) {
    let dir = URL(filePath: NSTemporaryDirectory())
        .appending(path: "arch-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try populate(dir)
    return try launchChecker(targetName: targetName,
                             sourcesPath: dir.path(percentEncoded: false),
                             allow: allow,
                             additionalArguments: additionalArguments)
}

/// Runs the checker over a fixture directory holding one `Probe.swift`.
func runChecker(targetName: String = "Geometry",
                allow: [String] = [],
                source: String) throws -> (status: Int32, stderr: String) {
    try runChecker(targetName: targetName, allow: allow) { dir in
        try source.write(to: dir.appending(path: "Probe.swift"), atomically: true, encoding: .utf8)
    }
}

/// Rule 4 helper: writes manifests into a temp dir and runs the checker with `--manifests <dir>` alone.
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
    // SE-0409 access-level spellings: an attribute-only strip lets every one of them through.
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

/// Real code hidden behind a literal or comment construct that ends correctly, so the trailing
/// `import AppKit` is genuine code and must be caught.
@Test(arguments: [
    // A `//` inside a string literal must not start a comment.
    ##"let s = "//"; import AppKit"##,
    ##"let s = "\(Date())"; import AppKit"##,
    // Raw-string interpolation: the pound count in \#( must match the delimiter.
    ##"let s = #"\#(Date())"#; import AppKit"##,
    // In a raw string `\(` is literal text, so the string still closes at the first `"#`.
    ##"let s = #"a \(b) c"#; import AppKit"##,
    ##"let s = "\("\(Date())")"; import AppKit"##,
    // Multiline string: string state must survive newlines AND terminate.
    "let s = \"\"\"\nnot code\n\"\"\"\nimport AppKit",
    // A quote inside a line comment must not open string state for the rest of the file.
    "// he said \"hi\nimport AppKit",
    // Escaped backslash: the string DOES end at the following quote.
    ##"let s = "a \\"; import AppKit"##,
    "let s = #\"\"\"\nnot code\n\"\"\"#\nimport AppKit",
])
func rejectsImportHiddenBehindLiterals(_ source: String) throws {
    let result = try runChecker(source: source)
    #expect(result.status == 1, "should reject: \(source)")
    #expect(!result.stderr.isEmpty)
}

/// `import` + newline + module fully typechecks, so a line-local statement scan lets AppKit in.
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

/// `file:line:` is the contract: a `\` continuation inside a multiline literal must not swallow its newline.
@Test func reportsAccurateLineNumberAfterStringLineContinuation() throws {
    let source = "let s = \"\"\"\na \\\nb\n\"\"\"\nimport AppKit"   // import is on line 5
    let result = try runChecker(source: source)
    #expect(result.status == 1)
    #expect(result.stderr.contains(":5: error:"),
            "line number drifted: \(result.stderr)")
}

/// The same line-number contract for the regex frame; both branches are pinned so neither is tidied away.
@Test func reportsAccurateLineNumberAfterRegexLineContinuation() throws {
    let source = "public let r = #/\n  a\\\n  b\n/#\nimport AppKit"   // import is on line 5
    let result = try runChecker(source: source)
    #expect(result.status == 1)
    #expect(result.stderr.contains(":5: error:"),
            "line number drifted: \(result.stderr)")
}

/// Separators Swift accepts between `import` and the module name that a space/tab/newline tokenizer does not. Form feed is the dangerous one: invisible in every diff viewer.
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

/// Swift terminates the `import` keyword at a backtick, so the tokenizer must flush at a backtick and keep it.
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

/// Sibling edges consult the same token, so a tokenizer bypass is a bypass for F2 as well as F1.
@Test func rejectsBacktickGluedSiblingImport() throws {
    // `Variants`, not `Framing`: Framing declares Timeline since the framing gates landed
    // (2026-08-19), and an example that stopped being undeclared tests nothing.
    let result = try runChecker(targetName: "Variants", source: "import`Geometry`")
    #expect(result.status == 1, "Variants does not declare Geometry\nstderr: \(result.stderr)")
}

/// Constructs where a quote is ORDINARY CONTENT — SE-0451 raw identifiers and extended regex literals —
/// so a scanner that does not model them opens a string frame on source that compiles clean.
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

/// The same construction defeats the sibling-edge rule; both consult the same token stream.
@Test func rejectsSiblingImportHiddenBehindRawIdentifier() throws {
    let result = try runChecker(targetName: "Variants",
                                source: "public let `a\"\"\"b` = 1\nimport Geometry")
    #expect(result.status == 1, "Variants does not declare Geometry\nstderr: \(result.stderr)")
}

/// Swift ends a `//` comment at a lone CR and compiles what follows; FF, VT, NEL, U+2028 and U+2029 do NOT end one — see `acceptsLineCommentsThatDoNotEnd`.
@Test func rejectsImportAfterCarriageReturnInLineComment() throws {
    let result = try runChecker(source: "// note\u{000D}import AppKit")
    #expect(result.status == 1)
    #expect(result.stderr.contains("AppKit"))
}

// MARK: - must be ACCEPTED

@Test(arguments: [
    "import Foundation",
    // The same access-level forms on a LEGITIMATE module must not be false-positived.
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
    "let s = \"\"\"\nimport AppKit\n\"\"\"",
    // Swift block comments nest.
    "/* /* nested */ import AppKit */",
    ##"let s = #"import AppKit"#"##,
    // An escaped quote does not close the string.
    ##"let s = "a \" import AppKit""##,
    "let s = #\"\"\"\nimport AppKit\n\"\"\"#",
    ##"let s = "\("import AppKit")""##,
])
func acceptsLiteralsAndComments(_ source: String) throws {
    let result = try runChecker(source: source)
    #expect(result.status == 0, "should accept: \(source)\nstderr: \(result.stderr)")
}

/// `import` appearing as something other than an import declaration, and a legitimate module spelled unusually.
@Test(arguments: [
    "import `Foundation`",
    // A backtick-escaped `import` is an IDENTIFIER; flushing the token run at a backtick must not restore the keyword.
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

/// Characters that are NOT Swift line terminators: a `//` comment runs straight through them, so the import stays commented out.
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

/// A raw identifier is one token and its interior is not code; splitting it on interior spaces misreports `` `does import work` ``. Regex literal content is not code either.
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

/// Direct declared edges only: the transitive closure would admit undeclared edges that SwiftPM itself only warns about.
@Test func rejectsTransitiveButUndeclaredEdge() throws {
    // Both examples are `Variants`, whose manifest edge is `Framing` + `Timeline`:
    // Geometry is reachable transitively through Framing and declared nowhere, and Render
    // is not reachable at all. `Framing` was the first example until it declared Timeline
    // for the framing gates (2026-08-19) — an example that stops being undeclared silently
    // stops testing, which is the failure this comment exists to prevent recurring.
    let transitive = try runChecker(targetName: "Variants", source: "import Geometry")
    #expect(transitive.status == 1, "Variants does not declare Geometry\nstderr: \(transitive.stderr)")

    let unrelated = try runChecker(targetName: "Variants", source: "import Render")
    #expect(unrelated.status == 1, "Variants does not declare Render\nstderr: \(unrelated.stderr)")
}

/// Dependencies parsed out of `Package.swift`, so this test cannot drift away from it.
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

/// Every sibling pair, checked against what the manifest declares, so the fallback table cannot mirror the wrong graph.
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

/// `swift package dump-package`'s `targets` array. A separate `--scratch-path` keeps this off the `.build` directory the enclosing `swift test` is holding.
func resolvedManifestTargets() throws -> [[String: Any]] {
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
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "swift package dump-package failed")

    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(root["targets"] as? [[String: Any]])
}

/// Deleting `plugins: archCheck` from a target silently voids rule 1 for it. Asserted against the RESOLVED
/// manifest, so it also catches `archCheck` redefined to `[]` or repointed at another plugin.
@Test func everyLibraryTargetUsesTheCheckerPluginInTheResolvedManifest() throws {
    let targets = try resolvedManifestTargets()

    // EVERY regular target, not a remembered list; the known ones are asserted as a floor so the filter cannot match nothing.
    let regular = targets.filter { $0["type"] as? String == "regular" }
    let regularNames = Set(regular.compactMap { $0["name"] as? String })
    #expect(regularNames.isSuperset(of: libraryModules),
            "expected at least \(libraryModules) among the regular targets, got \(regularNames.sorted())")

    // Every regular target carries a guard; WHICH guard depends on the tier. An entry here asserts a guard, not an exemption.
    // Both runnable-tier targets carry the same guard: Phase 3A-4 split `Headless` into
    // `Capture` and `Compositing`, and the invariant the plugin enforces — needs a window
    // or a running app, does not belong here — is what BOTH names still state.
    let guardForTarget: [String: String] = ["Capture": "HeadlessCheck",
                                            "Compositing": "HeadlessCheck"]

    for target in regular where !pluginExemptTargets.contains(target["name"] as? String ?? "") {
        let name = target["name"] as? String ?? "<unnamed>"
        let usages = target["pluginUsages"] as? [[String: Any]] ?? []
        let plugins = usages.compactMap { ($0["plugin"] as? [Any])?.first as? String }
        let required = guardForTarget[name] ?? "ArchitectureCheck"
        #expect(plugins.contains(required),
                "regular target \(name) does not use the \(required) plugin — its architecture rule is void for it. pluginUsages: \(usages)")
    }

    // And the tiers do not swap guards. `HeadlessCheck` on a pure target is the dangerous, silent
    // direction: rule 1's allow-list and rule 2 would both be off and the build would stay green.
    for target in regular {
        let name = target["name"] as? String ?? "<unnamed>"
        let plugins = (target["pluginUsages"] as? [[String: Any]] ?? [])
            .compactMap { ($0["plugin"] as? [Any])?.first as? String }
        if guardForTarget[name] == nil {
            #expect(!plugins.contains("HeadlessCheck"), """
                \(name) uses HeadlessCheck. That mode turns OFF rule 1's import allow-list and \
                rule 2's CG ban — for a pure target this is a silent void, not a build failure.
                """)
        } else {
            #expect(!plugins.contains("ArchitectureCheck"),
                    "\(name) uses both guards; the pure guard cannot pass on this tier's imports")
        }
    }

    // The checker's own target must NOT be checked: its source legitimately names the banned modules.
    let checker = try #require(targets.first { $0["name"] as? String == "architecture-checker" })
    let checkerPlugins = (checker["pluginUsages"] as? [[String: Any]] ?? [])
        .compactMap { ($0["plugin"] as? [Any])?.first as? String }
    #expect(!checkerPlugins.contains("ArchitectureCheck"))

    // The exemption is real, not aspirational: `CheckerLexer` must exist and must not carry the plugin (attaching it closes a dependency cycle SwiftPM refuses to resolve, so that second assert can hardly fire).
    for name in pluginExemptTargets {
        let target = try #require(targets.first { $0["name"] as? String == name },
                                  "\(name) is exempt from the plugin but no longer exists")
        let plugins = (target["pluginUsages"] as? [[String: Any]] ?? [])
            .compactMap { ($0["plugin"] as? [Any])?.first as? String }
        #expect(!plugins.contains("ArchitectureCheck"),
                "\(name) is listed as plugin-exempt but now uses the plugin — remove it from the list")
    }
}

/// The one regular target the plugin is deliberately not attached to: attaching `ArchitectureCheck` to `CheckerLexer` closes a dependency cycle SwiftPM refuses to resolve, so rule 1 is kept BY HAND there.
let pluginExemptTargets: Set<String> = ["CheckerLexer"]

/// **The exemption list is a hole in every check above it, so its CONTENTS are an assertion.** Adding a name
/// here skips that target in the guard-coverage loop, voiding its rule with every test still green.
@Test func theOnlyPluginExemptTargetIsTheLexer() {
    #expect(pluginExemptTargets == ["CheckerLexer"], """
        pluginExemptTargets is \(pluginExemptTargets.sorted()), not ["CheckerLexer"].
        Every name in that set is skipped by the guard-coverage loop, so adding one is how a \
        target's architecture rule gets voided with every test still green. The single \
        legitimate entry is there because attaching the plugin to CheckerLexer closes a \
        dependency cycle and SwiftPM refuses to resolve the package — a structural reason, not \
        a convenience. A target that carries a DIFFERENT guard belongs in guardForTarget inside \
        everyLibraryTargetUsesTheCheckerPluginInTheResolvedManifest, which asserts a guard \
        rather than excusing one.
        """)
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
    // SwiftPM prefers Package@swift-6.4.swift: a dependency declared there resolves and builds while Package.swift declares none.
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

// MARK: - rule 8: a validating initialiser under a synthesised `Decodable`
//
// The synthesised `init(from:)` assigns stored properties directly and never calls yours, so every `precondition`
// and `throw` defining the invariant is skipped exactly on the path carrying untrusted input. The fixture names
// are deliberately not the real ones, which are exempt and would be waved through.

/// Rejected. Each of these is a shape a real violator is written in.
@Test(arguments: [
    // The commonest shape: a `precondition` in the initialiser, `Codable` on the declaration line.
    """
    public struct FixtureScale: Codable {
        public let factor: Double
        public init(factor: Double) {
            precondition(factor > 0)
            self.factor = factor
        }
    }
    """,
    // A throwing initialiser instead of a precondition.
    """
    public struct FixtureDigest: Codable {
        public let bytes: [UInt8]
        public init(bytes: [UInt8]) throws {
            guard bytes.count == 32 else { throw FixtureError.wrongLength }
            self.bytes = bytes
        }
    }
    public enum FixtureError: Error { case wrongLength }
    """,
    // The conformance is on an EXTENSION; a scan keyed on the declaration line lets this through, and did.
    """
    public struct FixtureRegistry {
        public let entries: [String]
        public init(entries: [String]) throws {
            guard !entries.isEmpty else { throw FixtureError.empty }
            self.entries = entries
        }
    }
    extension FixtureRegistry: Codable {}
    public enum FixtureError: Error { case empty }
    """,
    // The mirror: the validating initialiser on the extension, the conformance on the declaration.
    """
    public struct FixtureSpan: Codable {
        public let start: Double
        public let end: Double
    }
    extension FixtureSpan {
        public init(start: Double, end: Double) throws {
            guard end >= start else { throw FixtureError.reversed }
            self.start = start
            self.end = end
        }
    }
    public enum FixtureError: Error { case reversed }
    """,
    // `Decodable` alone is the whole exposure; `Codable` is not required.
    """
    public struct FixtureCount: Decodable {
        public let n: Int
        public init(n: Int) { precondition(n >= 0); self.n = n }
    }
    """,
    // THE SECOND TYPE IN THE FILE: a scan that stops at the first public type counts three as one.
    """
    public struct FixtureFirst: Codable {
        public let a: Int
        public init(from decoder: any Decoder) throws {
            a = try decoder.singleValueContainer().decode(Int.self)
        }
    }
    public struct FixtureSecond: Codable {
        public let b: Int
        public init(b: Int) { precondition(b >= 0); self.b = b }
    }
    """,
    // A decoder initialiser on a NEIGHBOUR does not close this type; the scan is per type, not per file.
    """
    public struct FixtureNeighbour: Codable {
        public let a: Int
        public init(from decoder: any Decoder) throws {
            a = try decoder.singleValueContainer().decode(Int.self)
        }
    }
    public struct FixtureOpen: Codable {
        public let b: Int
        public init(b: Int) throws {
            guard b >= 0 else { throw FixtureError.negative }
            self.b = b
        }
    }
    public enum FixtureError: Error { case negative }
    """,
    // `init(fromRaw:)` is not the decoder initialiser — the first parameter LABEL is matched exactly.
    """
    public struct FixtureRaw: Codable {
        public let v: Int
        public init(fromRaw raw: Int) { precondition(raw >= 0); self.v = raw }
    }
    """,
    // A `precondition` outside the initialiser still counts: deliberately over-approximate, in the loud direction.
    """
    public struct FixtureMethod: Codable {
        public let v: Int
        public func scaled(by k: Int) -> Int {
            precondition(k != 0)
            return v * k
        }
    }
    """,
    // A `final class`: the rule is about synthesis, not about structs.
    """
    public final class FixtureBox: Codable {
        public let v: Int
        public init(v: Int) { precondition(v >= 0); self.v = v }
    }
    """,
    // A FAILABLE initialiser states an invariant too — verified against the real `Sources/Graph/Evidence.swift`.
    """
    public struct FixtureNonEmpty: Codable {
        public let head: Int
        public let tail: [Int]
        public init?(_ values: [Int]) {
            guard let head = values.first else { return nil }
            self.head = head
            self.tail = Array(values.dropFirst())
        }
    }
    """,
    // THE PARAMETER'S TYPE, not only its label: `init(from data: Data)` coexists legally with the synthesised one.
    """
    public struct FixtureFromData: Codable {
        public let name: String
        public init(from data: Data) throws {
            precondition(!data.isEmpty)
            self.name = String(decoding: data, as: UTF8.self)
        }
    }
    """,
    // A conformance INHERITED THROUGH A PROTOCOL; naming `Codable` on the declaration line is house style, not enforcement.
    """
    public protocol FixtureRecord: Codable, Sendable {
        var kind: String { get }
    }
    public struct FixtureSample: FixtureRecord, Hashable {
        public let kind = "sample"
        public let delta: Double
        public init(delta: Double) { precondition(delta.isFinite); self.delta = delta }
    }
    """,
    // Two levels of protocol, because inheritance is transitive.
    """
    public protocol FixtureBase: Codable {}
    public protocol FixtureDerived: FixtureBase {}
    public struct FixtureLeaf: FixtureDerived {
        public let v: Int
        public init(v: Int) throws {
            guard v >= 0 else { throw FixtureError.negative }
            self.v = v
        }
    }
    public enum FixtureError: Error { case negative }
    """,
    // A `where` clause containing `==`: a scan that stops at any `=` never registers this extension — silent direction.
    """
    public struct FixtureBox2<T> {
        public let v: T
        public init(v: T) { precondition(true); self.v = v }
    }
    extension FixtureBox2: Codable where T == Int {}
    """,
])
func rejectsValidatingInitialiserUnderSynthesisedDecodable(_ source: String) throws {
    let result = try runChecker(source: "import Foundation\n" + source)
    #expect(result.status == 1, "should reject:\n\(source)")
    #expect(result.stderr.contains("init(from decoder:)"),
            "rejected for the wrong reason: \(result.stderr)")
}

/// Accepted. A false positive here is worse than a miss: it is a build failure someone fixes by deleting the rule.
@Test(arguments: [
    // DisplayGeometry: decoder initialiser on the declaration.
    """
    public struct FixtureGeometry: Codable {
        public let scale: Double
        public init(scale: Double) throws {
            guard scale > 0 else { throw FixtureError.notPositive }
            self.scale = scale
        }
        public init(from decoder: any Decoder) throws {
            let scale = try decoder.singleValueContainer().decode(Double.self)
            try self.init(scale: scale)
        }
    }
    public enum FixtureError: Error { case notPositive }
    """,
    // BOTH the conformance and the decoder initialiser live on an extension.
    """
    public struct FixtureRegistry {
        public let entries: [String]
        public init(entries: [String]) throws {
            guard !entries.isEmpty else { throw FixtureError.empty }
            self.entries = entries
        }
    }
    extension FixtureRegistry: Codable {
        public init(from decoder: any Decoder) throws {
            let entries = try decoder.singleValueContainer().decode([String].self)
            try self.init(entries: entries)
        }
    }
    public enum FixtureError: Error { case empty }
    """,
    // The parameter's internal name is not part of the match.
    """
    public struct FixtureNamed: Codable {
        public let v: Int
        public init(v: Int) { precondition(v >= 0); self.v = v }
        public init(from d: any Decoder) throws {
            v = try d.singleValueContainer().decode(Int.self)
        }
    }
    """,
    // A validating type that is not Codable at all, so nothing bypasses its initialiser.
    """
    public struct FixturePlain: Sendable {
        public let v: Int
        public init(v: Int) throws {
            guard v >= 0 else { throw FixtureError.negative }
            self.v = v
        }
    }
    public enum FixtureError: Error { case negative }
    """,
    // `Encodable` alone: a synthesised encode reads validated properties and bypasses nothing.
    """
    public struct FixtureOut: Encodable {
        public let v: Int
        public init(v: Int) { precondition(v >= 0); self.v = v }
    }
    """,
    // Codable with no invariant to bypass.
    """
    public struct FixtureData: Codable {
        public let v: Int
    }
    """,
    // A NESTED type's throwing initialiser is not the outer type's.
    """
    public struct FixtureOuter: Codable {
        public struct Inner: Sendable {
            public init(v: Int) throws {
                guard v >= 0 else { throw FixtureError.negative }
            }
        }
        public let v: Int
    }
    public enum FixtureError: Error { case negative }
    """,
    // `rethrows` is not `throws`: it states no invariant of its own.
    """
    public struct FixtureRethrow: Codable {
        public let v: Int
        public init(make: () throws -> Int) rethrows { v = try make() }
    }
    """,
    // A protocol that is NOT Codable does not make its conformers Codable; the closure must terminate.
    """
    public protocol FixtureTagged: Sendable {
        var tag: String { get }
    }
    public struct FixtureTag: FixtureTagged {
        public let tag: String
        public init(tag: String) { precondition(!tag.isEmpty); self.tag = tag }
    }
    """,
    // A parameter labelled `from` whose type IS a decoder closes the type, in both spellings.
    """
    public struct FixtureBothSpellings: Codable {
        public let v: Int
        public init(v: Int) { precondition(v >= 0); self.v = v }
        public init(from: any Decoder) throws {
            v = try from.singleValueContainer().decode(Int.self)
        }
    }
    """,
    // Prose about the rule is not the rule: the rule's own vocabulary in comments and literals must not fire.
    """
    // FixtureProse is Codable and has a precondition( in its init(from decoder:)
    /* Codable precondition( init(from decoder: */
    public struct FixtureProse: Sendable {
        public let note = "Codable precondition( init(from decoder:"
    }
    """,
])
func acceptsAnExplicitDecoderInitialiserOrNothingToBypass(_ source: String) throws {
    let result = try runChecker(source: "import Foundation\n" + source)
    #expect(result.status == 0, "should accept:\n\(source)\nstderr: \(result.stderr)")
}

/// The names in `ArchitectureChecker.decodeValidationExemptTypes`, parsed out of the checker's own source
/// rather than mirrored: a second copy is a copy that drifts, and this list is meant to SHRINK.
func decodeValidationExemptTypes() throws -> Set<String> {
    let source = try String(contentsOf: repositoryRoot
        .appending(path: "Sources/architecture-checker/main.swift"), encoding: .utf8)
    let marker = "static let decodeValidationExemptTypes: Set<String> = ["
    let start = try #require(source.range(of: marker),
                             "decodeValidationExemptTypes is gone from the checker — rule 8 has no exemption list")
    // The list's closing bracket at its own indentation, not the first `]`: the entries carry comments.
    let end = try #require(source.range(of: "\n    ]", range: start.upperBound..<source.endIndex))

    // Only the quoted literals count. Splitting on commas swallows the prose.
    var names: Set<String> = []
    var remainder = source[start.upperBound..<end.lowerBound]
    while let open = remainder.firstIndex(of: "\""),
          let close = remainder[remainder.index(after: open)...].firstIndex(of: "\"") {
        names.insert(String(remainder[remainder.index(after: open)..<close]))
        remainder = remainder[remainder.index(after: close)...]
    }
    return names
}

/// **The exemption list must not be able to lie in either direction.** Running the real checker over the real
/// sources with the exemptions OFF answers from the binary which types still violate rule 8: it catches a new
/// violator, and a type closed without its line being deleted — otherwise silent.
@Test func theDecodeValidationExemptionListIsExactlyWhatStillViolatesRule8() throws {
    let exempt = try decodeValidationExemptTypes()
    try #require(!exempt.isEmpty,
                 "the exemption list is empty — either every type is closed (delete this test's premise, not the rule) or the parse broke")

    var violating: Set<String> = []
    for module in libraryModules {
        let sources = repositoryRoot.appending(path: "Sources/\(module)")
        let result = try launchChecker(
            targetName: module,
            sourcesPath: sources.path(percentEncoded: false),
            additionalArguments: ["--ignore-decode-validation-exemptions"])
        for line in result.stderr.split(whereSeparator: \.isNewline) {
            guard let open = line.range(of: "error: '"),
                  line.contains("init(from decoder:)"),
                  let close = line[open.upperBound...].firstIndex(of: "'") else { continue }
            violating.insert(String(line[open.upperBound..<close]))
        }
    }

    #expect(violating == exempt,
            """
            rule 8's exemption list no longer matches the package.
            Exempt but no longer violating (DELETE these lines from \
            ArchitectureChecker.decodeValidationExemptTypes): \(exempt.subtracting(violating).sorted())
            Violating but not exempt: \(violating.subtracting(exempt).sorted())
            The list is a live record of the remaining work, and closing a type means deleting \
            its line. Re-measure with scripts/scan-decode-validation.py.
            """)
}

/// A rule with no fixture on the real sources could be scanning nothing: with the exemptions off the real
/// package must FAIL while the list is non-empty.
@Test func theRuleStillFiresOnTheRealSourcesWithTheExemptionsOff() throws {
    let sources = repositoryRoot.appending(path: "Sources/Geometry")
    let withExemptions = try launchChecker(targetName: "Geometry",
                                           sourcesPath: sources.path(percentEncoded: false))
    #expect(withExemptions.status == 0,
            "Sources/Geometry does not pass rule 8 with the exemptions on: \(withExemptions.stderr)")

    let without = try launchChecker(targetName: "Geometry",
                                    sourcesPath: sources.path(percentEncoded: false),
                                    additionalArguments: ["--ignore-decode-validation-exemptions"])
    #expect(without.status == 1,
            "with the exemptions off the real Geometry sources must still violate rule 8 — five of the eight are there")
    #expect(without.stderr.contains("NormalizedFrame"), "stderr: \(without.stderr)")
}

/// **Rule 8 answers per TARGET, not per file.** A type in one file with `extension Foo: Codable {}` in another
/// is the house style here, and per-file it was a silent pass.
@Test func conformanceInAnotherFileIsStillAConformance() throws {
    let result = try runChecker { dir in
        try """
        import Foundation
        public struct FixtureSplit {
            public let v: Int
            public init(v: Int) { precondition(v >= 0); self.v = v }
        }
        """.write(to: dir.appending(path: "A.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        extension FixtureSplit: Codable {}
        """.write(to: dir.appending(path: "B.swift"), atomically: true, encoding: .utf8)
    }
    #expect(result.status == 1, "a conformance one file over is still a conformance\nstderr: \(result.stderr)")
    #expect(result.stderr.contains("FixtureSplit"))
}

/// The other direction of the same fact: a decoder initialiser in a third file closes the type.
@Test func aDecoderInitialiserInAnotherFileClosesTheType() throws {
    let result = try runChecker { dir in
        try """
        import Foundation
        public struct FixtureSplit {
            public let v: Int
            public init(v: Int) { precondition(v >= 0); self.v = v }
        }
        """.write(to: dir.appending(path: "A.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        extension FixtureSplit: Codable {}
        """.write(to: dir.appending(path: "B.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        extension FixtureSplit {
            public init(from decoder: any Decoder) throws {
                let v = try decoder.singleValueContainer().decode(Int.self)
                guard v >= 0 else {
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "negative"))
                }
                self.init(v: v)
            }
        }
        """.write(to: dir.appending(path: "C.swift"), atomically: true, encoding: .utf8)
    }
    #expect(result.status == 0, "stderr: \(result.stderr)")
}

/// **Two nested `Entry` types are two types.** Merging by simple name would let one gaining `init(from:)`
/// silence the other, so types are keyed by their nesting-qualified name.
@Test func twoNestedTypesOfTheSameNameAreNotMerged() throws {
    let result = try runChecker(source: """
        import Foundation
        public struct FixtureLeft {
            public struct Entry: Codable {
                public let v: Int
                public init(from decoder: any Decoder) throws {
                    v = try decoder.singleValueContainer().decode(Int.self)
                }
            }
        }
        public struct FixtureRight {
            public struct Entry: Codable {
                public let v: Int
                public init(v: Int) { precondition(v >= 0); self.v = v }
            }
        }
        """)
    #expect(result.status == 1, "the closed Entry silenced the open one\nstderr: \(result.stderr)")
    #expect(result.stderr.contains("'FixtureRight.Entry'"),
            "a nested type must be reported by its qualified name: \(result.stderr)")
    #expect(!result.stderr.contains("'FixtureLeft.Entry'"),
            "the closed Entry must not be reported: \(result.stderr)")
}

// MARK: - the second guard: --mode headless
//
// The runnable tier legitimately imports AVFoundation, CoreImage, CoreVideo, CoreMedia, Metal and CoreGraphics
// and legitimately names CGRect, so `ArchitectureCheck` cannot be attached; it gets a SECOND guard of its own.

/// Runs the real built checker in headless mode over a one-file fixture.
func runHeadlessChecker(ban: [String] = ["AppKit", "SwiftUI", "Cocoa", "Quartz"],
                        source: String) throws -> (status: Int32, stderr: String) {
    try runChecker(targetName: "Headless",
                   additionalArguments: ["--mode", "headless"] + ban.flatMap { ["--ban", $0] },
                   populate: { dir in
                       try source.write(to: dir.appending(path: "Probe.swift"),
                                        atomically: true, encoding: .utf8)
                   })
}

/// The one rule. Every spelling rule 1 closes is closed here too: both rules read the SAME token stream.
@Test(arguments: [
    "import AppKit",
    "import SwiftUI",
    "@preconcurrency import AppKit",
    "public import SwiftUI",
    "internal import AppKit",
    "import\nAppKit",
    "import\u{000C}SwiftUI",
    "import`AppKit`",
    "import class AppKit.NSColor",
    "import Foundation; import SwiftUI",
    "public let `a\"\"\"b` = 1\nimport AppKit",
    // `Cocoa` and `Quartz` both re-export `AppKit` (measured), so a two-name AppKit/SwiftUI deny-list
    // would let a file that needs a window straight into `Sources/Headless` under either alias.
    "import Cocoa",
    "import Quartz",
    "@preconcurrency import Cocoa",
    "import Foundation; import Quartz",
])
func headlessModeRejectsTheBannedModules(_ source: String) throws {
    let result = try runHeadlessChecker(source: source)
    #expect(result.status == 1, "should reject: \(source.debugDescription)")
    #expect(!result.stderr.isEmpty)
}

/// What the tier EXISTS to permit; if any of these fails the guard is the pure guard wearing a different name.
@Test(arguments: [
    "import AVFoundation",
    "import CoreImage",
    "import CoreVideo",
    "import CoreMedia",
    "import Metal",
    "import CoreGraphics",
    "import Foundation",
    "import Render",
    "import Project",
    "import Timeline",
])
func headlessModeAllowsThePlatformFrameworksTheTierIsFor(_ source: String) throws {
    let result = try runHeadlessChecker(source: source)
    #expect(result.status == 0, "should accept: \(source)\nstderr: \(result.stderr)")
}

/// Rule 2 is OFF in headless mode: this tier is the boundary where CG geometry is converted, so banning
/// CGRect here would ban the tier's purpose.
@Test func headlessModeDoesNotBanCGGeometry() throws {
    let result = try runHeadlessChecker(source: """
        import CoreGraphics
        public enum Fixture { public static let box = CGRect(x: 0, y: 0, width: 1, height: 1) }
        """)
    #expect(result.status == 0, "stderr: \(result.stderr)")
}

/// Comment and string content is not code, in this mode as in every other.
@Test(arguments: [
    "// import AppKit is banned here",
    "/* import SwiftUI */",
    #"let s = "import AppKit""#,
    "public func `does import AppKit work`() {}",
])
func headlessModeDoesNotFireOnProse(_ source: String) throws {
    let result = try runHeadlessChecker(source: "import Foundation\n" + source)
    #expect(result.status == 0, "should accept: \(source)\nstderr: \(result.stderr)")
}

/// **A guard that bans nothing is not a guard**: `--mode headless` with the `--ban` flags dropped would silently void it.
@Test func headlessModeWithNoBanListFailsClosed() throws {
    let result = try runHeadlessChecker(ban: [], source: "import Foundation")
    #expect(result.status == 2, "stderr: \(result.stderr)")
    #expect(result.stderr.contains("--ban"))
}

/// Rule 8 still runs in headless mode — a synthesised `Decodable` bypasses a stated invariant wherever the type lives.
@Test func headlessModeStillEnforcesDecodeValidation() throws {
    let result = try runHeadlessChecker(source: """
        import Foundation
        public struct FixtureHeadlessScale: Codable {
            public let factor: Double
            public init(factor: Double) { precondition(factor > 0); self.factor = factor }
        }
        """)
    #expect(result.status == 1, "stderr: \(result.stderr)")
    #expect(result.stderr.contains("init(from decoder:)"))
}

/// **The loosening flags must never reach the pure guard**: `--mode headless` turns off rule 1's allow-list
/// and rule 2, so a pure target passing them could import AppKit with the build still green.
@Test func theArchitectureCheckPluginNeverPassesTheHeadlessFlags() throws {
    let source = try String(contentsOf: repositoryRoot
        .appending(path: "Plugins/ArchitectureCheck/ArchitectureCheck.swift"), encoding: .utf8)
    let code = SwiftSourceLexer.codeViewLines(of: source).joined(separator: "\n")
    #expect(!code.contains("--mode"),
            "ArchitectureCheck passes --mode: rule 1's allow-list and rule 2 would be off for a pure target")
    #expect(!code.contains("--ban"),
            "ArchitectureCheck passes --ban: the deny-list belongs to HeadlessCheck alone")
}

/// The mirror: `HeadlessCheck` must pass both bans and must NOT pass `--allow`. The presence checks read
/// `source`, not the code view, because `codeViewLines` blanks string literals — and each is anchored to the
/// argument-list shape (a flag paired with its value), not the bare module name a doc comment could also contain.
@Test func theHeadlessCheckPluginPassesBothBansAndNoAllowList() throws {
    let source = try String(contentsOf: repositoryRoot
        .appending(path: "Plugins/HeadlessCheck/HeadlessCheck.swift"), encoding: .utf8)
    let code = SwiftSourceLexer.codeViewLines(of: source).joined(separator: "\n")
    #expect(source.contains("\"--ban\", \"AppKit\""))
    #expect(source.contains("\"--ban\", \"SwiftUI\""))
    #expect(source.contains("\"--ban\", \"Cocoa\""))
    #expect(source.contains("\"--ban\", \"Quartz\""))
    #expect(source.contains("\"--mode\", \"headless\""))
    #expect(!code.contains("--allow"),
            "headless mode has no allow-list; passing --allow would misdescribe the guard")
}
