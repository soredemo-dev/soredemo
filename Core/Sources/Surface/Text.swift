import Foundation

/// The same answers, for a person at a terminal: one record per line, nothing wrapped, so `grep`
/// and `cut` work on it too. English only — this is a developer's surface, like `--help` text.
enum Text {
    /// Tenths of a second, rounded half away from zero, in integers — `String(format:)` is a
    /// C variadic and this package admits no unsafe construct.
    static func seconds(_ nanos: Int64) -> String {
        let tenths = (abs(nanos) + 50_000_000) / 100_000_000
        return (nanos < 0 ? "-" : "") + "\(tenths / 10).\(tenths % 10)s"
    }

    static func span(_ span: TimeSpan) -> String { "\(seconds(span.startNanos))–\(seconds(span.endNanos))" }

    static func verbs(_ result: VerbsResult) -> String {
        let width = result.verbs.map(\.usage.count).max() ?? 0
        let rows = result.verbs.map { row in
            row.usage.padding(toLength: width, withPad: " ", startingAt: 0) + "  [\(row.kind.rawValue)] \(row.summary)"
        }
        return (rows + ["", result.note]).joined(separator: "\n") + "\n"
    }

    static func status(_ s: StatusResult) -> String {
        var lines = ["project  \(s.project)", "media    \(s.media)"]
        guard let log = s.observationLog, let duration = s.durationNanos else {
            lines.append("log      none — recorded without an observation log")
            return lines.joined(separator: "\n") + "\n"
        }
        lines.append("log      \(log)")
        lines.append("length   \(seconds(duration)) (from the log's trailer)")
        if let output = s.outputDurationNanos { lines.append("edited   \(s.edited ? "yes" : "no"), plays \(seconds(output))") }
        if let steps = s.steps { lines.append("steps    \(steps)") }
        if let clicks = s.clicks, let framed = s.framedClicks { lines.append("clicks   \(clicks), \(framed) framed") }
        if let p = s.proposals {
            lines.append("cuts     \(p.pending) pending, \(p.alreadyCut) already cut, \(p.dismissed) kept (audio not read; propose-cut reads it)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func steps(_ result: StepsResult) -> String {
        guard !result.steps.isEmpty else { return "No steps: nothing named was pressed.\n" }
        return result.steps.map { row in
            "\(row.number)\t\(span(row.span))\t\(row.label)\t\(row.application ?? "—")"
        }.joined(separator: "\n") + "\n"
    }

    static func framing(_ result: FramingResult) -> String {
        let rows = result.clicks.map { row in
            "\(seconds(row.atNanos))\t" + (row.framed ? "framed \(row.role ?? "")" : "refused: \(row.refusedBecause ?? "")")
        }
        return (rows + ["\(result.framed) framed, \(result.refused) refused"]).joined(separator: "\n") + "\n"
    }

    static func proposals(_ result: ProposalsResult) -> String {
        func name(_ bound: ProposalsResult.Bound) -> String {
            bound.step.map { "step \($0)" } ?? bound.kind
        }
        let rows = result.proposals.map { row in
            "cut \(span(row.removes))\tquiet \(seconds(row.quiet.endNanos - row.quiet.startNanos))\t"
                + "after \(name(row.openedBy)), until \(name(row.closedBy))"
                + (row.survival == "partly" ? "\t(partly cut already)" : "")
        }
        let summary = "\(result.proposals.count) proposed, \(result.alreadyCut) already cut, \(result.dismissed) kept. Nothing was applied: accept cuts in the editor's Cuts tab."
        return (rows + [summary, result.hearingNote]).joined(separator: "\n") + "\n"
    }
}
