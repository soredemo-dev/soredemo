/// The environment the person's agent is started with: **an allow-list, never the app's whole
/// environment.** An agent runs tools on the person's behalf, and anything left in the environment
/// — a cloud key, a repository token — is readable by every process it starts. So the child gets
/// what a CLI needs to run and find its own sign-in, the agent's own configuration variables, and
/// nothing else. See `docs/research/agent-native-designs.md`, "What the agent may do".
public enum AgentEnvironment {
    /// What any command-line program needs: where things are, who is running it, its locale, its
    /// scratch space, and the operator's proxy.
    public static let shared: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TERM",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
    ]

    /// Where a GUI app does not look, because it does not inherit a login shell's `PATH`, but an
    /// agent's own subprocesses expect to: the native installer's place and Homebrew's two.
    public static let extraPath = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]

    /// The variables kept for an agent whose own configuration lives under `prefixes` — `ANTHROPIC_`
    /// and `CLAUDE_` for Claude Code, `OPENAI_` and `CODEX_` for Codex.
    public static func forAgent(_ environment: [String: String], prefixes: [String], home: String) -> [String: String] {
        var kept = environment.filter { key, _ in
            shared.contains(key) || prefixes.contains(where: key.hasPrefix)
        }
        let path = (kept["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        let extra = extraPath.map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        kept["PATH"] = (path + extra.filter { !path.contains($0) }).joined(separator: ":")
        if kept["HOME"] == nil { kept["HOME"] = home }
        return kept
    }
}
