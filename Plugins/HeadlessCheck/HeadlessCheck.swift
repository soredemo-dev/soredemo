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
