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

/// Rule 3 (no ambient time or randomness) for `CheckerLexer`, textually — the
/// cheap partial the final whole-branch review asked for, closing the gap this
/// file's own header and `Package.swift`'s comment beside this target's
/// declaration both name as hand-kept.
///
/// **Strictly weaker than the package-side symbol scan, and that is stated
/// rather than hidden.** The symbol scan reads the linked object file, so it
/// sees THROUGH whatever this target calls into transitively; this reads only
/// `CheckerLexer`'s own source text, so a violation reached indirectly (a call
/// into a helper this target imports, if it ever gained one) would not be
/// caught here. That gap is acceptable for exactly one reason: `CheckerLexer`
/// is one small, Foundation-only, string-in/string-out module with no
/// dependencies of its own (rule 1, enforced above) — there is no other module
/// for a violation to hide behind, so a textual scan of this target's own text
/// is close to sufficient here specifically, not as a general replacement for
/// the symbol scan elsewhere.
///
/// **This would have caught the exact violation the repro planted.** The header
/// above records Task 8's measurement: a real `Date()` call added to
/// `SwiftSourceLexer.swift`, with `CheckerLexer` wired into `DeterminismTests`'
/// dependency graph, left `noLibraryModuleReferencesAmbientTimeOrRandomness`
/// green — because that scan's module list is plugin-derived, not
/// dependency-derived, and `CheckerLexer` carries no `ArchitectureCheck` plugin
/// by construction (the dependency cycle explained above). A text scan over this
/// target's own code view has no such indirection: `Date()` in the source text
/// is `Date()` in the source text.
///
/// **No permitted file — unlike the app's `Minting.swift` and
/// `Sources/Headless`'s `MP4Exporter.swift` (see `AppSourceAllowListTests.swift`
/// for both).** `CheckerLexer` has no legitimate need for ambient time or
/// randomness anywhere: it is a pure function from source text to a code view.
/// Every hit here is a violation, full stop.
///
/// **The needle list mirrors `ambientBannedNames` in
/// `Tests/AppSourceTests/AppSourceAllowListTests.swift` — copied, not shared.**
/// Sharing it would need a test-target-to-test-target dependency SwiftPM does
/// not support, and the two lists already scan different bodies of source for
/// the same reason `bannedCGTypes` is mirrored rather than shared between the
/// package and app halves of rule 5 (that file's own header): either side may
/// gain a name the other must not, and a shared list would sit in the
/// least-guarded of the two targets that read it.
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
