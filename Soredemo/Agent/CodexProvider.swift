import Foundation
import Surface

/// The person's own Codex, driven through `codex app-server` under their own login. No API key is
/// held by Soredemo.
///
/// **What it may do is decided in `Surface`**, not here: `CodexAppServer.serverArguments` closes
/// everything that is not Soredemo's before the server starts, and `CodexSession` answers every
/// request, checks the thread's sandbox and stops a turn that reaches for anything else. This type
/// moves lines between that value and the process, and runs the tool calls it is handed. See the
/// design document's "Codex, as designed".
///
/// **One server per conversation, kept between turns** — unlike Claude Code's one process per
/// turn: the thread lives in the server, so each message is a turn on it.
@MainActor
final class CodexProvider: AgentProvider {
    let name = "Codex"
    let mark = "OpenAIMark"
    let markIsTemplate = true

    /// Where a GUI app looks: Homebrew's two, the native installer's place, npm's global bin. The
    /// person's login shell is asked last.
    nonisolated static let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                                         "~/.local/bin/codex", "~/.npm-global/bin/codex"]

    private var executable: String?
    private var connection: CodexConnection?

    func availability() async -> AgentAvailability {
        guard let path = await AgentExecutable.locate("codex", candidates: Self.candidates) else { return .notInstalled }
        executable = path
        // "codex-cli 0.167.0" — the number alone, since the panel already names the agent.
        let version = await AgentExecutable.output(of: path, ["--version"], environment: Self.environment())?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").last.map(String.init)
        return version.map { .ready(version: $0) } ?? .notInstalled
    }

    func models() async -> [AgentModel] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSString(string: "~/.codex").expandingTildeInPath
        let cache = URL(fileURLWithPath: home).appending(path: "models_cache.json")
        guard let data = try? Data(contentsOf: cache) else { return [] }
        return CodexAppServer.models(fromCache: data)
    }

    func run(message: String, session: String?, model: String?, tools: AgentTurnTools) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            Task { @MainActor in
                do {
                    let connection = try await self.connect(tools: tools)
                    if session == nil { connection.newThread() }
                    connection.begin(message: message, model: model, continuation: continuation)
                } catch {
                    continuation.yield(.failed("\(error)"))
                    continuation.finish()
                }
            }
        }
    }

    func stop() {
        connection?.interrupt()
    }

    func close() {
        connection?.terminate()
        connection = nil
    }

    /// The running server, or a new one: its MCP servers listed and each closed by name first.
    private func connect(tools: AgentTurnTools) async throws -> CodexConnection {
        if let connection, connection.isRunning { return connection }
        guard let executable else { throw CodexStartError("Codex was not found on this Mac.") }
        let environment = Self.environment()
        let listing = await AgentExecutable.output(of: executable, CodexAppServer.listingArguments, environment: environment) ?? ""
        // A listing that cannot be read refuses the turn: starting Codex anyway would leave every
        // server it failed to name switched on.
        guard let servers = CodexAppServer.serverNames(fromListing: listing) else {
            let said = listing.split(separator: "\n").first.map(String.init) ?? "nothing"
            throw CodexStartError("Codex's list of MCP servers could not be read, so Codex was not started. It said: \(said)")
        }
        let directory = URL(fileURLWithPath: tools.relayConfigPath).deletingLastPathComponent()
        let session = CodexSession(tools: tools.toolbox.tools, instructions: AgentPrompt.systemPrompt,
                                   workingDirectory: directory.path(percentEncoded: false))
        let connection = try CodexConnection(executable: executable, arguments: CodexAppServer.serverArguments(closing: servers),
                                             directory: directory, environment: environment,
                                             session: session, toolbox: tools.toolbox)
        self.connection = connection
        return connection
    }

    /// An allow-list, never the app's whole environment (`AgentEnvironment`).
    private nonisolated static func environment() -> [String: String] {
        AgentEnvironment.forAgent(ProcessInfo.processInfo.environment, prefixes: ["OPENAI_", "CODEX_"], home: NSHomeDirectory())
    }
}

struct CodexStartError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The running `codex app-server` and the conversation with it. **`@unchecked Sendable` with its
/// reason**: the session and the turn's stream are touched only under `lock`, and writes to the
/// server only under `writing`, so a tool's reply finishing on another thread cannot interleave
/// with a line the reader is answering.
nonisolated final class CodexConnection: @unchecked Sendable {
    private let lock = NSLock()
    private let writing = NSLock()
    private var session: CodexSession
    private var continuation: AsyncStream<AgentEvent>.Continuation?
    private let process = Process()
    private let input: FileHandle
    private let toolbox: any MCPToolbox

    init(executable: String, arguments: [String], directory: URL, environment: [String: String],
         session: CodexSession, toolbox: any MCPToolbox) throws {
        self.session = session
        self.toolbox = toolbox
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        input = stdin.fileHandleForWriting

        let lines = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            for line in lines.append(handle.availableData) { self?.receive(line) }
        }
        let errors = LineBuffer()
        let lastError = LastLine()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if let line = errors.append(handle.availableData).last { lastError.set(line) }
        }
        process.terminationHandler = { [weak self] finished in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            let reason = lastError.value ?? "exit \(finished.terminationStatus)"
            self.perform(self.lock.withLock { self.session.processEnded(reason: reason) })
        }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func begin(message: String, model: String?, continuation: AsyncStream<AgentEvent>.Continuation) {
        let outputs: [CodexSession.Output]? = lock.withLock {
            guard self.continuation == nil else { return nil }
            self.continuation = continuation
            return session.begin(message: message, model: model)
        }
        guard let outputs else {
            continuation.yield(.failed("Codex is still working on the last message."))
            continuation.finish()
            return
        }
        perform(outputs)
    }

    func newThread() { lock.withLock { session.newThread() } }

    func interrupt() { perform(lock.withLock { session.interrupt() }) }

    func terminate() {
        process.terminate()
    }

    private func receive(_ line: String) {
        perform(lock.withLock { session.receive(line) })
    }

    private func perform(_ outputs: [CodexSession.Output]) {
        for output in outputs {
            switch output {
            case .send(let line):
                write(line)
            case .event(let event):
                lock.withLock { continuation }?.yield(event)
            case .callTool(let id, let name, let arguments):
                let toolbox = toolbox
                Task { [weak self] in
                    let result = await toolbox.call(name, argumentsJSON: arguments)
                        ?? .failure(message: "There is no tool named \(name) here.", code: "usage")
                    self?.write(CodexSession.reply(to: id, with: result))
                }
            case .turnEnded:
                let ended = lock.withLock {
                    let ended = continuation
                    continuation = nil
                    return ended
                }
                ended?.finish()
            }
        }
    }

    private func write(_ line: String) {
        writing.withLock {
            // A failed write means the server has exited; its termination handler ends the turn
            // and says why, so there is nothing further to report here.
            try? input.write(contentsOf: Data((line + "\n").utf8))
        }
    }
}
