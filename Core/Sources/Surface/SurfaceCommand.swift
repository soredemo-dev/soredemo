import Foundation
import Framing
import Timeline

/// Runs one call and returns what to print and the exit status — **returned, not printed**, so
/// a test reads exactly what a terminal would see, and the app's entry point is the only place
/// that touches stdout.
public enum SurfaceCommand {
    public struct Output: Equatable, Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
    }

    public static func run(_ arguments: [String], reader: any ProjectReading,
                           hearing: any Hearing) async -> Output {
        let invocation: Invocation
        switch Invocation.parse(arguments) {
        case .success(let parsed): invocation = parsed
        case .failure(let problem):
            // `--json` is honoured even on a call that failed to parse, so an agent that asked
            // for JSON is never handed prose to parse.
            return fail(Failure(code: .usage, message: problem.message), verb: nil,
                        json: arguments.contains("--json"))
        }
        do {
            switch invocation.verb {
            case .verbs: return ok(.verbs, Verbs.listing(), invocation.json, text: Text.verbs)
            case .status:
                return ok(.status, try Verbs.status(try open(invocation, reader), reader: reader),
                          invocation.json, text: Text.status)
            case .steps:
                return ok(.steps, try Verbs.steps(try open(invocation, reader), reader: reader),
                          invocation.json, text: Text.steps)
            case .explainFraming:
                return ok(.explainFraming, try Verbs.framing(try open(invocation, reader), reader: reader),
                          invocation.json, text: Text.framing)
            case .proposeCut:
                let project = try open(invocation, reader)
                let heard = await hearing.heard(in: project)
                return ok(.proposeCut, try Verbs.proposals(project, heard: heard, reader: reader),
                          invocation.json, text: Text.proposals)
            }
        } catch let failure as Failure {
            return fail(failure, verb: invocation.verb, json: invocation.json)
        } catch {
            return fail(Failure(code: .unreadableObservationLog, message: "\(error)"),
                        verb: invocation.verb, json: invocation.json)
        }
    }

    private static func open(_ invocation: Invocation, _ reader: any ProjectReading) throws -> OpenedProject {
        guard let path = invocation.project else {
            throw Failure(code: .usage, message: Invocation.Problem.missingProject(invocation.verb).message)
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
    static func encoded<R>(_ envelope: Envelope<R>) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // An encoding failure here is a programming error in a result type, not a property of
        // the input, and it is reported as one rather than printed as an empty line.
        guard let data = try? encoder.encode(envelope) else {
            preconditionFailure("a Surface result failed to encode: \(R.self)")
        }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func ok<R: Encodable & Sendable>(_ verb: Verb, _ result: R, _ json: Bool,
                                                    text: (R) -> String) -> Output {
        Output(stdout: json ? encoded(Envelope.success(verb, result)) : text(result), stderr: "", exitCode: 0)
    }

    private static func fail(_ failure: Failure, verb: Verb?, json: Bool) -> Output {
        let envelope = Envelope<Nothing>(schemaVersion: Envelope<Nothing>.schemaVersion, verb: verb?.rawValue,
                                         ok: false, result: nil, error: failure)
        // The message goes to stderr in both modes, for the person watching; in JSON mode the
        // envelope also goes to stdout, for the program reading.
        return Output(stdout: json ? encoded(envelope) : "", stderr: failure.message + "\n",
                      exitCode: failure.exitCode)
    }
}

extension Failure: Error {}
