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
/// **This is a deny-list, and a deny-list is enumerative, not closed by
/// construction the way rule 1's allow-list is.** `Cocoa` re-exports `AppKit` —
/// measured: `import Cocoa` followed by `NSWindow(...)` typechecks clean at this
/// package's deployment target — so it is banned alongside `AppKit` itself.
/// `Quartz` was checked the same way: it re-exports `AppKit` too (`NSWindow`
/// typechecks under `import Quartz` alone) but NOT `SwiftUI` (`Text`/`View` do not
/// resolve under `import Quartz` alone), so it is banned for the same reason as
/// `Cocoa`. Both are named here because the checker matches the imported module by
/// its own name, not by what it re-exports — so the next umbrella framework that
/// reaches AppKit or SwiftUI through a re-export is a known gap in an enumerated
/// list, not a silent surprise.
///
/// **`CheckerLexer`'s arrangement is deliberately NOT inherited.** That target
/// carries no plugin (a dependency cycle makes it impossible) and keeps its rule-1
/// consequence by hand. `Headless` is the target most likely to drift, so its rule
/// is enforced rather than remembered.
///
/// `context.tool(named:).path` rather than `.url`, for the same reason
/// `ArchitectureCheck` gives: `URL.path()` percent-encodes Xcode's `${BUILD_DIR}`
/// placeholder and breaks the command under `xcodebuild`.
/// **`URL`, with `path(percentEncoded: false)` where a string is needed** — see
/// `ArchitectureCheck` for the reason the `Path` API was kept until now and why it no longer
/// has to be.
@main
struct HeadlessCheck: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }

        let stamp = context.pluginWorkDirectoryURL.appending(
            path: "\(target.name).headlesscheck")

        // Every Package*.swift is an input, as in ArchitectureCheck: rule 4 still runs
        // in this mode, and a manifest-only edit must re-run the checker or the rule
        // never fires on an incremental build.
        let manifests = (try? FileManager.default.contentsOfDirectory(
            atPath: context.package.directoryURL.path(percentEncoded: false)))?
            .filter { $0.hasPrefix("Package") && $0.hasSuffix(".swift") }
            .sorted()
            .map { context.package.directoryURL.appending(path: $0) } ?? []

        return [
            .buildCommand(
                displayName: "HeadlessCheck: \(target.name)",
                executable: try context.tool(named: "architecture-checker").url,
                arguments: ["--target-name", target.name,
                            "--sources", target.directoryURL.path(percentEncoded: false),
                            "--manifests", context.package.directoryURL.path(percentEncoded: false),
                            "--mode", "headless",
                            "--ban", "AppKit",
                            "--ban", "SwiftUI",
                            "--ban", "Cocoa",
                            "--ban", "Quartz",
                            "--touch", stamp.path(percentEncoded: false)],
                inputFiles: target.sourceFiles.map(\.url) + manifests,
                outputFiles: [stamp]
            )
        ]
    }
}
