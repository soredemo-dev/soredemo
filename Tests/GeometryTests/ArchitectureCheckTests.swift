import Testing
import Foundation

/// Runs the real built checker against a temporary fixture directory.
/// Never reimplement the checking logic in-process — that tests the test.
func runChecker(targetName: String = "Geometry", source: String) throws -> (status: Int32, stderr: String) {
    let binDir = URL(filePath: #filePath)               // …/Tests/GeometryTests/ArchitectureCheckTests.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: ".build/debug")
    let checker = binDir.appending(path: "architecture-checker")
    try #require(FileManager.default.fileExists(atPath: checker.path(percentEncoded: false)),
                 "architecture-checker not built at \(checker.path(percentEncoded: false))")

    let dir = URL(filePath: NSTemporaryDirectory())
        .appending(path: "arch-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try source.write(to: dir.appending(path: "Probe.swift"), atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = checker
    process.arguments = ["--target-name", targetName,
                         "--sources", dir.path(percentEncoded: false)]
    let err = Pipe()
    process.standardError = err
    try process.run()
    let data = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

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
