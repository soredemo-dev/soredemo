import Compositing
import Dispatch
import Foundation
import Surface
import Synchronization

/// `Soredemo.app/Contents/MacOS/Soredemo cli <verb> <project.soredemo> [--json]` — the surface's
/// terminal front end, inside the app's own executable so there is one signed binary to trust.
///
/// **Checked first in `SoredemoApp.init`, and it exits there**, before any window or the
/// recording coordinator exists: a terminal call opens nothing on screen, the same way
/// `--dump-permissions` does. Everything it answers is computed in `Surface`; this file only
/// hands it the package reader and writes what comes back.
enum CommandLineSurface {
    /// The first argument that makes this a terminal call. A word rather than a flag, so the
    /// launch flags the app already takes (`--open-project`, `--show-countdown`) cannot collide.
    static let word = "cli"

    /// The first argument that makes this process an MCP server over stdio, for the agent that
    /// started it: `claude mcp add soredemo -- <app>/Contents/MacOS/Soredemo mcp`.
    static let mcpWord = "mcp"

    /// Runs and exits when the process was started as `… cli …` or `… mcp`; returns otherwise.
    static func runIfAsked(_ arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
        if arguments.first == mcpWord { serveMCP() }
        guard arguments.first == word else { return }
        let rest = Array(arguments.dropFirst())
        // **A semaphore, on purpose.** This runs inside `App.init`, which is synchronous, and the
        // process has nothing else to do: blocking the main thread until the verb answers is the
        // whole program. The verb's work runs off the main actor, so it cannot wait on this.
        let done = DispatchSemaphore(value: 0)
        let box = OutputBox()
        Task.detached {
            let output = await SurfaceCommand.run(rest, reader: PackageProjectReader(), hearing: WaveformHearing())
            box.answer.withLock { $0 = output }
            done.signal()
        }
        done.wait()
        guard let output = box.answer.withLock({ $0 }) else { exit(70) }  // EX_SOFTWARE: the task ended without an answer
        write(output.stdout, to: .standardOutput)
        write(output.stderr, to: .standardError)
        exit(output.exitCode)
    }

    /// **One line in, at most one line out, until the client closes stdin** — stdio's framing.
    /// Nothing but replies goes to stdout; the one log line goes to stderr, which the protocol
    /// leaves to the server. No port is opened, so only the process that started this one can
    /// reach it.
    private static func serveMCP() -> Never {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let server = MCPServer(reader: PackageProjectReader(), hearing: WaveformHearing(), version: version)
        write("soredemo \(version): MCP over stdio, read-only tools\n", to: .standardError)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            while let line = readLine(strippingNewline: true) {
                guard !line.isEmpty, let reply = await server.handle(line) else { continue }
                write(reply + "\n", to: .standardOutput)
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    /// A closed pipe — `… --json | head -c 1` — is the reader's choice, not an error worth a crash.
    private nonisolated static func write(_ text: String, to handle: FileHandle) {
        guard !text.isEmpty else { return }
        try? handle.write(contentsOf: Data(text.utf8))  // a closed pipe is the reader's choice
    }
}

/// Carries the answer out of the detached task, behind a `Mutex` so it is `Sendable` without an
/// unchecked claim — the semaphore orders the write before the read, and the lock says so to the
/// compiler too.
private nonisolated final class OutputBox: Sendable {
    let answer = Mutex<SurfaceCommand.Output?>(nil)
}
