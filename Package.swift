// swift-tools-version: 6.4
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .strictMemorySafety(),
]

let archCheck: [Target.PluginUsage] = ["ArchitectureCheck"]

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
        // `plugins: [archCheck]` on the six library targets — and deliberately NOT
        // on architecture-checker itself, whose own source legitimately contains
        // the banned module names.
        .target(name: "Geometry", swiftSettings: strict, plugins: archCheck),
        .target(name: "Timeline", swiftSettings: strict, plugins: archCheck),
        .target(name: "Graph", dependencies: ["Geometry", "Timeline"], swiftSettings: strict, plugins: archCheck),
        .target(name: "Framing", dependencies: ["Graph", "Geometry"], swiftSettings: strict, plugins: archCheck),
        .target(name: "Variants", dependencies: ["Framing", "Timeline"], swiftSettings: strict, plugins: archCheck),
        .target(name: "Project", dependencies: ["Graph", "Geometry", "Timeline"], swiftSettings: strict, plugins: archCheck),

        // Rule 1 (Foundation-only imports) is enforced here, not by the compiler.
        .executableTarget(name: "architecture-checker", swiftSettings: strict),
        .plugin(name: "ArchitectureCheck", capability: .buildTool(),
                dependencies: ["architecture-checker"]),

        .testTarget(name: "GeometryTests", dependencies: ["Geometry"], swiftSettings: strict),
        .testTarget(name: "TimelineTests", dependencies: ["Timeline"], swiftSettings: strict),
        .testTarget(name: "GraphTests", dependencies: ["Graph"], swiftSettings: strict),
        .testTarget(name: "FramingTests", dependencies: ["Framing"], swiftSettings: strict),
        .testTarget(name: "VariantsTests", dependencies: ["Variants"], swiftSettings: strict),
        .testTarget(name: "ProjectTests", dependencies: ["Project"], swiftSettings: strict),
    ]
)
