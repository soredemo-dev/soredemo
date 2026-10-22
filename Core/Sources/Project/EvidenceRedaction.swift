import Foundation

/// The observation log with the words on the screen taken out, for a project somebody shares.
///
/// **The log keeps the accessibility title under every click** — a window's name, a button's
/// label, sometimes an e-mail's subject or a document's name. That is what makes "the Save
/// button" identifiable to the editor, and it is a surprise in a file somebody sends on (audit
/// R5). Every `"title"` value becomes `[redacted]`; roles, positions and times stay, so the copy
/// still draws its cursor and still zooms.
///
/// **A text transform, not a decode and re-encode**, for `scripts/redact-observation-log.swift`'s
/// reason: re-encoding is not byte-identical (floating-point, key order), and a redaction should
/// change the redacted values and nothing else. The two agree — `EvidenceRedactionTests` checks
/// that the fixture the script wrote is a fixed point here.
public enum EvidenceRedaction {
    /// Field names whose string values are replaced. Kept in step with the `REDACT` rows of
    /// `FixtureRedactionTests.adjudicatedStringFields` that reach an observation log.
    public static let redactedFields = ["title"]
    public static let placeholder = "[redacted]"

    public enum Failure: Error, Equatable {
        /// A log that is not text cannot be searched for titles, so it cannot be shared as
        /// redacted. **Refused, never skipped**: skipping it would hand on the very thing the
        /// person asked to leave out, under a status that said it had been.
        case notText(String)
    }

    /// Rewrites every `"field":"…"` for the redacted fields, escape-aware: `\"` does not end a
    /// value and `\\` does not escape the character after it twice, so a title holding a quote or
    /// a backslash is replaced whole rather than leaving part of itself behind.
    public static func redacted(_ text: String) -> String {
        let chars = Array(text)
        var result = ""
        result.reserveCapacity(chars.count)
        let needles = redactedFields.map { (field: $0, chars: Array("\"\($0)\":\"")) }
        var i = 0
        while i < chars.count {
            guard let needle = needles.first(where: { needle in
                i + needle.chars.count <= chars.count
                    && chars[i..<(i + needle.chars.count)].elementsEqual(needle.chars)
            }) else {
                result.append(chars[i])
                i += 1
                continue
            }
            result += "\"\(needle.field)\":\"\(placeholder)\""
            i += needle.chars.count
            var escaped = false
            while i < chars.count {
                let c = chars[i]
                i += 1
                if escaped { escaped = false; continue }
                if c == "\\" { escaped = true; continue }
                if c == "\"" { break }
            }
        }
        return result
    }

    /// Redacts every `observations/*.jsonl` in a package, in place, and says how many it rewrote.
    /// Only the evidence: `project.json` is the person's own edit, captions and titles they wrote.
    /// Each log is read through `BoundedRead`, as everything from a package is.
    public static func redactObservations(in packageURL: URL) throws -> Int {
        let folder = packageURL.appending(path: "observations", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: folder.path) else { return 0 }
        var rewritten = 0
        for entry in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        where entry.pathExtension == "jsonl" {
            let data = try BoundedRead.data(at: entry, limit: BoundedRead.observationLogLimit)
            guard let text = String(data: data, encoding: .utf8) else {
                throw Failure.notText(entry.lastPathComponent)
            }
            try Data(redacted(text).utf8).write(to: entry, options: .atomic)
            rewritten += 1
        }
        return rewritten
    }
}
