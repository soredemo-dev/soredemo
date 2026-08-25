import Foundation
import PackagePlugin

/// Runs `architecture-checker` over every source file of the target it is
/// attached to, on every build.
///
/// `.prebuildCommand` cannot be used: a SwiftPM prebuild command may not depend
/// on an executable built from source. `.buildCommand` can, and gets its
/// up-to-date check from a stamp file the checker writes only on success.
///
/// **`URL`, with `path(percentEncoded: false)` everywhere a string is needed.** This file was
/// held on the deprecated `Path` API by a real problem: `URL.path()` percent-encodes Xcode's
/// `${BUILD_DIR}` placeholder, so `${BUILD_DIR}` became `$%7BBUILD_DIR%7D` and the command could
/// not run under `xcodebuild`. `path(percentEncoded: false)` does not encode, which is the
/// answer that was missing — and every `Path` member this used is deprecated, so the choice was
/// between one honest conversion and a wall of warnings on every build.
///
/// The `xcodebuild` gate is what proves it: that placeholder is only expanded there, so a
/// regression here fails the app build rather than hiding in a passing `swift build`.
@main
struct ArchitectureCheck: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }

        let stamp = context.pluginWorkDirectoryURL.appending(path: "\(target.name).archcheck")

        // EVERY Package*.swift is an input: a manifest-only edit — adding a
        // dependency edge, say — must re-run the checker, or the rule never
        // fires on an incremental build.
        let manifests = (try? FileManager.default.contentsOfDirectory(
            atPath: context.package.directoryURL.path(percentEncoded: false)))?
            .filter { $0.hasPrefix("Package") && $0.hasSuffix(".swift") }
            .sorted()
            .map { context.package.directoryURL.appending(path: $0) } ?? []

        // The allow-list IS the manifest: one `--allow` per DECLARED dependency,
        // read out of PluginContext rather than mirrored by hand in the checker.
        // Direct edges only — the transitive closure would permit undeclared
        // imports (Framing→Timeline, Variants→Geometry), which are exactly the
        // edges SwiftPM's own diagnostic degrades to a warning on a warm .build.
        // `.product` dependencies are deliberately not expanded: a product may
        // vend several modules under a name that is not a module name, so
        // guessing would be wrong. The package has none today, and if one is
        // added the checker fails closed — loudly — rather than silently open.
        let declared = target.dependencies.flatMap { dependency -> [String] in
            if case .target(let dependencyTarget) = dependency {
                return ["--allow", dependencyTarget.name]
            }
            return []
        }

        return [
            .buildCommand(
                displayName: "ArchitectureCheck: \(target.name)",
                executable: try context.tool(named: "architecture-checker").url,
                arguments: ["--target-name", target.name,
                            "--sources", target.directoryURL.path(percentEncoded: false),
                            "--manifests", context.package.directoryURL.path(percentEncoded: false),
                            "--allow", "Foundation",
                            "--touch", stamp.path(percentEncoded: false)] + declared,
                inputFiles: target.sourceFiles.map(\.url) + manifests,
                outputFiles: [stamp]
            )
        ]
    }
}
