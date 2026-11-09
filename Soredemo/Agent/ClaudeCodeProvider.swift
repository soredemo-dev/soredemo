import Foundation
import Surface

/// Something that runs one turn of an agent and reports what it said and did. The panel holds one
/// of these and never a wire format, so a second agent — Codex, the on-device model — is a new
/// conformance and nothing in the panel changes.
protocol AgentProvider: AnyObject {
    var name: String { get }
    /// Whether it can run here, and why not.
    func availability() async -> AgentAvailability
    /// Runs one turn. Events arrive on the main actor; the stream ends when the turn does.
    func run(message: String, session: String?, model: String?, mcpConfigPath: String) -> AsyncStream<AgentEvent>
    /// Ends the running turn. What it already did stays, and is revertible.
    func stop()
}

enum AgentAvailability: Equatable {
    case ready(version: String)
    case notInstalled
}

/// The person's own Claude Code, started headless for each turn under their own login. No API key
/// is held by Soredemo. See `AgentPrompt.claudeArguments` for what it is allowed to do.
@MainActor
final class ClaudeCodeProvider: AgentProvider {
    let name = "Claude Code"
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
        let fileManager = FileManager.default
        for candidate in candidates {
            let path = NSString(string: candidate).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        // The person's login shell, for an install somewhere else on their PATH.
        let found = await output(of: "/bin/zsh", ["-lc", "command -v claude"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return found.flatMap { fileManager.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    nonisolated static func output(of executable: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }

    func run(message: String, session: String?, model: String?, mcpConfigPath: String) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
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
}

/// The last line Claude Code wrote to stderr — what a failed turn is reported with. **`@unchecked
/// Sendable` with its reason**: every access holds `lock`.
nonisolated private final class LastLine: @unchecked Sendable {
    private let lock = NSLock()
    private var line: String?
    func set(_ text: String) { lock.withLock { line = text } }
    var value: String? { lock.withLock { line } }
}
