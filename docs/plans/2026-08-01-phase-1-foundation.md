# Phase 1 Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use a skill chain:subagent-driven-development (recommended) or a skill chain:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An app that launches to an empty window, a package that cannot violate its own architecture rules, and the three data structures every later phase is expressed in.

**Architecture:** One SwiftPM package at the repository root with six library targets whose dependency edges are compile-enforced, consumed by a hand-made Xcode app target. The package imports Foundation only; a build-tool plugin enforces that, because SwiftPM does not. Every derived value carries a citation that cannot be omitted.

**Tech Stack:** Swift 6.4 · macOS 26.0 deployment · macOS 27 SDK (Xcode 27 beta 4, `27A5228h`) · SwiftPM tools-version 6.4 · Swift Testing · SwiftUI + AppKit

**Task order.** Revised after Task 2, with reasons — a plan that says one thing while the work does another is the failure mode `AGENTS.md` names:

| Task | When | Why |
| --- | --- | --- |
| 3 · rules 2 and 4 | **next** | Rule 2 guards a mistake Phase 2 will tempt constantly — `CGEvent`, `CGDisplayBounds` and AX frames are all `CGRect`. Rule 4 keeps rule 1 honest, because rule 1's completeness rests on the package having zero dependencies. One round, substring scans over the existing code view — **not** the token stream |
| 4 · rule 3, determinism | after **Task 6** | `Sources/` is six placeholders, so the rule has nothing to protect, and the link-time symbol spike needs real object files with real symbols. Task 6 is where determinism first matters |
| 5 · rule 5, CG bridge | at **Task 18** | `CGGeometryBridge.swift` does not exist until Task 18 creates it and the app is two template files, so the test would be trivially green — the vacuous pass this plan warns against elsewhere |

Tasks 4 and 5 are deferred for the same reason, applied to scheduling rather than to a test: running them now would produce a check that passes without proving anything.

**Design doc:** `docs/design/2026-08-01-phase-1-foundation-design.md` — read it before Task 1. Findings are cited as F1–F8 and decisions as D-P0–D-P4; this plan does not repeat their reasoning.

## Progress — read this, not the step checkboxes

**The per-step `- [ ]` checkboxes below were never maintained.** All 77 sit unchecked while sixteen
tasks are done, so anything that reads them as progress reads 0%. This table is the committed
progress record; the SDD ledger at `a skill chain/sdd/2026-08-01-phase-1-foundation/progress.md`
carries the per-task detail but is **git-ignored**, so it does not survive a fresh clone. Between
this table and `git log --oneline 7419058..HEAD`, a new session has what it needs.

| Task | | Landed at | Note |
| --- | --- | --- | --- |
| 1 · repo-skeleton | ☑ | `07e9f1b` | package at root, app target, launches empty |
| 2 · rule 1, import allow-list | ☑ | `50f09e0` … `e5edc8b` | four rounds, then capped; gaps recorded with reachability |
| 2.5 · does the plugin run under Xcode? | ☑ | (spike) | `ENABLE_USER_SCRIPT_SANDBOXING = YES` does not suppress it; violation ⇒ `xcodebuild` exit 65 |
| 3 · rules 2 and 4 | ☑ | `23ba054` | banned CG types (substring, not tokens), no manifest dependencies |
| 4 · rule 3, determinism | ☑ | `2ca8bfc` | link-time symbols, 37 mangled names derived not guessed |
| 5 · rule 5, CG bridge | ☐ | — | **deferred into Task 18** — `CGGeometryBridge.swift` does not exist yet |
| 6 · canonical encoding + digest | ☑ | `2e60445` | 41 pinned bytes, revision `0xbcf4_9ed7_dcb4_2be0` |
| 7 · geometry registry | ☑ | `d65fc5c` | two failure modes, decode throws rather than traps |
| 8 · normalized types + cross-revision trap | ☑ | `50c13ef` | guard is uncoverable in-process; see the task's ledger entry |
| 9 · NormalizationContext | ☑ | `33e0519` | the single Y-axis flip — **no caller yet**, which is why Task 19 must not tick `geometry` |
| 10 · DisplayArrangement | ☑ | `470035d` | extrinsic global→local routing |
| 10.5 · point vs pixel as a type | ☑ | `cbc3655` | inserted after a measured mis-route; mixing units is now a compile error |
| 11 · timeline | ☑ | `02f4e78` | `Nanoseconds`, half-open `TimeRange` |
| 12 · ContentDigest + non-empty Evidence | ☑ | `e1117b6` | citation types |
| 13 · Derived + approvalBytes | ☑ | `5a32eb2` | `CanonicallyEncodable` in the generic constraint, so a bad payload fails to compile |
| 14 · producer-value rule | ☑ | `9a668e3` | mutation reddened 5 tests, three of them Task 13's |
| 15 · reverse index + cache pairing | ☑ | `09a6d5c` | `rebuild` replaces, never merges; no self-triggering staleness detection |
| 16 · project snapshot + upgrade chain | ☑ | `2a30000` + `ace903c` | `SchemaProbe` reads the version without decoding the document; `tooNew` throws before any field lands |
| 17 · package I/O + truncated tail | ☑ | `46e31ae` + `3180653` | four mutations passed and the mechanism was still untested; see the ledger |
| 18 · NSDocument coordinator | ☐ | — | absorbs Task 5, plus Step 2.5 from **Open items** §1 |
| 19 · close out the phase | ☐ | — | **must not** tick `geometry`; see **Open items** §2 |

**Test count, and how to count it.** `swift test` prints one summary line per test target, and the
line reads `1 test` for a target with one and `N tests` for a target with more. A grep for `tests`
therefore silently drops every single-test target — which is how the figure 226 got into this table
and into a task brief when the real total was 229. Count with `tests?`, or read the per-target lines
and add them yourself:

```
swift test 2>&1 | grep -oE "^✔ Test run with ([0-9]+) tests?" | grep -oE '[0-9]+' | paste -sd+ - | bc
```

At Task 17: **259 green** — 107 Geometry · 93 Graph · 31 Project · 18 Timeline · 8 Determinism ·
1 Framing · 1 Variants (the last two are placeholders that assert the target builds).

## Global Constraints

- `// swift-tools-version: 6.3`, `platforms: [.macOS(.v26)]`. No `if #available` anywhere. **Not 6.4** — Xcode 26.6 ships SwiftPM 6.3.3 and refuses a 6.4 manifest; 6.3 builds under both toolchains with no feature loss.
- `swiftSettings: [.swiftLanguageMode(.v6), .strictMemorySafety()]` on **every** target. **`.strictConcurrency` is not a `SwiftSetting`** and will fail the manifest (F6).
- The package imports **Foundation only**. No AppKit, ScreenCaptureKit, AVFoundation, SwiftUI, CryptoKit, CoreGraphics.
- No `CGPoint`, `CGRect`, `CGSize`, `CGFloat` anywhere in the package.
- No ambient time or randomness in the package: no `Date()`, `Date.now`, `UUID()`, `.random(in:)`, `SystemRandomNumberGenerator`, `DispatchTime.now()`, `ContinuousClock`. IDs, timestamps and digests are minted in the app and passed in.
- **No type may share its module's name** (D-P1). `Timeline.Timeline` is the failure being avoided.
- Anything whose bytes are digested uses the **canonical encoding** rules (D-P4 § Canonical encoding): hand-written `Codable` for dictionaries, sorted deterministically, leading version byte, floats as `.bitPattern`.
- **Swift Testing only** (`@Test`, `#expect`, `#require`). Never XCTest.
- Never `.glassEffect()`, never `NSGlassEffectView`.
- Work on branch `phase-1-foundation` in `~/Documents/Soredemo/soredemo-main`. **No git worktree** (D-P0).
- **Rollback point: `8f43c34`** — where `main` actually stood when this phase began, carrying a
  superseded design document from an abandoned attempt. An earlier version of this line claimed
  `7419058` and was never checked against the repository; `main` was already two commits past it.
  Verify with `git log --oneline -1 main` rather than trusting this line — that is how it drifted.
  (No tag: the owner does not want one.)
- **Never hand-edit `Soredemo.xcodeproj/project.pbxproj` structurally** (F8). Value substitutions only. Package references are added in Xcode by the project owner.

## The verification rule

**A check that has never been observed RED is not a known check.**

This binds the plan's own verification steps, not only the tests it writes. Every step that claims to verify something records the observed failure *and* the pass. Three prior failures were the same shape — a green light read as evidence for a claim it did not support:

- the plugin's tests passing was read as "the rule is enforced"; it proved only that *imagined* violations were blocked
- `xcodebuild ** BUILD SUCCEEDED **` was read as "the plugin works under Xcode" while the app had no reference to the package, so the package was never built there
- a grep reporting a deployment target collapsed two values and reported the wrong one — **confirm build settings with `-showBuildSettings`, never grep**
- a warm `swift build` reported *Build complete!* with only a warning for an undeclared cross-target import, where a clean build errors — **`rm -rf .build` before verifying any dependency edge.** Measured on this repository; `.treatAllWarnings(as: .error)` does not close it, because the diagnostic comes from the dependency scanner rather than the compiler frontend

---

## File Structure

```
soredemo-main/
├── Package.swift                     tools 6.4 · .macOS(.v26)
├── Sources/
│   ├── Geometry/                     FNV1a · DisplayGeometry · GeometryRevision
│   │                                 GeometryRegistry · Normalized · PixelRect
│   │                                 NormalizationContext · DisplayArrangement
│   ├── Timeline/                     Nanoseconds · TimeRange
│   ├── Graph/                        ContentDigest · EvidenceRef · Evidence
│   │                                 Derivation · Derived · ReverseIndex
│   ├── Framing/                      empty in Phase 1 (fixes the edge)
│   ├── Variants/                     empty in Phase 1 (fixes the edge)
│   ├── Project/                      ProjectSnapshot · SchemaProbe · ProjectUpgrade
│   │                                 ProjectPackageIO · JSONLReader
│   └── architecture-checker/         the executable the plugin runs
├── Tests/{Geometry,Timeline,Graph,Framing,Variants,Project}Tests/
├── Plugins/ArchitectureCheck/
├── Metal/                            empty; Phase 2 render-core
├── scripts/                          Soredemo.entitlements
├── docs/  assets/                    assets/ = renamed soredemo-brand-kit/
├── Soredemo.xcodeproj                app · objectVersion 77 · committed
└── Soredemo/
    ├── App/SoredemoApp.swift
    ├── UI/ProjectDocument.swift
    ├── Capture/CGGeometryBridge.swift    the ONLY file allowed to name CGRect
    ├── Support/Minting.swift             UUID/Date/SHA-256 injection points
    └── Resources/Assets.xcassets/
```

---

### Task 1: repo-skeleton

**Files:** `Package.swift`; `Sources/<Module>/Placeholder.swift` ×6; `Tests/<Module>Tests/BuildsTests.swift` ×6; moves `Soredemo/Soredemo.xcodeproj` → root, `Soredemo/Soredemo/*` → `Soredemo/`; renames `soredemo-brand-kit/` → `assets/`; `Metal/README.md`.

**Interfaces produced:** target names `Geometry`, `Timeline`, `Graph`, `Framing`, `Variants`, `Project`; the `SoredemoCore` library product; a launchable `Soredemo.app`.

- [ ] **Step 1: Move the app project into layout A**

The project is currently at `Soredemo/Soredemo.xcodeproj` with sources at `Soredemo/Soredemo/`. It must end at the root with sources at `Soredemo/`.

```bash
cd ~/Documents/Soredemo/soredemo-main
git mv Soredemo/Soredemo.xcodeproj Soredemo.xcodeproj
git mv Soredemo/Soredemo Soredemo.tmp && git rm -r --cached Soredemo 2>/dev/null; rmdir Soredemo 2>/dev/null
git mv Soredemo.tmp Soredemo
mkdir -p Soredemo/App Soredemo/UI Soredemo/Capture Soredemo/Resources
git mv Soredemo/SoredemoApp.swift Soredemo/App/
git mv Soredemo/ContentView.swift Soredemo/UI/
git mv Soredemo/Assets.xcassets Soredemo/Resources/
git mv soredemo-brand-kit assets
```

No `pbxproj` edit is needed — `PBXFileSystemSynchronizedRootGroup` picks up subfolders (F8, verified).

- [ ] **Step 2: Set the deployment target to 26.0**

Value substitution only, in both target-level configurations:

```bash
sed -i '' 's/MACOSX_DEPLOYMENT_TARGET = 26.5;/MACOSX_DEPLOYMENT_TARGET = 26.0;/g' Soredemo.xcodeproj/project.pbxproj
sed -i '' 's/SWIFT_VERSION = 5.0;/SWIFT_VERSION = 6.0;/g' Soredemo.xcodeproj/project.pbxproj
```

Confirm with `-showBuildSettings`, **not grep** — the project-level configs carry a different value and grep collapses them:

```bash
xcodebuild -project Soredemo.xcodeproj -target Soredemo -showBuildSettings 2>/dev/null | grep -E "^ +(MACOSX_DEPLOYMENT_TARGET|SWIFT_VERSION) ="
```
Expected: `26.0` and `6.0`.

- [ ] **Step 3: Write the failing test**

`Tests/GeometryTests/BuildsTests.swift`:

```swift
import Testing
@testable import Geometry

@Test func geometryModuleBuilds() {
    #expect(GeometryModule.name == "Geometry")
}
```

Note the type is `GeometryModule`, not `Geometry` — no type may share its module's name.

- [ ] **Step 4: Run it and watch it fail**

```bash
swift test 2>&1 | tail -5
```
Expected: FAIL — no `Package.swift` yet.

- [ ] **Step 5: Write the manifest**

`Package.swift` at the repository root:

```swift
// swift-tools-version: 6.3
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .strictMemorySafety(),
]

let package = Package(
    name: "SoredemoCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "SoredemoCore",
            targets: ["Geometry", "Timeline", "Graph", "Framing", "Variants", "Project"]
        )
    ],
    targets: [
        .target(name: "Geometry", swiftSettings: strict),
        .target(name: "Timeline", swiftSettings: strict),
        .target(name: "Graph", dependencies: ["Geometry", "Timeline"], swiftSettings: strict),
        .target(name: "Framing", dependencies: ["Graph", "Geometry"], swiftSettings: strict),
        .target(name: "Variants", dependencies: ["Framing", "Timeline"], swiftSettings: strict),
        .target(name: "Project", dependencies: ["Graph", "Geometry", "Timeline"], swiftSettings: strict),

        .testTarget(name: "GeometryTests", dependencies: ["Geometry"], swiftSettings: strict),
        .testTarget(name: "TimelineTests", dependencies: ["Timeline"], swiftSettings: strict),
        .testTarget(name: "GraphTests", dependencies: ["Graph"], swiftSettings: strict),
        .testTarget(name: "FramingTests", dependencies: ["Framing"], swiftSettings: strict),
        .testTarget(name: "VariantsTests", dependencies: ["Variants"], swiftSettings: strict),
        .testTarget(name: "ProjectTests", dependencies: ["Project"], swiftSettings: strict),
    ]
)
```

- [ ] **Step 6: Add one placeholder per module**

`Sources/Geometry/Placeholder.swift`:

```swift
public enum GeometryModule {
    public static let name = "Geometry"
}
```

Repeat for `TimelineModule`, `GraphModule`, `FramingModule`, `VariantsModule`, `ProjectModule`, with a matching one-line test in each test target. These are scaffolding; later tasks delete them as real code lands. `Framing` and `Variants` keep theirs through Phase 1.

- [ ] **Step 7: Run the tests**

```bash
swift test 2>&1 | tail -5
```
Expected: PASS, 6 tests.

- [ ] **Step 8: Prove the dependency edges are real**

The premise D-P1 rests on. Observe it red, then restore:

```bash
echo "import Graph" >> Sources/Geometry/Placeholder.swift
swift build 2>&1 | grep -E "error:" | head -2      # expect a module dependency cycle / no such module
git checkout Sources/Geometry/Placeholder.swift
swift build 2>&1 | tail -1                          # expect Build complete
```

- [ ] **Step 9: Add Metal/ and scripts/**

`Metal/README.md`:

```markdown
# Metal

`.metal` shader sources live here, outside the Swift tree, so the compiler
toolchains stay separate. Populated in Phase 2 by `render-core`.
```

`scripts/Soredemo.entitlements` — mirroring the target's existing sandbox settings:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.files.user-selected.read-only</key><true/>
</dict>
</plist>
```

**Do not wire `CODE_SIGN_ENTITLEMENTS` into the pbxproj** — that is an Xcode step for the project owner. Say so in the report.

- [ ] **Step 10: Build and launch the app**

This is the row's completion criterion, and it is now performable — a `.macOS(.v26)` binary runs on this machine (macOS 26.5.2), verified.

```bash
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -destination 'platform=macOS' build 2>&1 | tail -2
APP="$(xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2}')/Soredemo.app"
otool -l "$APP/Contents/MacOS/Soredemo" | grep -A3 LC_BUILD_VERSION | grep -E "minos|sdk"
open "$APP" && sleep 3
pgrep -x Soredemo >/dev/null && echo "RUNNING" || echo "FAILED TO LAUNCH"
osascript -e 'tell application "Soredemo" to quit' 2>/dev/null
```
Expected: `** BUILD SUCCEEDED **`, `minos 26.0`, `RUNNING`.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "repo-skeleton: package at root, app target, launches empty

Six library targets with compile-enforced dependency edges. App project
moved to the root with sources feature-foldered; no pbxproj edit needed
because the project uses PBXFileSystemSynchronizedRootGroup.

Deployment target 26.0, verified with -showBuildSettings rather than grep.
The app builds to minos 26.0 and launches on this machine."
```

---

### Task 2: architecture-plugin — rule 1, with the full evasion suite

The rule the compiler does **not** enforce (F1). The evasion set is known from the design doc, so it is written now rather than discovered over four rounds.

**Files:** `Sources/architecture-checker/main.swift`; `Plugins/ArchitectureCheck/ArchitectureCheck.swift`; `Tests/GeometryTests/ArchitectureCheckTests.swift`; modify `Package.swift`.

**Interfaces produced:** executable `architecture-checker` taking `--target-name <name> --sources <dir>`, exit 0 clean / 1 on violation, `file:line: error: <message>` on stderr; plugin `ArchitectureCheck` on all six library targets.

- [ ] **Step 1: Write the failing tests — the whole evasion suite at once**

`Tests/GeometryTests/ArchitectureCheckTests.swift`:

```swift
import Testing
import Foundation

/// Runs the real built checker against a temporary fixture directory.
/// Never reimplement the checking logic in-process — that tests the test.
func runChecker(targetName: String = "Geometry", source: String) throws -> (status: Int32, stderr: String) {
    let binDir = URL(filePath: #filePath)               // …/Tests/GeometryTests/ArchitectureCheckTests.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: ".build/debug")
    let checker = binDir.appending(path: "architecture-checker")
    try #require(FileManager.default.fileExists(atPath: checker.path()),
                 "architecture-checker not built at \(checker.path())")

    let dir = URL(filePath: NSTemporaryDirectory())
        .appending(path: "arch-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try source.write(to: dir.appending(path: "Probe.swift"), atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = checker
    process.arguments = ["--target-name", targetName, "--sources", dir.path()]
    let err = Pipe()
    process.standardError = err
    try process.run()
    let data = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

// --- must be REJECTED ---

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

// --- must be ACCEPTED ---

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

@Test func allowsDeclaredSiblingImports() throws {
    let result = try runChecker(targetName: "Graph", source: "import Geometry\nimport Timeline")
    #expect(result.status == 0)
}

@Test func rejectsSiblingNotDeclared() throws {
    // Geometry is a leaf; Graph is not among its allowed imports.
    let result = try runChecker(targetName: "Geometry", source: "import Graph")
    #expect(result.status == 1)
}
```

- [ ] **Step 2: Run and watch every one fail**

```bash
swift test --filter ArchitectureCheckTests 2>&1 | tail -8
```
Expected: FAIL — `architecture-checker not built`. Record this output; it is the observed-red for the whole suite.

- [ ] **Step 3: Write the checker**

`Sources/architecture-checker/main.swift`. The comment/string handling is a single file-scoped pass with a frame stack, because line-local stripping cannot see multi-line strings and interpolation bodies are *code*, not string content:

```swift
import Foundation

/// Permitted imports per target. Must match the dependency edges in Package.swift;
/// changing an edge changes this table.
let allowedImports: [String: Set<String>] = [
    "Geometry": ["Foundation"],
    "Timeline": ["Foundation"],
    "Graph":    ["Foundation", "Geometry", "Timeline"],
    "Framing":  ["Foundation", "Geometry", "Graph", "Timeline"],
    "Variants": ["Foundation", "Geometry", "Graph", "Timeline", "Framing"],
    "Project":  ["Foundation", "Geometry", "Graph", "Timeline"],
]

func value(of flag: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: flag),
          CommandLine.arguments.index(after: i) < CommandLine.arguments.endIndex
    else { return nil }
    return CommandLine.arguments[CommandLine.arguments.index(after: i)]
}

guard let targetName = value(of: "--target-name"), let sources = value(of: "--sources"),
      let allowed = allowedImports[targetName] else {
    FileHandle.standardError.write(Data("error: bad arguments or unknown target\n".utf8))
    exit(2)
}

var failed = false
func report(_ file: String, _ line: Int, _ message: String) {
    FileHandle.standardError.write(Data("\(file):\(line): error: \(message)\n".utf8))
    failed = true
}

/// One pass over the whole file, returning each line with comments and string
/// CONTENT blanked, but interpolation bodies preserved as code.
/// Handles: // and /* */; plain, multiline and raw strings with any pound count;
/// \(…) and \#(…) interpolation nested to any depth.
func codeViewLines(of text: String) -> [String] { /* frame-stack scanner */ }

/// Access levels permitted in front of `import` by SE-0409. Stripping only `@`
/// attributes lets `public import AppKit` — the idiomatic Swift 6 spelling —
/// straight through, since the statement then does not start with `import`.
let importAccessLevels: Set<String> = ["public", "package", "internal", "fileprivate", "private"]

func importedModule(fromStatement statement: String) -> String? {
    var tokens = statement.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    while let first = tokens.first, first.hasPrefix("@") { tokens.removeFirst() }
    while let first = tokens.first, importAccessLevels.contains(first) { tokens.removeFirst() }
    guard tokens.first == "import", tokens.count >= 2 else { return nil }
    // `import class AppKit.NSColor` -> AppKit
    return tokens.last?.split(separator: ".").first.map(String.init)
}

let enumerator = FileManager.default.enumerator(atPath: sources)
while let relative = enumerator?.nextObject() as? String {
    guard relative.hasSuffix(".swift") else { continue }
    let path = sources + "/" + relative
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

    for (index, line) in codeViewLines(of: text).enumerated() {
        // Semicolon-joined statements are checked independently, in any order.
        for statement in line.split(separator: ";").map(String.init) {
            guard let module = importedModule(fromStatement: statement.trimmingCharacters(in: .whitespaces))
            else { continue }
            if !allowed.contains(module) {
                report(path, index + 1,
                       "'\(module)' is not importable from \(targetName). Allowed: \(allowed.sorted().joined(separator: ", ")). See ARCHITECTURE.md D6.")
            }
        }
    }
}

exit(failed ? 1 : 0)
```

`codeViewLines` is the one piece with real substance. Implement it as a character scan over the whole text with a stack of frames — `.string(hashCount:)`, `.interpolation`, `.paren` — so that `#"\#(Date())"#` puts the interpolation body back into code mode, and `"""` state survives newlines. The test suite above pins the behaviour.

- [ ] **Step 4: Write the plugin**

`Plugins/ArchitectureCheck/ArchitectureCheck.swift`:

```swift
import PackagePlugin

@main
struct ArchitectureCheck: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        let stamp = context.pluginWorkDirectory.appending("\(target.name).archcheck")
        // Every Package*.swift is an input: a manifest-only edit must re-run the checker,
        // or rule 4 never fires on an incremental build.
        let manifests = (try? FileManager.default.contentsOfDirectory(atPath: context.package.directory.string))?
            .filter { $0.hasPrefix("Package") && $0.hasSuffix(".swift") }
            .map { context.package.directory.appending($0) } ?? []
        return [
            .buildCommand(
                displayName: "ArchitectureCheck: \(target.name)",
                executable: try context.tool(named: "architecture-checker").path,   // .path, NOT .url
                arguments: ["--target-name", target.name,
                            "--sources", target.directory.string,
                            "--touch", stamp.string],
                inputFiles: target.sourceFiles.map(\.path) + manifests,
                outputFiles: [stamp]
            )
        ]
    }
}
```

`.prebuildCommand` cannot be used — SwiftPM prebuild commands cannot depend on an executable built from source. `.path` rather than `.url` because `URL.path()` percent-encodes Xcode's `${BUILD_DIR}`.

- [ ] **Step 5: Wire into Package.swift**

Add to `targets:`, and `plugins: ["ArchitectureCheck"]` to all six library targets (not to the checker itself — its own source legitimately contains the banned strings):

```swift
        .executableTarget(name: "architecture-checker", swiftSettings: strict),
        .plugin(name: "ArchitectureCheck", capability: .buildTool(),
                dependencies: ["architecture-checker"]),
```

- [ ] **Step 6: Run the suite**

```bash
swift test --filter ArchitectureCheckTests 2>&1 | tail -6
```
Expected: PASS. 11 rejection cases + 5 acceptance cases + 2 sibling cases.

- [ ] **Step 7: Observe rule 1 red under `swift build`**

```bash
cp Sources/Geometry/Placeholder.swift /tmp/ph.bak
echo "import AppKit" >> Sources/Geometry/Placeholder.swift
swift build 2>&1 | tail -3; echo "exit=${PIPESTATUS[0]}"    # expect NON-ZERO and a diagnostic
cp /tmp/ph.bak Sources/Geometry/Placeholder.swift
swift build 2>&1 | tail -1                                   # expect Build complete
```

Also observe one access-level form directly, since that class was the total bypass:

```bash
echo "public import AppKit" >> Sources/Geometry/Placeholder.swift
swift build 2>&1 | tail -3; echo "exit=${PIPESTATUS[0]}"    # expect NON-ZERO
cp /tmp/ph.bak Sources/Geometry/Placeholder.swift
```

**`xcodebuild` is deliberately NOT checked here.** The app does not yet reference the package, so
Xcode never compiles it and the result would be a meaningless zero. `KICKOFF.md` says "fails the
build" without saying which; that ambiguity is answered in **Task 2.5**, which exists for exactly
this and runs next.

- [ ] **Step 8: Correct the two wrong documents**

`ARCHITECTURE.md` D6 mechanism 1 and `AGENTS.md` architecture rule 1 both claim the compiler enforces the import rule. Replace with: the compiler enforces edges *between package targets* (F2), but places no restriction on system frameworks (F1), so `Plugins/ArchitectureCheck` enforces the Foundation-only rule.

- [ ] **Step 9: Commit**

---

### Task 2.5: does the plugin run under Xcode at all?

**This is the plan's largest unknown, and it is answered here rather than at Task 18.** If
`ENABLE_USER_SCRIPT_SANDBOXING = YES` suppresses SwiftPM build-tool plugins under Xcode, then every
rule built in Tasks 2–5 is inert in the app build — and the cost of learning that at Task 18 is
sixteen tasks of plugin work that does not enforce anything where it matters most.

Rule 1 exists as of Task 2, which is all this needs. `Package.swift` exists as of Task 1, so this is
the earliest point the question can be asked.

**Prerequisite — the project owner must do this in Xcode.** Hand-editing the pbxproj does not work
(F8), verified twice at two object versions:

> **File → Add Package Dependencies… → Add Local…** → select the repository root (it contains
> `Package.swift`) → add the **SoredemoCore** product to the **Soredemo** target.

- [ ] **Step 1: Confirm Xcode compiles package targets**

```bash
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -destination 'platform=macOS' build > /tmp/xb0.log 2>&1
echo "exit=$?"
grep -cE "SwiftDriver.* (Geometry|Timeline|Graph) |Compiling.*(Geometry|Timeline|Graph)" /tmp/xb0.log
```
Zero means the package reference is missing → **report NEEDS_CONTEXT and stop.**

- [ ] **Step 2: Make the app actually use the package**

A linked-but-unused package can still be skipped. Give it a real reference in `Soredemo/UI/ContentView.swift`:

```swift
import SwiftUI
import Geometry

struct ContentView: View {
    var body: some View {
        Text(GeometryModule.name).padding()
    }
}
```

- [ ] **Step 3: Observe rule 1 RED under xcodebuild**

```bash
cp Sources/Geometry/Placeholder.swift /tmp/ph.bak
echo "import AppKit" >> Sources/Geometry/Placeholder.swift
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -destination 'platform=macOS' build > /tmp/xb1.log 2>&1
echo "exit=$?"                                   # expect NON-ZERO
grep -c "ArchitectureCheck" /tmp/xb1.log         # expect non-zero
cp /tmp/ph.bak Sources/Geometry/Placeholder.swift
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -destination 'platform=macOS' build 2>&1 | tail -1
```

Interpret using the three-outcome table in Task 18 Step 2.

- [ ] **Step 4: If the plugin does NOT run, establish why before continuing**

Try, in order, recording each result:

1. Set `ENABLE_USER_SCRIPT_SANDBOXING = NO` (a value substitution, permitted) and re-run Step 3. If the plugin then fires, the sandbox is the cause — report it as a decision for the owner, since disabling it weakens the app's build hygiene.
2. Check whether Xcode requires plugin validation/trust for this project.

**If neither explains it, report BLOCKED.** Do not continue to Tasks 3–5 building rules that are provably inert under the build system the app ships from. Better to stop at task three than at task eighteen.

- [ ] **Step 5: Commit, recording the answer**

The commit message states plainly whether the plugin enforces under Xcode, under `swift build`, or both. This is the fact the rest of the phase rests on.

---

### Task 3: architecture-plugin — rules 2 and 4

Both read source text, so both get evasion lists.

**Files:** modify `Sources/architecture-checker/main.swift`, `Tests/GeometryTests/ArchitectureCheckTests.swift`.

- [ ] **Step 1: Write the failing tests**

```swift
// Rule 2 — CG types anywhere in the package
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

// Rule 4 — manifests
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
```

Add a `runManifestChecker(files:)` helper that writes the given manifests into a temp directory and invokes the checker with `--manifests <dir>`.

- [ ] **Step 2: Run and watch them fail**

- [ ] **Step 3: Implement rule 2**

Inside the per-line loop, over the **code view** so comments and string content do not fire:

```swift
        for banned in ["CGRect", "CGPoint", "CGSize", "CGFloat"] where line.contains(banned) {
            report(path, index + 1,
                   "'\(banned)' may not appear in the package. Convert at the boundary; see ARCHITECTURE.md D3.")
        }
```

- [ ] **Step 4: Implement rule 4**

Scan **every** `Package*.swift` in the package root for `.package(`, over the code view. `Package.Dependency` has no public initialiser, so the token is unforgeable — but the file set is what was previously wrong:

```swift
if let manifestDir = value(of: "--manifests") {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: manifestDir)) ?? []
    for name in names where name.hasPrefix("Package") && name.hasSuffix(".swift") {
        let path = manifestDir + "/" + name
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        for (index, line) in codeViewLines(of: text).enumerated() where line.contains(".package(") {
            report(path, index + 1, "the package must declare no package dependencies.")
        }
    }
}
```

Pass `--manifests` from the plugin alongside `--sources`.

- [ ] **Step 5: Run the tests, then observe both rules red in a real build**

```bash
swift test --filter ArchitectureCheckTests 2>&1 | tail -5
# rule 2
echo 'let probe: CGRect = .zero' >> Sources/Geometry/Placeholder.swift
swift build 2>&1 | grep -c "may not appear"          # expect >= 1
git checkout Sources/Geometry/Placeholder.swift
# rule 4, in the version-specific manifest specifically
cp Package.swift Package@swift-6.4.swift
python3 - <<'PY'
p="Package@swift-6.4.swift"; s=open(p).read()
s=s.replace("    targets: [\n", "    dependencies: [.package(path: \"/tmp/LocalDep\")],\n    targets: [\n",1)
open(p,"w").write(s)
PY
swift build 2>&1 | grep -c "no package dependencies"  # expect >= 1
rm Package@swift-6.4.swift
swift build 2>&1 | tail -1
```

- [ ] **Step 6: Commit**

---

### Task 4: architecture-plugin — rule 3 mechanism spike

**Read the design doc's "Rule 3's mechanism is unresolved" section before starting.** A build-tool plugin's command runs before its target compiles, so the object files do not exist when it runs. This task establishes the mechanism; it does not assume one.

**Files:** whatever the chosen mechanism needs, plus `Tests/GeometryTests/DeterminismRuleTests.swift`.

- [ ] **Step 1: Establish the ground truth**

Confirm the symbols are what the design says (F7). Build a scratch module calling `Date()`, `UUID()`, `Int.random(in:)` and read its object file:

```bash
nm -u <object>.o | grep -E "Foundation4DateVACycfC|Foundation4UUIDVACycfC|FixedWidthIntegerPsE6random"
```
Expected: `_$s10Foundation4DateVACycfC`, `_$s10Foundation4UUIDVACycfC`, `_$ss17FixedWidthIntegerPsE6random2inxSnyxG_tFZ`.

- [ ] **Step 2: Choose the mechanism, with evidence**

Evaluate in this order and record why each is accepted or rejected:

1. **A test that READS already-built object files** — preferred, and safe. It needs nobody to
   remember to invoke it, and it does **not** need to build anything: `GeometryTests` depends on
   `Geometry`, so by the time the test body runs, `Geometry`'s object files necessarily exist. No
   nested `swift build`, therefore no `.build` lock and no deadlock. Locate them under
   `.build/*/debug/` and read with `nm -u`.
2. A separate check target depending on the six libraries, so its command runs after they compile.
3. A post-build script phase in `Soredemo.xcodeproj` — only fires under `xcodebuild`, which is half
   the enforcement, and needs a pbxproj edit (forbidden by the global constraints).

If none works cleanly, **report BLOCKED**. A documented gap is worth more than a symbol check nobody
can prove runs.

**The empty-glob guard is mandatory.** If the object-file search returns nothing, the symbol check
passes vacuously — a rule that silently enforces nothing, which is the exact failure this plan's
verification rule exists to prevent, arriving on the rule where it would be least visible. Task 5
already carries the equivalent clause for app sources; this one is the same shape:

```swift
try #require(!objectFiles.isEmpty,
             "no object files found under \(searchRoot.path()) — the symbol check would pass vacuously")
try #require(!undefinedSymbols.isEmpty,
             "nm returned no undefined symbols — the check is not reading what it thinks it is")
```

Both are required. An empty file list and a file list that yields no symbols fail for different
reasons and would both look like success.

- [ ] **Step 3: Write the failing test**

```swift
@Test func rejectsAmbientDate() throws { … }        // Date() in a package source
@Test func rejectsInterpolatedDate() throws { … }   // "\(Date())" — the text-scan predecessor passed this
@Test func rejectsRawInterpolatedUUID() throws { … } // #"\#(UUID())"#
@Test func rejectsAmbientRandom() throws { … }
@Test func allowsInjectedValues() throws { … }      // `let at: Date` and `let id: UUID` are legal types
```

The last one is load-bearing: timestamps are *injected*, so the **types** `Date` and `UUID` must remain usable. Only the constructors are banned.

- [ ] **Step 4: Run, watch fail, implement, run**

- [ ] **Step 5: Observe it red in a real build, including the two forms text scanning missed**

```bash
printf 'import Foundation\npublic enum P { public static let d = Date() }\n' >> Sources/Geometry/Placeholder.swift
# expect rejection
git checkout Sources/Geometry/Placeholder.swift
printf 'import Foundation\npublic enum P { public static let s = "\\(Date())" }\n' >> Sources/Geometry/Placeholder.swift
# expect rejection — this is the case the previous text-based implementation passed
git checkout Sources/Geometry/Placeholder.swift
```

- [ ] **Step 6: Commit**

---

### Task 5: rule 5 — the CG bridge allow-list

The plugin attaches to SwiftPM targets and cannot see the Xcode app target, so this is a package test rather than a plugin rule.

**Files:** `Tests/GeometryTests/AppSourceCGTests.swift`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation

@Test func cgTypesAppearOnlyInTheBridge() throws {
    let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let appSources = root.appending(path: "Soredemo")

    // A missing or empty app source tree is a FAILURE, not a vacuous pass.
    var files: [URL] = []
    let e = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil)
    while let url = e?.nextObject() as? URL where url.pathExtension == "swift" { files.append(url) }
    try #require(!files.isEmpty, "no app sources found at \(appSources.path())")

    let bridge = "CGGeometryBridge.swift"
    for file in files where file.lastPathComponent != bridge {
        let text = try String(contentsOf: file, encoding: .utf8)
        for (i, line) in codeOnlyLines(of: text).enumerated() {
            for banned in ["CGRect", "CGPoint", "CGSize", "CGFloat"] {
                #expect(!line.contains(banned),
                        "\(file.lastPathComponent):\(i + 1) names \(banned); only \(bridge) may.")
            }
        }
    }
}
```

- [ ] **Step 2: Observe it red**

The bridge does not exist yet (Task 18 creates it), so today the test must pass by finding no violations — and must fail when one appears:

```bash
echo 'let probe = CGRect.zero' >> Soredemo/UI/ContentView.swift
swift test --filter AppSourceCGTests 2>&1 | tail -4      # expect FAIL
git checkout Soredemo/UI/ContentView.swift
swift test --filter AppSourceCGTests 2>&1 | tail -3      # expect PASS
```

Both outputs go in the report. A test that has only ever passed is not a known test.

- [ ] **Step 3: Commit**

---

### Task 6: geometry — canonical encoding and the stable digest

**Files:** `Sources/Geometry/{FNV1a,CanonicalEncoding,GeometryRevision,DisplayGeometry}.swift`; `Tests/GeometryTests/DigestTests.swift`; delete `Sources/Geometry/Placeholder.swift` and its test.

**Interfaces produced:** `GeometryRevision(id:)`; `DisplayGeometry(displayUUID:pixelWidth:pixelHeight:scale:)` with `.revision`; internal `fnv1a64(_:)`; `CanonicalEncoding.version`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Geometry

private let displayA = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
private let displayB = UUID(uuidString: "6BA7B811-9DAD-11D1-80B4-00C04FD430C8")!

@Test func fnv1aMatchesKnownVectors() {
    #expect(fnv1a64([]) == 0xcbf2_9ce4_8422_2325)
    #expect(fnv1a64(Array("a".utf8)) == 0xaf63_dc4c_8601_ec8c)
    #expect(fnv1a64(Array("foobar".utf8)) == 0x8594_4171_f739_67e8)
}

@Test func identicalGeometryYieldsIdenticalRevision() {
    let a = DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2)
    let b = DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2)
    #expect(a.revision == b.revision)
}

@Test func differentDisplaysDoNotCollide() {
    #expect(DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2).revision
         != DisplayGeometry(displayUUID: displayB, pixelWidth: 3840, pixelHeight: 2160, scale: 2).revision)
}

@Test func scaleParticipates() {
    #expect(DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2).revision
         != DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 1).revision)
}

@Test func canonicalBytesCarryAVersionPrefix() {
    let g = DisplayGeometry(displayUUID: displayA, pixelWidth: 100, pixelHeight: 100, scale: 1)
    #expect(g.canonicalBytes.first == CanonicalEncoding.version)
}

@Test func revisionIsPinned() {
    // Guards the Hasher trap AND any future change to the canonical encoding.
    // Fill in from the first green run, then treat as frozen.
    let g = DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2)
    #expect(g.revision.id == 0x0000_0000_0000_0000)   // ← replace with observed value
}
```

- [ ] **Step 2: Run and watch it fail**

- [ ] **Step 3: Implement**

`Sources/Geometry/CanonicalEncoding.swift`:

```swift
/// Rules for any bytes that get digested. See the design doc § Canonical encoding.
public enum CanonicalEncoding {
    /// Leading byte of every canonical encoding. Bump ONLY as an explicit breaking
    /// change with a re-approval path. Deliberately NOT ProjectSnapshot.schemaVersion:
    /// a document schema upgrade must leave existing approvals verifiable.
    public static let version: UInt8 = 1
}

extension UInt64 {
    var littleEndianBytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: (self >> (8 * UInt64($0))) & 0xff) }
    }
}
```

`Sources/Geometry/FNV1a.swift`:

```swift
/// FNV-1a, 64-bit. Deterministic across processes, unlike Swift's seeded Hasher.
/// Identity only — never use this on the evidence path, which needs a cryptographic digest.
func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
}
```

`Sources/Geometry/DisplayGeometry.swift` — note `displayUUID`, not `CGDirectDisplayID` (D-P2), and `scale` digested as `.bitPattern`:

```swift
import Foundation

public struct DisplayGeometry: Hashable, Codable, Sendable {
    public let displayUUID: UUID
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scale: Double

    public init(displayUUID: UUID, pixelWidth: Int, pixelHeight: Int, scale: Double) {
        precondition(pixelWidth > 0 && pixelHeight > 0, "display must have positive dimensions")
        precondition(scale.isFinite && scale > 0, "scale must be finite and positive, got \(scale)")
        self.displayUUID = displayUUID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
    }

    var canonicalBytes: [UInt8] {
        var bytes: [UInt8] = [CanonicalEncoding.version]
        let u = displayUUID.uuid
        bytes.append(contentsOf: [u.0,u.1,u.2,u.3,u.4,u.5,u.6,u.7,u.8,u.9,u.10,u.11,u.12,u.13,u.14,u.15])
        bytes.append(contentsOf: UInt64(bitPattern: Int64(pixelWidth)).littleEndianBytes)
        bytes.append(contentsOf: UInt64(bitPattern: Int64(pixelHeight)).littleEndianBytes)
        bytes.append(contentsOf: scale.bitPattern.littleEndianBytes)   // exact; decimal is not
        return bytes
    }

    public var revision: GeometryRevision { GeometryRevision(id: fnv1a64(canonicalBytes)) }
}
```

The UUID tuple is expanded explicitly rather than via `withUnsafeBytes`, because `.strictMemorySafety()` is enabled.

- [ ] **Step 4: Run, pin the literal, remove the placeholder, commit**

---

### Task 7: geometry — the registry

**Files:** `Sources/Geometry/GeometryRegistry.swift`; `Tests/GeometryTests/RegistryTests.swift`.

- [ ] **Step 1: Write the failing tests**

The two failure modes are different in kind and must be tested separately (D-P2):

```swift
@Test func insertThenLookup() { … }
@Test func reinsertingKeepsTheFirstObservation() { … }
@Test func twoRegistriesAgreeOnOneGeometry() { … }

@Test func decodingRejectsAMismatchedKey() throws {
    // A corrupt or hand-edited file is INPUT. It must throw, not trap:
    // trapping on untrusted input turns a bad file into an unopenable document.
    let json = Data(#"{"entries":[{"revision":{"id":1},"geometry":{"displayUUID":"…","pixelWidth":100,"pixelHeight":100,"scale":1}}]}"#.utf8)
    #expect(throws: GeometryRegistry.DecodingFailure.self) {
        _ = try JSONDecoder().decode(GeometryRegistry.self, from: json)
    }
}

@Test func encodingIsStableAcrossProcesses() throws {
    // Dictionaries encode in per-process-random iteration order (design § Canonical encoding).
    // Two encodes in ONE process prove nothing; this test asserts the sorted array form.
    var r = GeometryRegistry()
    for i in 1...8 { r.insert(sample(width: 100 * i), observedAt: Int64(i)) }
    let encoded = try JSONEncoder().encode(r)
    let text = String(decoding: encoded, as: UTF8.self)
    let ids = /* extract revision ids in document order */
    #expect(ids == ids.sorted(), "entries must be encoded sorted by revision id")
}
```

- [ ] **Step 2: Run and watch fail**

- [ ] **Step 3: Implement with hand-written `Codable`**

```swift
public struct GeometryRegistry: Hashable, Sendable {
    public struct DecodingFailure: Error, Equatable { public let revision: GeometryRevision }

    private var entries: [GeometryRevision: DisplayGeometry]
    private var observed: [GeometryRevision: Int64]

    public init() { entries = [:]; observed = [:] }

    public func geometry(for r: GeometryRevision) -> DisplayGeometry? { entries[r] }
    public func firstObserved(for r: GeometryRevision) -> Int64? { observed[r] }
    public var revisions: Set<GeometryRevision> { Set(entries.keys) }

    /// Merge-time collision is a PROGRAMMER error: two distinct geometries producing one
    /// revision would make them compare equal, which is the silent direction.
    public mutating func insert(_ geometry: DisplayGeometry, observedAt: Int64) {
        let revision = geometry.revision
        if let existing = entries[revision] {
            precondition(existing == geometry,
                "geometry revision collision on \(revision): \(existing) vs \(geometry)")
            return
        }
        entries[revision] = geometry
        observed[revision] = observedAt
    }
}

extension GeometryRegistry: Codable {
    private struct Entry: Codable { let revision: GeometryRevision; let geometry: DisplayGeometry; let firstObserved: Int64 }

    /// Hand-written because synthesised Codable encodes a non-String-keyed Dictionary
    /// as an unkeyed container in per-process-random iteration order.
    public func encode(to encoder: any Encoder) throws {
        let sorted = entries.keys.sorted { $0.id < $1.id }
            .map { Entry(revision: $0, geometry: entries[$0]!, firstObserved: observed[$0] ?? 0) }
        var c = encoder.singleValueContainer()
        try c.encode(sorted)
    }

    public init(from decoder: any Decoder) throws {
        let list = try decoder.singleValueContainer().decode([Entry].self)
        entries = [:]; observed = [:]
        for e in list {
            // Disk input: validate, throw. Do not trap.
            guard e.geometry.revision == e.revision else { throw DecodingFailure(revision: e.revision) }
            entries[e.revision] = e.geometry
            observed[e.revision] = e.firstObserved
        }
    }
}
```

- [ ] **Step 4: Run, commit**

---

### Task 8: geometry — normalized types and the cross-revision trap

`geometry`'s completion criterion.

**Files:** `Sources/Geometry/Normalized.swift`; `Tests/GeometryTests/NormalizedTests.swift`.

- [ ] **Step 1–4: TDD as above.** `NormalizedPoint` (0…1, bottom-left), `NormalizedSize`, `NormalizedFrame` carrying `GeometryRevision`, with `contains`/`intersects` guarded by

```swift
precondition(revision == other.revision,
    "geometry revision mismatch: \(revision) vs \(other.revision). Frames normalized \
against different display configurations are not comparable.")
```

- [ ] **Step 5: Observe the trap**

A precondition kills the process, so it is verified out-of-process, not with `#expect`:

```bash
swift build
cat > /tmp/traptest.swift <<'SWIFT'
import Geometry
let a = NormalizedFrame(origin: .init(x: 0, y: 0), size: .init(width: 1, height: 1), revision: .init(id: 1))
let b = NormalizedFrame(origin: .init(x: 0, y: 0), size: .init(width: 1, height: 1), revision: .init(id: 2))
_ = a.contains(b)
print("NO TRAP — FAILURE")
SWIFT
swiftc -I .build/debug -L .build/debug -lGeometry /tmp/traptest.swift -o /tmp/traptest
/tmp/traptest; echo "exit=$?"
```
Expected: crash naming the mismatch, non-zero exit. `exit=0` with `NO TRAP` printed means the row is not done.

- [ ] **Step 6: Correct `ARCHITECTURE.md` D3** — bottom-left holds for the render path, but `CGDisplayBounds`, `CGEventGetLocation` and AX are top-left, so exactly one flip is required at capture entry.

- [ ] **Step 7: Commit**

---

### Task 9: geometry — NormalizationContext, the single Y-flip

**Files:** `Sources/Geometry/{PixelRect,NormalizationContext}.swift`; `Tests/GeometryTests/ConversionTests.swift`.

Takes **display-local** top-left pixels, never global — routing happens first (Task 10). Tests pin: a rect at input top-left lands at high normalized y; `denormalize` round-trips; the frame carries the display's revision.

- [ ] Steps 1–5: TDD, then commit.

---

### Task 10: geometry — DisplayArrangement

**Files:** `Sources/Geometry/DisplayArrangement.swift`; `Tests/GeometryTests/ArrangementTests.swift`.

Extrinsic placement, **not digested**. The regression test that matters:

```swift
@Test func rearrangingDisplaysChangesNoRevision() {
    let before = arrangement(sideOriginX: 1000).placements.map(\.geometry.revision)
    let after  = arrangement(sideOriginX: -800).placements.map(\.geometry.revision)
    #expect(before == after)
}

@Test func clickOnSecondaryNormalizesAgainstSecondary() throws {
    let hit = try #require(arrangement().route(globalTopLeftX: 1400, globalTopLeftY: 300))
    let p = NormalizationContext(geometry: hit.geometry).normalize(topLeftX: hit.localX, topLeftY: hit.localY)
    #expect(p.x == 0.5)   // 400/800, not 1400/1000
}
```

- [ ] Steps 1–4: TDD, then commit.

---

### Task 11: timeline

**Files:** `Sources/Timeline/{Nanoseconds,TimeRange}.swift`; `Tests/TimelineTests/TimeRangeTests.swift`; delete the placeholder.

Integer nanoseconds, half-open ranges (touching is not overlapping). No type named `Timeline`.

- [ ] Steps 1–4: TDD, then commit.

---

### Task 12: graph — ContentDigest and non-empty Evidence

**Files:** `Sources/Graph/{ContentDigest,EvidenceRef,Evidence}.swift`; `Tests/GraphTests/EvidenceTests.swift`; delete the placeholder.

Key points, all from D-P4: `ContentDigest` is 32 opaque bytes, validated on decode, **compared but never computed** in the package. `Evidence` stores `head`/`tail` — **not `first`**, which shadows `Collection.first` and resolves differently through a generic context — encodes as a flat array, rejects an empty one on decode, and has an array initialiser because Swift cannot splat into a variadic.

- [ ] Steps 1–5: TDD, then commit.

---

### Task 13: graph — Derived, Origin, approvalBytes

**Files:** `Sources/Graph/{Derivation,Derived}.swift`; `Tests/GraphTests/DerivedTests.swift`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func approvalBytesIgnoreReviewState() throws {
    var d = try generated(42)
    let before = d.approvalBytes
    d.review = .approved
    #expect(d.approvalBytes == before)
}

@Test func approvalBytesChangeWithValueAndOrigin() throws { … }

@Test func approvalBytesCarryAVersionPrefix() throws {
    #expect(try generated(42).approvalBytes.first == CanonicalEncoding.version)
}

@Test func approvalBytesAreStableAcrossProcesses() throws {
    // Written to a file and compared by a second process invocation — one process
    // shares a hash seed, so an in-process repeat proves nothing.
}
```

- [ ] **Step 2–3: Implement**

`approvalBytes` covers `value` + `origin`, **never `review`** — approving mutates `review`, and a digest over it would invalidate the approval it just recorded. It emits canonical bytes with the version prefix; the app hashes them.

- [ ] **Step 4–5: Run, commit**

---

### Task 14: graph — the producer-value rule

`derivation-graph`'s completion criterion.

**Files:** `Sources/Graph/ReferenceProducer.swift`; `Tests/GraphTests/ProducerValueTests.swift`.

The mandatory test form — supply a value the producer **could not have derived**:

```swift
@Test func authoredValueSurvivesTheProducer() throws {
    let authored = Derived(value: 99, origin: .authored(Authorship(note: "operator override")), review: .approved)
    let produced = ReferenceProducer.produce(from: try evidence(count: 3))
    let result = authored.applyingProduced(produced)
    #expect(result.value == 99)         // producer counts evidence; it can never yield 99
    guard case .authored = result.origin else { Issue.record("origin replaced"); return }
    #expect(result.review == .approved)
}

@Test func rerunningTheProducerDoesNotEraseAnOverride() throws { … }
```

- [ ] Steps 1–5: TDD, then commit.

---

### Task 15: graph — reverse index with cache pairing

**Files:** `Sources/Graph/ReverseIndex.swift`; `Tests/GraphTests/ReverseIndexTests.swift`.

Every cache-hit test paired with an invalidation test: `cacheHitAfterRebuild`, `invalidationClearsTheCache`, `rebuildAfterInvalidationReflectsNewEdges`. `dependents(of:)` returns empty when not current — a stale answer would silently under-invalidate.

- [ ] Steps 1–5: TDD, then commit.

---

### Task 16: project — snapshot, schema probe, upgrade chain

**Files:** `Sources/Project/{ProjectSnapshot,SchemaProbe,ProjectUpgrade}.swift`; `Tests/ProjectTests/UpgradeTests.swift`; delete the placeholder.

`project-format`'s first completion criterion: a v1 document round-trips and a synthetic v0 upgrades. A future version **throws** rather than partial-decoding — a partial decode followed by a save destroys fields a newer build wrote.

Note `ProjectSnapshot.schemaVersion` is the **document** version and moves independently of `CanonicalEncoding.version`.

- [ ] Steps 1–6: TDD, then commit.

---

### Task 17: project — package I/O and the truncated-tail rule

**Files:** `Sources/Project/{ProjectPackageIO,JSONLReader}.swift`; `Tests/ProjectTests/PackageIOTests.swift`.

All of this implements **D-P3**. Media is written once and never mutated, so only the manifest needs atomicity (`replaceItemAt`) — the textbook temp-directory-and-rename would copy every gigabyte on every save. Unreferenced sidecars are listed by `unreferencedSidecars(in:snapshot:)` and removed only by an explicit compact — **a save must never delete media**, and there is a test for exactly that. `JSONLReader.lines(from:)` discards a truncated final line and reports the dropped byte count, because silence would turn a crash into a quietly shortened observation log.

Document the durability decision in a comment: atomic is not durable; `F_FULLFSYNC` is the difference, and D-P3 chooses atomicity deliberately rather than by omission.

The package layout is the one D-P3 fixes:

```
MyDemo.soredemo/          UTType(exportedAs:conformingTo: .package)
├─ project.json           atomically replaced on save
├─ media/…                write-once, never mutated
└─ observations/…jsonl    append-only
```

- [ ] Steps 1–6: TDD, then commit.

---

### Task 18: app — NSDocument coordinator, and the package reference

**Files:** `Soredemo/Support/Minting.swift`, `Soredemo/Capture/CGGeometryBridge.swift`, `Soredemo/UI/ProjectDocument.swift`, `Soredemo/App/SoredemoApp.swift`.

**This task has a prerequisite only the project owner can perform.** In Xcode: **File → Add Package Dependencies… → Add Local…** → select the repository root (which contains `Package.swift`), and add the `SoredemoCore` product to the `Soredemo` target. Hand-editing the pbxproj does not work (F8) — verified twice, at two object versions.

- [ ] **Step 1: Confirm the package is actually BUILT, not merely mentioned**

A `grep` for `SoredemoCore` in the pbxproj proves only that the string is present — and failed hand-editing attempts have left exactly that residue before. Ask the build system what it built — **from empty derived data, or the check inverts**:

```bash
rm -rf /tmp/soredemo-dd
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -destination 'platform=macOS' \
  -derivedDataPath /tmp/soredemo-dd build 2>&1 \
  | grep -cE "Compiling .*(Geometry|Timeline|Graph|Project)|SwiftDriver.* (Geometry|Timeline|Graph|Project) "
```
Expected: non-zero, meaning Xcode compiled package targets.

**Without `-derivedDataPath` on a fresh path this check reads zero on a correctly configured project.** Measured: with warm derived data, `xcodebuild` emitted no compile lines for any package target because they were already up to date, while the same project on empty derived data emitted 45 and produced `Geometry/Timeline/Graph/Project/Framing/Variants.swiftmodule`. An up-to-date target does not announce itself. This is the same warm-versus-clean axis as F2a, arriving at a different tool — and here the failure direction is worse, because a zero says "stop, the prerequisite is missing" about a prerequisite that is present.

If zero *from empty derived data*, **stop and report NEEDS_CONTEXT** — the local package reference has not been added, and everything below depends on it. Do not proceed on a build that silently never compiles the package.

**Compiled is not linked — and `nm` on "the app binary" does not measure it.** Two things about this, both found by measuring rather than reasoning, after this paragraph first stated the opposite.

`Soredemo.app/Contents/MacOS/Soredemo` is a **59 KB launcher stub** with 120 symbols in a Debug build; all app code lives in `Soredemo.debug.dylib`. `nm` on the stub reports **zero** `Geometry` symbols before Task 18 and **zero** after — a check that returns the same answer whether or not the work was done.

On the dylib, the count barely moves: **1191 → 1197**. SwiftPM's static product is force-loaded whole, so the package's symbols were already present when nothing imported it at all. "Zero before" was never true of the app; it was true of the file being measured.

What discriminates is the app's **own** new types:

| Symbols naming | before | after |
| --- | --- | --- |
| `Minting` | 0 | 9 |
| `CGGeometryBridge` | 0 | 10 |
| `ProjectDocument` | 0 | 117 |

Measure those, on `Soredemo.debug.dylib`, found with `find "$DD" -name "Soredemo.debug.dylib"`.

- [ ] **Step 2: Re-verify rule 1 under `xcodebuild` — for the first time meaningfully**

Until the package is compiled by Xcode, `** BUILD SUCCEEDED **` said nothing about the plugin. Now it can.

**Do not grep for the checker's prose.** That message is defined in Task 2 and may have been reworded; grepping it risks a false negative on the single most important check in this plan. Use the build's own outcome instead:

```bash
cp Sources/Geometry/FNV1a.swift /tmp/fnv.bak
echo "import AppKit" >> Sources/Geometry/FNV1a.swift
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -destination 'platform=macOS' build > /tmp/xb.log 2>&1
echo "exit=$?"                                  # expect NON-ZERO
grep -c "ArchitectureCheck" /tmp/xb.log         # expect non-zero: the command ran
grep -E "FNV1a.swift:[0-9]+: error:" /tmp/xb.log | head -2
cp /tmp/fnv.bak Sources/Geometry/FNV1a.swift
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -destination 'platform=macOS' build 2>&1 | tail -1
```

Expected: non-zero exit, `ArchitectureCheck` present in the log, an `error:` anchored to the offending file, then a clean build after the revert.

**Three outcomes, three different conclusions — distinguish them:**

| Observation | Means |
| --- | --- |
| non-zero exit, `ArchitectureCheck` in log | the plugin runs under Xcode and enforces. Done |
| zero exit, `ArchitectureCheck` **absent** from log | the plugin command never ran — most likely `ENABLE_USER_SCRIPT_SANDBOXING = YES` suppressing it |
| zero exit, `ArchitectureCheck` **present** in log | the command ran and did not fail — a checker bug, not a wiring problem |

Report which one you observed. Do not work around it.

- [ ] **Step 2.5: Close the untested half of `ContentDigest`**

The package produces canonical bytes; the **app** hashes them. Task 13 proved the bytes are stable
across processes, but every test target is package-side, so the hashing half — the half
`approval-gate` binds on — has never been exercised.

Pin a vector across the boundary, no app test target required:
- package side: a test pinning *known canonical bytes → known SHA-256 digest*, comparing only
- here: `Minting.digest(of:)` over those same bytes, asserted to produce that digest

Record both values in the report. Drift in CryptoKit, in the encoding, or in the bridge then turns
a test red rather than silently producing unverifiable approvals.

- [ ] **Step 3: Write `Minting.swift`** — everything the package is forbidden to do: `UUID()`, `Date()`, and `SHA256.hash` via CryptoKit, returning a `ContentDigest`.

- [ ] **Step 4: Write `CGGeometryBridge.swift`** — the only file in the codebase allowed to name `CGRect`. Task 5's test now has a bridge to allow-list.

- [ ] **Step 5: Write the NSDocument coordinator**

Per F4. `read(from url:ofType:)` receives the package **directory** and decodes `project.json` alone; `writeSafely(to:ofType:for:)` is overridden to bypass the whole-package copy. Both overrides are **nonisolated** — marking them `@MainActor` is a compile error — so document state is held in a `Mutex`.

Declare the exported UTType via `INFOPLIST_KEY_*` build settings or a checked-in `Info.plist`; whichever needs a pbxproj change is an Xcode step for the owner.

- [ ] **Step 6: Build, launch, verify the document type registers**

- [ ] **Step 7: Correct `ARCHITECTURE.md` D5 and `ROADMAP.md`** — `NSDocument` coordinator, not `ReadableDocument`/`WritableDocument`; § To verify item 1 resolved (the API handles packages but is macOS 27 only).

- [ ] **Step 8: Commit**

---

### Task 19: close out the phase

- [ ] **Step 1: Run everything — and from nothing, not from a warm `.build`**

```bash
swift test 2>&1 | grep -E "^✔ Test run with"
xcodebuild -project Soredemo.xcodeproj -scheme Soredemo -destination 'platform=macOS' build 2>&1 | tail -2

# The clean build. Not the same check.
rm -rf /tmp/soredemo-clean
swift build --build-tests --scratch-path /tmp/soredemo-clean 2>&1 | tail -3
```

**`--build-tests` is not optional and neither is the scratch path.** Plain `swift build` does not
build test targets, so it cannot see an undeclared import in a test target at all; and a warm
`.build` leaves stale module artifacts that make undeclared imports resolve (F2). Every green light
in Phase 1 up to Task 16 was observed on a warm `.build` — the first clean build of this repository
was run at Task 16, because nothing asked for one before and there is no CI to run one unasked.

It found no defect. That is not the reason to keep it: a verification that has never been performed
covers nothing regardless of what it would have found, and this is the same shape as "which build?"
on a second axis. It did correct F2 — see **F2a** in the design doc: the clean build does not
promote the scanner's warning to an error, the *linker* fails, and the rule does not reach
transitive imports at all.

- [ ] **Step 2: Re-run all five negative cases end to end**, recording each observed failure. This is the phase's real acceptance test: five rules, five reds, five greens.

- [ ] **Step 3: Update `ROADMAP.md`** — mark rows honestly. **Do not mark `geometry` ☑ — see Open items 2.** The row was renamed `geometry-types` and one of its three claims was moved, precisely because marking it complete was the error this phase keeps making. `repo-skeleton` is ☑ only if the app launched.

- [ ] **Step 4: Update `docs/TOOLCHAIN.md`** — § 2 (macOS 27 beta volume) is no longer required at a 26.0 floor; keep the section, mark it not required, and say why it is kept. Xcode 27 beta stays; it is the SDK.

- [ ] **Step 5: Commit**

---

## Verification summary

| Row | Verified by |
| --- | --- |
| `repo-skeleton` | `xcodebuild` succeeds, `otool -l` shows `minos 26.0`, **and the app launches** |
| `architecture-plugin` | five rules, each observed failing on its own negative case; rule 1 under **both** `swift build` and `xcodebuild` |
| `geometry-types` | cross-revision `contains` traps out-of-process; registry throws on a corrupt file and traps on a merge collision. **Renamed** — see Open items 2 |
| `derivation-graph` | authored 99 survives repeated production; cache hit paired with invalidation; `approvalBytes` stable across processes |
| `project-format` | v1 round-trips, synthetic v0 upgrades, a save never deletes media |

---

## Open items

Two things carried past this session. Both were derived from the project's own rules rather than
found by a test, and both are the same failure shape recorded throughout this phase: **a green check
read as evidence for a claim it does not cover.**

### 1 · `ContentDigest`'s production half is untested — Task 18

The chain is: the **package** produces canonical bytes → the **app** computes SHA-256 in
`Minting.swift` → the digest is stored → it is verified later.

Task 13 proved the bytes are byte-identical across five separate processes. But every test target
is package-side, so **digest comparison is tested and digest production is not** — and Phase 8's
`approval-gate` binds on production. Thirty-nine tests touch the half that is not load-bearing.

Close it without an app test target, crossing the boundary with a pinned vector:

- **Package side:** a test pinning *known canonical bytes → known SHA-256 digest*. It **compares
  only and never computes**, so D6 is untouched.
- **App side, in Task 18's verification:** `Minting.digest(of:)` over those same bytes, asserted to
  produce that same digest.

Same shape as the `fnv1a64` known-answer vectors, across the package/app boundary. Drift in
CryptoKit, in the canonical encoding, or in the bridge between them then turns a test red instead
of silently producing approvals nobody can verify.

Already added as Task 18 Step 2.5; restated here so it is not lost in a step list.

### 2 · Do not mark `geometry` ☑ — Task 19

The `ROADMAP.md` row claimed three things: the normalized types, **all conversion in one place**,
and the cross-revision precondition. The first and third are observable. The second is not —
`NormalizationContext` appears in non-test code only inside comments, and its caller count is
**zero**.

The completion rule is explicit:

> A pure function with no caller does not satisfy a row that claims a product behaviour. If the
> caller belongs to a different row, rename the row to what it actually delivers.

**This was already got wrong once**, in commit `6d3e1af`: the row was marked ☑ on the strength of
the cross-revision trap being verified out-of-process — one claim of three, with a green check read
as a completed row.

Applied remedy: the row is renamed **`geometry-types`**, and *all conversion in one place* moved to
`input-observation` and `ax-observation`, whose code will be the first to convert. The alternative —
leaving it ◐ until Phase 2's capture entry — is equally honest and was not chosen only because the
types themselves genuinely are finished.

Task 19 must not silently reinstate the original wording.
