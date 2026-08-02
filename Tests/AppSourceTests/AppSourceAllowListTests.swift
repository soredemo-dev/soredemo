import CheckerLexer
import Foundation
import Testing

// MARK: - why these are package tests and not plugin rules
//
// `Plugins/ArchitectureCheck` attaches to SwiftPM targets. The app lives in
// `Soredemo.xcodeproj`, which the plugin cannot see at all, so the two app-side
// allow-lists below cannot be plugin rules however much they look like ones.
//
// They scan through `SwiftSourceLexer.codeViewLines` — the SAME code view the
// plugin's rules 1, 2 and 4 use — so a banned name inside a comment or a string
// literal does not fire. That sharing is the whole point of the `CheckerLexer`
// target: a second copy of the lexer written here would start at round zero of
// the four evasion-closing rounds the real one has been through, and would then
// drift away from the enforcement it exists to mirror. A scanner that fires on a
// comment is a scanner people route around, and every file below has prose about
// `CGRect` and `UUID` in it precisely because that is what those files are for.
//
// SUBSTRING, NOT TOKEN EQUALITY, deliberately — settled for rule 2 in Task 3.
// `contains("CGRect")` matches `` `CGRect` ``, a backtick-escaped identifier
// resolving to the same declaration; token equality would not, because the code
// view keeps the backticks as part of the token's text. For a question about
// which NAMES appear, substring is the stronger mechanism, not a weaker one.
// It over-approximates in the loud direction: `contains("Date(")` would also
// fire on a hypothetical `refreshDate(`. That is a visible false positive, which
// this project's design doc treats as survivable, and a miss is not.

/// `<root>/Tests/AppSourceTests/AppSourceAllowListTests.swift` → `<root>`.
/// Three `deletingLastPathComponent()` calls: one drops the file name, one drops
/// `AppSourceTests`, one drops `Tests`. If this file is ever moved, the count is
/// wrong and `appSourceFiles()` finds nothing — which the `#require` there turns
/// into a loud failure rather than a scan of an empty set.
let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

/// The app's sources, and ONLY the app's sources.
///
/// Scoped to `Soredemo/` rather than the repository, deliberately:
/// `scripts/cross-boundary-digest-probe.swift` legitimately names `CGRect` and
/// calls `UUID()` — it is a standalone probe, not app code — and `Sources/` is
/// the package, which has its own enforcement in the plugin.
let appSourceDirectory = repositoryRoot.appending(path: "Soredemo")

/// Every `.swift` file under `Soredemo/`.
///
/// A missing or empty app source tree is a FAILURE, not a vacuous pass: an empty
/// scan finds no violations and reads exactly like a clean one. `AGENTS.md`
/// carries this rule because a probe on this plan already reported a green from
/// having measured nothing.
func appSourceFiles() throws -> [URL] {
    let enumerator = try #require(
        FileManager.default.enumerator(at: appSourceDirectory, includingPropertiesForKeys: nil),
        "cannot enumerate \(appSourceDirectory.path(percentEncoded: false))")

    var files: [URL] = []
    while let url = enumerator.nextObject() as? URL {
        if url.pathExtension == "swift" { files.append(url) }
    }
    try #require(!files.isEmpty,
                 "no app sources found at \(appSourceDirectory.path(percentEncoded: false)) — this scan would pass vacuously")
    return files.sorted { $0.path < $1.path }
}

/// `Soredemo/UI/ProjectDocument.swift`, not the absolute path — the form the
/// checker prints, and the form that is greppable from the repository root.
///
/// `repositoryRoot` is a DIRECTORY URL, so its `path` already ends in `/`;
/// appending another one produced `…soredemo-main//Soredemo/…`, matched nothing,
/// and left every reported path absolute. Found by the mutation check in Part 3
/// of this task, which is the entire argument for running one.
func pathRelativeToRepositoryRoot(_ url: URL) -> String {
    let root = repositoryRoot.path(percentEncoded: false)
    let prefix = root.hasSuffix("/") ? root : root + "/"
    let path = url.path(percentEncoded: false)
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
}

/// One violation, in the `file:line:` form the checker prints, so a failure here
/// reads the same way a plugin failure does.
func violations(
    banned: [String],
    permittedFile: String,
    in files: [URL]
) throws -> [String] {
    // The permitted file must exist. If it were renamed away, this scan would
    // still pass — the rename direction is the safe one, because the file's
    // contents would then be scanned and fail loudly — but the CLAIM the test
    // stands for ("this happens at exactly one audited place") would be about a
    // place that no longer exists.
    let permitted = files.filter { $0.lastPathComponent == permittedFile }
    try #require(permitted.count == 1,
                 "expected exactly one \(permittedFile) under \(appSourceDirectory.path(percentEncoded: false)), found \(permitted.count)")

    let scanned = files.filter { $0.lastPathComponent != permittedFile }
    try #require(!scanned.isEmpty,
                 "only \(permittedFile) exists — nothing outside the allow-list was scanned")

    var found: [String] = []
    var linesScanned = 0
    for file in scanned {
        let text = try String(contentsOf: file, encoding: .utf8)
        for (index, line) in SwiftSourceLexer.codeViewLines(of: text).enumerated() {
            linesScanned += 1
            for name in banned where line.contains(name) {
                found.append("\(pathRelativeToRepositoryRoot(file)):\(index + 1): names '\(name)'")
            }
        }
    }
    try #require(linesScanned > 0, "no lines were examined — the scan would pass vacuously")
    return found
}

// MARK: - rule 5: the CoreGraphics bridge

/// `AGENTS.md` rule 2 keeps `CGRect`, `CGPoint`, `CGSize` and `CGFloat` out of the
/// PACKAGE, enforced by the plugin. This is the app-side half: they may appear in
/// exactly one file, the bridge, where CoreGraphics geometry is converted into
/// this project's own types on entry and back out on exit. Nothing in between
/// speaks in pixels (ARCHITECTURE.md D3).
///
/// The four names are the same four the plugin bans, mirrored rather than shared
/// because they are two rules over two different bodies of source and either may
/// change without the other.
@Test func coreGraphicsGeometryTypesAppearOnlyInTheBridge() throws {
    let found = try violations(
        banned: ["CGRect", "CGPoint", "CGSize", "CGFloat"],
        permittedFile: "CGGeometryBridge.swift",
        in: try appSourceFiles())

    #expect(found.isEmpty,
            """
            a CoreGraphics geometry type reached the app outside the bridge:
            \(found.joined(separator: "\n"))
            Convert at Soredemo/Capture/CGGeometryBridge.swift and pass the \
            package's own types onward; see ARCHITECTURE.md D3.
            """)
}

// MARK: - rule 3's app-side half: where non-determinism enters

/// Architecture rule 3 — no ambient time or randomness — is checked over the
/// LINK-TIME SYMBOLS in the package's object files (`Tests/DeterminismTests`).
/// `Soredemo/Support/Minting.swift` is in the **app** target, so nothing checks
/// it, and nothing stops `ProjectDocument.swift` calling `UUID()` directly.
///
/// That would produce no wrong result — a UUID is a UUID — which is exactly why
/// it needs a test rather than a review habit. It would make the sentence
/// "non-determinism enters at one audited place" false while `Minting.swift`'s
/// own doc comment, `AGENTS.md` and the design doc all still assert it. That is
/// the same failure as `NormalizationContext` having no caller: a true-sounding
/// sentence with nothing underneath it.
///
/// `SHA256` is here for the same reason and one more: `ContentDigest` documents
/// at length that the package COMPARES digests and never computes one, because
/// computing needs CryptoKit and rule 1 forbids it. The producer is `Minting`,
/// and it must stay the only one.
@Test func ambientTimeRandomnessAndHashingEnterOnlyThroughMinting() throws {
    let found = try violations(
        banned: ["UUID(", "Date(", "SHA256", "SystemRandomNumberGenerator"],
        permittedFile: "Minting.swift",
        in: try appSourceFiles())

    #expect(found.isEmpty,
            """
            an ambient value was minted outside Soredemo/Support/Minting.swift:
            \(found.joined(separator: "\n"))
            Identifiers, timestamps and digests enter at that one boundary and \
            are passed onward as plain values — that is what makes derivation a \
            deterministic function of its input.
            """)
}
