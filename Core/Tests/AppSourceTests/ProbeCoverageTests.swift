import Foundation
import Testing

// Reuses `repositoryRoot`, `appSourceFiles()` and `pathRelativeToRepositoryRoot` from
// `AppSourceAllowListTests.swift` — file-scope declarations in this same target.

/// The path of the only app source the probe cannot compile, and the reason, in one place.
private let theFileWithMain = "Soredemo/App/SoredemoApp.swift"

/// Every `Soredemo/…swift` path passed to `xcrun swiftc` by the probe runner.
///
/// Parsed from the script rather than restated: the script's own header says "The authoritative
/// list is the `swiftc` invocation below; do not restate it here, where it would drift out of
/// date without failing anything", and a second copy in this file would be exactly that.
private func probeCompiledAppSources() throws -> Set<String> {
    let script = repositoryRoot.appending(path: "scripts/run-cross-boundary-probe.sh")
    let text = try String(contentsOf: script, encoding: .utf8)
    var found: Set<String> = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // A continued argument line and nothing else: a `#` comment naming a path must not
        // count as coverage, which is the failure mode a looser match would have.
        guard !trimmed.hasPrefix("#"), trimmed.hasSuffix(".swift \\") else { continue }
        let path = String(trimmed.dropLast(2)).trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("Soredemo/") { found.insert(path) }
    }
    try #require(!found.isEmpty, """
        no `Soredemo/…swift` argument lines were found in run-cross-boundary-probe.sh. Either \
        the invocation was reformatted or this parser has stopped matching it; either way the \
        scan below would pass over nothing, which is worse than not having it.
        """)
    return found
}

/// **The probe compiles every app source but the one carrying `@main`.**
///
/// The Xcode app target has no test target — `ROADMAP.md`'s `project-format` row has said so
/// since Phase 1 — so `scripts/run-cross-boundary-probe.sh` is the app tier's only executing
/// instrument, and what it does not compile, nothing executes. That list used to be curated by
/// hand and drifted: the whole recording cluster (`ContentView.swift`, where
/// `RecordingCoordinator` lives, plus `RecordingBar`, `MenuBarRecorder` and `SettingsWindow`)
/// sat outside it, and the script's header explained the omission with a reason that was true
/// of two string constants rather than of the app lifecycle. Nothing failed while that was so.
///
/// `SoredemoApp.swift` is the single exemption and it is a structural one, not a judgement: it
/// carries `@main`, the probe binary has its own entry point, and two of those do not link. If a
/// second file ever needs exempting, the reason belongs here beside this one — an exemption
/// nobody has to write down is an exemption nobody re-reads.
@Test func theProbeCompilesEveryAppSourceExceptTheOneWithMain() throws {
    let compiled = try probeCompiledAppSources()
    let onDisk = Set(try appSourceFiles().map(pathRelativeToRepositoryRoot))

    try #require(onDisk.contains(theFileWithMain), """
        \(theFileWithMain) is not on disk under that path. It is named here as the probe's one \
        permitted exemption, so a rename must move this constant with it rather than silently \
        turning the exemption into a hole.
        """)

    let missing = onDisk.subtracting(compiled).subtracting([theFileWithMain])
    #expect(missing.isEmpty, """
        \(missing.sorted().joined(separator: ", ")) — app sources the probe does not compile.
        The app target has no test target, so a file outside the probe's `xcrun swiftc` \
        invocation is executed by no gate at all: it is type-checked by `xcodebuild` and \
        otherwise unreached. Add it to the invocation in scripts/run-cross-boundary-probe.sh. \
        If it genuinely cannot be compiled there, say why beside `theFileWithMain` above — \
        that one is exempt because it carries `@main` and a binary has one entry point.
        """)

    // The other direction: a path listed in the script that is not on disk any more. The build
    // would fail loudly, so this is not the safety net — it is what keeps the count above from
    // being satisfied by a stale entry standing in for a renamed file.
    let vanished = compiled.subtracting(onDisk)
    #expect(vanished.isEmpty, """
        \(vanished.sorted().joined(separator: ", ")) — listed in the probe's invocation and \
        not on disk.
        """)
}
