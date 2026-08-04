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
            name: "SoredemoCore",
            targets: ["Geometry", "Timeline", "Graph", "Framing", "Variants", "Project", "Render"]
        )
    ],
    targets: [
        // `plugins: [archCheck]` on the six library targets — and deliberately NOT
        // on architecture-checker itself, whose own source legitimately contains
        // the banned module names.
        .target(name: "Geometry", swiftSettings: strict, plugins: archCheck),
        .target(name: "Timeline", swiftSettings: strict, plugins: archCheck),
        .target(name: "Graph", dependencies: ["Geometry", "Timeline"], swiftSettings: strict, plugins: archCheck),
        .target(name: "Framing", dependencies: ["Graph", "Geometry"], swiftSettings: strict, plugins: archCheck),
        .target(name: "Variants", dependencies: ["Framing", "Timeline"], swiftSettings: strict, plugins: archCheck),
        .target(name: "Project", dependencies: ["Graph", "Geometry", "Timeline"], swiftSettings: strict, plugins: archCheck),
        .target(name: "Render", dependencies: ["Geometry", "Timeline", "Project"],
                swiftSettings: strict, plugins: archCheck),

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
        // Consequences, both kept by hand rather than enforced:
        //   * rule 1 (Foundation only) — this target imports Foundation and must
        //     keep to it;
        //   * rule 3 (no ambient time or randomness) — `DeterminismTests` derives
        //     its module list from the targets the PLUGIN is attached to, so this
        //     target is outside that scan too. The code view is a pure function of
        //     its input string and must stay one.
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
                    dependencies: ["Geometry", "Timeline", "Graph", "Framing", "Variants", "Project", "Render"],
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
        .testTarget(name: "FramingTests", dependencies: ["Framing"], swiftSettings: strict),
        .testTarget(name: "VariantsTests", dependencies: ["Variants"], swiftSettings: strict),
        .testTarget(name: "ProjectTests", dependencies: ["Project", "Geometry"], swiftSettings: strict),
        .testTarget(name: "RenderTests", dependencies: ["Render", "Geometry", "Timeline", "Project"],
                    swiftSettings: strict),
    ]
)
