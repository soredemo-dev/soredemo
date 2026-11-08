import Foundation
import Network
import Surface
import Synchronization

/// The way the panel's agent reaches the **open** editor.
///
/// The agent is the person's own `claude`, started by the panel; it starts its MCP server as a
/// child process, `Soredemo mcp --relay <socket>`, which can see nothing of this app on its own.
/// So that child is only a pipe: every line it reads on stdin it writes to a Unix socket here, and
/// every line that comes back it writes to stdout. **This app answers**, with the live toolbox, so
/// the agent reads what the person sees — its own last cut included — and its edits land on the
/// timeline in front of them.
///
/// **No port**: the socket lives in a directory created `0700` for this session, so only this
/// user can open it, and it is removed when the session ends. See
/// `docs/design/2026-11-08-evidence-cut-and-the-agent-surface.md`, "How it works".
nonisolated final class AgentRelay: @unchecked Sendable {
    /// The directory and socket, and the MCP config that tells `claude` to start the relay.
    let directory: URL
    let socketPath: String
    let configPath: String

    private let listener: NWListener
    private let server: MCPServer
    private let queue = DispatchQueue(label: "dev.soredemo.agent-relay")
    // `@unchecked Sendable` because these are touched only on `queue`.
    private var connections: [NWConnection] = []

    init(toolbox: any MCPToolbox, version: String, executable: String) throws {
        // A fresh directory the system names — unique without this app minting a value — and
        // then narrowed to this user alone before anything is put in it.
        let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                    appropriateFor: FileManager.default.temporaryDirectory, create: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
        self.directory = directory
        socketPath = directory.appending(path: "s").path(percentEncoded: false)
        configPath = directory.appending(path: "mcp.json").path(percentEncoded: false)
        server = MCPServer(toolbox: toolbox, version: version, instructions: AgentPrompt.systemPrompt)

        let config = ["mcpServers": ["soredemo": ["command": executable, "args": ["mcp", "--relay", socketPath]]]]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: configPath))

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socketPath)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        // **Listening before this returns.** The config handed to `claude` names the socket, and
        // a child that arrives before the socket exists waits, then — taking that for an app that
        // has gone — exits; a relay test failed exactly so under a loaded full run (2026-11-08).
        let settled = DispatchSemaphore(value: 0)
        let outcome = Mutex<NWListener.State?>(nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                if outcome.withLock({ current in defer { current = current ?? state }; return current == nil }) {
                    settled.signal()
                }
            default: break
            }
        }
        listener.start(queue: queue)
        guard settled.wait(timeout: .now() + 3) == .success else {
            listener.cancel()
            throw RelayError.notListening("the socket was not listening after three seconds")
        }
        if case .failed(let error)? = outcome.withLock({ $0 }) {
            throw RelayError.notListening("\(error)")
        }
    }

    enum RelayError: Error, CustomStringConvertible {
        case notListening(String)
        var description: String {
            switch self { case .notListening(let why): "The agent relay could not listen: \(why)." }
        }
    }

    /// Stops listening and removes the directory, socket and config with it.
    func close() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() }; connections = [] }
        try? FileManager.default.removeItem(at: directory)
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receive(on: connection, state: ConnectionState())
    }

    /// **Every request is answered before the connection closes.** A client that has said all it
    /// will say — `claude` closes its server's stdin on shutdown — still waits for the replies in
    /// flight, so the close is deferred until the last one is sent.
    private func receive(on connection: NWConnection, state: ConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            for line in state.lines.append(data ?? Data()) {
                state.pending += 1
                let server = self.server
                let queue = self.queue
                Task {
                    let reply = await server.handle(line)
                    queue.async {
                        let finish: @Sendable () -> Void = {
                            state.pending -= 1
                            if state.ended && state.pending == 0 { connection.cancel() }
                        }
                        guard let reply else { finish(); return }
                        connection.send(content: Data((reply + "\n").utf8), completion: .contentProcessed { _ in
                            queue.async(execute: finish)
                        })
                    }
                }
            }
            if isComplete || error != nil {
                state.ended = true
                if state.pending == 0 { connection.cancel() }
                return
            }
            self.receive(on: connection, state: state)
        }
    }

    /// The child side: stdin to the socket, the socket to stdout, until either closes.
    static func pipe(socketPath: String) -> Never {
        RelayChild(socketPath: socketPath).run()
    }
}

/// `Soredemo mcp --relay`: the pipe the panel's agent starts. **A type rather than nested local
/// functions**, so each callback is a method on one `Sendable` value rather than a closure the
/// compiler cannot prove safe to run on Network's queue.
nonisolated private final class RelayChild: Sendable {
    let connection: NWConnection
    let finished = DispatchSemaphore(value: 0)
    let queue = DispatchQueue(label: "dev.soredemo.agent-relay.child")
    let connected = Mutex(false)

    init(socketPath: String) {
        connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
    }

    func run() -> Never {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: connected.withLock { $0 = true }
            case .failed, .cancelled: finished.signal()
            // With the app gone there is nothing at the socket, and a Unix-socket connection
            // WAITS there rather than failing — an orphan that never exits, found when a killed
            // test run left one behind (2026-11-08). But it can also pass through `.waiting` on
            // its way to `.ready`, and ending on the first one dropped every reply; so it ends
            // only when, a second later, it has still never connected.
            case .waiting:
                queue.asyncAfter(deadline: .now() + 1) { [self] in
                    if !connected.withLock({ $0 }) { finished.signal() }
                }
            default: break
            }
        }
        connection.start(queue: queue)
        forward()
        Thread.detachNewThread { [self] in readStdin() }
        finished.wait()
        connection.cancel()
        exit(0)
    }

    /// The socket to stdout, until the app closes its end.
    private func forward() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty { try? FileHandle.standardOutput.write(contentsOf: data) }  // a closed stdout is the client gone
            if isComplete || error != nil { finished.signal(); return }
            forward()
        }
    }

    /// stdin to the socket. At its end, say so and keep reading until the app has answered
    /// everything and closed its side — exiting here would drop the replies still on their way.
    private func readStdin() {
        while let line = readLine(strippingNewline: false) {
            connection.send(content: Data(line.utf8), completion: .contentProcessed { _ in })
        }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in })
    }
}

/// One connection's framing and in-flight count. Touched only on the relay's queue.
nonisolated final class ConnectionState: @unchecked Sendable {
    let lines = LineBuffer()
    var pending = 0
    var ended = false
}

/// Bytes in, whole lines out — the framing MCP's stdio transport and this socket share.
nonisolated final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        return lines
    }
}
