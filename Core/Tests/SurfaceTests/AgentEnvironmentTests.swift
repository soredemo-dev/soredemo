import Testing
@testable import Surface

// The agent's environment: what a CLI needs, its own configuration, and nothing else.

private let operatorShell = [
    "PATH": "/usr/bin:/bin", "HOME": "/Users/someone", "USER": "someone", "LANG": "zh_TW.UTF-8",
    "AWS_SECRET_ACCESS_KEY": "secret", "GITHUB_TOKEN": "ghp_x", "OPENAI_API_KEY": "sk-openai",
    "ANTHROPIC_API_KEY": "sk-ant", "CLAUDE_CONFIG_DIR": "/Users/someone/.claude", "HTTPS_PROXY": "http://proxy",
]

@Suite struct AgentEnvironmentTests {
    /// The point of the type: a cloud key and a repository token never reach the agent.
    @Test func whatTheOperatorsShellHoldsBeyondTheListNeverReachesTheAgent() {
        let kept = AgentEnvironment.forAgent(operatorShell, prefixes: ["ANTHROPIC_", "CLAUDE_"], home: "/Users/someone")
        #expect(kept["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(kept["GITHUB_TOKEN"] == nil)
        #expect(kept["OPENAI_API_KEY"] == nil, "another agent's key is not this one's")
    }

    @Test func theAgentKeepsItsOwnConfigurationAndWhatAnyCLINeeds() {
        let kept = AgentEnvironment.forAgent(operatorShell, prefixes: ["ANTHROPIC_", "CLAUDE_"], home: "/Users/someone")
        #expect(kept["ANTHROPIC_API_KEY"] == "sk-ant" && kept["CLAUDE_CONFIG_DIR"] == "/Users/someone/.claude")
        #expect(kept["HOME"] == "/Users/someone" && kept["LANG"] == "zh_TW.UTF-8" && kept["HTTPS_PROXY"] == "http://proxy")
        let codex = AgentEnvironment.forAgent(operatorShell, prefixes: ["OPENAI_", "CODEX_"], home: "/Users/someone")
        #expect(codex["OPENAI_API_KEY"] == "sk-openai" && codex["ANTHROPIC_API_KEY"] == nil)
    }

    /// A GUI app's PATH is short; the agent's own subprocesses look where an installer put them.
    @Test func thePathGainsTheInstallersPlacesOnceEach() throws {
        let kept = AgentEnvironment.forAgent(["PATH": "/usr/bin:/opt/homebrew/bin"], prefixes: [], home: "/Users/someone")
        let path = try #require(kept["PATH"]).split(separator: ":").map(String.init)
        #expect(path == ["/usr/bin", "/opt/homebrew/bin", "/Users/someone/.local/bin", "/usr/local/bin"])
        #expect(kept["HOME"] == "/Users/someone", "HOME is supplied when the app had none")
    }
}
