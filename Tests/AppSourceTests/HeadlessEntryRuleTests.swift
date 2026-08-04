import CheckerLexer
import Foundation
import Testing

// Reuses `repositoryRoot`, `codeLinesNaming(_:in:)`, `violations(banned:permittedPath:in:)`
// and `pathRelativeToRepositoryRoot(_:)` from `AppSourceAllowListTests.swift` —
// file-scope declarations in this same target.

/// Every `.swift` file under `Sources/Headless`.
func headlessSourceFiles() throws -> [URL] {
    try swiftFiles(under: "Sources/Headless")
}

/// Every `.swift` file under `Tests/HeadlessTests`.
func headlessTestFiles() throws -> [URL] {
    try swiftFiles(under: "Tests/HeadlessTests")
}

/// Same enumeration `firstPartySourceFiles()` uses, over one directory. Non-empty is
/// required for the reason that helper gives: a scan over nothing passes vacuously,
/// and a scanner that passes vacuously is worse than no scanner because someone is
/// counting on it.
func swiftFiles(under relativePath: String) throws -> [URL] {
    let root = repositoryRoot.appending(path: relativePath)
    let enumerator = try #require(
        FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
        "cannot enumerate \(relativePath) — it must exist for this scan to mean anything")
    var files: [URL] = []
    while let url = enumerator.nextObject() as? URL {
        if url.pathExtension == "swift" { files.append(url) }
    }
    try #require(!files.isEmpty, "no .swift files under \(relativePath) — this scan would pass vacuously")
    return files.sorted { $0.path < $1.path }
}

// MARK: - rule 5's Headless half

/// **Rule 5's Headless half.** The app tier confines CoreGraphics geometry to
/// `Soredemo/Capture/CGGeometryBridge.swift`; this tier confines it to
/// `Sources/Headless/HeadlessGeometryBridge.swift`. Two tiers, two bridges, two
/// tests — and neither test has an exception, which is the only reason either is
/// worth having.
///
/// `HeadlessCheck` cannot do this job: rule 2 is OFF in headless mode, deliberately,
/// because this tier is where CG conversion legitimately happens. "Where it happens"
/// still has to be one file, and that is what this pins.
@Test func coreGraphicsGeometryTypesAppearOnlyInTheHeadlessBridge() throws {
    let found = try violations(
        banned: ["CGRect", "CGPoint", "CGSize", "CGFloat"],
        permittedPath: "Sources/Headless/HeadlessGeometryBridge.swift",
        in: try headlessSourceFiles())

    #expect(found.isEmpty, """
        a CoreGraphics geometry type reached Headless outside its bridge:
        \(found.joined(separator: "\n"))
        Convert at Sources/Headless/HeadlessGeometryBridge.swift and pass scalars or the \
        package's own types onward; see ARCHITECTURE.md D3.
        """)
}

/// Every function declared in one file, by **full signature** — base name plus
/// argument labels, `point(x:y:)` rather than `point`.
///
/// **The granularity is a correction to this task's brief, and it is a measured
/// one.** The brief specified bare base names, on the argument that an overload set
/// is one name — true, but the two bridges already share the base name `point`:
/// `CGGeometryBridge.point(fromAXValue:)` decodes an accessibility value into
/// scalars and `HeadlessGeometryBridge.point(x:y:)` builds a `CGPoint` from them.
/// They are opposite directions of the pipeline and neither can drift from the
/// other, so a base-name check would have been red on the day it was written — a
/// gate that cannot go green gets an exception added to it, and an exception is
/// exactly what the two-bridge split refuses to buy. Full signatures still catch the
/// failure mode the check exists for: a second `point(x:y:)`, or a second
/// `outputCanvas(width:height:)`, appearing in whichever bridge someone happened to
/// be editing.
///
/// **The residual weakening, stated rather than left as an unstated cost:** a
/// duplicate written with DIFFERENT labels — `point(atX:y:)` beside `point(x:y:)` —
/// is two signatures and this check does not see it, where a base-name check would
/// have. That is unavoidable, because the base-name check is not writable at all
/// here (`point` is already shared, legitimately), but it is a real hole and review
/// is what covers it. The same trade the entry scanner makes one section down: the
/// instrument is a necessary condition, and saying so is the only thing that keeps
/// it from being read as more.
///
/// A line scan, so a declaration whose parameter list wraps is not parsed — which
/// would be a silent miss. The count check below turns it into a loud one instead.
func functionSignatures(inFileAt relativePath: String) throws -> Set<String> {
    let text = try String(contentsOf: repositoryRoot.appending(path: relativePath),
                          encoding: .utf8)
    let lines = SwiftSourceLexer.codeViewLines(of: text)
    var signatures: [String] = []
    var declarationLines = 0

    for line in lines {
        guard let keyword = line.range(of: "func ") else { continue }
        declarationLines += 1
        let rest = line[keyword.upperBound...]
        guard let open = rest.firstIndex(of: "(") else { continue }
        let base = rest[..<open].trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, base.allSatisfy({ SwiftSourceLexer.isIdentifierCharacter($0) })
        else { continue }

        var depth = 0
        var parameters = ""
        var closed = false
        for character in rest[open...] {
            if character == "(" {
                depth += 1
                if depth == 1 { continue }
            }
            if character == ")" {
                depth -= 1
                if depth == 0 { closed = true; break }
            }
            parameters.append(character)
        }
        guard closed else { continue }

        var labels: [String] = []
        var depthInParameters = 0
        var current = ""
        for character in parameters + "," {
            switch character {
            case "(", "[", "<": depthInParameters += 1; current.append(character)
            case ")", "]", ">": depthInParameters -= 1; current.append(character)
            case "," where depthInParameters == 0:
                let label = current.split(whereSeparator: { !SwiftSourceLexer.isIdentifierCharacter($0) && $0 != "_" })
                    .map(String.init).first
                if let label, !label.isEmpty { labels.append(label) }
                current = ""
            default: current.append(character)
            }
        }

        signatures.append("\(base)(\(labels.map { "\($0):" }.joined()))")
    }

    try #require(signatures.count == declarationLines, """
        \(relativePath): \(declarationLines) code line(s) declare a function but only \
        \(signatures.count) were parsed into a signature. A declaration whose parameter list \
        wraps onto a second line is invisible to this line scan, and an invisible declaration \
        is a hole in the disjointness check below rather than a failure of it.
        """)
    return Set(signatures)
}

/// **Two bridges, one definition each.** The tiers are split because their ENTRANCES
/// differ — AX and ScreenCaptureKit need `ApplicationServices`, the render exits need
/// nothing — but a function defined in both would be the split's actual failure mode:
/// one copy gets a fix, the other does not, and both pass their own tier's test.
///
/// Measured when the split was made: the three render exits had 17 call sites and not
/// one of them in `Soredemo/Capture/`, so there is nothing to delegate and no edge to
/// add. This test is about the day after that measurement stops being true.
///
/// When `Capture` moves in 3A-2 the two bridges become one and this test is deleted
/// with them — it is scaffolding for a boundary that is meant to be temporary, which
/// is stated here so it is not mistaken for a permanent rule.
///
/// **`…ShareNoFunctionSignature`, not `…ShareNoFunctionName`, and the rename is the
/// point.** Under the first name this test was green while the two bridges
/// demonstrably DO share the function name `point` — a title claiming more than the
/// check verifies, which is the exact defect this file's own entry scanner carries a
/// paragraph about. A doc comment does not travel with `--list-tests` output; the
/// identifier does.
@Test func theTwoGeometryBridgesShareNoFunctionSignature() throws {
    let app = try functionSignatures(inFileAt: "Soredemo/Capture/CGGeometryBridge.swift")
    let headless = try functionSignatures(inFileAt: "Sources/Headless/HeadlessGeometryBridge.swift")
    try #require(!app.isEmpty && !headless.isEmpty,
                 "a bridge scanned as empty — the scan is broken, not the bridges")

    #expect(app.isDisjoint(with: headless), """
        both geometry bridges define \(app.intersection(headless).sorted()).
        Two implementations of the same conversion drift: one gets the fix, the other does not, \
        and each passes its own tier's rule-5 test while disagreeing with the other.
        Define it once. `Soredemo/Capture/` is the upper tier and can `import Headless` if it \
        genuinely needs a render-side exit — but measure the call sites first; when this split \
        was made there were none.
        """)
}

// MARK: - the entry rule

/// Every `public` type declared in a set of files, at any nesting depth, read
/// through the code view so a `public struct` inside a doc comment is not one.
///
/// A line scan, not a brace-matching parse. `architecture-checker` has the real
/// parser (`declarationSites(in:file:)`) and a test target cannot import an
/// `executableTarget`, so this is the second-cheapest thing that answers the
/// question — and the question is only ever a NECESSARY condition, so a line scan
/// is the right size of instrument for it. Nested declarations are found because
/// they are still lines beginning (after whitespace and modifiers) with `public`.
func publicTypeDeclarations(in files: [URL]) throws -> [(name: String, location: String)] {
    let typeKeywords: Set<String> = ["struct", "class", "enum", "actor", "protocol"]
    // Modifiers Swift permits between `public` and the keyword. `final`, `nonisolated`
    // and `indirect` all appear in this tree today; the list is walked, not matched,
    // so an unknown modifier costs a missed declaration rather than a wrong name —
    // and a missed declaration is caught by review, which is the level that enforces
    // the rule anyway.
    let modifiers: Set<String> = ["final", "nonisolated", "indirect", "open", "static"]
    var found: [(name: String, location: String)] = []
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        for (index, line) in SwiftSourceLexer.codeViewLines(of: text).enumerated() {
            let words = line.split(whereSeparator: { !SwiftSourceLexer.isIdentifierCharacter($0) })
                .map(String.init)
            guard let publicIndex = words.firstIndex(of: "public") else { continue }
            var cursor = publicIndex + 1
            while cursor < words.count, modifiers.contains(words[cursor]) { cursor += 1 }
            guard cursor + 1 < words.count, typeKeywords.contains(words[cursor]) else { continue }
            let name = words[cursor + 1].replacingOccurrences(of: "`", with: "")
            guard !name.isEmpty else { continue }
            found.append((name: name,
                          location: "\(pathRelativeToRepositoryRoot(file)):\(index + 1)"))
        }
    }
    return found
}

/// **The entry rule's SCANNER — a necessary condition, and not the rule.**
///
/// The rule is: every `public` type in `Headless` has a test that CONSTRUCTS AND
/// EXERCISES it. No scanner can see that. A type annotation, a doc comment that
/// survived the code view, or an unused `import` would satisfy this check while the
/// type is never built and never run. **Review enforces the rule; this enforces
/// that the type is at least mentioned in code by a test that links the product.**
///
/// Saying otherwise would plant this project's own recurring defect inside the gate
/// built to prevent it: probe § 12 passed because its fixture and the code under
/// test shared one wrong frame of reference, and its title claimed more than it
/// checked. A gate that overstates itself is that shape exactly.
///
/// **Discriminating power falls as the name gets generic.** `Frame`, `Track`,
/// `Renderer` appear at a word boundary in almost any test file, so for names like
/// those this check is close to vacuous — and a dumping ground is full of names
/// like those. That is stated in the failure message too, not only here.
@Test func everyPublicTypeInHeadlessIsNamedByATestThatLinksTheProduct() throws {
    let declarations = try publicTypeDeclarations(in: try headlessSourceFiles())
    try #require(!declarations.isEmpty,
                 "no public types found under Sources/Headless — this scan would pass vacuously")

    let testFiles = try headlessTestFiles()
    for declaration in declarations {
        let mentions = try codeLinesNaming(declaration.name, in: testFiles)
            .filter { line in
                // Word boundary, the same filter `theUnexercisedPublicAPITableMatchesTheTree`
                // uses and for the same reason: without it `CMTimeRange` counts as a use of
                // `TimeRange`, and a presence count is exactly where that difference decides
                // the answer.
                var searchRange = line.text.startIndex..<line.text.endIndex
                while let hit = line.text.range(of: declaration.name, range: searchRange) {
                    let before = hit.lowerBound > line.text.startIndex
                        ? line.text[line.text.index(before: hit.lowerBound)] : " "
                    let after = hit.upperBound < line.text.endIndex
                        ? line.text[hit.upperBound] : " "
                    let glued = { (c: Character) in c.isLetter || c.isNumber || c == "_" }
                    if !glued(before) && !glued(after) { return true }
                    searchRange = hit.upperBound..<line.text.endIndex
                }
                return false
            }
        #expect(!mentions.isEmpty, """
            `\(declaration.name)` (\(declaration.location)) is public in Headless and no test \
            under Tests/HeadlessTests names it.

            THIS CHECK IS A NECESSARY CONDITION, NOT THE RULE. The rule is that a test \
            CONSTRUCTS AND EXERCISES the type, and no scanner can see that — a type annotation \
            or an unused import would satisfy this message. Review is what enforces the rule.

            For a generic name (Frame, Track, Renderer) this check is close to vacuous, because \
            such a name appears at a word boundary in almost any test file. Those are also the \
            names a dumping ground is full of.

            If this type does not need to be public, un-public it — that is the cheaper fix and \
            the one the entry rule is for.
            """)
    }
}

// MARK: - the manifest's own shape

/// `swift package dump-package`'s `targets` array.
///
/// **Duplicated from `Tests/GeometryTests/ArchitectureCheckTests.swift`, and the
/// duplication is a target boundary rather than carelessness**: the two live in
/// different test targets, which cannot share a file-scope declaration, and the only
/// module both can import is `CheckerLexer` — the one target outside plugin
/// enforcement, which is the least-guarded place in the package to put shared code.
///
/// A separate `--scratch-path` keeps this off the `.build` directory the enclosing
/// `swift test` is holding.
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

/// One target's declared dependency names, whichever of `dump-package`'s two
/// spellings (`byName`, `target`) the manifest produced.
func manifestDependencyNames(of target: [String: Any]) -> [String] {
    (target["dependencies"] as? [[String: Any]] ?? [])
        .compactMap { ($0["byName"] as? [Any] ?? $0["target"] as? [Any])?.first as? String }
}

/// **The tier boundary in the other direction, and the manifest is the ONLY place it
/// can be checked.**
///
/// `noDeterministicTestTargetDependsOnHeadless` below covers test targets. This one
/// covers the library targets, and the reason it is not redundant is that
/// `ArchitectureCheck` cannot possibly catch it: the plugin passes one `--allow` per
/// DECLARED dependency, so **rule 1's allow-list IS the manifest**. Declare
/// `Headless` as a dependency of a pure target and `import Headless` inside it
/// immediately becomes legal — rule 1 permits it, rule 2 never looks at what a
/// permitted import drags in, and the deterministic tier has absorbed AVFoundation,
/// the GPU and wall time with every guard still green.
///
/// **Which pure targets can actually do this, measured rather than assumed.**
/// `Headless` depends on `Project`, which depends on `Graph`, so `Geometry`,
/// `Timeline`, `Project`, `Graph` and `Render` are all cycle-blocked: SwiftPM
/// refuses to resolve the package (`cyclic dependency declaration found:
/// DeterminismTests -> Graph -> Headless -> Project -> Graph`) and the failure
/// arrives before any test runs. `Framing` and `Variants` are NOT reachable from
/// `Headless`, so for those two the edge resolves cleanly and every guard stays
/// green — which is what this test was observed red on. A rule that holds for five
/// targets by accident of the graph and for two only because nobody has tried is
/// exactly the shape this phase exists to replace, so the manifest is asserted
/// directly.
///
/// `Headless` itself is excluded for the obvious reason, and the exclusion is by
/// exact name rather than by a pattern: a second headless-ish target would be a
/// second tier and must argue for itself here.
@Test func noPureTargetDependsOnHeadless() throws {
    let targets = try resolvedManifestTargets()
    let regular = targets.filter { $0["type"] as? String == "regular" }
    try #require(regular.count > 1, "expected several regular targets, got \(regular.count)")
    try #require(regular.contains { $0["name"] as? String == "Headless" },
                 "no regular target named Headless — this scan would pass vacuously")

    for target in regular {
        let name = target["name"] as? String ?? "<unnamed>"
        guard name != "Headless" else { continue }
        #expect(!manifestDependencyNames(of: target).contains("Headless"), """
            \(name) declares Headless as a dependency, and no guard can see that this is wrong.
            ArchitectureCheck passes one --allow per DECLARED dependency, so rule 1's allow-list \
            is this manifest: the edge itself is what makes `import Headless` legal inside \
            \(name). The deterministic tier would then reach AVFoundation, the GPU and wall time \
            through one import, with the plugin green on every file.
            The dependency runs the other way. Headless depends on the pure targets; nothing pure \
            depends on Headless.
            """)
    }
}

/// **The two test populations are kept apart by the build graph, not by a rule.**
///
/// Two counts are an assertion until something prevents a test landing in the wrong
/// one. A deterministic test target that cannot LINK `Headless` cannot have a
/// GPU-dependent or time-sensitive test written against it, so the manifest is the
/// mechanism and this test is what keeps the manifest honest.
@Test func noDeterministicTestTargetDependsOnHeadless() throws {
    let targets = try resolvedManifestTargets()
    let testTargets = targets.filter { $0["type"] as? String == "test" }
    try #require(testTargets.count > 1, "expected several test targets, got \(testTargets.count)")

    for target in testTargets {
        let name = target["name"] as? String ?? "<unnamed>"
        let dependencies = manifestDependencyNames(of: target)
        if name == "HeadlessTests" {
            #expect(dependencies.contains("Headless"),
                    "HeadlessTests must depend on Headless or the headless population is empty")
        } else {
            #expect(!dependencies.contains("Headless"), """
                \(name) depends on Headless. The deterministic population is defined by NOT being \
                able to link it; once one deterministic target can, `swift test --skip HeadlessTests` \
                stops meaning "the deterministic tests" and the two counts become two numbers.
                """)
        }
    }
}
