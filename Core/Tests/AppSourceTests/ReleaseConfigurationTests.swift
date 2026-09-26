import Foundation
import Testing

/// Settings the app target may set differently in Debug and Release, each with its reason.
/// Empty: nothing has needed to differ yet, and anything that does should say why here.
private let permittedConfigurationDifferences: [String: String] = [:]

/// The app target's build settings, per configuration name, read from the project file.
private func appTargetSettings() throws -> [String: [String: String]] {
    let project = try String(contentsOf: repositoryRoot.appending(path: "Soredemo.xcodeproj/project.pbxproj"),
                             encoding: .utf8)
    var byName: [String: [String: String]] = [:]
    for block in project.components(separatedBy: "isa = XCBuildConfiguration;").dropFirst() {
        guard let settingsStart = block.range(of: "buildSettings = {"),
              let settingsEnd = block.range(of: "\n\t\t\t};", range: settingsStart.upperBound..<block.endIndex),
              let nameLine = block.range(of: "name = ", range: settingsEnd.upperBound..<block.endIndex)
        else { continue }
        let name = block[nameLine.upperBound...].prefix { $0 != ";" }
        var settings: [String: String] = [:]
        // One setting per line; a multi-line array value keeps only its first line, which is
        // enough to tell two configurations apart.
        for line in block[settingsStart.upperBound..<settingsEnd.lowerBound].components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " = ")
            guard parts.count >= 2 else { continue }
            settings[parts[0]] = parts.dropFirst().joined(separator: " = ")
        }
        guard settings["PRODUCT_BUNDLE_IDENTIFIER"] == "dev.soredemo.mac;" else { continue }
        byName[String(name)] = settings
    }
    return byName
}

/// **The app a person downloads is built the way the app that was tested is.**
///
/// Release was missing `ENABLE_RESOURCE_ACCESS_CAMERA = YES`, which Debug had. Under the
/// hardened runtime that entitlement is what lets the camera open, so every build anybody used
/// recorded the camera and the first Developer ID export could not — found on 2026-09-26 by
/// reading the entitlements of `dist/export/Soredemo.app`, not by any check. A difference now
/// has to be written down in `permittedConfigurationDifferences` to exist.
@Test func releaseBuildsTheAppWithTheSameSettingsAsDebug() throws {
    let configurations = try appTargetSettings()
    let debug = try #require(configurations["Debug"], "no Debug configuration for dev.soredemo.mac")
    let release = try #require(configurations["Release"], "no Release configuration for dev.soredemo.mac")
    try #require(debug.count > 20 && release.count > 20,
                 "read \(debug.count) and \(release.count) settings — the parser stopped matching")
    let differing = Set(debug.keys).union(release.keys)
        .filter { debug[$0] != release[$0] && permittedConfigurationDifferences[$0] == nil }
        .sorted()
        .map { "\($0): Debug \(debug[$0] ?? "unset"), Release \(release[$0] ?? "unset")" }
    #expect(differing.isEmpty, """
        The app target is configured differently in Release, so the tested build is not the \
        shipped one:
        \(differing.joined(separator: "\n"))
        Make them match, or add the key to permittedConfigurationDifferences with its reason.
        """)
}
