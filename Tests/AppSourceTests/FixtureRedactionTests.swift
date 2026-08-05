import Testing
import Foundation
import CheckerLexer

/// **Redaction adjudicated by SCHEMA, not by instance.**
///
/// Enumerating the string fields PRESENT IN THE FILE finds one piece of user data
/// (`AXElementRecord.title`). Enumerating the string fields IN THE SCHEMA finds two,
/// and the second — `KeySample.shortcut` — has zero occurrences in this file (there
/// is no `"kind":"key"` line in `segment-00.jsonl` at all: 251 pointer, 149
/// tapDisabled, 6 button, 3 axChain, 1 header, 1 trailer). A scan of the instance can
/// never find `shortcut`, and the next fixture recorded by someone who used a
/// keyboard shortcut carries their typing into git.
///
/// **This table was filled from the scan's own first-run failure, not transcribed
/// from the task brief's illustrative list.** The brief's sketch named
/// `KeyRecord.shortcut` (the type is `KeySample`, not `KeyRecord`), `kind (×6
/// types)` (the scan finds 8 — `AXChainRecord`, `ButtonEvent`, `KeySample`,
/// `ObservationLogHeader`, `ObservationLogTrailer`, `PointerSample`,
/// `SecureInputInterval`, `TapDisabledInterval` each carry their own `kind: String`),
/// and `epoch.id`, `blindness[]`, `detectedBy`, `disabledBy`, `phase`, `button`,
/// `truncation`, `lowerBoundFrom`, `gapWatches[].site`, `gapWatches[].lostUnit` — none
/// of which the scan reports, because every one of those is typed as an ENUM
/// (`BootEpoch`, `[ObservationBlindness]`, `TapDisableDetection`,
/// `TapDisableReason?`, `ButtonPhase`, `PointerButton`, `ChainTruncation`,
/// `TapBlindWindowLowerBound`, `GapSite`, `GapUnit`) — several of those enums HAVE a
/// `String` raw value, which is exactly the distinction "by schema" exists to draw:
/// the STORED PROPERTY's type is the enum, not `String`, so a value on disk is one of
/// a small closed set of ASCII case names, not open text. That is real, checkable
/// discipline this schema already has, not an oversight the scan is failing to see.
///
/// `stringValuedFieldsInObservationSchema()` walks the whole of `Sources/Project`,
/// not only the observation-log record types, so it also reports
/// `ProjectSnapshot.mediaFilenames` and `MasterSegment.mediaFilename` —
/// `project.json`-manifest and segment-table fields that never appear in an
/// observation log at all. They are adjudicated below anyway: an unadjudicated
/// `String` field is red regardless of which file it would show up in, and scoping
/// the scan tighter than "every record type in the package" would recreate exactly
/// the narrowing this task exists to refuse.
let adjudicatedStringFields: [String: String] = [
    "AXElementRecord.title": "REDACT — user data; UI text (button/window labels) appears in hit, ancestors[], children[]; already legible in the video this log accompanies (ObservationLog's own \"what a record may contain\" section)",
    "KeySample.shortcut": "REDACT — reflects what key combination a person pressed, even filtered to an approved-shortcut identifier by InputObserver; zero occurrences in today's fixture (no \"key\" record is present), which is exactly why an instance scan cannot find it and a schema scan must",
    "AXElementRecord.role": "keep — system AX role constant (e.g. AXButton, AXWindow), not user-authored text",
    "PointerSample.kind": "keep — literal discriminator \"pointer\", never anything else (ObservationRecord.kind)",
    "ButtonEvent.kind": "keep — literal discriminator \"button\"",
    "KeySample.kind": "keep — literal discriminator \"key\" (the type itself is unused in this fixture, but the field is still schema)",
    "SecureInputInterval.kind": "keep — literal discriminator \"secureInput\"",
    "TapDisabledInterval.kind": "keep — literal discriminator \"tapDisabled\"",
    "AXChainRecord.kind": "keep — literal discriminator \"axChain\"",
    "ObservationLogHeader.kind": "keep — literal discriminator \"logHeader\"",
    "ObservationLogTrailer.kind": "keep — literal discriminator \"logTrailer\"",
    "ObservationLogHeader.mediaFilename": "keep — a relative filename minted by ProjectPackageIO/the app (e.g. \"segment-00.mov\"), never typed by a person; the join key between a log and its recording, not content",
    "MasterSegment.mediaFilename": "keep — same app-minted relative filename as above, on SegmentTable's record; not present in this observation log (it lives in project.json), reported because the scan walks all of Sources/Project rather than only the observation-log file",
    "ProjectSnapshot.mediaFilenames": "keep — array of the same app-minted relative filenames, on the project manifest; not present in this observation log at all, reported for the same reason as MasterSegment.mediaFilename above",
]

/// **An unadjudicated string field is red.** Scans every `String`-typed stored
/// property of every record type in `Sources/Project` and compares the set against
/// `adjudicatedStringFields`. A field added without a verdict fails here, before a
/// fixture carrying it can be committed.
@Test func everyStringFieldInTheObservationLogSchemaHasAVerdict() throws {
    let found = try stringValuedFieldsInObservationSchema()
    try #require(!found.isEmpty,
                 "no string fields found in the observation-log schema — the scan would pass vacuously")

    let adjudicated = Set(adjudicatedStringFields.keys)
    #expect(found == adjudicated, """
        the observation-log schema's string fields no longer match the adjudicated set.

        UNADJUDICATED (a field exists with no verdict — decide REDACT or keep, with a reason):
        \(found.subtracting(adjudicated).sorted().joined(separator: "\n  "))

        ADJUDICATED BUT GONE (delete the line; a verdict covering nothing is a verdict that lies):
        \(adjudicated.subtracting(found).sorted().joined(separator: "\n  "))

        The answer is never to widen this scan. A string field with no verdict is user data \
        until someone says otherwise, and the fixture is committed to git.
        """)
}

/// Every `String`-valued stored property of every record type in `Sources/Project`,
/// keyed `Type.field`, read through the code view so a `String` named in a doc
/// comment is not a field.
///
/// A line scan, keyed by the most recent enclosing `struct`/`enum` declaration. The
/// schema is a flat set of record structs — verified by reading `Sources/Project`
/// before this was written — so nesting depth is not a question this has to answer,
/// and if the schema ever grows a nested record the qualified name simply gets the
/// outer type, which is loud rather than silent.
func stringValuedFieldsInObservationSchema() throws -> Set<String> {
    var fields: Set<String> = []
    for file in try swiftFiles(under: "Sources/Project") {
        let text = try String(contentsOf: file, encoding: .utf8)
        var enclosing = ""
        for line in SwiftSourceLexer.codeViewLines(of: text) {
            let words = line.split(whereSeparator: { !SwiftSourceLexer.isIdentifierCharacter($0) })
                .map(String.init)
            if let keywordIndex = words.firstIndex(where: { ["struct", "enum", "class"].contains($0) }),
               keywordIndex + 1 < words.count,
               words.first != "import" {
                enclosing = words[keywordIndex + 1]
                continue
            }
            guard !enclosing.isEmpty,
                  let bindingIndex = words.firstIndex(where: { $0 == "let" || $0 == "var" }),
                  bindingIndex + 1 < words.count else { continue }
            // `name: String`, `name: String?`, `name: [String]` — the type text is
            // whatever follows the colon on this line.
            guard let colon = line.firstIndex(of: ":") else { continue }
            let type = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard type == "String" || type == "String?" || type == "[String]" else { continue }
            fields.insert("\(enclosing).\(words[bindingIndex + 1])")
        }
    }
    return fields
}

/// **Gate 1 — content.** No `title` and no `shortcut` in any committed fixture holds
/// a value other than the placeholder. This exists for the FUTURE: a second fixture,
/// or a re-redaction, when nobody re-checks that the script ran correctly. A leak is
/// red before it is committed.
@Test func noCommittedFixtureCarriesAnUnredactedStringField() throws {
    let redactedFields = adjudicatedStringFields
        .filter { $0.value.hasPrefix("REDACT") }
        .map { String($0.key.split(separator: ".").last!) }
    try #require(!redactedFields.isEmpty, "nothing is marked REDACT — this gate would pass vacuously")

    let fixtures = try FileManager.default.contentsOfDirectory(
        at: repositoryRoot.appending(path: "Tests/HeadlessFixtures"),
        includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "jsonl" }
    try #require(!fixtures.isEmpty, "no committed fixtures found — this gate would pass vacuously")

    for fixture in fixtures {
        let text = try String(contentsOf: fixture, encoding: .utf8)
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            for field in redactedFields {
                // Every occurrence of `"field":"…"` must hold exactly the placeholder.
                var search = line.startIndex..<line.endIndex
                while let key = line.range(of: "\"\(field)\":\"", range: search) {
                    guard let close = line[key.upperBound...].firstIndex(of: "\"") else { break }
                    let value = String(line[key.upperBound..<close])
                    // **Not `#expect(value == "[redacted]", …)`.** Swift Testing's macro
                    // decomposes a `==` expression passed directly to `#expect` and captures
                    // BOTH operands for its own auto-diagnostic — independently of whatever the
                    // trailing message string says. Measured here: the message above never names
                    // `value`, and the framework printed it anyway, as `value → "…"`, under a
                    // synthetic scratch leak used to observe this gate's red. So the boolean is
                    // computed first and `#expect` is handed an already-atomic `Bool` with
                    // nothing left to decompose — the one form that keeps the framework's own
                    // diagnostic machinery from being a second leak path alongside the one the
                    // message text is guarding against.
                    let isRedacted = value == "[redacted]"
                    #expect(isRedacted, """
                        \(fixture.lastPathComponent):\(index + 1) carries an unredacted `\(field)`.
                        Value length \(value.count). The value itself is NOT printed here — printing \
                        it would put the leak in CI logs, which is the same exposure with an audience.
                        Re-run scripts/redact-observation-log.swift before committing.
                        """)
                    search = close..<line.endIndex
                }
            }
        }
    }
}

/// **Gate 2 — consumption.** The render path never reads either field. Scanned
/// through `codeLinesNaming` over `Sources/Headless` and `Sources/Render`, so a
/// mention in a doc comment does not count and a real read does.
@Test func theRenderPathNeverReadsARedactedField() throws {
    let redactedFields = adjudicatedStringFields
        .filter { $0.value.hasPrefix("REDACT") }
        .map { String($0.key.split(separator: ".").last!) }
    let renderFiles = try swiftFiles(under: "Sources/Headless") + swiftFiles(under: "Sources/Render")

    for field in redactedFields {
        let readers = try codeLinesNaming(".\(field)", in: renderFiles)
        #expect(readers.isEmpty, """
            the render path reads `\(field)`, a field the fixture redacts:
            \(readers.map { "  \($0.location): \($0.text)" }.joined(separator: "\n"))
            If the render path needs this value, the fixture cannot be redacted of it and the \
            adjudication changes — not this gate.
            """)
    }
}
