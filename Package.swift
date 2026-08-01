// swift-tools-version: 6.4
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
