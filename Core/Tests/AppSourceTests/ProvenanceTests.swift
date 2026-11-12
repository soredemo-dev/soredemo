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

/// **Three app files talk to a network: the update check, the agent's picture import and the plan's usage.**
///
/// The privacy pane says nothing is sent unless a person asks, and names the three requests
/// Soredemo itself makes: the update check, the agent's picture import and the plan's usage. This keeps the
/// sentence true: a fourth file naming a networking API is a thing leaving the Mac the pane does not mention.
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
        // The agent relay is a pipe between two of this app's own processes, over a Unix socket in
        // a directory only this user can open. Admitted only while that is all it is: no host, no
        // port, no endpoint but `.unix(path:)`.
        if file.lastPathComponent == "AgentRelay.swift" {
            let code = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            let reaches = ["NWEndpoint.Host", ".hostPort", "NWEndpoint.Port", ".service(", "URLSession", "URLRequest"].filter(code.contains)
            #expect(reaches.isEmpty && code.contains(".unix(path:"), """
                AgentRelay.swift is admitted as a local Unix-socket pipe, and it now names \(reaches) — \
                something that reaches past this Mac. The privacy pane would no longer be true.
                """)
            continue
        }
        // The agent's picture import, the second request the privacy pane names
        // (`docs/design/2026-11-13-the-agent-may-search-the-web.md`). Admitted only while every
        // address it fetches is checked first and every redirect is checked before it is followed.
        // The plan's usage, the third request the pane names
        // (`docs/design/2026-11-13-the-plan-usage-before-a-message.md`). Admitted only while it
        // names no address of its own: the two it may reach are `AccountUsage`'s.
        if file.lastPathComponent == "AccountUsageReader.swift" {
            let code = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            #expect(!code.contains("http://") && !code.contains("https://")
                    && code.contains("AccountUsage.claudeEndpoint") && code.contains("AccountUsage.codexEndpoint"), """
                AccountUsageReader.swift is admitted as the usage request to AccountUsage's two hosts; it now names \
                an address of its own, which the privacy pane does not mention.
                """)
            continue
        }
        if file.lastPathComponent == "AgentEditorBridge+Import.swift" {
            let code = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            #expect(code.contains("ImageImport.refusal(for: address)") && code.contains("delegate: RedirectCheck()"), """
                AgentEditorBridge+Import.swift is admitted as the picture import that checks each address and each \
                redirect; one of those checks is gone, and the privacy pane's promise with it.
                """)
            continue
        }
        found.append("\(pathRelativeToRepositoryRoot(file)): \(named.joined(separator: ", "))")
    }
    try #require(theCheckItself, "UpdateCheck.swift names no networking API — the scan's positive control is gone")
    #expect(found.isEmpty, """
        These app files name a networking API, and the privacy pane promises the update check is \
        the only request:
        \(found.joined(separator: "\n"))
        """)
}

/// **Starting the person's own agent is said in the privacy pane.** The Agent tab hands what a
/// person types to their Claude Code, which sends it to its provider; the pane's promise that
/// nothing is sent unless you ask stays true only while it says this one does, when you ask.
@Test func thePrivacyPaneSaysWhatTheAgentTabSends() throws {
    let provider = repositoryRoot.appending(path: "Soredemo/Agent/ClaudeCodeProvider.swift")
    try #require(FileManager.default.fileExists(atPath: provider.path(percentEncoded: false)),
                 "ClaudeCodeProvider.swift is gone — rewrite this check for whatever starts an agent now")
    let pane = try String(contentsOf: repositoryRoot.appending(path: "Soredemo/Settings/SettingsWindow.swift"), encoding: .utf8)
    #expect(pane.contains("The Agent tab sends what you type"), "the privacy pane does not say what the Agent tab sends")
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
