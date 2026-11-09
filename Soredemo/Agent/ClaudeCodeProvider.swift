import Foundation
import Surface

/// The person's own Claude Code, started headless for each turn under their own login. No API key
/// is held by Soredemo. See `AgentPrompt.claudeArguments` for what it is allowed to do.
@MainActor
final class ClaudeCodeProvider: AgentProvider {
    let name = "Claude Code"
    let mark = "ClaudeMark"
    let markIsTemplate = false
    private var process: Process?

    /// Where a GUI app looks, because it does not inherit a shell's `PATH`: the native installer's
    /// place, Homebrew's two, npm's global bin. A shell is asked last.
    nonisolated static let candidates = ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude",
                             "/usr/local/bin/claude", "~/.npm-global/bin/claude"]

    private var executable: String?

    func availability() async -> AgentAvailability {
        guard let path = await Self.locate() else { return .notInstalled }
        executable = path
        // "2.1.318 (Claude Code)" — the number alone, since the panel already names the agent.
        let version = await Self.output(of: path, ["--version"])?
            .split(separator: " ").first.map(String.init)
        return version.map { .ready(version: $0) } ?? .notInstalled
    }

    nonisolated static func locate() async -> String? {
        await AgentExecutable.locate("claude", candidates: candidates)
    }

    nonisolated static func output(of executable: String, _ arguments: [String]) async -> String? {
        await AgentExecutable.output(of: executable, arguments)
    }

    /// The aliases Claude Code takes for `--model`; each is its newest model of that tier.
    func models() async -> [AgentModel] {
        [AgentModel(id: "sonnet", label: "Sonnet"), AgentModel(id: "opus", label: "Opus")]
    }

    func run(message: String, session: String?, model: String?, tools: AgentTurnTools) -> AsyncStream<AgentEvent> {
        let mcpConfigPath = tools.relayConfigPath
        return AsyncStream { continuation in
            guard let executable else {
                continuation.yield(.failed("Claude Code was not found on this Mac."))
                continuation.finish()
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = AgentPrompt.claudeArguments(message: message, session: session,
                                                            mcpConfigPath: mcpConfigPath, model: model)
            // An empty working directory, so no project's own CLAUDE.md or settings join the turn.
            process.currentDirectoryURL = URL(fileURLWithPath: mcpConfigPath).deletingLastPathComponent()
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            // An allow-list, never the app's whole environment: a cloud key or a token left in it
            // would be readable by every process the agent starts (`AgentEnvironment`).
            process.environment = AgentEnvironment.forAgent(ProcessInfo.processInfo.environment,
                                                            prefixes: ["ANTHROPIC_", "CLAUDE_"],
                                                            home: NSHomeDirectory())
            let lines = LineBuffer()
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                for line in lines.append(data) {
                    for event in ClaudeStream.events(from: line) { continuation.yield(event) }
                }
            }
            let stderr = LineBuffer()
            let lastError = LastLine()
            err.fileHandleForReading.readabilityHandler = { handle in
                if let line = stderr.append(handle.availableData).last { lastError.set(line) }
            }
            process.terminationHandler = { finished in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                if finished.terminationStatus != 0, finished.terminationReason == .exit, let line = lastError.value {
                    continuation.yield(.failed(line))
                }
                continuation.finish()
            }
            do {
                try process.run()
                self.process = process
            } catch {
                continuation.yield(.failed("Claude Code could not be started: \(error.localizedDescription)"))
                continuation.finish()
            }
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    /// One process per turn, so ending everything is ending the turn.
    func close() { stop() }
}
