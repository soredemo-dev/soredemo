import Foundation
import Testing

/// **The build-provenance file in the tree is the placeholder, not a stamp.**
///
/// `scripts/build-provenance.sh stamp` bakes a commit and a time into the app for the length of
/// one build. A stamped copy left in the tree was committed with unrelated work more than forty
/// times, so the committed baseline read "5ee4041-dirty" and a plain Xcode build reported that
/// as its own identity — a plausible value where a refusal belonged. Both build scripts now put
/// the placeholder back on exit; this fails if one did not, or a stamp is about to be committed.
@Test func appProvenanceIsCommittedAsThePlaceholder() throws {
    let file = repositoryRoot.appending(path: "Soredemo/App/BuildProvenance.swift")
    let text = try String(contentsOf: file, encoding: .utf8)
    let values = text.components(separatedBy: .newlines).filter { $0.contains("static let") }
    try #require(values.count == 2, "expected builtAt and commit, found \(values)")
    for value in values {
        #expect(value.contains("UNBUILT"), """
            \(value.trimmingCharacters(in: .whitespaces)) — a stamped value is in the tree. Run \
            scripts/build-provenance.sh placeholder, and do not commit the stamp.
            """)
    }
}

/// **One app file talks to a network, and it is the update check.**
///
/// The privacy pane says nothing is sent unless a person asks, and the update check is the one
/// request that exists. This keeps the sentence true: a second file naming a networking API is
/// a second thing leaving the Mac that the pane does not mention.
@Test func noOtherAppSourceTalksToANetwork() throws {
    let networking = ["URLSession", "URLRequest", "NWConnection", "NWListener", "NSURLConnection",
                      "WKWebView", "CFStream", "Socket("]
    var found: [String] = []
    var theCheckItself = false
    for file in try appSourceFiles() {
        let text = try String(contentsOf: file, encoding: .utf8)
        let named = networking.filter { text.contains($0) }
        guard !named.isEmpty else { continue }
        if file.lastPathComponent == "UpdateCheck.swift" { theCheckItself = true; continue }
        found.append("\(pathRelativeToRepositoryRoot(file)): \(named.joined(separator: ", "))")
    }
    try #require(theCheckItself, "UpdateCheck.swift names no networking API — the scan's positive control is gone")
    #expect(found.isEmpty, """
        These app files name a networking API, and the privacy pane promises the update check is \
        the only request:
        \(found.joined(separator: "\n"))
        """)
}

/// **The language model that suggests chapters is the one on this Mac.** FoundationModels also
/// offers `PrivateCloudComputeLanguageModel`, which sends the prompt — a person's transcript —
/// off the machine. Nothing leaves unless a person sends it, so no first-party source may name
/// it. The positive control is the on-device model's own use, which must still be found.
@Test func onlyTheOnDeviceLanguageModelIsUsed() throws {
    let files = try firstPartySourceFiles()
    let onDevice = try codeLinesNaming("SystemLanguageModel", in: files)
    try #require(!onDevice.isEmpty, "nothing names SystemLanguageModel — this scan's positive control is gone")
    let offDevice = try violationsEverywhere(banned: ["PrivateCloudComputeLanguageModel"], in: files)
    #expect(offDevice.isEmpty, """
        These sources name the language model that runs off this Mac:
        \(offDevice.joined(separator: "\n"))
        See docs/design/2026-09-27-chapters.md.
        """)
}
