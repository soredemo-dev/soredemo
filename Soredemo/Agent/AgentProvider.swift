import Foundation
import Surface

/// Something that runs one turn of an agent and reports what it said and did. The panel holds one
/// of these and never a wire format, so a second agent is a new conformance and nothing in the
/// panel changes — Codex was exactly that.
protocol AgentProvider: AnyObject {
    var name: String { get }
    /// The asset beside its name in the panel (`docs/third-party-marks.md`).
    var mark: String { get }
    /// Whether the mark is drawn in the text colour (a one-colour mark) or as it is.
    var markIsTemplate: Bool { get }
    /// The models its own picker offers; empty when it cannot say, and the panel offers only the
    /// person's default.
    func models() async -> [AgentModel]
    /// Whether it can run here, and why not.
    func availability() async -> AgentAvailability
    /// Runs one turn. Events arrive on the main actor; the stream ends when the turn does. A `nil`
    /// session is a new conversation.
    func run(message: String, session: String?, model: String?, tools: AgentTurnTools) -> AsyncStream<AgentEvent>
    /// Ends the running turn. What it already did stays, and is revertible.
    func stop()
    /// Ends everything it started; the next `run` starts afresh.
    func close()
}

/// What a turn's tools are reached through: Claude Code starts Soredemo's MCP relay from its
/// config file; Codex is handed the toolbox and calls back over its own pipe.
struct AgentTurnTools {
    let relayConfigPath: String
    let toolbox: any MCPToolbox
}

enum AgentAvailability: Equatable {
    case ready(version: String)
    case notInstalled
}

/// The person's own CLI, found where a GUI app can see it — it does not inherit a shell's `PATH`,
/// so the usual install places are tried first and the person's login shell is asked last.
enum AgentExecutable {
    nonisolated static func locate(_ command: String, candidates: [String]) async -> String? {
        let fileManager = FileManager.default
        for candidate in candidates {
            let path = NSString(string: candidate).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        let found = await output(of: "/bin/zsh", ["-lc", "command -v \(command)"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return found.flatMap { fileManager.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    /// Standard output of a short command, or `nil` when it could not be started. A non-zero exit
    /// still returns what it wrote: the caller decides whether that reads as an answer.
    nonisolated static func output(of executable: String, _ arguments: [String],
                                   environment: [String: String]? = nil) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment { process.environment = environment }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }
}

/// The last line a process wrote to stderr — what a failed turn is reported with. **`@unchecked
/// Sendable` with its reason**: every access holds `lock`.
nonisolated final class LastLine: @unchecked Sendable {
    private let lock = NSLock()
    private var line: String?
    func set(_ text: String) { lock.withLock { line = text } }
    var value: String? { lock.withLock { line } }
}
