# Phase 3A-1 — `Headless` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use a skill chain:subagent-driven-development (recommended) or a skill chain:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `Soredemo/Render/` (5 files) and `Soredemo/Export/MP4Exporter.swift` into a new SwiftPM target `Headless`, so that `swift test` can link and execute the code that held `1a98402` for a whole phase.

**Architecture:** Three testability tiers. `Sources/Geometry…Render` stay deterministic and keep the Foundation-only `ArchitectureCheck` guard. New `Sources/Headless` is *runnable under `swift test` on a developer machine* — real GPU, real pixel buffers, wall time all permitted — and carries its own guard banning AppKit and SwiftUI. `Soredemo/` keeps only what a running app can reach. The two guards are two rules with no exceptions, not one guard with a hole.

**Tech Stack:** Swift 6.3 tools / language mode v6, `.strictMemorySafety()`, macOS 26 floor, Swift Testing, SwiftPM build-tool plugins, AVFoundation / CoreImage / CoreVideo / Metal / CoreGraphics inside `Headless` only.

**Design doc:** `docs/design/2026-08-04-phase-3a-foundation-design.md`. Read it once before Task 1; do not re-derive its decisions.

## Global Constraints

Every task's requirements implicitly include this section.

- **The target is `Headless`; the product is `SoredemoHeadless`.** It is NOT `SoredemoCore` and it is never added to `SoredemoCore`'s `targets:` array — that name is the Foundation-only product in five documents (KICKOFF.md D6, the `architecture-plugin` completion criterion, AGENTS.md, `Minting.swift`'s header, and `componentsAssertedInProseDoNotExistOnlyInProse`). `Sources/SoredemoCore` must never exist as a directory; a test already pins this.
- **`Sources/Headless` carries the `HeadlessCheck` plugin, never `ArchitectureCheck`.** Measured: `ArchitectureCheck` rule 1 allows only Foundation plus declared sibling targets, and rule 2 bans `CGRect`/`CGPoint`/`CGSize`/`CGFloat` anywhere. The moved files import AVFoundation, CoreImage, CoreVideo, CoreMedia, Metal and CoreGraphics, and name CG types on 8 lines. Attaching the pure guard is impossible; loosening it is forbidden.
- **`Headless`'s invariant: `import AppKit` or `import SwiftUI` fails the build.** No exceptions, no directory carve-outs, no name-keyed special cases inside the pure guard.
- **The entry rule: every `public` type in `Headless` must have a test in `swift test` that constructs and exercises it.** "Type" means every `public` `struct`, `class`, `actor` and `enum`, at any nesting depth. A `public` protocol is exempt from CONSTRUCTION and not from exercise: some conforming type must be exercised, **and the exercised conforming type may not be a test-only type**. A `public` function or property on an already-exercised type needs no separate entry.
- **The entry rule is enforced at two levels and they are not the same.** The scanner enforces a NECESSARY condition only — the type's identifier appears at a word boundary in the code view of a test target. Review enforces the rule itself. Every scanner message must say which of the two it is; writing "the scanner enforces the rule" would plant this project's own recurring defect inside the gate built to prevent it.
- **Deterministic test targets must not depend on the `Headless` target.** A test that cannot link it cannot be written against it. `HeadlessTests` is the only test target that declares it. (The design doc says "`SoredemoHeadless`" here; that is the product the Xcode app links. Inside the package the dependency edge is on the target, and the target is what the manifest test asserts.)
- **The cross-boundary probe compiles `Headless` sources BY PATH, as source.** It must not link `SoredemoHeadless`, and **no declaration may be widened to `public` in order to make the probe compile.** Widening for the probe's sake grows the public surface, which the entry rule then requires tests for, which puts pressure on loosening the scanner.
- **`ArchitectureCheck`'s plugin source may never pass `--mode` or `--ban`.** Those flags exist for `HeadlessCheck`. A test pins this.
- **Numbers in reports are executable, and a test count never goes into a prose document.** `swift test`'s total comes from `scripts/count-tests.sh` — never from a hand-written `grep`, never from memory, and never copied into a `.md` that changes less often than the number does. Baseline measured once, on 2026-08-05 at `f8b9998`, for this plan's own arithmetic only: **454** (`--skip RenderTests` 422 + `--filter RenderTests` 32 = 454, confirmed). Three documents currently disagree with it and with each other — `ROADMAP.md` 464, `docs/ARCHITECTURE.md` 462, the design doc's § 4 example 466. **Task 8 removes all three rather than correcting them**, and gates the position they were written at.
- **The probe is 349 checks.** `scripts/run-cross-boundary-probe.sh` must stay green at every task boundary.
- **No recording, log or frame dump is committed** except the one deliberately redacted fixture Task 5 creates. Capture output goes to temp directories and is deleted; never write to `$HOME`.
- **Never `git add -A`.** Add named paths.

## Gates at every task boundary

Every task ends with all four green, and the task's commit message quotes the numbers:

```bash
swift build                                  # both guards run here
scripts/count-tests.sh                       # per-target breakdown + total
scripts/run-cross-boundary-probe.sh          # 349 checks
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -configuration Debug build
```

## File Structure

| Path | Responsibility | Task |
| --- | --- | --- |
| `Sources/architecture-checker/main.swift` | gains `--mode headless` and `--ban <module>`: a deny-list mode replacing rule 1's allow-list and disabling rule 2 | 1 |
| `Plugins/HeadlessCheck/HeadlessCheck.swift` | the second guard's build-tool plugin; passes `--mode headless --ban AppKit --ban SwiftUI` | 1 |
| `Tests/GeometryTests/ArchitectureCheckTests.swift` | gains the headless-mode fixtures; loop over regular targets now demands the RIGHT guard per target | 1, 2 |
| `Sources/Headless/CursorArt.swift` | moved from `Soredemo/Render/`; the skeleton's one type | 2 |
| `Tests/HeadlessTests/CursorArtTests.swift` | the skeleton's entry-rule test | 2 |
| `Tests/AppSourceTests/HeadlessEntryRuleTests.swift` | the entry scanner (necessary condition) and the manifest-shape tests | 2 |
| `scripts/count-tests.sh` | gains `--split`: two populations plus the sum invariant | 2 |
| `Sources/Headless/FrameRenderer.swift`, `CoreImageFrameRenderer.swift` | the `FrameRendering` seam and its production conformer | 3 |
| `Sources/Headless/StageCompositor.swift`, `CompositionBuilder.swift` | the compositor and the composition it is installed into | 4 |
| `Tests/HeadlessFixtures/segment-00-redacted.jsonl` | the recorded observation log, redacted by schema | 5 |
| `scripts/redact-observation-log.swift` | the committed redaction tool | 5 |
| `Tests/AppSourceTests/FixtureRedactionTests.swift` | the schema scan, the content gate and the consumption gate | 5 |
| `Tests/HeadlessTests/RecordedPointerPositionTests.swift` | the completion condition | 6 |
| `Sources/Headless/MP4Exporter.swift` | moved from `Soredemo/Export/`, with I6's uncapped poll capped | 7 |
| `Tests/CheckerLexerTests/LexerImportDisciplineTests.swift` | CheckerLexer's hand-maintained rule-1 consequence, enforced | 8 |

**Tasks 1 and 2 together are the walking skeleton.** Task 3 is the first bulk move and **must not start until Task 2's gates are green.** If the skeleton finds that "deterministic test targets must not depend on `SoredemoHeadless`" cannot be expressed, or that the two-population split has no clean form under SwiftPM, the loss is one moved type — not six files.

---

### Task 1: The second guard (walking skeleton, part 1 of 2)

Teach `architecture-checker` a deny-list mode and give `HeadlessCheck` a plugin. No target moves in this task; the mode is exercised entirely through temporary fixture directories, exactly as every other checker rule already is.

**Files:**
- Modify: `Sources/architecture-checker/main.swift`
- Create: `Plugins/HeadlessCheck/HeadlessCheck.swift`
- Modify: `Package.swift` (declare the plugin only — no `Headless` target yet)
- Test: `Tests/GeometryTests/ArchitectureCheckTests.swift`

**Interfaces:**
- Consumes: `ArchitectureChecker.importedModules(in:)`, `values(of:in:)`, `SwiftSourceLexer.codeViewLines(of:)` — all existing.
- Produces: the checker CLI contract `--mode headless --ban <module>…`, consumed by Task 2's `Package.swift` when it attaches `plugins: headlessCheck` to `Headless`.

Read `Sources/architecture-checker/main.swift` before starting. The relevant region is `run(arguments:)`, lines 637-805: the allow-list resolution at 691-700, rule 1 at 739-743, rule 2 at 748-753.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/GeometryTests/ArchitectureCheckTests.swift`:

```swift
// MARK: - the second guard: --mode headless
//
// `Sources/Headless` is the tier `swift test` can run but a person still has to
// believe. It legitimately imports AVFoundation, CoreImage, CoreVideo, CoreMedia,
// Metal and CoreGraphics, and it legitimately names CGRect — it is the boundary
// where CG geometry gets converted (ARCHITECTURE.md D3), so rule 2's ban is not
// its rule. Attaching `ArchitectureCheck` to it is therefore impossible, and the
// answer is a SECOND GUARD with its own single rule, not a hole in the first.

/// Runs the real built checker in headless mode over a one-file fixture.
func runHeadlessChecker(ban: [String] = ["AppKit", "SwiftUI"],
                        source: String) throws -> (status: Int32, stderr: String) {
    try runChecker(targetName: "Headless",
                   additionalArguments: ["--mode", "headless"] + ban.flatMap { ["--ban", $0] },
                   populate: { dir in
                       try source.write(to: dir.appending(path: "Probe.swift"),
                                        atomically: true, encoding: .utf8)
                   })
}

/// The one rule. Every spelling `rejectsDisallowedImport` already closes for rule 1
/// is closed here too, because both rules read the SAME token stream — a bypass in
/// the tokenizer is a bypass for both, and a guard that only knows the plain
/// spelling is a guard whose evasions start again at round zero.
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
])
func headlessModeRejectsTheBannedModules(_ source: String) throws {
    let result = try runHeadlessChecker(source: source)
    #expect(result.status == 1, "should reject: \(source.debugDescription)")
    #expect(!result.stderr.isEmpty)
}

/// What the tier EXISTS to permit. If any of these fails the guard is the pure
/// guard wearing a different name, and the whole design has bought nothing.
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

/// Rule 2 is OFF in headless mode, deliberately and with a reason: this tier is
/// the app boundary where CG geometry is converted to and from the package's own
/// types. `CursorArt` draws in CG space; banning CGRect here would ban the tier's
/// purpose.
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

/// **A guard that bans nothing is not a guard.** Same rule as
/// `failsOnSourcesDirectoryWithNoSwiftFiles`: a vacuous pass is not a pass, and
/// `--mode headless` with the `--ban` flags dropped would be a silent void of the
/// entire second guard on every build.
@Test func headlessModeWithNoBanListFailsClosed() throws {
    let result = try runHeadlessChecker(ban: [], source: "import Foundation")
    #expect(result.status == 2, "stderr: \(result.stderr)")
    #expect(result.stderr.contains("--ban"))
}

/// Rule 8 still runs in headless mode. It is not about frameworks — a synthesised
/// `Decodable` bypasses a stated invariant wherever the type lives — so switching
/// it off with rules 1 and 2 would be scope creep in the silent direction.
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

/// **The loosening flags must never reach the pure guard.** `--mode headless`
/// turns off rule 1's allow-list and rule 2 entirely; a day where
/// `ArchitectureCheck` passes it is a day `SoredemoCore` can import AppKit and the
/// build stays green. Read through the code view so a mention in this plugin's own
/// doc comment does not fire.
@Test func theArchitectureCheckPluginNeverPassesTheHeadlessFlags() throws {
    let source = try String(contentsOf: repositoryRoot
        .appending(path: "Plugins/ArchitectureCheck/ArchitectureCheck.swift"), encoding: .utf8)
    let code = SwiftSourceLexer.codeViewLines(of: source).joined(separator: "\n")
    #expect(!code.contains("--mode"),
            "ArchitectureCheck passes --mode: rule 1's allow-list and rule 2 would be off for a pure target")
    #expect(!code.contains("--ban"),
            "ArchitectureCheck passes --ban: the deny-list belongs to HeadlessCheck alone")
}

/// The mirror: `HeadlessCheck` must pass both bans and must NOT pass `--allow`.
/// A `--allow` there would read as an allow-list in a mode that has none — the
/// shape that makes a reader believe a guard is stricter than it is.
@Test func theHeadlessCheckPluginPassesBothBansAndNoAllowList() throws {
    let source = try String(contentsOf: repositoryRoot
        .appending(path: "Plugins/HeadlessCheck/HeadlessCheck.swift"), encoding: .utf8)
    let code = SwiftSourceLexer.codeViewLines(of: source).joined(separator: "\n")
    #expect(code.contains("\"AppKit\""))
    #expect(code.contains("\"SwiftUI\""))
    #expect(code.contains("\"--mode\", \"headless\""))
    #expect(!code.contains("--allow"),
            "headless mode has no allow-list; passing --allow would misdescribe the guard")
}
```

`ArchitectureCheckTests.swift` needs `import CheckerLexer` at the top for `SwiftSourceLexer` — add it if absent, and add `"CheckerLexer"` to `GeometryTests`' dependencies in `Package.swift`.

The existing `runChecker(targetName:allow:populate:)` has no `additionalArguments` parameter. Add one, defaulted, so no existing caller changes:

`additionalArguments` goes BEFORE `populate` in the signature: `populate` is the trailing closure, and a non-closure parameter after it cannot be written in trailing position.

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
swift build --product architecture-checker && swift test --filter GeometryTests
```

Expected: the headless-mode tests fail. `headlessModeRejectsTheBannedModules` fails because without the mode the checker rejects everything not in `Geometry`'s allow-list including `AVFoundation`, so its sibling `headlessModeAllowsThePlatformFrameworksTheTierIsFor` fails first and loudest. `theHeadlessCheckPluginPassesBothBansAndNoAllowList` fails on a missing file.

- [ ] **Step 3: Add the mode to the checker**

In `Sources/architecture-checker/main.swift`, inside `run(arguments:)`, immediately after the `ignoringDecodeValidationExemptions` line (currently 647-648), add:

```swift
        // **The second guard.** `Sources/Headless` is defined by testability, not by
        // a framework list: it may use the GPU, wall time and real pixel buffers, so
        // rule 1's allow-list and rule 2's CG ban are not its rules — it is precisely
        // the boundary where CG geometry is converted (ARCHITECTURE.md D3). What it
        // owes instead is one invariant: it must not need a window or a running app.
        // `AppKit` and `SwiftUI` are how that would arrive, so they are named and
        // banned. Rules 4 and 8 are unaffected; neither is about frameworks.
        //
        // A `--mode` that silently disabled rules would be a hole wearing a mode's
        // name, so the two it disables are stated here and pinned by
        // `headlessModeDoesNotBanCGGeometry` and
        // `headlessModeAllowsThePlatformFrameworksTheTierIsFor`.
        let headlessMode = value(of: "--mode", in: arguments) == "headless"
        let banned = Set(values(of: "--ban", in: arguments))
```

Replace the allow-list resolution block (currently 691-700) with:

```swift
        let explicit = values(of: "--allow", in: arguments)
        var allowed: Set<String> = alwaysAllowed
        if headlessMode {
            // A deny-list mode with an empty deny-list checks nothing and exits 0 on
            // every file. Same rule as the empty sources directory below: a vacuous
            // pass is not a pass.
            guard !banned.isEmpty else {
                return fail("--mode headless with no --ban: a guard that bans nothing is not a guard. Pass --ban AppKit --ban SwiftUI.")
            }
        } else if explicit.isEmpty {
            guard let edges = declaredEdges[targetName] else {
                return fail("unknown target '\(targetName)' and no --allow given. Known: \(declaredEdges.keys.sorted().joined(separator: ", ")). Add it to declaredEdges in architecture-checker, or pass --allow.")
            }
            allowed = edges.union(alwaysAllowed)
        } else {
            allowed = Set(explicit).union(alwaysAllowed)
        }
```

Replace rule 1's loop (currently 739-743) with:

```swift
            if headlessMode {
                for (module, line) in importedModules(in: lines) where banned.contains(module) {
                    report(path, line,
                           "'\(module)' may not be imported from \(targetName). This target's invariant is that `swift test` can run it on a developer machine with no window and no running app; \(module) is how that stops being true. See the Phase 3A-1 design, § 2.")
                }
            } else {
                for (module, line) in importedModules(in: lines)
                where !allowed.contains(module) {
                    report(path, line,
                           "'\(module)' is not importable from \(targetName). Allowed: \(allowed.sorted().joined(separator: ", ")). See ARCHITECTURE.md D6.")
                }
            }
```

Wrap rule 2's loop (currently 748-753) in `if !headlessMode { … }`.

Update the usage string at line 683 to name the two new flags:

```swift
                return fail("usage: architecture-checker --target-name <name> --sources <dir> [--allow <module>]… [--mode headless --ban <module>…] [--manifests <dir>] [--touch <stamp>] [--ignore-decode-validation-exemptions]")
```

- [ ] **Step 4: Write the plugin**

Create `Plugins/HeadlessCheck/HeadlessCheck.swift`:

```swift
import Foundation
import PackagePlugin

/// The second guard. Runs `architecture-checker --mode headless` over every source
/// file of the target it is attached to, on every build.
///
/// **Why a second plugin rather than an exception in the first.** `ArchitectureCheck`
/// enforces rule 1 (Foundation plus declared siblings) and rule 2 (no CG geometry).
/// `Headless` legitimately breaks both: it is the tier that owns AVFoundation, Core
/// Image, Metal and CoreVideo, and it is the boundary where CG geometry is converted
/// to and from the package's own types. Widening the pure guard to admit it would
/// widen it for `SoredemoCore` too, and a guard with an exception is not a guard —
/// this repository has watched that fail twice.
///
/// So `Headless` gets its own rule instead of a hole in someone else's: **`import
/// AppKit` or `import SwiftUI` fails the build.** That is the whole rule, and it is
/// the tier's own invariant written as a mechanism: needing a window or a running
/// app is exactly what disqualifies code from this target.
///
/// **`CheckerLexer`'s arrangement is deliberately NOT inherited.** That target
/// carries no plugin (a dependency cycle makes it impossible) and keeps its rule-1
/// consequence by hand. `Headless` is the target most likely to drift, so its rule
/// is enforced rather than remembered.
///
/// `context.tool(named:).path` rather than `.url`, for the same reason
/// `ArchitectureCheck` gives: `URL.path()` percent-encodes Xcode's `${BUILD_DIR}`
/// placeholder and breaks the command under `xcodebuild`.
@main
struct HeadlessCheck: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }

        let stamp = context.pluginWorkDirectory.appending("\(target.name).headlesscheck")

        // Every Package*.swift is an input, as in ArchitectureCheck: rule 4 still runs
        // in this mode, and a manifest-only edit must re-run the checker or the rule
        // never fires on an incremental build.
        let manifests = (try? FileManager.default.contentsOfDirectory(
            atPath: context.package.directory.string))?
            .filter { $0.hasPrefix("Package") && $0.hasSuffix(".swift") }
            .sorted()
            .map { context.package.directory.appending($0) } ?? []

        return [
            .buildCommand(
                displayName: "HeadlessCheck: \(target.name)",
                executable: try context.tool(named: "architecture-checker").path,
                arguments: ["--target-name", target.name,
                            "--sources", target.directory.string,
                            "--manifests", context.package.directory.string,
                            "--mode", "headless",
                            "--ban", "AppKit",
                            "--ban", "SwiftUI",
                            "--touch", stamp.string],
                inputFiles: target.sourceFiles.map(\.path) + manifests,
                outputFiles: [stamp]
            )
        ]
    }
}
```

In `Package.swift`, beside the existing plugin declaration, add:

```swift
        .plugin(name: "HeadlessCheck", capability: .buildTool(),
                dependencies: ["architecture-checker"]),
```

and beside `let archCheck`, add:

```swift
let headlessCheck: [Target.PluginUsage] = ["HeadlessCheck"]
```

Add `"CheckerLexer"` to `GeometryTests`' dependencies:

```swift
        .testTarget(name: "GeometryTests", dependencies: ["Geometry", "CheckerLexer"], swiftSettings: strict),
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
swift build && swift test --filter GeometryTests
```

Expected: PASS, including every pre-existing rule-1/2/4/8 test — the mode must be off by default.

- [ ] **Step 6: Observe the red that proves the guard is wired, not merely present**

The mode is exercised by fixtures, so verify the *default* path did not regress: temporarily add `import AppKit` to `Sources/Geometry/Normalized.swift`, run `swift build`, confirm it fails with the rule-1 message, then revert. Record the observed message in the task report.

- [ ] **Step 7: Run all gates and commit**

```bash
swift build && scripts/count-tests.sh && scripts/run-cross-boundary-probe.sh
git add Sources/architecture-checker/main.swift Plugins/HeadlessCheck/HeadlessCheck.swift Package.swift Tests/GeometryTests/ArchitectureCheckTests.swift
git commit -m "Phase 3A-1 Task 1: the second guard, with its own rule and no exceptions"
```

---

### Task 2: The walking skeleton (part 2 of 2)

Create the target, move exactly one type, and make every structural claim in the design run at least once — before 404 lines move.

**Files:**
- Create: `Sources/Headless/CursorArt.swift` (git mv from `Soredemo/Render/CursorArt.swift`)
- Create: `Sources/Headless/HeadlessGeometryBridge.swift`
- Create: `Tests/HeadlessTests/CursorArtTests.swift`, `Tests/HeadlessTests/HeadlessGeometryBridgeTests.swift`
- Create: `Tests/AppSourceTests/HeadlessEntryRuleTests.swift`
- Modify: `Soredemo/Capture/CGGeometryBridge.swift`, `Soredemo/Render/CoreImageFrameRenderer.swift`, `Soredemo/Render/CompositionBuilder.swift`, `Tests/AppSourceTests/AppSourceAllowListTests.swift`
- Modify: `Package.swift`, `scripts/count-tests.sh`, `scripts/run-cross-boundary-probe.sh`, `Soredemo.xcodeproj/project.pbxproj`, `Tests/GeometryTests/ArchitectureCheckTests.swift`, `docs/ARCHITECTURE.md`

**Interfaces:**
- Consumes: `HeadlessCheck` plugin and the `--mode headless` CLI contract from Task 1.
- Produces: target `Headless`, product `SoredemoHeadless`, test target `HeadlessTests`; `public nonisolated enum CursorArt` (read the file for its members — do not invent signatures); `public nonisolated enum HeadlessGeometryBridge` with `public nonisolated static func outputCanvas(width: Int, height: Int) -> CGRect`, `public nonisolated static func renderSize(width: Int, height: Int) -> CGSize` and `public nonisolated static func point(x: Double, y: Double) -> CGPoint`; the helpers `headlessSourceFiles() throws -> [URL]`, `headlessTestFiles() throws -> [URL]`, `publicTypeDeclarations(in:) throws -> [(name: String, location: String)]` and `resolvedManifestTargets() throws -> [[String: Any]]` in `Tests/AppSourceTests/HeadlessEntryRuleTests.swift`, all consumed by Tasks 3, 4 and 7.

`Soredemo.xcodeproj` uses `PBXFileSystemSynchronizedRootGroup` (verified), so moving a file out of `Soredemo/` removes it from the app target automatically. **The only pbxproj edit needed is adding the product dependency.**

#### `CursorArt` is not self-contained, and that is why it is the right skeleton type

Found while writing this plan, not while executing it, and it is a real finding the design doc does not contain. `CursorArt` imports only `CoreGraphics` and `Foundation` — but every point it builds comes from `CGGeometryBridge.point(x:y:)`, and `CGGeometryBridge` lives in `Soredemo/Capture/`, which is **3A-2 and out of scope**.

Moving the whole bridge would drag `ApplicationServices`, the AX decoders and the ScreenCaptureKit attachment decoder into `Headless` — 3A-2's scope, pulled forward, in the task whose entire purpose is to move as little as possible.

**The answer is a second bridge, one per tier**, matching the shape already chosen for the plugins: two bridges with two scopes, not one bridge stretched across a boundary it no longer fits. `CGGeometryBridge`'s last three functions — `outputCanvas(width:height:)`, `renderSize(width:height:)` and `point(x:y:)` — are the RENDER-side exits. They take plain scalars, they touch no AX and no ScreenCaptureKit, and all three exist only because the render path needed them (their own doc comments say so, each naming the Phase 2B task that added it). They move to `Sources/Headless/HeadlessGeometryBridge.swift`; everything else stays for 3A-2.

`CGGeometryBridge`'s header currently opens **"The only file in this repository allowed to name a CoreGraphics geometry type."** That sentence becomes false in this task and must be corrected in the same commit — it becomes the only file in the APP TARGET, with a pointer to the Headless bridge and one line on why there are now two. A sentence that quietly outlives its truth is this phase's subject; leaving that one standing while making it false would be the plan writing its own D6a-N row.

**MOVE, never copy — and the measurement that says a copy is not even tempting.** Call sites, counted with the code view before this plan was written:

| function | callers | in |
| --- | --- | --- |
| `outputCanvas(width:height:)` | 2 | `CoreImageFrameRenderer` |
| `renderSize(width:height:)` | 1 | `CompositionBuilder` |
| `point(x:y:)` | 14 | `CursorArt` |

**Zero callers in `Soredemo/Capture/`, for all three.** So after the move there is one implementation and nothing left behind to drift from it; `CGGeometryBridge` does not delegate to `HeadlessGeometryBridge` because it has nothing to delegate, and adding `import Headless` to it would be a dependency edge carrying no call.

What is NOT free is the future: nothing stops someone adding a `point(x:y:)` to whichever bridge they happen to be in, and then two implementations pass two tests while disagreeing. The invariant worth enforcing is therefore **the two bridges' function names are disjoint**, and it is worth one test rather than one dependency edge:

```swift
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
@Test func theTwoGeometryBridgesShareNoFunctionName() throws {
    func functionNames(inFileAt relativePath: String) throws -> Set<String> {
        let text = try String(contentsOf: repositoryRoot.appending(path: relativePath),
                              encoding: .utf8)
        var names: Set<String> = []
        for line in SwiftSourceLexer.codeViewLines(of: text) {
            let words = line.split(whereSeparator: { !SwiftSourceLexer.isIdentifierCharacter($0) })
                .map(String.init)
            guard let funcIndex = words.firstIndex(of: "func"), funcIndex + 1 < words.count
            else { continue }
            names.insert(words[funcIndex + 1])
        }
        return names
    }

    let app = try functionNames(inFileAt: "Soredemo/Capture/CGGeometryBridge.swift")
    let headless = try functionNames(inFileAt: "Sources/Headless/HeadlessGeometryBridge.swift")
    try #require(!app.isEmpty && !headless.isEmpty, "a bridge scanned as empty — the scan is broken, not the bridges")

    #expect(app.isDisjoint(with: headless), """
        both geometry bridges define \(app.intersection(headless).sorted()).
        Two implementations of the same conversion drift: one gets the fix, the other does not, \
        and each passes its own tier's rule-5 test while disagreeing with the other.
        Define it once. `Soredemo/Capture/` is the upper tier and can `import Headless` if it \
        genuinely needs a render-side exit — but measure the call sites first; when this split \
        was made there were none.
        """)
}
```

This goes in `Tests/AppSourceTests/HeadlessEntryRuleTests.swift` beside rule 5's two halves. Note `rect(from:)` is overloaded on `PixelRect`/`PointRect` and stays entirely in the app bridge — name-based disjointness is the right granularity here precisely because an overload set is one name.

- [ ] **Step 1: Move `CursorArt` and split the bridge**

```bash
git mv Soredemo/Render/CursorArt.swift Sources/Headless/CursorArt.swift
```

Create `Sources/Headless/HeadlessGeometryBridge.swift` holding exactly three functions, moved verbatim (bodies and doc comments) from `Soredemo/Capture/CGGeometryBridge.swift:240-269`: `outputCanvas(width:height:)`, `renderSize(width:height:)`, `point(x:y:)`. All three `public nonisolated static`. Give the type a header stating:

- that it is the **render tier's** CoreGraphics exit, and the only file in `Sources/Headless` allowed to name `CGRect`/`CGPoint`/`CGSize`/`CGFloat`;
- that `Soredemo/Capture/CGGeometryBridge.swift` is the app tier's, holding the AX and ScreenCaptureKit ENTRANCES, which need `ApplicationServices` and belong to 3A-2;
- that the split is by tier and not by convenience, and that when `Capture` moves in 3A-2 the two are reconsidered together;
- that each is confined by its own test, so neither is confined by memory.

Delete those three functions from `CGGeometryBridge.swift` and correct its opening sentence. Then repoint their three call sites, which are still in the app target at this point:

```bash
grep -rn "CGGeometryBridge.outputCanvas\|CGGeometryBridge.renderSize\|CGGeometryBridge.point(x:" Soredemo/ Sources/
```

`Soredemo/Render/CoreImageFrameRenderer.swift` and `Soredemo/Render/CompositionBuilder.swift` gain `import Headless` and call `HeadlessGeometryBridge.…`; `Sources/Headless/CursorArt.swift` calls it directly with no import (same module). Rule 5 still holds at all three sites — none of them names a CG type.

- [ ] **Step 1b: Make `CursorArt`'s API public**

Change `nonisolated enum CursorArt {` to `public nonisolated enum CursorArt {` and add `public` to each member the app or a test calls. Determine which by measurement, not by guessing:

```bash
grep -rn "CursorArt\." Soredemo/ Tests/ scripts/ | grep -v "^Sources/Headless/"
```

Add nothing to the public surface that this command does not justify — every `public` type is an entry-rule obligation, and `public` on a member of an already-admitted type is the known free-entry gap the design records.

- [ ] **Step 1c: Give `Headless` its own half of rule 5**

`coreGraphicsGeometryTypesAppearOnlyInTheBridge` (`Tests/AppSourceTests/AppSourceAllowListTests.swift:164`) scans `appSourceFiles()` — `Soredemo/` only — with `permittedPath: "Soredemo/Capture/CGGeometryBridge.swift"`. **Leave it exactly as it is.** It is still true and still the app tier's rule; widening its permitted path to cover a file in another tree is precisely the "guard with an exception" move this phase refuses.

Add its mirror to `Tests/AppSourceTests/HeadlessEntryRuleTests.swift`:

```swift
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
```

`violations(banned:permittedPath:in:)` is at `AppSourceAllowListTests.swift:109`, file-scope in this same target, so it is directly callable.

Observe its red: temporarily write `let r = CGRect.zero` into `Sources/Headless/CursorArt.swift`, run, record the message, revert.

- [ ] **Step 2: Declare the target, the product and the test target**

In `Package.swift`, add to `products:`:

```swift
        // NOT added to `SoredemoCore`'s targets array, and not named `SoredemoCore`:
        // that product is Foundation-only by definition in five documents, and this
        // target's whole purpose is the platform frameworks that definition excludes.
        .library(name: "SoredemoHeadless", targets: ["Headless"]),
```

and to `targets:`, after `Render`:

```swift
        // **The tier `swift test` can run but a person still has to believe.**
        // Deterministic modules above; a running app below. This one may use the GPU,
        // real pixel buffers and wall time — what it may NOT do is need a window or an
        // app lifecycle, which is what the name states and what `HeadlessCheck`
        // enforces by banning AppKit and SwiftUI.
        //
        // `plugins: headlessCheck`, NOT `archCheck`: rule 1 would ban AVFoundation and
        // rule 2 would ban the CGRect this target exists to convert. Two guards with two
        // rules, not one guard with a hole.
        .target(name: "Headless", dependencies: ["Geometry", "Timeline", "Project", "Render"],
                swiftSettings: strict, plugins: headlessCheck),
```

and, with the other test targets:

```swift
        // The ONLY test target that depends on `Headless`. The deterministic targets
        // must not: a test that cannot link the product cannot be written against it,
        // so the two populations are kept apart by the build graph rather than by
        // anyone remembering which suite a test belongs in.
        // `noDeterministicTestTargetDependsOnHeadless` asserts this against the
        // resolved manifest.
        .testTarget(name: "HeadlessTests", dependencies: ["Headless", "Geometry", "Timeline", "Project", "Render"],
                    swiftSettings: strict),
```

- [ ] **Step 3: Write the failing entry-rule scanner and the manifest tests**

Create `Tests/AppSourceTests/HeadlessEntryRuleTests.swift`:

```swift
import Testing
import Foundation
import CheckerLexer

// Reuses `repositoryRoot`, `codeLinesNaming(_:in:)` and `pathRelativeToRepositoryRoot(_:)`
// from `AppSourceAllowListTests.swift` — file-scope declarations in this same target.

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
```

The declaration scan, and the test:

```swift
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
```

Then the manifest-shape tests, in the same file:

```swift
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
        let dependencies = (target["dependencies"] as? [[String: Any]] ?? [])
            .compactMap { ($0["byName"] as? [Any] ?? $0["target"] as? [Any])?.first as? String }
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
```

`resolvedManifestTargets()` is the `swift package dump-package` invocation already written inside `everyLibraryTargetUsesTheCheckerPluginInTheResolvedManifest` (`Tests/GeometryTests/ArchitectureCheckTests.swift:485-514`). Extract it there into a file-scope `func resolvedManifestTargets() throws -> [[String: Any]]`, and duplicate the same helper into `HeadlessEntryRuleTests.swift` — the two live in different test targets and cannot share a declaration. State that in a comment at both sites so the duplication reads as a target boundary rather than as carelessness.

- [ ] **Step 4: Fix the guard-coverage test, which will be red**

`everyLibraryTargetUsesTheCheckerPluginInTheResolvedManifest` loops over every regular target not in `pluginExemptTargets` and demands `ArchitectureCheck`. Adding `Headless` turns it red. **The fix is not to add `Headless` to `pluginExemptTargets`** — that list means "carries no architecture check at all", and `Headless` is the target most likely to drift. Replace the loop with:

```swift
    // Every regular target carries a guard; WHICH guard depends on the tier. `Headless`
    // is not exempt — it carries `HeadlessCheck`, whose single rule (no AppKit, no
    // SwiftUI) is its own invariant. An entry here is the opposite of an exemption:
    // adding a name to this map asserts that target has a guard, and the assertion is
    // checked below.
    let guardForTarget: [String: String] = ["Headless": "HeadlessCheck"]

    for target in regular where !pluginExemptTargets.contains(target["name"] as? String ?? "") {
        let name = target["name"] as? String ?? "<unnamed>"
        let usages = target["pluginUsages"] as? [[String: Any]] ?? []
        let plugins = usages.compactMap { ($0["plugin"] as? [Any])?.first as? String }
        let required = guardForTarget[name] ?? "ArchitectureCheck"
        #expect(plugins.contains(required),
                "regular target \(name) does not use the \(required) plugin — its architecture rule is void for it. pluginUsages: \(usages)")
    }

    // And the tiers do not swap guards. `ArchitectureCheck` on `Headless` would ban
    // AVFoundation and CGRect — a loud failure, so this is belt to that brace.
    // `HeadlessCheck` on a pure target is the dangerous direction and silent: rule 1's
    // allow-list and rule 2 would both be off and the build would stay green.
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
```

Leave `pluginExemptTargets` as `["CheckerLexer"]` and leave its doc comment intact — a single-name list is the point.

- [ ] **Step 5: Write the skeleton's entry-rule tests**

Create `Tests/HeadlessTests/CursorArtTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
import Headless

/// **The entry rule's first discharge, and the standard every later one is held to.**
///
/// The rule is CONSTRUCT AND EXERCISE. A test asserting `CursorArt.self != nil` would
/// satisfy the scanner in `HeadlessEntryRuleTests` and defeat the rule entirely —
/// that scanner is a necessary condition, and this is what the sufficient one looks
/// like: the real path is built and something the drawing actually determines is
/// asserted.
@Test func theArrowPathScalesWithItsScaleArgument() {
    let unit = CursorArt.pointerPath(scale: 1).boundingBox
    let doubled = CursorArt.pointerPath(scale: 2).boundingBox

    #expect(!unit.isEmpty, "the arrow outline is seven points; an empty box means no path was built")
    #expect(abs(doubled.width - unit.width * 2) < 0.001)
    #expect(abs(doubled.height - unit.height * 2) < 0.001)
}

/// The tip is the origin — the hot-spot convention `pointerPath`'s own header states,
/// and the fact Task 6's position assertion rests on. A path translated so its tip
/// lands on the recorded position is only correct if the tip really is at (0, 0).
@Test func theArrowsTipIsAtTheOrigin() {
    let box = CursorArt.pointerPath(scale: 1).boundingBox
    // The outline runs toward positive x and negative y from the tip, so the tip is
    // the box's top-left corner: maxY is 0 and minX is 0.
    #expect(abs(box.maxY) < 0.001, "the tip is not at y = 0; box: \(box)")
    #expect(abs(box.minX) < 0.001, "the tip is not at x = 0; box: \(box)")
}

/// `ripplePath(phase:)` clamps out-of-range phases rather than building a circle from
/// a radius outside its documented range. Both ends, because a clamp written on one
/// side only is the commonest way this shape is got wrong.
@Test func theRipplePhaseIsClampedAtBothEnds() {
    let atZero = CursorArt.ripplePath(phase: 0).boundingBox
    let belowZero = CursorArt.ripplePath(phase: -5).boundingBox
    let atOne = CursorArt.ripplePath(phase: 1).boundingBox
    let aboveOne = CursorArt.ripplePath(phase: 17).boundingBox

    #expect(abs(belowZero.width - atZero.width) < 0.001)
    #expect(abs(aboveOne.width - atOne.width) < 0.001)
    #expect(atOne.width > atZero.width, "the ripple must grow with phase")
}
```

Create `Tests/HeadlessTests/HeadlessGeometryBridgeTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
import Headless

/// The render tier's three CoreGraphics exits, exercised. Trivial functions, and the
/// entry rule does not exempt trivial ones: `outputCanvas` and `renderSize` differ
/// only in which of two same-shaped CG types they build, which is exactly the pair a
/// copy-paste swaps.
@Test func theOutputCanvasIsOriginedAtZeroWithTheGivenExtent() {
    let canvas = HeadlessGeometryBridge.outputCanvas(width: 1920, height: 1080)
    #expect(canvas.origin.x == 0 && canvas.origin.y == 0)
    #expect(canvas.width == 1920 && canvas.height == 1080)
}

@Test func theRenderSizeCarriesWidthAndHeightInThatOrder() {
    let size = HeadlessGeometryBridge.renderSize(width: 1280, height: 720)
    #expect(size.width == 1280 && size.height == 720)
}

@Test func thePointBridgeCarriesXAndYInThatOrder() {
    let point = HeadlessGeometryBridge.point(x: 3.5, y: -17.25)
    #expect(point.x == 3.5 && point.y == -17.25)
}
```

If `CursorArt`'s real member names differ from `pointerPath(scale:)` / `ripplePath(phase:)` / `pointerMaxExtent`, use the real ones — read the file. Do not add a member to make a test compile.

- [ ] **Step 6: Split the gate output**

Verified before this plan was written, so the arithmetic below is a measurement and not a hope: `swift test` = 454, `--skip RenderTests` = 422, `--filter RenderTests` = 32, and 422 + 32 = 454.

Add to `scripts/count-tests.sh`:

```bash
# --split: the two populations, and the invariant that makes them two counts rather
# than two numbers.
#
# `swift test` now holds suites with different guarantees. The deterministic targets
# answer the same on any machine; HeadlessTests may need a GPU, may be time-sensitive,
# and may answer differently elsewhere. Reporting one "N tests pass" silently changes
# what that number means — one symbol for two things is the shape this project has
# caught most often.
#
# The sum check is the load-bearing part. Two filtered runs alone could double-count a
# suite or drop one and both numbers would still look plausible; only the total says
# the partition is a partition. Cost: three full test runs. That is why --split is
# opt-in and the default stays one run.
if [ "${1:-}" = "--split" ]; then
    count_run() {
        local output
        output=$(swift test "$@" 2>&1) || {
            echo "swift test $* FAILED — no count. Its output:" >&2
            echo "$output" | tail -40 >&2
            exit 1
        }
        printf '%s\n' "$output" | grep -oE "Test run with [0-9]+ tests?" \
            | grep -oE "[0-9]+" | awk '{s+=$1} END {print s+0}'
    }

    DETERMINISTIC=$(count_run --skip HeadlessTests)
    HEADLESS=$(count_run --filter HeadlessTests)
    EVERYTHING=$(count_run)

    # The partition check runs BEFORE anything is printed. Printing three numbers and
    # letting the reader add them up is how two instruments answering different
    # questions get read as agreeing — and here all three numbers would look equally
    # plausible whichever way it broke. So the relation is enforced, and the output
    # says it was enforced rather than inviting anyone to check.
    if [ $((DETERMINISTIC + HEADLESS)) -ne "$EVERYTHING" ]; then
        echo "the two populations do not partition the suite: $DETERMINISTIC + $HEADLESS != $EVERYTHING" >&2
        echo "either a suite is counted twice or one is counted by neither filter. The split is not a split." >&2
        echo "no numbers printed: a partition that is not one has no two counts to report." >&2
        exit 3
    fi

    printf '  swift test — deterministic  %6d passed\n' "$DETERMINISTIC"
    printf '  swift test — headless       %6d passed    (GPU / timing sensitive)\n' "$HEADLESS"
    printf '  ---------------------------------------\n'
    printf '  %6d  total (partition verified: %d + %d)\n' \
        "$EVERYTHING" "$DETERMINISTIC" "$HEADLESS"
    exit 0
fi
```

Place this block after the `set -euo pipefail`/`cd` preamble and before the existing single-run body.

- [ ] **Step 7: Keep the probe compiling the same code at its new path**

In `scripts/run-cross-boundary-probe.sh`, change `Soredemo/Render/CursorArt.swift` to `Sources/Headless/CursorArt.swift` in the `xcrun swiftc` input list. **Compiled as source, not linked as a product** — so the probe still sees `internal` declarations and nothing is widened to `public` for its benefit.

- [ ] **Step 8: Add the product dependency to the Xcode project**

`Soredemo.xcodeproj/project.pbxproj` needs `SoredemoHeadless` alongside `SoredemoCore`. Mirror the four existing entries, generating two fresh unique 24-hex-character IDs (`NEWBUILDFILE`, `NEWPRODUCTDEP` below are placeholders — replace with generated IDs that appear nowhere else in the file):

1. In `PBXBuildFile` (near line 10):
   `NEWBUILDFILE /* SoredemoHeadless in Frameworks */ = {isa = PBXBuildFile; productRef = NEWPRODUCTDEP /* SoredemoHeadless */; };`
2. In the Frameworks build phase `files` list (near line 30): `NEWBUILDFILE /* SoredemoHeadless in Frameworks */,`
3. In the app target's `packageProductDependencies` (near line 73): `NEWPRODUCTDEP /* SoredemoHeadless */,`
4. In `XCSwiftPackageProductDependency` (near line 360):
   ```
   NEWPRODUCTDEP /* SoredemoHeadless */ = {
       isa = XCSwiftPackageProductDependency;
       productName = SoredemoHeadless;
   };
   ```

Copy the `package = …` line from the `SoredemoCore` entry if it has one.

- [ ] **Step 9: Verify the pbxproj change by a red, not by a parse**

Hand-edited pbxproj has failed in this repo before, and "it parses" is not verification.

```bash
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -configuration Debug build   # expect SUCCESS
```

Then delete the `packageProductDependencies` entry (edit 3 above), rebuild, and confirm the build FAILS with an unresolved `CursorArt`/`SoredemoHeadless` error. Restore it, rebuild, confirm success. Put both observed messages in the task report.

- [ ] **Step 10: Record the tier in ARCHITECTURE.md**

Add a section to `docs/ARCHITECTURE.md` stating the three tiers and their invariants (the table in the design doc's § 2), that `Headless` carries `HeadlessCheck` and why the pure guard cannot be attached, and that the entry rule's scanner is a necessary condition with review enforcing the rule. Do not restate the design doc — cite it and state what a reader of ARCHITECTURE.md needs to decide where a new file goes.

- [ ] **Step 11: All gates, then commit**

```bash
swift build && scripts/count-tests.sh --split && scripts/run-cross-boundary-probe.sh
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -configuration Debug build
git add Package.swift Sources/Headless Tests/HeadlessTests Tests/AppSourceTests/HeadlessEntryRuleTests.swift Tests/GeometryTests/ArchitectureCheckTests.swift scripts/count-tests.sh scripts/run-cross-boundary-probe.sh Soredemo.xcodeproj/project.pbxproj docs/ARCHITECTURE.md
git rm --cached Soredemo/Render/CursorArt.swift 2>/dev/null || true
git commit -m "Phase 3A-1 Task 2: the walking skeleton — one type, both guards, two populations"
```

---

### Task 3: The `FrameRendering` seam and its production conformer

**Files:**
- Create: `Sources/Headless/FrameRenderer.swift`, `Sources/Headless/CoreImageFrameRenderer.swift` (git mv)
- Create: `Tests/HeadlessTests/CoreImageFrameRendererTests.swift`
- Modify: `Tests/AppSourceTests/RenderSeamTests.swift`, `scripts/run-cross-boundary-probe.sh`

**Interfaces:**
- Consumes: `Sources/Headless` and `HeadlessTests` from Task 2; `headlessTestFiles()` and `publicTypeDeclarations(in:)` from Task 2.
- Produces: `public protocol FrameRendering: Sendable` with `func render(_ plan: RenderPlan, source: CVPixelBuffer, into destination: CVPixelBuffer) throws`; `public enum FrameRenderingError: Error { case noRenderDevice }`; `public final class CoreImageFrameRenderer: FrameRendering` — all consumed by Task 4's `StageCompositor` and Task 6's completion test.

- [ ] **Step 1: Move both files**

```bash
git mv Soredemo/Render/FrameRenderer.swift Sources/Headless/FrameRenderer.swift
git mv Soredemo/Render/CoreImageFrameRenderer.swift Sources/Headless/CoreImageFrameRenderer.swift
```

Make `FrameRendering`, its `render` requirement, `CoreImageFrameRenderer`, and its initialiser `public`. `FrameRenderingError` is already `public`. Add `public` to nothing the app or a test does not call.

- [ ] **Step 2: Fix `RenderSeamTests.swift`, which will be red**

`Tests/AppSourceTests/RenderSeamTests.swift:11` reads `Soredemo/Render/FrameRenderer.swift` by path. Point it at `Sources/Headless/FrameRenderer.swift`. Its assertion — that no Core Image, Metal or pixel-buffer type appears in the seam file — is unchanged and still correct: the seam still chooses neither implementation.

- [ ] **Step 3: Update the probe's input list**

In `scripts/run-cross-boundary-probe.sh`, change `Soredemo/Render/FrameRenderer.swift` → `Sources/Headless/FrameRenderer.swift` and `Soredemo/Render/CoreImageFrameRenderer.swift` → `Sources/Headless/CoreImageFrameRenderer.swift`. Still compiled as source. No declaration is widened to `public` for the probe.

- [ ] **Step 4: Write the failing test — the PRODUCTION conformer, exercised**

Create `Tests/HeadlessTests/CoreImageFrameRendererTests.swift`:

```swift
import Testing
import Foundation
import CoreVideo
import Geometry
import Render
@testable import Headless

/// **The seam's entry-rule obligation, discharged by the production conformer and
/// not by a double.**
///
/// `FrameRendering` is exempt from construction and not from exercise, and the
/// exercised conforming type may not be a test-only one. A `struct` in this file
/// conforming to `FrameRendering` would satisfy the letter and invert the meaning:
/// the seam would be fully verified through a double while `CoreImageFrameRenderer`
/// — the only thing that ever runs in the app — never executed. That is the exact
/// shape of `1a98402`, where every automatic check agreed with an implementation
/// that had never drawn anything.
///
/// **This test needs a GPU**, which is why `HeadlessTests` is a separate population.
/// On a machine with no Metal device `CoreImageFrameRenderer.init` throws
/// `FrameRenderingError.noRenderDevice`, and that is a real answer, not a skip.
@Test func theProductionRendererDrawsIntoTheDestinationBuffer() throws {
    let width = 640, height = 360
    let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
    let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))

    let base = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                 sourceWidth: width, sourceHeight: height,
                                 style: .default)
    let plan = RenderPlan(outputWidth: base.outputWidth, outputHeight: base.outputHeight,
                          card: base.card, cornerRadius: base.cornerRadius,
                          style: base.style, pointer: nil)

    let renderer = try CoreImageFrameRenderer()
    try renderer.render(plan, source: source, into: destination)

    // Not "the call returned" — pixels the renderer actually wrote. The destination
    // started all-black; the stage background is (0.09, 0.09, 0.11) and the card
    // carries the source fill, so a renderer that did nothing leaves this all zero.
    let written = try pixels(of: destination).filter { $0 != (0, 0, 0) }
    #expect(!written.isEmpty, "the destination is still the all-black buffer it started as")
}
```

Create `Tests/HeadlessTests/PixelBufferSupport.swift` alongside it, consumed by Task 6 as well:

```swift
import Foundation
import CoreVideo
import Testing

/// **The source fill, and why it is this colour.**
///
/// `CursorArt` draws a WHITE-filled, BLACK-stroked arrow. A white or near-white source
/// frame makes "find the drawn pointer" fail for a reason that has nothing to do with
/// position — red for the wrong reason, which is the failure mode this whole phase is
/// about. A saturated mid-blue is far from both the fill and the stroke, and far from
/// `StageStyle.default`'s (0.09, 0.09, 0.11) background too, so a differing pixel is
/// attributable.
let sourceFill: (r: UInt8, g: UInt8, b: UInt8) = (32, 96, 224)

/// A 32BGRA buffer of the given size, every pixel set to `fill`.
///
/// 32BGRA because that is what `StageCompositor.sourcePixelBufferAttributes` and
/// `requiredPixelBufferAttributesForRenderContext` both declare; a test that composed
/// in another format would be exercising a path the app never takes.
func makePixelBuffer(width: Int, height: Int,
                     fill: (r: UInt8, g: UInt8, b: UInt8)) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
        &buffer)
    let created = try #require(buffer, "CVPixelBufferCreate failed with status \(status)")

    CVPixelBufferLockBaseAddress(created, [])
    defer { CVPixelBufferUnlockBaseAddress(created, []) }
    let base = try #require(CVPixelBufferGetBaseAddress(created)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(created)
    for row in 0..<height {
        for column in 0..<width {
            let offset = row * stride + column * 4
            base[offset + 0] = fill.b
            base[offset + 1] = fill.g
            base[offset + 2] = fill.r
            base[offset + 3] = 255
        }
    }
    return created
}

/// Every pixel of a 32BGRA buffer as `(r, g, b)`, row-major.
func pixels(of buffer: CVPixelBuffer) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    var out: [(r: UInt8, g: UInt8, b: UInt8)] = []
    out.reserveCapacity(width * height)
    for row in 0..<height {
        for column in 0..<width {
            let offset = row * stride + column * 4
            out.append((r: base[offset + 2], g: base[offset + 1], b: base[offset + 0]))
        }
    }
    return out
}
```

If `CoreImageFrameRenderer`'s initialiser is not `init() throws`, use the real one — read the file. It throws `FrameRenderingError.noRenderDevice` when Metal has no device; on a machine with no GPU that is a real answer and a real failure, not a skip, and that is why `HeadlessTests` is a separate population.

- [ ] **Step 4b: Observe the red**

Temporarily `return` from the top of `CoreImageFrameRenderer.render(_:source:into:)`, run, confirm `theProductionRendererDrawsIntoTheDestinationBuffer` fails on the all-black destination, record the message, revert. A test whose red has not been seen is a test that has only ever been green.

- [ ] **Step 5: Run the gates**

```bash
swift build && scripts/count-tests.sh --split && scripts/run-cross-boundary-probe.sh
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -configuration Debug build
```

Expected: green. The entry scanner from Task 2 now covers three more public types; if it is red, the fix is a real test or a narrower access level, never a scanner change.

- [ ] **Step 6: Commit**

```bash
git add Sources/Headless Tests/HeadlessTests Tests/AppSourceTests/RenderSeamTests.swift scripts/run-cross-boundary-probe.sh
git commit -m "Phase 3A-1 Task 3: the FrameRendering seam, exercised through its production conformer"
```

---

### Task 4: The compositor and the composition

**Files:**
- Create: `Sources/Headless/StageCompositor.swift`, `Sources/Headless/CompositionBuilder.swift` (git mv)
- Create: `Tests/HeadlessTests/StageCompositorTests.swift`, `Tests/HeadlessTests/CompositionBuilderTests.swift`
- Modify: `scripts/run-cross-boundary-probe.sh`

**Interfaces:**
- Consumes: `FrameRendering`, `FrameRenderingError`, `CoreImageFrameRenderer` from Task 3.
- Produces: `public final class StageCompositor` with `public static var renderer/style/observationLogURL/overrides`, `public static var diagnostics`, `public static func resetDiagnostics()`, `public struct Diagnostics`, `public enum CompositorError`; **`public func pointerPlacement(at time: CMTime, in plan: RenderPlan) -> PointerPlacement?`**; `public enum CompositionBuilder` with its existing entry point and `public enum BuilderError`. Task 6 depends on `pointerPlacement` being public.

**The one deliberate widening, and its reason.** `startRequest(_:)` takes an `AVAsynchronousVideoCompositionRequest`, which only AVFoundation can construct — no `swift test` test can call it. `pointerPlacement(at:in:)` is where the log, the anchor and the clock conversion meet, and it is reachable. It becomes `public` with a doc comment saying exactly that: it is the seam `swift test` reaches, `startRequest` is not, and the AVFoundation glue around it remains covered only by the probe and by a person. A method on an already-admitted type is the entry rule's known free-entry gap, recorded in the design as a cost rather than argued away — this is that cost being spent deliberately, once, with the reason written down.

- [ ] **Step 1: Move both files and set access levels**

```bash
git mv Soredemo/Render/StageCompositor.swift Sources/Headless/StageCompositor.swift
git mv Soredemo/Render/CompositionBuilder.swift Sources/Headless/CompositionBuilder.swift
```

Make public: `StageCompositor` and every static the app sets (`renderer`, `style`, `observationLogURL`, `overrides`, `diagnostics`, `resetDiagnostics()`), `Diagnostics` and its `framesDropped`, `CompositorError`, `pointerPlacement(at:in:)`, `CompositionBuilder` and its entry point, `BuilderError`. Measure the app's call sites first:

```bash
grep -rn "StageCompositor\.\|CompositionBuilder\." Soredemo/ | grep -v "^Sources/"
```

`AVVideoCompositing` conformance members (`sourcePixelBufferAttributes`, `requiredPixelBufferAttributesForRenderContext`, `renderContextChanged`, `startRequest`) must be `public` for the protocol conformance to compile from another module.

- [ ] **Step 2: Update the probe's input list**

`Soredemo/Render/StageCompositor.swift` → `Sources/Headless/StageCompositor.swift`, `Soredemo/Render/CompositionBuilder.swift` → `Sources/Headless/CompositionBuilder.swift`. Compiled as source; nothing widened for the probe.

- [ ] **Step 3: Write the entry-rule tests**

`Tests/HeadlessTests/StageCompositorTests.swift`:

```swift
import Testing
import Foundation
import CoreMedia
import Render
import Timeline
@testable import Headless

/// `Diagnostics` starts at zero and `resetDiagnostics()` returns it there. A counter
/// nobody can read is indistinguishable from an event that never happened, which is
/// why this type exists; a counter nothing tests is the same thing one step later.
@Test func resettingDiagnosticsReturnsTheDropCountToZero() {
    StageCompositor.resetDiagnostics()
    #expect(StageCompositor.diagnostics.framesDropped == 0)
}

/// **With no observation log configured, no pointer is placed** — and that is not a
/// fifth `PointerReading` case smuggled in through a side door, it is nothing having
/// been configured to read from. Pinning it here means Task 6's positive result
/// cannot be produced by a default.
@Test func noConfiguredLogPlacesNoPointer() {
    StageCompositor.observationLogURL = nil
    StageCompositor.overrides = []
    let compositor = StageCompositor()
    let base = StagePlanner.plan(outputWidth: 640, outputHeight: 360,
                                 sourceWidth: 640, sourceHeight: 360, style: .default)
    let plan = RenderPlan(outputWidth: base.outputWidth, outputHeight: base.outputHeight,
                          card: base.card, cornerRadius: base.cornerRadius,
                          style: base.style, pointer: nil)
    #expect(compositor.pointerPlacement(at: CMTime(value: 0, timescale: 600), in: plan) == nil)
}

/// `Diagnostics` is a public type whose whole content is a count, so what is pinned is
/// that the count is readable and resettable — nothing here claims the drop path RAN.
/// `startRequest` takes an `AVAsynchronousVideoCompositionRequest`, which only
/// AVFoundation constructs, so no `swift test` test reaches the two increment sites.
/// That limit is stated rather than left for a reader to discover, because a
/// `framesDropped == 0` in a report means "the compositor was not asked" here and
/// "the compositor dropped nothing" in the app, and those are different sentences.
@Test func theDropCounterIsReadableAndResettable() {
    StageCompositor.resetDiagnostics()
    #expect(StageCompositor.diagnostics.framesDropped == 0)
}

/// `CompositorError` is public and thrown from `startRequest`'s leading guard. Same
/// limit as above: what is pinned is that the case exists and is distinguishable from
/// another error, not that the guard fires.
@Test func theCompositorErrorIsDistinguishableFromAnotherError() {
    let error: any Error = StageCompositor.CompositorError.notConfigured
    #expect(error as? StageCompositor.CompositorError == .notConfigured)
    #expect((CancellationError() as any Error) as? StageCompositor.CompositorError == nil)
}
```

`Tests/HeadlessTests/CompositionBuilderTests.swift`:

```swift
import Testing
import Foundation
import AVFoundation
import Render
@testable import Headless

/// `CompositionBuilder`'s entry-rule discharge, against a REAL asset —
/// `Tests/RenderParityFixtures/two-tone.mov`, the file the cross-boundary probe
/// already composes. A synthesised asset would test the builder against an input
/// shape nothing else in this repository uses.
@Test func aCompositionIsBuiltFromARealAssetAndInstallsTheStageCompositor() async throws {
    let asset = AVURLAsset(url: repositoryRootFromTests
        .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
    let composition = try await CompositionBuilder.build(from: asset, style: .default)

    #expect(composition.renderSize.width > 0 && composition.renderSize.height > 0)
    #expect(composition.customVideoCompositorClass == StageCompositor.self,
            "the composition does not install StageCompositor; nothing this phase tests would run")
}

/// The failure the builder names. An asset with no video track is a real condition —
/// an audio-only recording, or a file that failed to write its video track — and the
/// builder must say so rather than build an empty composition.
@Test func anAssetWithNoVideoTrackIsRejected() async throws {
    let empty = FileManager.default.temporaryDirectory
        .appending(path: "no-video-\(UUID().uuidString).mov")
    try Data().write(to: empty)
    defer { try? FileManager.default.removeItem(at: empty) }

    await #expect(throws: CompositionBuilder.BuilderError.noVideoTrack) {
        _ = try await CompositionBuilder.build(from: AVURLAsset(url: empty), style: .default)
    }
}
```

`CompositionBuilder`'s real entry point signature comes from the file — read it and use the real one; `build(from:style:)` above is the shape, not a promise. `repositoryRootFromTests` is the same `#filePath`-walk `ArchitectureCheckTests.swift:5` uses; declare it once at file scope in `HeadlessTests` and say in a comment that it is a per-target duplicate of the same walk, because test targets cannot share a declaration.

- [ ] **Step 4: Gates and commit**

```bash
swift build && scripts/count-tests.sh --split && scripts/run-cross-boundary-probe.sh
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -configuration Debug build
git add Sources/Headless Tests/HeadlessTests scripts/run-cross-boundary-probe.sh
git commit -m "Phase 3A-1 Task 4: the compositor moves, and pointerPlacement becomes the seam swift test can reach"
```

---

### Task 5: The fixture — recorded, not constructed

**Files:**
- Create: `scripts/redact-observation-log.swift`
- Create: `Tests/HeadlessFixtures/segment-00-redacted.jsonl`
- Create: `Tests/AppSourceTests/FixtureRedactionTests.swift`
- Modify: `Package.swift` (the fixture as a resource of `HeadlessTests`), `docs/ARCHITECTURE.md`

**Interfaces:**
- Consumes: nothing from earlier tasks; independent of the move.
- Produces: the committed fixture at `Tests/HeadlessFixtures/segment-00-redacted.jsonl`, and `adjudicatedStringFields: [String: String]` (keyed `Type.field`, valued with the verdict and its reason) in `Tests/AppSourceTests/FixtureRedactionTests.swift`. Task 6 consumes only the fixture, as a bundle resource.

**Source:** `~/soredemo-evidence/row14/soredemo-preview-98460A97-DAA9-4432-9434-506B039BCE14/observations/segment-00.jsonl` — verified present, 411 lines: 251 pointer / 149 tapDisabled / 6 button / 3 axChain / 1 header / 1 trailer.

**The property that matters is not that the file is untouched.** It is that every value the compositor consumes was recorded by the real writer through the real capture path, before this test existed. That is the sole reason it cannot repeat probe § 12, where a fixture's values were produced by the same misunderstanding as the code under test.

**Half its value is that it is dirty.** 149 tap-disabled windows, an `accessibilityUnavailable` in the header's `blindness`, a mid-recording authorisation flip, two different blind rates across one session. Four seconds against an empty desktop would produce almost none of that.

- [ ] **Step 1: Write the schema scan first — it decides what the script must redact**

Create `Tests/AppSourceTests/FixtureRedactionTests.swift`:

```swift
import Testing
import Foundation
import CheckerLexer

/// **Redaction adjudicated by SCHEMA, not by instance.**
///
/// Enumerating the string fields PRESENT IN THE FILE finds one piece of user data.
/// Enumerating the string fields IN THE SCHEMA finds two, and the second —
/// `KeyRecord.shortcut` — has zero occurrences in this file. A scan of the instance
/// can never find it, and the next fixture recorded by someone who used a shortcut
/// carries their typing into git.
///
/// This table was verified by hand once (`AXElementRecord` has exactly `role`,
/// `title`, `frame`, `readInterval` — no `identifier`), and that clean result is the
/// REASON this scan exists rather than a reason it does not: the table's whole force
/// comes from "by schema", and a hand enumeration of a schema is itself a [prose]
/// assertion guarding user data reaching git. Phase 3 adds cursor shape, which will
/// very likely carry a string; the gate must speak up then instead of waiting for
/// someone to remember this table.
let adjudicatedStringFields: [String: String] = [
    "AXElementRecord.title": "REDACT — user data; appears in ancestors[], children[], hit",
    "KeyRecord.shortcut": "REDACT — keystrokes; zero occurrences in today's fixture, which is why an instance scan cannot find it",
    "AXElementRecord.role": "keep — system AX role constant",
    // …every remaining string-valued field in the observation-log schema, each with
    // its verdict: kind (×6 types), mediaFilename (×2), epoch.id, blindness[],
    // detectedBy, disabledBy, phase, button, truncation, lowerBoundFrom,
    // gapWatches[].site, gapWatches[].lostUnit
]

/// **An unadjudicated string field is red.** Scans every `String`-typed stored
/// property of every observation-log record type in `Sources/Project` and compares
/// the set against `adjudicatedStringFields`. A field added without a verdict fails
/// here, before a fixture carrying it can be committed.
@Test func everyStringFieldInTheObservationLogSchemaHasAVerdict() throws {
    let found = try stringValuedFieldsInObservationSchema()
    try #require(!found.isEmpty,
                 "no string fields found in the observation-log schema — the scan would pass vacuously")

    let adjudicated = Set(adjudicatedStringFields.keys)
    #expect(found == adjudicated, """
        the observation-log schema's string fields no longer match the adjudicated set.

        UNADJUDICATED (a field exists with no verdict — decide REDACT or keep, with a reason):
        \(found.subtracting(adjudicated).sorted().joined(separator: "\n  "))

        ADJUDICATED BUT GONE (delete the line; a verdict covering nothing is a verdict that lies):
        \(adjudicated.subtracting(found).sorted().joined(separator: "\n  "))

        The answer is never to widen this scan. A string field with no verdict is user data \
        until someone says otherwise, and the fixture is committed to git.
        """)
}

/// Every `String`-valued stored property of every record type in `Sources/Project`,
/// keyed `Type.field`, read through the code view so a `String` named in a doc
/// comment is not a field.
///
/// A line scan, keyed by the most recent enclosing `struct`/`enum` declaration. The
/// schema is a flat set of record structs — verified by reading `Sources/Project`
/// before this was written — so nesting depth is not a question this has to answer,
/// and if the schema ever grows a nested record the qualified name simply gets the
/// outer type, which is loud rather than silent.
func stringValuedFieldsInObservationSchema() throws -> Set<String> {
    var fields: Set<String> = []
    for file in try swiftFiles(under: "Sources/Project") {
        let text = try String(contentsOf: file, encoding: .utf8)
        var enclosing = ""
        for line in SwiftSourceLexer.codeViewLines(of: text) {
            let words = line.split(whereSeparator: { !SwiftSourceLexer.isIdentifierCharacter($0) })
                .map(String.init)
            if let keywordIndex = words.firstIndex(where: { ["struct", "enum", "class"].contains($0) }),
               keywordIndex + 1 < words.count,
               words.first != "import" {
                enclosing = words[keywordIndex + 1]
                continue
            }
            guard !enclosing.isEmpty,
                  let bindingIndex = words.firstIndex(where: { $0 == "let" || $0 == "var" }),
                  bindingIndex + 1 < words.count else { continue }
            // `name: String`, `name: String?`, `name: [String]` — the type text is
            // whatever follows the colon on this line.
            guard let colon = line.firstIndex(of: ":") else { continue }
            let type = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard type == "String" || type == "String?" || type == "[String]" else { continue }
            fields.insert("\(enclosing).\(words[bindingIndex + 1])")
        }
    }
    return fields
}
```

Determine the real type and field names by reading `Sources/Project` before writing the table — do not transcribe the list above as gospel; it is the design doc's reading and this test is what replaces it with a measurement.

- [ ] **Step 2: Run it and watch it fail, then fill the table from what it reports**

```bash
swift test --filter FixtureRedaction
```

The first run reports the real field set. Adjudicate each one in the table with a verdict and a reason. If the tree contains a string field the design doc did not anticipate, that is the scan doing its job — adjudicate it and say so in the task report.

- [ ] **Step 3: Write the redaction script**

Create `scripts/redact-observation-log.swift`: reads a `.jsonl` on stdin or by path, and for every record replaces the value of each REDACT field with the placeholder `"[redacted]"`, leaving every other field byte-identical. Header comment must state:

- what it redacts and why, field by field;
- that **nothing the compositor consumes is touched** — every timestamp, every coordinate, the anchor and all 149 intervals are byte-for-byte the recorded values;
- **the reproducibility cost, stated honestly**: reproducing this run needs the unredacted original, which exists only on the author's machine. **This redaction is auditable by its author and not by its readers** — a future reader can verify the negative (nothing remains) and cannot verify that the right things were removed. That is a known cost of choosing a recorded fixture over a constructed one, and it is written down because an unwritten cost reads as zero.

- [ ] **Step 4: Produce the fixture and verify it against the recorded original**

```bash
mkdir -p Tests/HeadlessFixtures
swift scripts/redact-observation-log.swift \
  ~/soredemo-evidence/row14/soredemo-preview-98460A97-DAA9-4432-9434-506B039BCE14/observations/segment-00.jsonl \
  > Tests/HeadlessFixtures/segment-00-redacted.jsonl
wc -l Tests/HeadlessFixtures/segment-00-redacted.jsonl     # expect 411
```

Then verify the negative AND the preservation, and put both in the report:

```bash
diff <(sed 's/"title":"[^"]*"/"title":"X"/g' ~/soredemo-evidence/row14/*/observations/segment-00.jsonl) \
     <(sed 's/"title":"[^"]*"/"title":"X"/g' Tests/HeadlessFixtures/segment-00-redacted.jsonl)
```

Expected: empty — every byte outside the redacted values is unchanged. Adjust the `sed` to cover each REDACT field the table names.

**Do not commit anything from `~/soredemo-evidence` other than the redacted output.**

- [ ] **Step 5: Add the two gates**

In the same test file:

```swift
/// **Gate 1 — content.** No `title` and no `shortcut` in any committed fixture holds
/// a value other than the placeholder. This exists for the FUTURE: a second fixture,
/// or a re-redaction, when nobody re-checks that the script ran correctly. A leak is
/// red before it is committed.
@Test func noCommittedFixtureCarriesAnUnredactedStringField() throws {
    let redactedFields = adjudicatedStringFields
        .filter { $0.value.hasPrefix("REDACT") }
        .map { String($0.key.split(separator: ".").last!) }
    try #require(!redactedFields.isEmpty, "nothing is marked REDACT — this gate would pass vacuously")

    let fixtures = try FileManager.default.contentsOfDirectory(
        at: repositoryRoot.appending(path: "Tests/HeadlessFixtures"),
        includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "jsonl" }
    try #require(!fixtures.isEmpty, "no committed fixtures found — this gate would pass vacuously")

    for fixture in fixtures {
        let text = try String(contentsOf: fixture, encoding: .utf8)
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            for field in redactedFields {
                // Every occurrence of `"field":"…"` must hold exactly the placeholder.
                var search = line.startIndex..<line.endIndex
                while let key = line.range(of: "\"\(field)\":\"", range: search) {
                    guard let close = line[key.upperBound...].firstIndex(of: "\"") else { break }
                    let value = String(line[key.upperBound..<close])
                    #expect(value == "[redacted]", """
                        \(fixture.lastPathComponent):\(index + 1) carries an unredacted `\(field)`.
                        Value length \(value.count). The value itself is NOT printed here — printing \
                        it would put the leak in CI logs, which is the same exposure with an audience.
                        Re-run scripts/redact-observation-log.swift before committing.
                        """)
                    search = close..<line.endIndex
                }
            }
        }
    }
}

/// **Gate 2 — consumption.** The render path never reads either field. Scanned
/// through `codeLinesNaming` over `Sources/Headless` and `Sources/Render`, so a
/// mention in a doc comment does not count and a real read does.
@Test func theRenderPathNeverReadsARedactedField() throws {
    let redactedFields = adjudicatedStringFields
        .filter { $0.value.hasPrefix("REDACT") }
        .map { String($0.key.split(separator: ".").last!) }
    let renderFiles = try swiftFiles(under: "Sources/Headless") + swiftFiles(under: "Sources/Render")

    for field in redactedFields {
        let readers = try codeLinesNaming(".\(field)", in: renderFiles)
        #expect(readers.isEmpty, """
            the render path reads `\(field)`, a field the fixture redacts:
            \(readers.map { "  \($0.location): \($0.text)" }.joined(separator: "\n"))
            If the render path needs this value, the fixture cannot be redacted of it and the \
            adjudication changes — not this gate.
            """)
    }
}
```

- [ ] **Step 6: Declare the fixture as a resource**

In `Package.swift`, `HeadlessTests` gains `resources: [.copy("../HeadlessFixtures/segment-00-redacted.jsonl")]` — or, if SwiftPM rejects the parent-directory path, move the fixture under `Tests/HeadlessTests/Fixtures/` and copy from there. Decide by running the build, and record which form worked.

- [ ] **Step 7: Record the redaction in ARCHITECTURE.md and commit**

Add the adjudication table, the two gates, and the honest reproducibility note.

```bash
swift build && scripts/count-tests.sh --split && scripts/run-cross-boundary-probe.sh
git add scripts/redact-observation-log.swift Tests/HeadlessFixtures Tests/AppSourceTests/FixtureRedactionTests.swift Package.swift docs/ARCHITECTURE.md
git commit -m "Phase 3A-1 Task 5: the recorded fixture, redacted by schema and gated twice"
```

---

### Task 6: The completion condition

**Files:**
- Create: `Tests/HeadlessTests/RecordedPointerPositionTests.swift`
- Modify: `ROADMAP.md`

**Interfaces:**
- Consumes: `StageCompositor.pointerPlacement(at:in:)` and `observationLogURL` (Task 4), `CoreImageFrameRenderer` (Task 3), the fixture (Task 5).
- Produces: nothing. This is the phase's proof.

**A person can see this:** `swift test` contains a test that **`import Headless`**, constructs a `StageCompositor`, feeds it the RECORDED observation log, and asserts the drawn pointer's position at a given frame. Changing `StageCompositor.pointerPlacement`'s `let time = anchor.hostTime + offset` back to `let time = offset` turns it red.

> **Correction to the design doc.** § 5 writes this condition as `import SoredemoHeadless`. `SoredemoHeadless` is the PRODUCT name; the importable module is the TARGET, `Headless`. `import SoredemoHeadless` does not compile. Nothing about the decision changes — the product still exists under that name and is still what the Xcode app target links — only the spelling in the test. Fix § 5's line when this task lands, rather than leaving the spec's version to be copied by the next reader.

**Observations recorded, source frame constructed.** The fixture carries no media — the 29 MB `.mov` is correctly excluded — so this test synthesises the frame it composes. That is deliberate: the assertion is about geometry, not about what the frame depicts. **The constructed frame must contrast with the cursor art** (white fill, black stroke); a white or near-white frame makes "find the drawn pointer" fail for a reason that has nothing to do with position.

- [ ] **Step 1: Write the two-layer test**

```swift
import Testing
import Foundation
import CoreMedia
import CoreVideo
import Render
import Timeline
import Headless

/// **The instrument that reaches the code only a person reached.**
///
/// `1a98402` lived in `pointerPlacement` for a whole phase: a composition time was
/// compared against samples stamped in the absolute host clock, `.noObservationYet`
/// came back for every frame of every recording, and no build of this app had ever
/// drawn a pointer — through 450 tests, 350 probe checks, eight task reviews and
/// fifteen fix rounds. It was found by a person recording four seconds and looking.
///
/// The input is the REAL recording's observation log, redacted by schema: 411 lines,
/// 251 pointer samples, 149 tap-disabled windows, an authorisation flip mid-session.
/// Every value this test consumes was written by the real `ObservationWriter` through
/// the real capture path, before this test existed. That is what stops it repeating
/// probe § 12, whose fixture and code under test shared one wrong frame of reference
/// and cancelled each other out.
///
/// **Two layers, because one mutation cannot calibrate both.** Reverting to
/// `let time = offset` makes the lookup time a small fraction while the records are
/// mach absolute times (~5.2 × 10¹⁴), so nothing matches and the compositor draws NO
/// pointer at all rather than a misplaced one. Both layers go red — but a vanished
/// pointer is what a person already catches, and the capability this test claims is
/// POSITION. So the second layer has its own mutation that can only misplace.

/// The fixture, and a composition time at which the recording really does have a
/// drawn pointer.
///
/// **Found by reading the log, never by a hardcoded index.** 149 of the 411 lines are
/// tap-disabled windows; a hardcoded offset that drifted into one would make
/// `position(at:)` return `.blind` and this test would then pass or fail for a reason
/// with nothing to do with the clock conversion it exists to check. So the time is
/// searched for, and the search asserts what it found before anything else runs.
func aCompositionTimeWithADrawnPointer() throws -> (time: CMTime, compositor: StageCompositor) {
    let fixture = try #require(
        Bundle.module.url(forResource: "segment-00-redacted", withExtension: "jsonl"),
        "the redacted fixture is not in the test bundle — check Package.swift's resources")
    StageCompositor.observationLogURL = fixture
    StageCompositor.overrides = []
    StageCompositor.style = .default
    let compositor = StageCompositor()

    let plan = probePlan()
    // Walk forward in 1/60 s steps across the recording's span. The first instant that
    // yields a placement is the one used; a recording with 251 pointer samples must
    // have one, and #require says so rather than letting a nil quietly end the search.
    for frame in 0..<600 {
        let time = CMTime(value: CMTimeValue(frame), timescale: 60)
        if compositor.pointerPlacement(at: time, in: plan) != nil {
            return (time, compositor)
        }
    }
    Issue.record("no composition time in the first 10 s of the fixture produced a pointer placement")
    throw CancellationError()
}

/// The plan both tests compose against: a 640×360 stage at `StageStyle.default`.
func probePlan() -> RenderPlan {
    let base = StagePlanner.plan(outputWidth: 640, outputHeight: 360,
                                 sourceWidth: 640, sourceHeight: 360, style: .default)
    return RenderPlan(outputWidth: base.outputWidth, outputHeight: base.outputHeight,
                      card: base.card, cornerRadius: base.cornerRadius,
                      style: base.style, pointer: nil)
}

/// **Layer 1: something got drawn.** This is what a person already catches — the
/// pointer being absent is exactly how `1a98402` was found — so it is asserted
/// separately from position and never allowed to stand in for it.
@Test func aPointerIsDrawnAtAll() throws {
    let (time, compositor) = try aCompositionTimeWithADrawnPointer()
    let placement = try #require(compositor.pointerPlacement(at: time, in: probePlan()))

    let withPointer = try composedFrame(pointer: placement)
    let withoutPointer = try composedFrame(pointer: nil)

    let differing = zip(withPointer, withoutPointer).filter { $0 != $1 }
    #expect(!differing.isEmpty, """
        composing with a pointer placement produced a frame identical to composing without one. \
        Nothing was drawn. This is the shape of 1a98402: the placement existed and the pixels \
        did not change.
        """)
}

/// **Layer 2: it got drawn where the recording says.** The capability this test
/// claims. Its calibrating mutation is NOT the `let time = offset` revert — that one
/// makes the compositor draw nothing, which layer 1 already covers — but a mutation
/// that can only misplace. Both are observed in step 2 and both go in the report.
@Test func aPointerIsDrawnAtTheRecordedPosition() throws {
    let (time, compositor) = try aCompositionTimeWithADrawnPointer()
    let placement = try #require(compositor.pointerPlacement(at: time, in: probePlan()))

    let withPointer = try composedFrame(pointer: placement)
    let withoutPointer = try composedFrame(pointer: nil)

    // Indices of the changed pixels, converted back to the plan's own coordinate
    // space: row-major from the buffer's top, and RenderPlan is bottom-left origin.
    let width = 640, height = 360
    var xs: [Double] = [], ys: [Double] = []
    for (index, pair) in zip(withPointer, withoutPointer).enumerated() where pair.0 != pair.1 {
        xs.append(Double(index % width))
        ys.append(Double(height - 1 - index / width))
    }
    try #require(!xs.isEmpty, "nothing was drawn; aPointerIsDrawnAtAll covers that case")

    // The TIP, not the centroid. `CursorArt`'s outline puts the tip at the origin and
    // extends down-and-right, so the drawn mass sits below and right of the recorded
    // point — a centroid would be offset by half the arrow and the tolerance would
    // have to absorb it, which is a tolerance hiding a systematic error.
    let tipX = xs.min()!
    let tipY = ys.max()!

    // Tolerance: 3 px. The arrow is stroked as well as filled, and antialiasing puts
    // changed pixels up to about a stroke width outside the true outline; 3 px covers
    // that and is far smaller than any misplacement worth catching — a swapped x/y at
    // 640×360 moves the tip by hundreds of pixels.
    #expect(abs(tipX - placement.x) < 3, """
        the drawn pointer's tip is at x = \(tipX); the recording places it at \(placement.x)
        """)
    #expect(abs(tipY - placement.y) < 3, """
        the drawn pointer's tip is at y = \(tipY); the recording places it at \(placement.y)
        """)
}

/// One composed frame, from a source filled with `sourceFill` (dark saturated blue —
/// see `PixelBufferSupport.swift` for why it must contrast with the white-filled,
/// black-stroked arrow).
func composedFrame(pointer: NormalizedPointerPlacement?) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
    let width = 640, height = 360
    let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
    let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
    let base = probePlan()
    let plan = RenderPlan(outputWidth: base.outputWidth, outputHeight: base.outputHeight,
                          card: base.card, cornerRadius: base.cornerRadius,
                          style: base.style, pointer: pointer)
    try CoreImageFrameRenderer().render(plan, source: source, into: destination)
    return try pixels(of: destination)
}
```

**Observations recorded, source frame constructed** — say so in the file's header. The 411 log lines are the real recording; the frame they are composed onto is synthesised, because the fixture correctly carries no media. The assertion is about geometry, not about what the frame depicts.

`Bundle.module` requires `HeadlessTests` to declare the fixture as a resource (Task 5, step 6). If `NormalizedPointerPlacement`'s field names or `pointerPlacement`'s return type differ from the above, use the real ones — read `Sources/Render/RenderPlan.swift` and `Sources/Headless/StageCompositor.swift`.

- [ ] **Step 2: Observe BOTH calibrating reds, and report both**

Mutation A — the historical defect. In `Sources/Headless/StageCompositor.swift`, change `let time = anchor.hostTime + offset` to `let time = offset`. Run. **Expected: both tests red.** Record the messages. Revert.

Mutation B — can only misplace. Swap `placement.x` and `placement.y` where the placement is constructed (or add a constant offset of a stated number of pixels). Run. **Expected: `aPointerIsDrawnAtAll` GREEN and `aPointerIsDrawnAtTheRecordedPosition` RED.** Record both. Revert.

If mutation B reddens layer 1 as well, the mutation is wrong for the job — pick a smaller offset that keeps the pointer inside the frame — not the test. **One mutation that reddens both layers proves only that the pipeline noticed something.** Both observed reds go in the task report; a report with only mutation A does not close this task.

- [ ] **Step 3: Update ROADMAP.md**

Retire the "no automated executing instrument" note for the render path, citing this test by name and stating precisely what it covers and what it does not: `startRequest`'s AVFoundation glue is still reached only by the probe and by a person.

- [ ] **Step 4: Gates and commit**

```bash
swift build && scripts/count-tests.sh --split && scripts/run-cross-boundary-probe.sh
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -configuration Debug build
git add Tests/HeadlessTests/RecordedPointerPositionTests.swift ROADMAP.md
git commit -m "Phase 3A-1 Task 6: swift test now draws a pointer from a real recording, and two mutations say so"
```

---

### Task 7: `MP4Exporter`, and I6 closed on the way in

**Files:**
- Create: `Sources/Headless/MP4Exporter.swift` (git mv)
- Create: `Tests/HeadlessTests/MP4ExporterTests.swift`
- Modify: `scripts/run-cross-boundary-probe.sh`, `ROADMAP.md`

**Interfaces:**
- Consumes: `CompositionBuilder` and `StageCompositor` from Task 4.
- Produces: `public enum MP4Exporter`, `public enum MP4Exporter.ExportError`, `public struct ExportReport`.

**`MP4Exporter` brings I6 with it.** Its readiness poll at `Soredemo/Export/MP4Exporter.swift:190-195` is uncapped, and this repo has *measured* the stall it would spin on (Spike D). The entry rule forces a test that exercises the exporter, and an uncapped poll inside `swift test` is a hang with no diagnosis. **The poll gets capped in this task, and the test also carries a timeout. Not neither, and here not either-or:** the cap is the real fix and the timeout is what stops a regression in the cap from hanging CI.

- [ ] **Step 1: Move the file and set access levels**

```bash
git mv Soredemo/Export/MP4Exporter.swift Sources/Headless/MP4Exporter.swift
```

Make `MP4Exporter`, its export entry point, `ExportError` and `ExportReport` (and its stored properties the app reads) `public`. Measure the app's call sites first: `grep -rn "MP4Exporter\.\|ExportReport" Soredemo/`.

- [ ] **Step 2: a Rust recorder the poll**

Replace the unbounded `while !writerInput.isReadyForMoreMediaData` loop with a bounded one carrying a stated deadline, and add a new `ExportError` case for exhausting it. The error message must name the frame index and the elapsed time — an export that stalls must say where, because Spike D's measured stall is a real condition and "it hung" is not a diagnosis. Choose the deadline from Spike D's measurement, cite the number in the code comment, and state it in the task report.

- [ ] **Step 3: Write the entry-rule test with its own timeout**

`Tests/HeadlessTests/MP4ExporterTests.swift` exports `Tests/RenderParityFixtures/two-tone.mov` through the real composition to a temp `.mp4`, and asserts:

1. the export completes and `ExportReport`'s `framesRead == framesWritten`;
2. the output file exists and is non-empty;
3. `ExportError`'s new timeout case is distinguishable.

Wrap the export in `withThrowingTaskGroup` with a `Task.sleep`-based cancelling arm at a stated wall-clock limit, so a regression in the cap fails rather than hangs. Write the temp file under `FileManager.default.temporaryDirectory` and delete it in a `defer`. **Never write to `$HOME`.** Do not commit the output.

- [ ] **Step 4: Update the probe's input list, gates, commit**

`Soredemo/Export/MP4Exporter.swift` → `Sources/Headless/MP4Exporter.swift`. Confirm probe § 14 stays green — it counts the finished file's own samples and checks the `ftyp` major brand, and the cap must not change either.

Update `ROADMAP.md`'s `export-basic` row to record that I6 is closed and how.

```bash
swift build && scripts/count-tests.sh --split && scripts/run-cross-boundary-probe.sh
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -configuration Debug build
git add Sources/Headless/MP4Exporter.swift Tests/HeadlessTests/MP4ExporterTests.swift scripts/run-cross-boundary-probe.sh ROADMAP.md
git commit -m "Phase 3A-1 Task 7: MP4Exporter moves and I6's uncapped poll is capped on the way in"
```

At this point `Soredemo/Render/` and `Soredemo/Export/` are empty. Remove the directories if git has not already.

---

### Task 8: The two hand-maintained claims this phase must not inherit

`Headless` is deliberately not inheriting `CheckerLexer`'s arrangement — a target with no guard whose consequences are "kept by hand". This task pays down the two places where that arrangement is already costing something, both found while planning this phase.

**Files:**
- Create: `Tests/CheckerLexerTests/LexerImportDisciplineTests.swift`
- Create: `Tests/AppSourceTests/ProseClaimTests.swift`
- Modify: `Package.swift` (comment only), `ROADMAP.md`, `docs/ARCHITECTURE.md`, `docs/design/2026-08-04-phase-3a-foundation-design.md`

**Interfaces:** none produced.

**Finding 1 — `CheckerLexer`'s reason IS written where its maintainer looks, and its consequences are not enforced.** The carried question was whether the missing `ArchitectureCheck` is deliberate and whether the reason lives anywhere but a commit message. Measured: `Package.swift:41-55` states it is deliberate, gives the reason (attaching the plugin closes `AppSourceTests → CheckerLexer → ArchitectureCheck → architecture-checker → CheckerLexer`), names both consequences, and points at the test that pins the exemption; `ArchitectureCheckTests.swift:554-566` says the same beside the list. **So the documentation half is already done and needs nothing.** What is missing is the enforcement half: the comment says rule 1 for this target is "kept by hand", and nothing checks it.

**Finding 2 — three documents state three different wrong test counts, and the tool built to prevent exactly that is wired to nothing.** Measured on a clean tree at `f8b9998`: `swift test` = 454, all passing, two instruments agreeing. `ROADMAP.md:85` says 464; `docs/ARCHITECTURE.md:649` says 462; the design doc's § 4 example says 466. `scripts/count-tests.sh` exists precisely because "the number was got wrong three times by hand" — and it sits unused at every site where the number is written.

**The finding is not that the digits are wrong.** It is that a number changing on most commits was written into documents changing rarely, three times, by someone with the measuring tool already in the repository. Correcting the digits leaves that fully intact and produces a fourth wrong value within a week. **The fix is to remove the claim and gate the position**, which is what steps 3 and 3b do.

- [ ] **Step 1: Enforce `CheckerLexer`'s rule-1 consequence**

Create `Tests/CheckerLexerTests/LexerImportDisciplineTests.swift`:

```swift
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
/// The other stated consequence — rule 3, no ambient time or randomness, since
/// `DeterminismTests` derives its module list from the plugin's attachments — is left
/// hand-kept and that is recorded rather than hidden: it needs a link-time symbol
/// scan, not a text scan, and the honest fix is to add this target to
/// `DeterminismTests`' own list. If that is done, delete this paragraph.
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
```

The scan is over the code view and word-split, not a substring or a line prefix, for the same reason the checker's own rule 1 is: `import` + newline + module typechecks, and `import\u{000C}AppKit` is one `printf` away. This is a narrower instrument than the checker's — it does not walk across lines — and that narrowness is worth naming in the doc comment rather than leaving a reader to assume parity with the plugin.

Observe its red by temporarily adding `import CoreGraphics` to `Sources/CheckerLexer/SwiftSourceLexer.swift`; record the message; revert.

- [ ] **Step 2: Decide rule 3 rather than leaving it**

Try adding `"CheckerLexer"` to `DeterminismTests`' dependencies in `Package.swift` and run `swift test --filter DeterminismTests`. If `determinismTestTargetDependsOnEveryCheckedModule` and the symbol scan both stay green, keep the change and delete the last paragraph of the doc comment above — the second hand-kept consequence is then enforced too. If either fails, revert and record the exact failure in the task report and in the `Package.swift` comment, so the next reader inherits a measurement rather than a plan.

- [ ] **Step 3: Take the number out of prose entirely — do not correct it**

**Writing 454 into the documents is the wrong fix**: a number that changes on most commits, written into documents that change rarely, expires by construction. It expired twice already, into two different wrong values, in files edited by someone who had `scripts/count-tests.sh` available. **A tool built to prevent an error, not wired to the place the error happens, prevents nothing** — that is the finding, and correcting the digits would leave it fully intact.

So: **the test count does not appear in prose.** It lives in the gate's output and nowhere else.

- `ROADMAP.md:85` — rewrite the sentence without a count. It is making a point about the app target having no executing instrument; the number was decoration on that point, not its content. Say "`swift test`'s suite does not link the app" and cite `scripts/count-tests.sh` for the figure.
- `docs/ARCHITECTURE.md:649` — same rewrite, same reason.
- **The design doc, `docs/design/2026-08-04-phase-3a-foundation-design.md` § 4**, whose example block prints `466 passed`. Left alone it becomes a FOURTH source disagreeing with the other three. Replace the digits with `N` in both rows of that block — it is illustrating a FORMAT, and a format example does not need a real number to illustrate it.

- [ ] **Step 3b: Wire the gate to the position the error happened at**

```swift
/// **A test count may not appear in prose.** Three documents carried three different
/// wrong values — 464, 462 and 466 — while `scripts/count-tests.sh` sat unused, and
/// that script exists because the number had already been got wrong three times by
/// hand. The tool was built and never connected to the place the mistake is made.
///
/// **The rule is narrow on purpose.** "No number near the word tests" would fire on
/// `AGENTS.md`'s "it survived 450 unit tests, 350 probe checks" — a HISTORICAL claim
/// about one moment in the past, correctly frozen, and one of the most valuable
/// sentences in that file. The general form of this rule was already measured on this
/// tree once, at roughly 97% false positives, and a gate at that rate gets switched
/// off. So this pins one shape: `swift test` followed closely by a bare integer, which
/// is exactly how both live claims were spelled and is never how a historical one is.
///
/// The count is not unavailable — it is one command away, and both sites now say which.
@Test func noProseDocumentStatesTheCurrentTestCount() throws {
    let documents = ["ROADMAP.md", "AGENTS.md", "docs/ARCHITECTURE.md", "KICKOFF.md",
                     "docs/design/2026-08-04-phase-3a-foundation-design.md"]
    for name in documents {
        let url = repositoryRoot.appending(path: name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var search = line.startIndex..<line.endIndex
            while let hit = line.range(of: "swift test", range: search) {
                // The 40 characters after the phrase: enough to cover "`swift test`'s 464
                // tests" and "swift test — deterministic   466 passed", short enough that a
                // sentence mentioning the command and, later, an unrelated number does not fire.
                let windowEnd = line.index(hit.upperBound, offsetBy: 40, limitedBy: line.endIndex)
                    ?? line.endIndex
                let window = line[hit.upperBound..<windowEnd]
                let hasCount = window.contains { $0.isNumber }
                #expect(!hasCount, """
                    \(name):\(index + 1) states a test count in prose:
                      \(line.trimmingCharacters(in: .whitespaces))
                    That number changes on most commits and this document does not. Three \
                    documents carried three different wrong values before this gate existed.
                    Cite `scripts/count-tests.sh` instead; the gate's output is where the \
                    number belongs.
                    """)
                search = hit.upperBound..<line.endIndex
            }
        }
    }
}
```

Put it in `Tests/AppSourceTests/`. **Observe its red before removing the numbers**: run it against the tree as it stands and confirm it names `ROADMAP.md:85`, `docs/ARCHITECTURE.md:649` and the design doc's § 4 block — three hits, the three known ones. A gate whose first run finds exactly the defects that motivated it is a gate with grade-1 evidence; one written after the cleanup would only ever have been green.

**Why not a gate that recomputes the number.** A test that shells out to `swift test` from inside `swift test` recurses, and a gate that hangs is worse than a stale number. Removing the claim is the fix that needs no recomputation at all — there is nothing left to go stale.

- [ ] **Step 4: Gates and commit**

```bash
swift build && scripts/count-tests.sh --split && scripts/run-cross-boundary-probe.sh
git add Tests/CheckerLexerTests/LexerImportDisciplineTests.swift Tests/AppSourceTests/ProseClaimTests.swift Package.swift ROADMAP.md docs/ARCHITECTURE.md docs/design/2026-08-04-phase-3a-foundation-design.md
git commit -m "Phase 3A-1 Task 8: CheckerLexer's hand-kept rule enforced, and the test count leaves prose for good"
```

---

## Final whole-branch review — three hunts to name in the dispatch

Beyond the standard rubric, the final reviewer is asked for these specifically, because each names a failure this repository has actually produced:

1. **Units and clock domains.** Every new comparison of two time values: are both in the same frame of reference, and does something say so at the type level rather than in a comment? `1a98402` was exactly this.
2. **Titles that claim more than the check performs.** Every new doc comment on a test or scanner: does the check verify what the title asserts? Probe § 12's title said "a real `ObservationWriter` log" — true of the writer, false of the clock.
3. **Fixture provenance.** For every fixture: were its values produced by the same understanding as the code under test? A fixture and an implementation sharing one misunderstanding cancel inside the section that contains them.
