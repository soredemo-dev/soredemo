import Testing
import Foundation
import CheckerLexer

/// **The consequence `Package.swift` says is "kept by hand", kept by a test instead.**
///
/// `CheckerLexer` carries no `ArchitectureCheck` plugin and cannot: the plugin depends
/// on `architecture-checker`, which depends on this target, and attaching it closes a
/// dependency cycle SwiftPM refuses to resolve. That is deliberate and its reason is
/// written at `Package.swift`'s declaration of this target and beside
/// `pluginExemptTargets` — both places a maintainer would look.
///
/// What was NOT enforced is the consequence: "this target imports Foundation and must
/// keep to it." A hand-maintained invariant expires silently, which is this phase's
/// whole subject. The plugin cannot run here, but a test can read the same code view
/// the plugin reads, so the rule holds by mechanism at the cost of one file.
///
/// **Narrower than the plugin's own instrument, and deliberately so.** The plugin's
/// `tokens(of:)` walks `codeViewLines(of:)`'s output as one continuous stream, so an
/// `import` split across a line break by a raw string or an interpolation still
/// resolves as one token. This test scans line by line and word-splits each line on
/// its own — it does not walk across lines — so it is blind to an import keyword and
/// its module name landing on different physical lines. That gap is acceptable here
/// only because it is named: a reader must not assume this test gives the same
/// guarantee the plugin gives everywhere else it runs.
///
/// The other stated consequence — rule 3, no ambient time or randomness, since
/// `DeterminismTests` derives its module list from the plugin's attachments — was
/// tried and measured, not left as a plan: adding `"CheckerLexer"` to
/// `DeterminismTests`' dependencies in `Package.swift` does not enforce it, because
/// `scannedModules(inDump:)` derives its module list from which targets carry the
/// `ArchitectureCheck` plugin, and `CheckerLexer` deliberately carries none — so the
/// symbol scan still never looks at `CheckerLexer.o` regardless of the dependency
/// edge. Both `determinismTestTargetDependsOnEveryCheckedModule` and the symbol scan
/// stay green with the edge added, but green here is vacuous: neither test's
/// behaviour changes, because neither reads `CheckerLexer` either way. The edge was
/// reverted. A real fix would have to change `scannedModules(inDump:)`'s own
/// derivation — out of scope for this task — so rule 3 for this target remains
/// hand-kept, recorded here rather than hidden.
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
