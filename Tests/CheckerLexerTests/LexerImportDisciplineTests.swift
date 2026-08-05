import Testing
import Foundation
import CheckerLexer

/// `Sources/CheckerLexer` imports Foundation and nothing else — rule 1 enforced here because the
/// target cannot carry the `ArchitectureCheck` plugin (it would close a dependency cycle SwiftPM
/// refuses). Narrower than the plugin: this scans line by line, so an `import` split across a
/// line break by a raw string or interpolation would be missed.
@Test func theCheckerLexerImportsFoundationOnly() throws {
    // …/Tests/CheckerLexerTests/LexerImportDisciplineTests.swift → the repository root.
    let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appending(path: "Sources/CheckerLexer")
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        .filter { $0.hasSuffix(".swift") }
    try #require(!names.isEmpty, "no sources found under Sources/CheckerLexer — this scan would pass vacuously")

    for name in names.sorted() {
        let text = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
        for (index, line) in SwiftSourceLexer.codeViewLines(of: text).enumerated() {
            let words = line.split(whereSeparator: { !SwiftSourceLexer.isIdentifierCharacter($0) })
                .map(String.init)
            guard let importIndex = words.firstIndex(of: "import"),
                  importIndex + 1 < words.count else { continue }
            let module = words[importIndex + 1].split(separator: ".").first.map(String.init) ?? ""
            #expect(module == "Foundation", """
                Sources/CheckerLexer/\(name):\(index + 1) imports `\(module)`.
                This target carries no ArchitectureCheck plugin — attaching it closes a dependency \
                cycle SwiftPM refuses to resolve (Package.swift states the reason at its declaration) \
                — so rule 1 for it is enforced HERE and nowhere else.
                """)
        }
    }
}

/// Rule 3 (no ambient time or randomness) for `CheckerLexer`, textually — the package-side symbol
/// scan's plugin-derived module list never reaches this target. Mirrors `ambientBannedNames` in
/// `AppSourceAllowListTests.swift`; copied, since SwiftPM cannot share it between test targets.
let checkerLexerAmbientBannedNames: [String] = [
    "Date(", "Date.init", "Date.now",
    "timeIntervalSinceNow", "timeIntervalSinceReferenceDate",
    "DispatchTime.now", "DispatchWallTime.now",
    "ContinuousClock", "SuspendingClock",
    "CFAbsoluteTimeGetCurrent",
    "mach_absolute_time", "mach_approximate_time", "mach_continuous_time",
    "clock_gettime", "gettimeofday",
    "clock(", "time(",
    "NSDate", "systemUptime",
    "UUID(", "UUID.init", "NSUUID",
    "CCRandomGenerateBytes",
    "rand48", "seed48", "lcong48",
    ".random(", "randomElement", "shuffle",
    "SystemRandomNumberGenerator",
    "arc4random", "SecRandomCopyBytes",
    "SHA256",
    "sysctlbyname", "CGDisplayCreateUUIDFromDisplayID",
]

@Test func theCheckerLexerNeverReadsAmbientTimeOrRandomness() throws {
    // …/Tests/CheckerLexerTests/LexerImportDisciplineTests.swift → the repository root.
    let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appending(path: "Sources/CheckerLexer")
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        .filter { $0.hasSuffix(".swift") }
    try #require(!names.isEmpty, "no sources found under Sources/CheckerLexer — this scan would pass vacuously")

    var found: [String] = []
    var linesScanned = 0
    for name in names.sorted() {
        let text = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
        for (index, line) in SwiftSourceLexer.codeViewLines(of: text).enumerated() {
            linesScanned += 1
            for needle in checkerLexerAmbientBannedNames where line.contains(needle) {
                found.append("Sources/CheckerLexer/\(name):\(index + 1): names '\(needle)'")
            }
        }
    }
    try #require(linesScanned > 0, "no lines were examined — this scan would pass vacuously")

    #expect(found.isEmpty, """
        Sources/CheckerLexer read ambient time or randomness:
        \(found.joined(separator: "\n"))
        This target has no legitimate need for either — it is a pure function from source \
        text to a code view, and carries no permitted boundary file the way the app \
        (Minting.swift) and Sources/Headless (MP4Exporter.swift) do.
        """)
}
