import Testing
import Foundation
import CheckerLexer

/// Redaction adjudicated by SCHEMA, not by instance: a field with zero occurrences in today's
/// fixture (`KeySample.shortcut` had none when this was written) can only be found by a schema
/// scan. Every `String` field and every `String`-carrying enum case under `Sources/Project`
/// needs a verdict here.
let adjudicatedStringFields: [String: String] = [
    "AXElementRecord.title": "REDACT — user data; UI text (button/window labels) appears in hit, ancestors[], children[]; already legible in the video this log accompanies (ObservationLog's own \"what a record may contain\" section)",
    "KeySample.shortcut": "keep — RE-ADJUDICATED 2026-08-25, from REDACT. An identifier from InputObserver.approvedShortcuts (⌘C, ⇧⌘Z), never a typed character: the allow-list is the redaction, applied before the value is written. It was marked REDACT \"on principle\" while nothing read it; the keystroke badges (KeystrokeTrack, design audit item 3) draw exactly this value, and Gate 2's own message says what happens then — the fixture cannot be redacted of a value the render path needs, so the adjudication changes, not the gate. A fixture that carries a key record must therefore show the identifier, which is what a badge test needs it to",
    "SegmentBoundary.failed": "REDACT — carries String(describing: error) from CaptureSession.stream(_:didStopWithError:); AVFoundation/ScreenCaptureKit error descriptions routinely embed a file URL (home path, username, package name). Persisted via MasterSegment.endedBy into project.json, NOT into an observation log — this case cannot appear in Tests/HeadlessFixtures/*.jsonl (the observation-log wire format), so Gate 1 below is scoped to a format this field structurally cannot reach. Note for the day a project.json fixture is ever committed: the JSON key that would actually carry the leak is the associated value's own label, \"reason\", not the case name \"failed\" — Swift's synthesised Codable for an associated-value case encodes {\"failed\":{\"reason\":\"…\"}}, a nested object, so a future gate over that format must key on \"reason\", not on this entry's own case name",
    "SegmentBoundary.interrupted": "keep — a closed vocabulary, not an error description. Unlike SegmentBoundary.failed above, which carries String(describing: error) and therefore whatever path AVFoundation put in it, this case is only ever given StreamStopReason.description: fixed English built by that type from its own case, plus an integer SCStreamError code, plus — in the .unrecognised case alone — an NSError DOMAIN, which is a reverse-DNS identifier and not a message. The closure is what makes this verdict true rather than hoped, so theInterruptedBoundaryCarriesNoUserData pins it: every case of StreamStopReason is asked for its description against an error whose own description is nothing but a home path, and none of them repeat it. Change that closure and the test fails before the fixture does",
    "StillInterval.kind": "keep — literal discriminator \"still\", and the only String this record has. StillInterval.init(from:) refuses any other value rather than carrying it, so unlike a free-text field this one cannot arrive holding something a producer did not write",
    "AXElementRecord.role": "keep — system AX role constant (e.g. AXButton, AXWindow), not user-authored text",
    "PointerSample.kind": "keep — literal discriminator \"pointer\", never anything else (ObservationRecord.kind)",
    "ButtonEvent.kind": "keep — literal discriminator \"button\"",
    "KeySample.kind": "keep — literal discriminator \"key\" (the type itself is unused in this fixture, but the field is still schema)",
    "SecureInputInterval.kind": "keep — literal discriminator \"secureInput\"",
    "TapDisabledInterval.kind": "keep — literal discriminator \"tapDisabled\"",
    "AXChainRecord.kind": "keep — literal discriminator \"axChain\"",
    "ContentCropSample.kind": "keep — literal discriminator \"contentCrop\". Like StillInterval.kind, ContentCropSample.init(from:) refuses any other value rather than carrying it. The record's other fields are a CropRect (four fractions of the capture buffer) and a Double; it describes where ScreenCaptureKit drew, never what was drawn, so there is nothing in it that could be about a person",
    "ObservationLogHeader.kind": "keep — literal discriminator \"logHeader\"",
    "ObservationLogTrailer.kind": "keep — literal discriminator \"logTrailer\"",
    "KindOnly.kind": "keep — ObservationLog.kind(of:)'s private decode-only helper, reading the same \"kind\" discriminator wire field as the ten entries above; not a second field, a second reader of the same one",
    "ObservationLogHeader.mediaFilename": "keep — a relative filename minted by ProjectPackageIO/the app (e.g. \"segment-00.mov\"), never typed by a person; the join key between a log and its recording, not content",
    "MasterSegment.mediaFilename": "keep — same app-minted relative filename as above, on SegmentTable's record; not present in this observation log (it lives in project.json), reported because the scan walks all of Sources/Project rather than only the observation-log file",
    "ProjectSnapshot.mediaFilenames": "keep — array of the same app-minted relative filenames, on the project manifest; not present in this observation log at all, reported for the same reason as MasterSegment.mediaFilename above",
    "ObservationLogError.foreignEpoch": "keep — ObservationLogError conforms to Error, Equatable only, never Codable; never serialised, never persisted, cannot reach a committed fixture",
    "ObservationLogError.noEpoch": "keep — same type, same reason as ObservationLogError.foreignEpoch above",
    "ProjectFormatError.malformed": "keep — ProjectFormatError conforms to Error, Equatable only, never Codable; never serialised, never persisted, cannot reach a committed fixture",
    "ProjectFormatError.sidecarAlreadyExists": "keep — same type, same reason as ProjectFormatError.malformed above",
    "ProjectFormatError.invalidSidecarName": "keep — same type, same reason as ProjectFormatError.malformed above",
    "ProjectFormatError.mediaIsNotAFile": "keep — same type, same reason as ProjectFormatError.malformed above",
    "ProjectFormatError.severalLogsNameOneMedia": "keep — same type, same reason as ProjectFormatError.malformed above; it carries a media filename and log filenames this app minted, never anything a person typed or a screen showed",
    "Failure.notText": "keep — EvidenceRedaction.Failure, Error and Equatable only, never Codable; it carries the name of a log file this app minted (segment-NN.jsonl), not anything a person typed or a screen showed",
    "EditState.cameraPace": "keep — one of CameraPace's raw values (\"gentle\", \"standard\", \"snappy\"), chosen from a fixed list in a picker and never typed; the app resolves it with CameraPace(rawValue:) and treats anything else as standard, so a person cannot put anything else in it that is used",
    "Item.pictureText": "REDACT — Library.Item: text read off a screenshot by on-device recognition when it was added (docs/design/2026-11-13-the-library.md). A screenshot shows whatever was on screen, an email or a client's name among it; EvidenceRedaction.redactLibrary drops it from a sharing copy, as AXElementRecord.title is dropped from its logs. Read only by the agent's search, never by the render path",
    "Origin.imported": "REDACT — Library.Origin: the original name of a file a person added, which can carry their own or a client's name. Not needed to find the file (Item.filename is), so a sharing copy keeps the case and empties the name — EvidenceRedaction.redactLibrary",
    "Origin.web": "keep — Library.Origin: the host of a public site a picture was fetched from by import_image, which only fetches public https sites by name (ImageImport.refusal). Where a picture came from is worth a viewer being able to check",
    "Item.filename": "keep — Library.Item: the file's name inside the package's library folder, made safe (letters, digits, -, _) by the app; it is how the file is found, and the file itself travels in the package beside it, as a background's or a picture's does",
    "Item.name": "keep — Library.Item: the name a person sees for a file they chose to add, its own file name's stem; it names a file the package contains, as Item.filename does",
    "Field.text": "keep — LibraryIndexEntry.Field's index text, built in memory for a search when the agent asks; LibraryIndexEntry is not Codable, never written, cannot reach a committed fixture",
    "Refusal.negative": "keep — Library.Refusal, Error and Equatable only, never Codable; it carries the name of a field, a constant in this file",
    "Refusal.unsafeName": "keep — Library.Refusal, never Codable; it carries the refused file name back to the caller that tried it, which is the person's own import, and is never persisted",
    "EditState.outputShapeName": "keep — one of AspectVariant's own names (\"Landscape\", \"Portrait\", \"Square\"), chosen from a fixed list in a picker and never typed. Stored as the NAME rather than as dimensions so a project made before a shape was retuned opens with the current one; a person cannot put anything else in it, and the decoder resolves it against AspectVariant.all rather than trusting the string",
]

/// **An unadjudicated string field is red.** Scans every `String` stored property and every
/// `String`-carrying enum case in `Sources/Project` against `adjudicatedStringFields`, so a
/// field added without a verdict fails here rather than in a committed fixture.
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

/// Every `String`-valued stored property and `String`-carrying enum-case associated value
/// under `Sources/Project`, keyed `Type.field`/`Type.caseName`, read through the code view.
/// One-line declarations (`struct KindOnly: Decodable { let kind: String }`) are scanned too.
func stringValuedFieldsInObservationSchema() throws -> Set<String> {
    try classifiedStringFieldsInObservationSchema().all
}

/// The subset of the walk's keys that are associated-value ENUM CASES, so Gate 2 can demand a
/// stricter needle without a hand-maintained literal naming which entry that is.
func stringValuedCaseFieldsInObservationSchema() throws -> Set<String> {
    try classifiedStringFieldsInObservationSchema().caseFields
}

/// The single walk both functions above read from, so the case/property split is computed once.
private func classifiedStringFieldsInObservationSchema() throws -> (all: Set<String>, caseFields: Set<String>) {
    var fields: Set<String> = []
    var caseFields: Set<String> = []
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
                if let brace = line.firstIndex(of: "{") {
                    let end = line.lastIndex(of: "}") ?? line.endIndex
                    let afterBrace = line.index(after: brace)
                    if afterBrace <= end {
                        let body = String(line[afterBrace..<end])
                        if let field = stringPropertyField(in: body, enclosing: enclosing) { fields.insert(field) }
                        if let caseField = stringCaseField(in: body, enclosing: enclosing) {
                            fields.insert(caseField); caseFields.insert(caseField)
                        }
                    }
                }
                continue
            }
            if let field = stringPropertyField(in: line, enclosing: enclosing) { fields.insert(field) }
            if let caseField = stringCaseField(in: line, enclosing: enclosing) {
                fields.insert(caseField); caseFields.insert(caseField)
            }
        }
    }
    return (all: fields, caseFields: caseFields)
}

/// `name: String`, `name: String?`, `name: [String]` as a `let`/`var` stored property of
/// `enclosing`, on one (sub)line. Known misses, none present in this schema today: an inline
/// initial value, a composite such as `[String: String]`, two bindings sharing a line.
func stringPropertyField(in text: String, enclosing: String) -> String? {
    guard !enclosing.isEmpty else { return nil }
    let words = text.split(whereSeparator: { !SwiftSourceLexer.isIdentifierCharacter($0) })
        .map(String.init)
    guard let bindingIndex = words.firstIndex(where: { $0 == "let" || $0 == "var" }),
          bindingIndex + 1 < words.count else { return nil }
    guard let colon = text.firstIndex(of: ":") else { return nil }
    let type = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    guard type == "String" || type == "String?" || type == "[String]" else { return nil }
    return "\(enclosing).\(words[bindingIndex + 1])"
}

/// `case name(…, label: String, …)` — an enum case carrying a `String`/`String?`/`[String]`
/// associated value, reported as `Type.caseName`. A dotted name is refused so a `switch`
/// pattern is never read as a declaration; one case declaration per line is assumed.
func stringCaseField(in text: String, enclosing: String) -> String? {
    guard !enclosing.isEmpty else { return nil }
    let words = text.split(whereSeparator: { !SwiftSourceLexer.isIdentifierCharacter($0) })
        .map(String.init)
    guard words.first == "case", words.count > 1 else { return nil }
    let caseName = words[1]
    guard !caseName.hasPrefix(".") else { return nil }
    guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return nil }

    var depth = 0
    var current = ""
    var parts: [String] = []
    for ch in text[text.index(after: open)..<close] {
        switch ch {
        case "(", "[", "<": depth += 1; current.append(ch)
        case ")", "]", ">": depth -= 1; current.append(ch)
        case "," where depth == 0: parts.append(current); current = ""
        default: current.append(ch)
        }
    }
    parts.append(current)

    for part in parts {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        let type: String
        if let colon = trimmed.firstIndex(of: ":") {
            type = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        } else {
            type = trimmed
        }
        if type == "String" || type == "String?" || type == "[String]" {
            return "\(enclosing).\(caseName)"
        }
    }
    return nil
}

/// Every committed `.jsonl` fixture anywhere under `Tests/` — the whole tree, not only
/// `Tests/HeadlessFixtures`, so no fixture location falls outside Gate 1's reach.
func committedJSONLFixtures() throws -> [URL] {
    let root = packageRoot.appending(path: "Tests")
    let enumerator = try #require(
        FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
        "cannot enumerate Tests/ — it must exist for this scan to mean anything")
    var files: [URL] = []
    while let url = enumerator.nextObject() as? URL {
        if url.pathExtension == "jsonl" { files.append(url) }
    }
    return files.sorted { $0.path < $1.path }
}

/// Every `String` value found anywhere in a decoded JSON value's tree, under a
/// Every `String` under a key in `fieldNames`, anywhere in a decoded JSON tree.
/// Structural, not textual: a substring scan for a `"field":"` byte sequence would share the
/// encoder-output assumption of the script that wrote the fixture, and pass green if it changed.
func stringValues(named fieldNames: Set<String>, in json: Any) -> [String] {
    var found: [String] = []
    switch json {
    case let dict as [String: Any]:
        for (key, value) in dict {
            if fieldNames.contains(key), let s = value as? String { found.append(s) }
            found += stringValues(named: fieldNames, in: value)
        }
    case let array as [Any]:
        for item in array { found += stringValues(named: fieldNames, in: item) }
    default:
        break
    }
    return found
}

/// Committed `.jsonl` fixtures that are not observation logs, each with what it is. The gate
/// below checks they carry no observation record at all before it skips them.
let fixturesThatAreNotObservationLogs: [String: String] = [
    "claude-code-2.1.318-steps.jsonl": "a recorded Claude Code stream-json session for SurfaceTests' parser, with personal paths replaced and the owner's own configuration (skills, plugins, usage) removed before it was committed",
    "codex-0.167.0-steps.jsonl": "a recorded `codex app-server` JSON-RPC session for SurfaceTests' CodexSession, both directions, with personal paths replaced and the account, usage and moderation lines removed before it was committed",
]

/// **Gate 1 — content.** No `REDACT`-marked field in any committed fixture holds a value other
/// than the placeholder. The vacuity guard is per fixture, summed across every redacted field,
/// so a REDACT field with no occurrence in a fixture cannot fail the guard on its own.
@Test func noCommittedFixtureCarriesAnUnredactedStringField() throws {
    let redactedFields = Set(adjudicatedStringFields
        .filter { $0.value.hasPrefix("REDACT") }
        .map { String($0.key.split(separator: ".").last!) })
    try #require(!redactedFields.isEmpty, "nothing is marked REDACT — this gate would pass vacuously")

    let fixtures = try committedJSONLFixtures()
    try #require(!fixtures.isEmpty, "no committed fixtures found — this gate would pass vacuously")

    for fixture in fixtures {
        let text = try String(contentsOf: fixture, encoding: .utf8)
        // `components(separatedBy:)`, not `split(omittingEmptySubsequences:)` — the latter
        // shifts every reported line number past any blank line.
        let lines = text.components(separatedBy: "\n")
        // A fixture that is not an observation log has none of its fields, so this gate has
        // nothing in it to examine. **Proved, not asserted**: it must carry no observation
        // record's `kind` at all, or it is an observation log under a misleading name.
        if let reason = fixturesThatAreNotObservationLogs[fixture.lastPathComponent] {
            let kinds = lines.filter { line in
                (line.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["kind"] != nil
            }
            #expect(kinds.isEmpty, "\(fixture.lastPathComponent) is exempt as \"\(reason)\", but \(kinds.count) line(s) carry an observation record's kind")
            continue
        }
        var occurrencesInThisFixture = 0

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // A line that does not parse as one JSON object is skipped, not failed — correct
            // for JSONLReader's truncated tail; the vacuity guard below is the backstop.
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }

            let values = stringValues(named: redactedFields, in: json)
            occurrencesInThisFixture += values.count
            let unredacted = values.filter { $0 != "[redacted]" }
            let isFullyRedacted = unredacted.isEmpty
            #expect(isFullyRedacted, """
                \(fixture.lastPathComponent):\(index + 1) carries \(unredacted.count) unredacted \
                value(s) among {\(redactedFields.sorted().joined(separator: ", "))}.
                Value length(s): \(unredacted.map { String($0.count) }.joined(separator: ", ")). The \
                value itself is NOT printed here — printing it would put the leak in CI logs, which \
                is the same exposure with an audience.
                Re-run scripts/redact-observation-log.swift before committing.
                """)
        }

        let examinedSomething = occurrencesInThisFixture > 0
        #expect(examinedSomething, """
            \(fixture.lastPathComponent): this gate found \(occurrencesInThisFixture) occurrence(s) \
            of {\(redactedFields.sorted().joined(separator: ", "))} in the whole file — it has not \
            actually examined anything in this fixture, and a check that examines nothing is not a \
            pass. Either this fixture genuinely carries none of these fields (confirm by eye and \
            state why in this test), or something about its shape defeated the JSON walk above \
            (every line failed to parse, or every value that WAS a redacted field's value was itself \
            not a String) — in which case this gate has been passing over unchecked content.
            """)
    }
}

// **The twelve-entry exclusion list that stood here is DELETED (Phase 3A-4).** It existed
// only to say "the render half of `Headless`" after a producer moved into a target whose
// name had been a proxy for a tier. `Headless` is now two targets, so Gate 2 names the one
// it means and the list — plus the `#require`-every-entry-exists machinery that guarded it
// against stale entries — has nothing left to do. A list that stops being needed is a
// better outcome than a list kept correct.

/// **Gate 2 — consumption.** The render path never reads a `REDACT`-marked field, scanned
/// through the code view over `Sources/Compositing` and `Sources/Render` — the two targets
/// that CONSUME evidence. `Sources/Capture` produces it and is not scanned: `AXObserver`
/// reads `.title` because it is the code that captures one, which is the whole reason the
/// old directory-wide scan went red when capture moved in.
@Test func theRenderPathNeverReadsARedactedField() throws {
    let redactedEntries = adjudicatedStringFields.filter { $0.value.hasPrefix("REDACT") }
    let caseKeys = try stringValuedCaseFieldsInObservationSchema()
    let renderFiles = try swiftFiles(under: "Sources/Compositing")
        + (try swiftFiles(under: "Sources/Render"))
    try #require(!renderFiles.isEmpty,
                 "no consumer sources found — this gate would pass vacuously")

    for (key, _) in redactedEntries {
        let field = String(key.split(separator: ".").last!)
        let needle = caseKeys.contains(key) ? ".\(field)(" : ".\(field)"
        let readers = try codeLinesNaming(needle, in: renderFiles)
        #expect(readers.isEmpty, """
            the render path reads `\(field)`, a field the fixture redacts:
            \(readers.map { "  \($0.location): \($0.text)" }.joined(separator: "\n"))
            If the render path needs this value, the fixture cannot be redacted of it and the \
            adjudication changes — not this gate.
            """)
    }
}
