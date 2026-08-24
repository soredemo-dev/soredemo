// Redacts an observation-log `.jsonl` for commit as a test fixture.
//
// **What it redacts, field by field, and why.**
//
//   * `title` (`AXElementRecord.title`) — REDACT. UI text: button labels, window
//     titles, whatever `kAXTitleAttribute` answered with for the element under a
//     click, or one of its ancestors or children. `ObservationLog`'s own schema
//     doc says a record MAY carry this (it is already legible in the recording's
//     video, and it is what makes "the Save button" identifiable in derivation) —
//     but that is a rule about what the CAPTURE PATH may write, not about what a
//     fixture checked into a public git history may carry, and the two questions
//     get different answers here.
//   * `shortcut` (`KeySample.shortcut`) — KEEP, re-adjudicated 2026-08-25 from
//     REDACT. The identifier of an approved keyboard shortcut (⌘C, ⇧⌘Z), which
//     `InputObserver` filters through an allow-list before it is ever written —
//     never a typed character. It was redacted "on principle" while nothing read
//     it; the keystroke badges now draw exactly this value, and a fixture stripped
//     of it could not exercise them. The allow-list is the redaction.
//
// This list is adjudicated once, by schema rather than by instance, in
// `Tests/AppSourceTests/FixtureRedactionTests.swift`'s `adjudicatedStringFields` —
// see that file for the full table (14 string-valued fields in `Sources/Project`,
// of which `title` is the observation-log `REDACT` verdict) and for
// `everyStringFieldInTheObservationLogSchemaHasAVerdict`, which fails the build the
// day a fifteenth field appears with no verdict attached. **The two lists —
// `redactedFields` below and the `REDACT` rows of that table — are kept in step by
// hand**, because this file cannot import a test target's `let`. Nothing but
// review holds them together; if they drift, `noCommittedFixtureCarriesAn
// UnredactedStringField` (that same test file, Gate 1) is the backstop that
// catches a fixture carrying real text under a field this script stopped touching.
//
// **Nothing the compositor consumes is touched.** Every timestamp
// (`instant`, `readInterval`, `hitTestInterval`, `interval`, `hostRange`, the
// `anchor`), every coordinate (`position`, `clickPosition`, `hitTestGlobalX/Y`,
// every `frame`), the boot epoch, the geometry revision, and all 149
// `tapDisabled` intervals in this fixture are left byte-for-byte the values the
// real writer recorded through the real capture path — that is the entire reason
// this fixture is worth having over a constructed one (see the task report). This
// script never parses the document into records and re-encodes it: it walks the
// raw bytes and rewrites only the value spans of the two field names above,
// leaving every other byte — punctuation, key order, number formatting, all of
// it — untouched. A JSON round-trip through `Codable` could not make that
// promise (floating-point re-encoding is not guaranteed byte-identical), which is
// why this is a text transform and not a decode/re-encode.
//
// **The reproducibility cost, stated honestly.** Reproducing this exact run needs
// the unredacted original — `~/soredemo-evidence/row14/…/segment-00.jsonl` — which
// exists only on the machine that recorded it and is never committed. **This
// redaction is auditable by its author and not by its readers.** A future reader
// of the committed fixture can verify the NEGATIVE — that no `title` value in the
// committed file is anything but the placeholder; Gate 1
// in `FixtureRedactionTests.swift` does exactly that, mechanically, forever. What
// a reader cannot do is verify that the right things were removed and nothing
// else was — that the diff against the original really is empty outside the
// redacted field — because the original is not there to diff against. That is a
// known, accepted cost of choosing a recorded fixture (half its value is that it
// is dirty: 149 tap-disabled windows, an `accessibilityUnavailable` flip, two
// different blind rates in one session — a constructed fixture would not have
// any of that) over a synthetic one, and it is written down here because an
// unwritten cost reads as a zero cost, and this one is not zero.
//
// Usage: `swift scripts/redact-observation-log.swift <path-to.jsonl> > out.jsonl`
// or pipe the input on stdin: `cat segment-00.jsonl | swift
// scripts/redact-observation-log.swift > out.jsonl`. Byte count in should equal
// byte count out, minus/plus exactly `(originalValueLength - 10) ×
// occurrenceCount` per redacted field — `[redacted]` is 10 bytes — and line count
// in must equal line count out, because this transform never touches a `\n`.

import Foundation

/// Kept in step BY HAND with the `REDACT` rows of `adjudicatedStringFields` in
/// `Tests/AppSourceTests/FixtureRedactionTests.swift` — see the header above.
let redactedFields = ["title"]
let placeholder = "[redacted]"

/// Rewrites every `"field":"…"` value for `field` in `redactedFields` to the
/// placeholder, walking the text once and copying everything else through
/// unchanged. JSON-escape-aware (`\"` does not end the value, `\\` does not
/// escape the character after it twice), so a title containing a literal quote
/// or backslash is still found and fully replaced rather than leaving a
/// fragment of itself behind.
func redact(_ text: String) -> String {
    let chars = Array(text)
    var result = ""
    result.reserveCapacity(chars.count)
    var i = 0

    while i < chars.count {
        var matched: String?
        for field in redactedFields {
            let needle = Array("\"\(field)\":\"")
            guard i + needle.count <= chars.count else { continue }
            if Array(chars[i..<(i + needle.count)]) == needle {
                matched = field
                break
            }
        }

        guard let field = matched else {
            result.append(chars[i])
            i += 1
            continue
        }

        let needle = "\"\(field)\":\""
        result += needle + placeholder + "\""
        i += needle.count

        // Skip the original value, honouring `\`-escapes, up to and including
        // the terminating unescaped quote — which is dropped, since the
        // placeholder's own closing quote was already appended above.
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

let input: String
if CommandLine.arguments.count > 1 {
    input = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
} else {
    input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

FileHandle.standardOutput.write(Data(redact(input).utf8))
