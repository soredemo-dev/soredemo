import Foundation
import Framing
import Timeline

/// Runs one call and returns what to print and the exit status — **returned, not printed**, so
/// a test reads exactly what a terminal would see, and the app's entry point is the only place
/// that touches stdout.
///
/// **`answer` is the one place a verb runs.** The terminal's `run` and the MCP server's
/// `tools/call` both go through it, so the two front ends cannot answer one question differently.
public enum SurfaceCommand {
    public struct Output: Equatable, Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
    }

    /// One verb's answer in every form a front end prints it.
    public struct Answer: Sendable {
        public let verb: Verb
        /// The whole envelope, one line with its newline — what `--json` prints.
        public let envelopeLine: String
        /// The result alone as JSON, or `nil` on failure — what MCP returns as structured content.
        public let resultJSON: String?
        /// The answer for a person — what the terminal prints without `--json`.
        public let text: String
        public let failure: Failure?
    }

    public static func run(_ arguments: [String], reader: any ProjectReading,
                           hearing: any Hearing) async -> Output {
        switch Invocation.parse(arguments) {
        case .failure(let problem):
            // `--json` is honoured even on a call that failed to parse, so an agent that asked
            // for JSON is never handed prose to parse.
            let failure = Failure(code: .usage, message: problem.message)
            return Output(stdout: arguments.contains("--json") ? failureLine(failure, verb: nil) : "",
                          stderr: failure.message + "\n", exitCode: failure.exitCode)
        case .success(let invocation):
            let answer = await answer(invocation.verb, project: invocation.project, reader: reader, hearing: hearing)
            if let failure = answer.failure {
                // The message goes to stderr in both modes, for the person watching; in JSON
                // mode the envelope also goes to stdout, for the program reading.
                return Output(stdout: invocation.json ? answer.envelopeLine : "", stderr: failure.message + "\n",
                              exitCode: failure.exitCode)
            }
            return Output(stdout: invocation.json ? answer.envelopeLine : answer.text, stderr: "", exitCode: 0)
        }
    }

    public static func answer(_ verb: Verb, project: String?, reader: any ProjectReading,
                              hearing: any Hearing) async -> Answer {
        do {
            switch verb {
            case .verbs: return success(.verbs, Verbs.listing(), text: Text.verbs)
            case .status:
                return success(.status, try Verbs.status(try open(verb, project, reader), reader: reader),
                               text: Text.status)
            case .steps:
                return success(.steps, try Verbs.steps(try open(verb, project, reader), reader: reader),
                               text: Text.steps)
            case .explainFraming:
                return success(.explainFraming, try Verbs.framing(try open(verb, project, reader), reader: reader),
                               text: Text.framing)
            case .proposeCut:
                let opened = try open(verb, project, reader)
                let heard = await hearing.heard(in: opened)
                return success(.proposeCut, try Verbs.proposals(opened, heard: heard, reader: reader),
                               text: Text.proposals)
            }
        } catch let failure as Failure {
            return failed(failure, verb: verb)
        } catch {
            return failed(Failure(code: .unreadableObservationLog, message: "\(error)"), verb: verb)
        }
    }

    private static func open(_ verb: Verb, _ path: String?, _ reader: any ProjectReading) throws -> OpenedProject {
        guard let path else {
            throw Failure(code: .usage, message: Invocation.Problem.missingProject(verb).message)
        }
        do {
            return try reader.open(path)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(code: .cannotOpenProject, message: "Could not open \(path): \(error)")
        }
    }

    // MARK: - writing

    /// Sorted keys, so one answer is one byte string — a caller diffing two runs sees a change
    /// only when something changed.
    static func encoded<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // An encoding failure here is a programming error in a result type, not a property of
        // the input, and it is reported as one rather than printed as an empty line.
        guard let data = try? encoder.encode(value) else {
            preconditionFailure("a Surface value failed to encode: \(Value.self)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func success<R: Encodable & Sendable>(_ verb: Verb, _ result: R,
                                                         text: (R) -> String) -> Answer {
        Answer(verb: verb, envelopeLine: encoded(Envelope.success(verb, result)) + "\n",
               resultJSON: encoded(result), text: text(result), failure: nil)
    }

    private static func failed(_ failure: Failure, verb: Verb) -> Answer {
        Answer(verb: verb, envelopeLine: failureLine(failure, verb: verb), resultJSON: nil,
               text: failure.message + "\n", failure: failure)
    }

    private static func failureLine(_ failure: Failure, verb: Verb?) -> String {
        encoded(Envelope<Nothing>(schemaVersion: Envelope<Nothing>.schemaVersion, verb: verb?.rawValue,
                                  ok: false, result: nil, error: failure)) + "\n"
    }
}

extension Failure: Error {}
