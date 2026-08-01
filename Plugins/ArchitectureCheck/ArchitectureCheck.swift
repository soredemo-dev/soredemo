import Foundation
import PackagePlugin

/// Runs `architecture-checker` over every source file of the target it is
/// attached to, on every build.
///
/// `.prebuildCommand` cannot be used: a SwiftPM prebuild command may not depend
/// on an executable built from source. `.buildCommand` can, and gets its
/// up-to-date check from a stamp file the checker writes only on success.
///
/// `context.tool(named:).path` rather than `.url`: `URL.path()` percent-encodes
/// Xcode's `${BUILD_DIR}` placeholder, which breaks the command under
/// `xcodebuild`. That keeps this file on the `Path`-based API throughout.
@main
struct ArchitectureCheck: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }

        let stamp = context.pluginWorkDirectory.appending("\(target.name).archcheck")

        // EVERY Package*.swift is an input: a manifest-only edit — adding a
        // dependency edge, say — must re-run the checker, or the rule never
        // fires on an incremental build.
        let manifests = (try? FileManager.default.contentsOfDirectory(
            atPath: context.package.directory.string))?
            .filter { $0.hasPrefix("Package") && $0.hasSuffix(".swift") }
            .sorted()
            .map { context.package.directory.appending($0) } ?? []

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
                executable: try context.tool(named: "architecture-checker").path,
                arguments: ["--target-name", target.name,
                            "--sources", target.directory.string,
                            "--allow", "Foundation",
                            "--touch", stamp.string] + declared,
                inputFiles: target.sourceFiles.map(\.path) + manifests,
                outputFiles: [stamp]
            )
        ]
    }
}
