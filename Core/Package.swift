// swift-tools-version: 6.3
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .strictMemorySafety(),
]

let archCheck: [Target.PluginUsage] = ["ArchitectureCheck"]
let headlessCheck: [Target.PluginUsage] = ["HeadlessCheck"]

let package = Package(
    name: "SoredemoCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "SoredemoCore", type: .static,
            targets: ["Geometry", "Timeline", "Graph", "Framing", "Variants", "Project", "Render",
                      "Captions"]
        ),

        // NOT added to `SoredemoCore`'s targets array, and not named `SoredemoCore`:
        // that product is Foundation-only by definition in five documents, and this
        // target's whole purpose is the platform frameworks that definition excludes.
        .library(name: "SoredemoHeadless", type: .static, targets: ["Capture", "Compositing"]),
    ],
    targets: [
        // `plugins: [archCheck]` on the six library targets — and deliberately NOT
        // on architecture-checker itself, whose own source legitimately contains
        // the banned module names.
        .target(name: "Geometry", swiftSettings: strict, plugins: archCheck),
        .target(name: "Timeline", swiftSettings: strict, plugins: archCheck),
        .target(name: "Graph", dependencies: ["Geometry", "Timeline"], swiftSettings: strict, plugins: archCheck),
        // `Project` and `Timeline` since the framing gates landed: the input is an
        // `AXChainRecord` and the staleness gate reads a `HostRange`.
        .target(name: "Framing", dependencies: ["Graph", "Geometry", "Project", "Timeline"],
                swiftSettings: strict, plugins: archCheck),
        .target(name: "Variants", dependencies: ["Framing", "Timeline"], swiftSettings: strict, plugins: archCheck),
        .target(name: "Project", dependencies: ["Graph", "Geometry", "Timeline"], swiftSettings: strict, plugins: archCheck),
        .target(name: "Render", dependencies: ["Geometry", "Timeline", "Project"],
                swiftSettings: strict, plugins: archCheck),

        // Speech into caption lines, and caption lines into a sidecar file. Deterministic and
        // deliberately so: WHERE to break a line and WHEN to show it are pure functions of a
        // transcript, and only PRODUCING the transcript needs a speech model. That half lives
        // in `Compositing`, which already reads a recording's audio. Depends on `Timeline`
        // alone — a caption track is retimed through an edit, and knows nothing else.
        // `Render` since text overlays landed: a `TextItem` carries the style it is drawn
        // with, and that style is a render-tier value. Deterministic → deterministic, and
        // `Render` does not and may not depend back.
        .target(name: "Captions", dependencies: ["Timeline", "Render"], swiftSettings: strict,
                plugins: archCheck),

        // **The tier `swift test` can run but a person still has to believe.**
        // Deterministic modules above; a running app below. This one may use the GPU,
        // real pixel buffers and wall time — what it may NOT do is need a window or an
        // app lifecycle, which is what the name states and what `HeadlessCheck`
        // enforces by banning AppKit and SwiftUI.
        //
        // `plugins: headlessCheck`, NOT `archCheck`: rule 1 would ban AVFoundation and
        // rule 2 would ban the CGRect this target exists to convert. Two guards with two
        // rules, not one guard with a hole.
        //
        // **`.enableUpcomingFeature("NonisolatedNonsendingByDefault")`, added in Phase 3A-1
        // Task 4, code review fix round 1 — measured, not guessed.** Moving
        // `CompositionBuilder.composition(for:...)` into this target made
        // `xcodebuild -project Soredemo.xcodeproj` fail at `MP4Exporter.swift`'s call site with
        // `sending 'asset' risks causing data races [#RegionIsolation::SendingRisksDataRace]` —
        // `swift build`/`swift test` never saw it, because neither compiles `MP4Exporter.swift`
        // at all. Both `MP4Exporter.export` and `composition` are `nonisolated async` and were
        // already both `nonisolated async` before the move; what changed is that the app target
        // builds with `SWIFT_APPROACHABLE_CONCURRENCY = YES` (`Soredemo.xcodeproj`'s own build
        // settings), which enables this upcoming feature for code the APP TARGET declares — and
        // the calling convention of a `nonisolated async` function is a property of the module
        // that DECLARES it, not of its caller. Without this flag, a `nonisolated async` function
        // in THIS target hops to the global concurrent executor on every call, so a non-
        // `Sendable` argument a caller sends it is genuinely crossing an isolation domain the app
        // target's own build no longer crosses for functions it declares internally. Enabling it
        // here matches `scripts/run-cross-boundary-probe.sh`'s own `xcrun swiftc` invocation,
        // which already compiles `Sources/Compositing/StageCompositor.swift` and
        // `Sources/Compositing/CompositionBuilder.swift` with this same flag (commit `ab941a9`,
        // "Compile the probe with the app's isolation semantics") — this target, the app target
        // and the probe now agree, where before this change only two of the three did. Verified
        // from a clean `.build`: `swift test`, `swift test --parallel` and `xcodebuild` all pass;
        // an earlier, since-retracted attempt to fix this per-declaration
        // (`nonisolated(nonsending)` on `composition` alone) recorded an `EXC_BAD_ACCESS` under
        // this exact flag that did not reproduce once re-measured from a clean build — see
        // `composition`'s own doc comment for that history. Not added to `strict` (every package
        // target): the other six targets expose no `nonisolated async` API the app target or the
        // probe calls, so there is no caller this would change behaviour for.
        // **Two targets, because the boundary between them was already a fact and nothing
        // checked it** (Phase 3A-4). After the Capture extraction, one `Headless` target held
        // twenty files doing two unrelated jobs; several headers named a "capture tier" and a
        // "render tier" the build system did not have, and one redaction gate had to carry a
        // twelve-file exclusion list to say which half it meant. Measured before splitting:
        // the two halves referenced each other ZERO times in either direction — the only
        // cross-mentions were prose. So this is not a boundary being introduced, it is one
        // being enforced, and by the compiler rather than by a scan. The 3A-1 design's own
        // words: an allow-list "is a mechanism, not an invariant". A target is an invariant.
        //
        // Neither depends on the other and neither may — `theTwoRunnableTargetsDoNotDependOnEachOther`
        // asserts both directions against this manifest. `Graph` is Capture's alone
        // (`Minting.digest` returns `ContentDigest`); `Render` is Compositing's alone.
        .target(name: "Capture", dependencies: ["Geometry", "Timeline", "Graph", "Project"],
                swiftSettings: strict + [.enableUpcomingFeature("NonisolatedNonsendingByDefault")],
                plugins: headlessCheck),

        // Turns a plan into pixels: GPU, Core Image, AVFoundation. **Not named `Render`** —
        // `Sources/Render` is the DETERMINISTIC planning tier (`PointerTrack`, `RenderPlan`,
        // `StagePlanner`; no GPU, no clock), and reusing the word for the tier that actually
        // touches a GPU would collapse the distinction the two exist to draw.
        // `Framing` since the camera landed: the compositor turns an observation log's AX
        // chains into zoom blocks and asks `CameraMotion` where to point. Runnable → pure,
        // the legal direction; `Framing` does not and may not depend back.
        .target(name: "Compositing",
                dependencies: ["Geometry", "Timeline", "Project", "Render", "Framing", "Captions"],
                swiftSettings: strict + [.enableUpcomingFeature("NonisolatedNonsendingByDefault")],
                plugins: headlessCheck),

        // The checker's lexical layer — the "code view" that blanks comment and
        // string CONTENT so a banned name mentioned in prose does not fire. It is
        // a library rather than part of the executable because a test target
        // cannot import an `executableTarget`, and `AppSourceTests` below must
        // scan the app's sources through the SAME view the plugin uses. A second
        // copy of that logic would start at round zero of the four evasion-closing
        // rounds this one has been through.
        //
        // NO `plugins: archCheck` HERE, DELIBERATELY — this is not an oversight.
        // The plugin depends on `architecture-checker`, which now depends on
        // `CheckerLexer`; attaching the plugin to `CheckerLexer` would close that
        // into a dependency cycle and SwiftPM would refuse to resolve the package.
        // It is the same reason `architecture-checker` itself carries no plugin.
        // Consequences:
        //   * rule 1 (Foundation only) — this target imports Foundation and must
        //     keep to it. Phase 3A-1 Task 8 stopped keeping this by hand:
        //     `Tests/CheckerLexerTests/LexerImportDisciplineTests.swift` reads this
        //     target's own sources through `SwiftSourceLexer.codeViewLines` and fails
        //     if any import names a module other than Foundation.
        //   * rule 3 (no ambient time or randomness) — `DeterminismTests` derives
        //     its module list from the targets the PLUGIN is attached to
        //     (`scannedModules(inDump:)` in `Tests/DeterminismTests/SymbolDeterminismTests.swift`
        //     filters the resolved manifest for `ArchitectureCheck` plugin usage), so
        //     this target is outside that scan and STAYS outside it. Task 8 tried the
        //     obvious fix — adding `"CheckerLexer"` to `DeterminismTests`'
        //     dependencies (the `.testTarget(name: "DeterminismTests", …)` declaration
        //     below) — and measured it not to work: with the edge added,
        //     both `determinismTestTargetDependsOnEveryCheckedModule` and
        //     `noLibraryModuleReferencesAmbientTimeOrRandomness` stayed green, but
        //     green there is vacuous — `scannedModules(inDump:)` still never lists
        //     `CheckerLexer` because it still carries no `ArchitectureCheck` plugin,
        //     so the symbol scan still never reads `CheckerLexer.o`. Confirmed by
        //     adding a real `Date()` call to `SwiftSourceLexer.swift` with the
        //     dependency edge in place: `noLibraryModuleReferencesAmbientTimeOrRandomness`
        //     stayed green over a genuine violation. The edge was reverted along with
        //     the probe call. **The symbol-scan route remains kept by hand — a real
        //     fix there needs `scannedModules(inDump:)`'s own derivation changed to
        //     include this target by name, not just its dependency graph, which is
        //     still out of scope.** What is NOT hand-kept any more, as of the final
        //     whole-branch review for Phase 3A-1:
        //     `Tests/CheckerLexerTests/LexerImportDisciplineTests.swift` also carries
        //     `theCheckerLexerNeverReadsAmbientTimeOrRandomness`, a textual scan of this
        //     target's own code view against a needle list mirroring
        //     `ambientBannedNames` (`Tests/AppSourceTests/AppSourceAllowListTests.swift`).
        //     It is strictly WEAKER than the symbol scan — it reads only this target's
        //     own source text, so it cannot see a violation reached transitively through
        //     another module — but this target is one small Foundation-only,
        //     string-in/string-out module with no dependencies of its own, so there is no
        //     other module for a violation to hide behind, and it caught the exact
        //     `Date()` repro described above. Rule 3 for `CheckerLexer` is therefore
        //     textually enforced with that one stated limit, not hand-kept in full any
        //     more. The code view is a pure function of its input string and must
        //     stay one.
        // `everyLibraryTargetUsesTheCheckerPluginInTheResolvedManifest` names this
        // target as the single permitted exemption, so a SEVENTH regular target
        // added without the plugin still fails.
        .target(name: "CheckerLexer", swiftSettings: strict),

        // Rule 1 (Foundation-only imports) is enforced here, not by the compiler.
        .executableTarget(name: "architecture-checker",
                          dependencies: ["CheckerLexer"], swiftSettings: strict),
        .plugin(name: "ArchitectureCheck", capability: .buildTool(),
                dependencies: ["architecture-checker"]),
        .plugin(name: "HeadlessCheck", capability: .buildTool(),
                dependencies: ["architecture-checker"]),

        // Rule 3 (no ambient time or randomness) is a LINK-TIME SYMBOL check, and a
        // build-tool plugin's command runs BEFORE its target compiles, so the plugin
        // cannot see object files at all. This test target is the mechanism: the
        // dependency edges below are load-bearing, not decorative. They are what
        // guarantees every library module has been compiled — and therefore that its
        // object file exists — by the time the test body runs. A module dropped from
        // this list would still be scanned under a full `swift test`, but the ordering
        // guarantee would be gone; `determinismTestTargetDependsOnEveryCheckedModule`
        // asserts the list stays complete.
        .testTarget(name: "DeterminismTests",
                    dependencies: ["Geometry", "Timeline", "Graph", "Framing", "Variants", "Project", "Render",
                                   "Captions"],
                    swiftSettings: strict),

        // The first direct test of the code view. Until now the lexer's four
        // evasion-closing rounds were only ever exercised OUT OF PROCESS, by the
        // plugin failing (or not failing) a build.
        .testTarget(name: "CheckerLexerTests", dependencies: ["CheckerLexer"], swiftSettings: strict),

        // Rule 5 (design doc): the app-side allow-lists. Depends on `CheckerLexer`
        // only — it scans `Soredemo/`, not any package module.
        .testTarget(name: "AppSourceTests", dependencies: ["CheckerLexer"], swiftSettings: strict),

        .testTarget(name: "GeometryTests", dependencies: ["Geometry", "CheckerLexer"], swiftSettings: strict),
        .testTarget(name: "TimelineTests", dependencies: ["Timeline"], swiftSettings: strict),
        .testTarget(name: "GraphTests", dependencies: ["Graph", "Geometry", "Timeline"], swiftSettings: strict),
        .testTarget(name: "FramingTests", dependencies: ["Framing", "Geometry", "Project", "Timeline"],
                    swiftSettings: strict),
        .testTarget(name: "VariantsTests", dependencies: ["Variants"], swiftSettings: strict),
        .testTarget(name: "CaptionsTests", dependencies: ["Captions", "Timeline", "Render"], swiftSettings: strict),
        .testTarget(name: "ProjectTests", dependencies: ["Project", "Geometry"], swiftSettings: strict),
        .testTarget(name: "RenderTests", dependencies: ["Render", "Geometry", "Timeline", "Project"],
                    swiftSettings: strict),

        // The ONLY two test targets that depend on the runnable tier. The deterministic
        // targets must not: a test that cannot link the product cannot be written against
        // it, so the two populations are kept apart by the build graph rather than by
        // anyone remembering which suite a test belongs in.
        //
        // **Each depends on ITS OWN target only** (Phase 3A-4), so a test cannot reach
        // across the boundary the product code is now forbidden to cross. The observation
        // log fixture is Compositing's: `RecordedPointerPositionTests` reads one to drive
        // `StageCompositor`. Capture writes logs and never reads them.
        .testTarget(name: "CaptureTests", dependencies: ["Capture", "Geometry", "Timeline", "Graph", "Project"],
                    swiftSettings: strict),

        .testTarget(name: "CompositingTests",
                    dependencies: ["Compositing", "Geometry", "Timeline", "Project", "Render", "Framing",
                                   "Captions"],
                    resources: [.copy("../HeadlessFixtures/segment-00-redacted.jsonl")],
                    swiftSettings: strict),
    ]
)
