import CheckerLexer
import Foundation
import Testing

// Reuses `repositoryRoot`, `codeLinesNaming`, `violations` and `pathRelativeToRepositoryRoot`
// from `AppSourceAllowListTests.swift` — file-scope declarations in this same target.

/// Every `.swift` file under `Sources/Headless`.
/// Every `.swift` file in the runnable tier — both targets. Phase 3A-4 split `Headless`
/// into `Capture` and `Compositing`; the scans that ask "does the runnable tier do X"
/// still mean both, and the scans that ask "which half" now say so by naming a directory
/// rather than by carrying an exclusion list.
func runnableTierSourceFiles() throws -> [URL] {
    try swiftFiles(under: "Sources/Capture") + (try swiftFiles(under: "Sources/Compositing"))
}

/// Kept under the old name so unrelated call sites read unchanged.
func headlessSourceFiles() throws -> [URL] { try runnableTierSourceFiles() }

func captureSourceFiles() throws -> [URL] { try swiftFiles(under: "Sources/Capture") }
func compositingSourceFiles() throws -> [URL] { try swiftFiles(under: "Sources/Compositing") }
func captureTestFiles() throws -> [URL] { try swiftFiles(under: "Tests/CaptureTests") }
func compositingTestFiles() throws -> [URL] { try swiftFiles(under: "Tests/CompositingTests") }

/// Same enumeration `firstPartySourceFiles()` uses, over one directory. Empty is a failure:
/// a scan over nothing passes vacuously, and someone is counting on it.
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

/// **Rule 5's Headless half.** CoreGraphics geometry is confined to
/// `Sources/Compositing/HeadlessGeometryBridge.swift`, with no exception. `HeadlessCheck` cannot
/// do this job: rule 2 is off in headless mode, which is where CG conversion legitimately happens.
@Test func coreGraphicsGeometryTypesAppearOnlyInTheHeadlessBridge() throws {
    let found = try violations(
        banned: ["CGRect", "CGPoint", "CGSize", "CGFloat"],
        permittedPaths: ["Sources/Compositing/HeadlessGeometryBridge.swift",
                         "Sources/Capture/CGGeometryBridge.swift"],
        in: try headlessSourceFiles())

    #expect(found.isEmpty, """
        a CoreGraphics geometry type reached Headless outside its bridge:
        \(found.joined(separator: "\n"))
        Convert at Sources/Compositing/HeadlessGeometryBridge.swift and pass scalars or the \
        package's own types onward; see ARCHITECTURE.md D3.
        """)
}

/// Every function declared in one file by **full signature** — `point(x:y:)`, not `point`:
/// both bridges legitimately declare the base name `point`, so a base-name check could never
/// go green. A line scan; a wrapped parameter list is caught loudly by the count check below.
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

/// **Two bridges, one definition each.** A function defined in both is the split's own failure
/// mode: one copy gets a fix, the other does not, and each passes its own tier's test. Named
/// `…ShareNoFunctionSignature`, not `…ShareNoFunctionName` — the bridges do share `point`.
///
/// **Both bridges are in `Sources/Headless` since Phase 3A-3**, which makes this check MORE
/// load-bearing rather than less: they are now two files in one target, where the pull toward
/// "merge them, they are both CG conversion" is strongest. They stay separate because they
/// face opposite directions — `CGGeometryBridge` is the capture tier's ENTRY (AX frames,
/// ScreenCaptureKit rects), `HeadlessGeometryBridge` the render tier's EXIT (the rects Core
/// Image and AVFoundation demand). The variable is still named `capture`/`render` after the
/// tier, not after the directory, because the tier is what the disjointness is about.
@Test func theTwoGeometryBridgesShareNoFunctionSignature() throws {
    let app = try functionSignatures(inFileAt: "Sources/Capture/CGGeometryBridge.swift")
    let headless = try functionSignatures(inFileAt: "Sources/Compositing/HeadlessGeometryBridge.swift")
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

/// Every `public`/`open` type declared in a set of files, at any nesting depth, read through the
/// code view. A line scan, not a parse — only ever a NECESSARY condition for the entry rule.
func publicTypeDeclarations(in files: [URL]) throws -> [(name: String, location: String)] {
    let typeKeywords: Set<String> = ["struct", "class", "enum", "actor", "protocol"]
    // `open` and `public` are distinct, mutually exclusive access levels — `open class Foo`
    // carries no `public` token, so both must be accepted as the declaration's entry keyword.
    let entryKeywords: Set<String> = ["public", "open"]
    // Modifiers Swift permits between the entry keyword and the type keyword. The list is
    // walked, not matched: an unknown modifier costs a missed declaration, not a wrong name.
    let modifiers: Set<String> = ["final", "nonisolated", "indirect", "static"]
    var found: [(name: String, location: String)] = []
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        for (index, line) in SwiftSourceLexer.codeViewLines(of: text).enumerated() {
            let words = line.split(whereSeparator: { !SwiftSourceLexer.isIdentifierCharacter($0) })
                .map(String.init)
            guard let entryIndex = words.firstIndex(where: { entryKeywords.contains($0) }) else { continue }
            var cursor = entryIndex + 1
            while cursor < words.count, modifiers.contains(words[cursor]) { cursor += 1 }
            guard cursor + 1 < words.count, typeKeywords.contains(words[cursor]) else { continue }
            // `public typealias` is deliberately not scanned: it names an existing type, found
            // here under its own declaration, and cannot widen that type's access.
            let name = words[cursor + 1].replacingOccurrences(of: "`", with: "")
            guard !name.isEmpty else { continue }
            found.append((name: name,
                          location: "\(pathRelativeToRepositoryRoot(file)):\(index + 1)"))
        }
    }
    return found
}

/// **The entry rule's SCANNER — a necessary condition, and not the rule.** The rule is that a
/// test CONSTRUCTS AND EXERCISES every `public` type in the runnable tier, which no scanner
/// can see; for a generic name (`Frame`, `Track`, `Renderer`) this check is close to vacuous.
///
/// **Per target since Phase 3A-4, and that is stricter than it was.** Each target is checked
/// against ITS OWN test directory, so a `Capture` type named only in a Compositing test no
/// longer counts — which is the same boundary the build graph now enforces on the product
/// code, applied to the tests that stand for it.
@Test func everyPublicTypeInCaptureIsNamedByACaptureTest() throws {
    try assertEveryPublicTypeIsNamedByItsOwnTests(
        target: "Capture", sources: try captureSourceFiles(), tests: try captureTestFiles(),
        testDirectory: "Tests/CaptureTests")
}

@Test func everyPublicTypeInCompositingIsNamedByACompositingTest() throws {
    try assertEveryPublicTypeIsNamedByItsOwnTests(
        target: "Compositing", sources: try compositingSourceFiles(),
        tests: try compositingTestFiles(), testDirectory: "Tests/CompositingTests")
}

private func assertEveryPublicTypeIsNamedByItsOwnTests(
    target: String, sources: [URL], tests testFiles: [URL], testDirectory: String
) throws {
    let declarations = try publicTypeDeclarations(in: sources)
    try #require(!declarations.isEmpty,
                 "no public types found in \(target) — this scan would pass vacuously")
    try #require(!testFiles.isEmpty,
                 "no tests found under \(testDirectory) — this scan would fail vacuously")

    for declaration in declarations {
        let mentions = try codeLinesNaming(declaration.name, in: testFiles)
            .filter { line in
                // Word boundary, or `CMTimeRange` counts as a use of `TimeRange` — and a
                // presence count is exactly where that difference decides the answer.
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
            `\(declaration.name)` (\(declaration.location)) is public in \(target) and no test \
            under \(testDirectory) names it.

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

/// `swift package dump-package`'s `targets` array. Duplicated from
/// `Tests/GeometryTests/ArchitectureCheckTests.swift` because separate test targets cannot share
/// a file-scope declaration. A separate `--scratch-path` keeps this off the enclosing `.build`.
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

/// **The tier boundary in the other direction, and the manifest is the only place it can be
/// checked.** `ArchitectureCheck` passes one `--allow` per DECLARED dependency, so the edge
/// itself is what would make `import Headless` legal inside a pure target, every guard green.
@Test func noPureTargetDependsOnTheRunnableTier() throws {
    let runnable = ["Capture", "Compositing"]
    let targets = try resolvedManifestTargets()
    let regular = targets.filter { $0["type"] as? String == "regular" }
    try #require(regular.count > 1, "expected several regular targets, got \(regular.count)")
    for name in runnable {
        try #require(regular.contains { $0["name"] as? String == name },
                     "no regular target named \(name) — this scan would pass vacuously")
    }

    for target in regular {
        let name = target["name"] as? String ?? "<unnamed>"
        guard !runnable.contains(name) else { continue }
        let dependencies = manifestDependencyNames(of: target)
        for runnableName in runnable {
            #expect(!dependencies.contains(runnableName), """
                \(name) declares \(runnableName) as a dependency, and no guard can see that this \
                is wrong. ArchitectureCheck passes one --allow per DECLARED dependency, so rule \
                1's allow-list is this manifest: the edge itself is what makes \
                `import \(runnableName)` legal inside \(name). The deterministic tier would then \
                reach AVFoundation, the GPU and wall time through one import, with the plugin \
                green on every file.
                The dependency runs the other way. The runnable tier depends on the pure targets; \
                nothing pure depends on it.
                """)
        }
    }
}

/// **`Capture` and `Compositing` do not depend on each other, and the manifest is where that
/// is checked.** This is the invariant Phase 3A-4's split exists to create. Before it, the two
/// halves lived in one target and referenced each other zero times — a fact nothing enforced,
/// so nothing would have reported the first reference that appeared.
///
/// Asserted in BOTH directions rather than once: they are different claims. Capture reaching
/// into Compositing would mean the thing that records has started depending on the thing that
/// draws; Compositing reaching into Capture would mean the renderer can start a tap. Neither
/// is more likely than the other and a single-direction check would call one of them fine.
@Test func theTwoRunnableTargetsDoNotDependOnEachOther() throws {
    let targets = try resolvedManifestTargets()
    let byName = Dictionary(uniqueKeysWithValues: targets.compactMap { target -> (String, [String: Any])? in
        guard let name = target["name"] as? String else { return nil }
        return (name, target)
    })
    for (a, b) in [("Capture", "Compositing"), ("Compositing", "Capture")] {
        let target = try #require(byName[a], "no target named \(a) — this scan would pass vacuously")
        #expect(!manifestDependencyNames(of: target).contains(b), """
            \(a) declares \(b) as a dependency. These two are siblings on purpose: \(a) and \(b) \
            do two unrelated jobs and referenced each other zero times when they were split \
            (Phase 3A-4). An edge here makes `import \(b)` legal throughout \(a), and the next \
            reader has no way to tell an intended dependency from one that compiled.
            If \(a) genuinely needs something from \(b), the shared thing belongs in a pure \
            target both can depend on — which is what Geometry, Timeline, Project and Render are.
            """)
    }
}

/// **The two test populations are kept apart by the build graph, not by a rule.** A deterministic
/// target that cannot LINK `Headless` cannot host a GPU-dependent or time-sensitive test.
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
