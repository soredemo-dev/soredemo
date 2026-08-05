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
/// types)` (the scan finds 8 stored-property `kind`s — `AXChainRecord`,
/// `ButtonEvent`, `KeySample`, `ObservationLogHeader`, `ObservationLogTrailer`,
/// `PointerSample`, `SecureInputInterval`, `TapDisabledInterval` each carry their
/// own `kind: String`), and `epoch.id`, `blindness[]`, `detectedBy`, `disabledBy`,
/// `phase`, `button`, `truncation`, `lowerBoundFrom`, `gapWatches[].site`,
/// `gapWatches[].lostUnit` — none of which the scan reports, because every one of
/// those is a STORED PROPERTY typed as an ENUM (`BootEpoch`,
/// `[ObservationBlindness]`, `TapDisableDetection`, `TapDisableReason?`,
/// `ButtonPhase`, `PointerButton`, `ChainTruncation`, `TapBlindWindowLowerBound`,
/// `GapSite`, `GapUnit`).
///
/// **That "typed as an enum" claim needs a narrower defence than the first version
/// of this comment gave it, and review round 1 is why.** Several of those enums
/// have a `String` RAW value, and for those the closure argument holds exactly:
/// Swift forbids associated values on a raw-value enum, so `GapSite`,
/// `TapDisableReason`, `ButtonPhase` and the rest really are a small, fixed,
/// ASCII case-name set — real discipline this schema already has, not an
/// oversight. But an enum case with a `String` ASSOCIATED value is not closed at
/// all, and the scan below was silent about it until this round: `SegmentBoundary
/// .failed(reason: String)` — `Codable`, `Sendable`, persisted via
/// `MasterSegment.endedBy` — is exactly that shape, and its one producer
/// (`CaptureSession.stream(_:didStopWithError:)`) writes `String(describing:
/// error)` into it, which for AVFoundation/ScreenCaptureKit errors routinely
/// embeds a file URL: home path, username, package name. The scan now reports
/// `Type.caseName` for any enum case carrying a `String`/`String?`/`[String]`
/// associated value, alongside `Type.field` for stored properties, and every one
/// found is adjudicated below — including three `ProjectFormatError` cases and two
/// `ObservationLogError` cases that are `Error` types, never `Codable`, never
/// persisted, and so cannot reach a committed fixture regardless.
///
/// `stringValuedFieldsInObservationSchema()` walks the whole of `Sources/Project`,
/// not only the observation-log record types, so it also reports
/// `ProjectSnapshot.mediaFilenames` and `MasterSegment.mediaFilename` —
/// `project.json`-manifest and segment-table fields that never appear in an
/// observation log at all — and, as of this round, `KindOnly.kind`, a private
/// decode-only helper struct inside `ObservationLog.kind(of:)` that was previously
/// invisible to the scan because its declaration and its one stored property share
/// a line (see that function's doc comment below for why). They are adjudicated
/// below anyway: an unadjudicated `String` field is red regardless of which file
/// it would show up in, and scoping the scan tighter than "every record type in
/// the package" would recreate exactly the narrowing this task exists to refuse.
let adjudicatedStringFields: [String: String] = [
    "AXElementRecord.title": "REDACT — user data; UI text (button/window labels) appears in hit, ancestors[], children[]; already legible in the video this log accompanies (ObservationLog's own \"what a record may contain\" section)",
    "KeySample.shortcut": "REDACT — reflects what key combination a person pressed, even filtered to an approved-shortcut identifier by InputObserver; zero occurrences in today's fixture (no \"key\" record is present), which is exactly why an instance scan cannot find it and a schema scan must",
    "SegmentBoundary.failed": "REDACT — carries String(describing: error) from CaptureSession.stream(_:didStopWithError:); AVFoundation/ScreenCaptureKit error descriptions routinely embed a file URL (home path, username, package name). Persisted via MasterSegment.endedBy into project.json, NOT into an observation log — this case cannot appear in Tests/HeadlessFixtures/*.jsonl (the observation-log wire format), so Gate 1 below is scoped to a format this field structurally cannot reach. Note for the day a project.json fixture is ever committed: the JSON key that would actually carry the leak is the associated value's own label, \"reason\", not the case name \"failed\" — Swift's synthesised Codable for an associated-value case encodes {\"failed\":{\"reason\":\"…\"}}, a nested object, so a future gate over that format must key on \"reason\", not on this entry's own case name",
    "AXElementRecord.role": "keep — system AX role constant (e.g. AXButton, AXWindow), not user-authored text",
    "PointerSample.kind": "keep — literal discriminator \"pointer\", never anything else (ObservationRecord.kind)",
    "ButtonEvent.kind": "keep — literal discriminator \"button\"",
    "KeySample.kind": "keep — literal discriminator \"key\" (the type itself is unused in this fixture, but the field is still schema)",
    "SecureInputInterval.kind": "keep — literal discriminator \"secureInput\"",
    "TapDisabledInterval.kind": "keep — literal discriminator \"tapDisabled\"",
    "AXChainRecord.kind": "keep — literal discriminator \"axChain\"",
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
]

/// **An unadjudicated string field is red.** Scans every `String`-typed stored
/// property AND every `String`-carrying enum case of every record type in
/// `Sources/Project` and compares the set against `adjudicatedStringFields`. A
/// field or case added without a verdict fails here, before a fixture carrying it
/// can be committed.
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

/// Every `String`-valued stored property, AND every `String`-carrying enum-case
/// associated value, of every record type in `Sources/Project`, keyed
/// `Type.field` or `Type.caseName` respectively, read through the code view so a
/// `String` named in a doc comment is not a field.
///
/// A line scan, keyed by the most recent enclosing `struct`/`enum`/`class`
/// declaration. The schema is a flat set of record structs — verified by reading
/// `Sources/Project` before this was written — so nesting depth is not a question
/// this has to answer, and if the schema ever grows a nested record the qualified
/// name simply gets the outer type, which is loud rather than silent.
///
/// **One-line type declarations are handled specially, and were not before this
/// round.** `private struct KindOnly: Decodable { let kind: String }`
/// (`ObservationLog.swift`) packs a stored property onto the SAME line as the
/// type keyword; the original scan set `enclosing` and `continue`d past that
/// line without ever looking at what followed the brace, so `KindOnly.kind` went
/// unreported. The text after the type's OWN opening `{` (up to its closing `}`,
/// so a one-liner's `: SomeProtocol` conformance list is never mistaken for a
/// property's own colon) is now scanned the same way an ordinary line is.
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
                if let brace = line.firstIndex(of: "{") {
                    let end = line.lastIndex(of: "}") ?? line.endIndex
                    let afterBrace = line.index(after: brace)
                    if afterBrace <= end {
                        let body = String(line[afterBrace..<end])
                        if let field = stringPropertyField(in: body, enclosing: enclosing) { fields.insert(field) }
                        if let caseField = stringCaseField(in: body, enclosing: enclosing) { fields.insert(caseField) }
                    }
                }
                continue
            }
            if let field = stringPropertyField(in: line, enclosing: enclosing) { fields.insert(field) }
            if let caseField = stringCaseField(in: line, enclosing: enclosing) { fields.insert(caseField) }
        }
    }
    return fields
}

/// `name: String`, `name: String?`, `name: [String]` on ONE (sub)line, as a
/// `let`/`var` stored property of `enclosing` — the rule this whole scan started
/// with, factored into its own function so it can run over either a full line or
/// (for a one-line type declaration) the text after that type's own opening
/// brace.
///
/// **Known misses, stated rather than fixed, because none exists in this schema
/// today** (verified by running this scan after writing it): an initial value on
/// the same line (`let x: String = "…"`) leaves trailing text after `String` and
/// does not match this exact-equality check; a composite carrying `String`
/// (`[String: String]`) is not `String`, `String?` or `[String]` and is not
/// intended to match — the same rule that already, correctly, excludes
/// `[String: Int]` (`ObservationLogTrailer.recordCounts`) and `[String: Any]`-
/// shaped things generally. A second `let`/`var` sharing a line with the first
/// (`let a: String, b: Int`) would also only report the first — not attempted,
/// because no line in this tree does that either.
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

/// `case name(…, label: String, …)` — an enum case carrying at least one
/// `String`/`String?`/`[String]`-typed associated value, reported as
/// `Type.caseName`. See the doc comment on `SegmentBoundary.failed`'s
/// adjudication entry for why this is a materially different, and materially
/// less closed, risk than a raw-value enum's fixed case-name set.
///
/// **Guarded against the one real ambiguity in this file's own source: a
/// `switch`'s pattern-match `case .foo(let x):` is not a declaration** — `Sources
/// /Project` has no such pattern with a parenthesised binding today (verified by
/// grep before writing this), but a case NAME is never dotted (`failed`, not
/// `.failed`) where a pattern match always is, so `caseName.hasPrefix(".")` is
/// refused rather than merely unencountered.
///
/// One case declaration per line — every case in `Sources/Project` today is
/// (verified by reading it before writing this) — so a comma-separated multi-
/// case line (`case foo(Int), bar(String)`) is not attempted: the first `(` to
/// the last `)` on the line would run two cases' parameter lists together.
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

/// Every committed `.jsonl` fixture anywhere under `Tests/` — not only
/// `Tests/HeadlessFixtures`, so a fixture landing at the task brief's own
/// fallback location (`Tests/HeadlessTests/Fixtures/`, named in Task 5's Step 6
/// as where the fixture would move if SwiftPM rejected the parent-directory
/// resource path — it did not, but the fallback location was never scanned
/// either way) or anywhere else under `Tests/` is not silently outside Gate 1's
/// reach. The scope is stated in this one place and every caller shares it,
/// rather than each gate hardcoding its own directory.
func committedJSONLFixtures() throws -> [URL] {
    let root = repositoryRoot.appending(path: "Tests")
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
/// key in `fieldNames` — recursing through dictionaries and arrays.
///
/// **Structural, not textual, and that is the fix for a concrete failure mode a
/// substring scan has.** The original form of Gate 1 searched for the literal
/// byte sequence `"field":"` with no whitespace tolerance — the same hardcoded
/// assumption `scripts/redact-observation-log.swift` makes about the encoder's
/// output. `ObservationLog.outputFormatting` is `[.sortedKeys]` today, but
/// nothing before this round PINNED that exactly: the test guarding it asserted
/// only `.contains(.sortedKeys)` (`Tests/ProjectTests/ObservationLogTests.swift`),
/// which stays green if `.prettyPrinted` is added alongside it. Had that
/// happened, the NEXT recorded log would write `"title" : "…"` (one space), the
/// script's own substring match would redact nothing, and the OLD Gate 1 — which
/// shared the exact same assumption — would find zero occurrences of its own
/// pattern and pass green over real UI text sitting in a committed fixture.
///
/// Walking the PARSED value instead of pattern-matching the bytes closes that
/// failure mode structurally: `JSONSerialization` does not care about whitespace
/// around a colon, key order, or indentation, so Gate 1 no longer shares an
/// assumption with the script that produced the fixture — which is the same
/// principle the two-direction verification in the task report already used
/// (an independent `sed` normalisation, not the redaction script re-run on
/// itself) to make one check's pass mean something about a DIFFERENT tool's
/// output, rather than only about its own determinism.
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

/// **Gate 1 — content.** No `title`, `shortcut` or other `REDACT`-marked field in
/// any committed fixture holds a value other than the placeholder. This exists
/// for the FUTURE: a second fixture, or a re-redaction, when nobody re-checks
/// that the script ran correctly. A leak is red before it is committed.
///
/// **`SegmentBoundary.failed` is in `redactedFields` (derived automatically from
/// every `REDACT` row of `adjudicatedStringFields`) but is never found here, and
/// that is not a coverage gap this gate is hiding.** The wire key this gate
/// searches for is the case name, `failed`; the wire key that would actually
/// carry the leak, if `SegmentBoundary` were ever serialised into a committed
/// `.jsonl`, is the associated value's own label, `reason` — Swift's synthesised
/// `Codable` encodes an associated-value case as `{"failed":{"reason":"…"}}`, a
/// NESTED object under the case name, so a search for a String directly under
/// the key `"failed"` will structurally never match. This is stated rather than
/// worked around because `SegmentBoundary` belongs to `project.json`'s schema,
/// not the observation log's, and no `project.json`-shaped fixture is committed
/// anywhere under `Tests/` today — the day one is, it needs its own gate keyed on
/// `reason`, not an extension of this one.
///
/// **The vacuity guard is per FIXTURE, summed across every redacted field, not
/// per (fixture, field) pair.** A per-field guard would fail permanently on
/// `shortcut`, which has zero occurrences in `segment-00-redacted.jsonl` by
/// design (see its own adjudication entry) — that zero is expected and already
/// explained, not a sign the gate checked nothing. What must never be zero is the
/// SUM across every redacted field, for a given fixture: a fixture where that sum
/// is zero is a fixture this gate examined nothing real in, whether because the
/// fixture genuinely carries none of these fields (worth a human's confirmation)
/// or because something about its shape defeated the walk above (worth a human's
/// alarm) — either way, `it must say so rather than pass`.
@Test func noCommittedFixtureCarriesAnUnredactedStringField() throws {
    let redactedFields = Set(adjudicatedStringFields
        .filter { $0.value.hasPrefix("REDACT") }
        .map { String($0.key.split(separator: ".").last!) })
    try #require(!redactedFields.isEmpty, "nothing is marked REDACT — this gate would pass vacuously")

    let fixtures = try committedJSONLFixtures()
    try #require(!fixtures.isEmpty, "no committed fixtures found — this gate would pass vacuously")

    for fixture in fixtures {
        let text = try String(contentsOf: fixture, encoding: .utf8)
        // `components(separatedBy:)`, not `split(omittingEmptySubsequences: true)` —
        // the latter silently shifts every reported line number past any blank
        // line, so a leak message could name the wrong line. A blank line
        // contributes an empty, harmlessly-skipped component here instead.
        let lines = text.components(separatedBy: "\n")
        var occurrencesInThisFixture = 0

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // A line that does not parse as one JSON object is skipped, not
            // treated as a violation — for `JSONLReader`'s own accepted
            // truncated-tail shape that is correct; for a genuinely malformed
            // record it is a known, stated gap this gate does not close (the
            // vacuity guard below is the backstop: if EVERY line in a fixture
            // failed to parse, `occurrencesInThisFixture` stays 0 and that
            // fixture fails loudly rather than passing unexamined).
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

/// **Case-associated REDACT entries need a stricter needle than a property does — found in
/// Phase 3A-1 Task 7, not designed in ahead of time.** `SegmentBoundary.failed(reason: String)`
/// is an ENUM CASE with a required associated value, and Swift will not compile a reference to
/// it (construction OR pattern match) without an immediately-following `(` — `case .failed:`
/// with no parens is a compile error for a case declared this way. A plain stored property
/// (`AXElementRecord.title`, `KeySample.shortcut`) carries no such guarantee: `.title` alone is
/// already a complete, valid reference. That difference matters here because AVFoundation
/// declares its OWN, semantically unrelated, no-associated-value `.failed` case twice
/// (`AVAssetWriter.Status.failed`, `AVAssetReader.Status.failed`), and `MP4Exporter.swift`
/// compares against both directly (`writer.status == .failed`) — moving that file into
/// `Sources/Headless` in this same task put it inside Gate 2's scan for the first time and
/// collided on the bare substring `.failed`, which `codeLinesNaming` cannot tell apart from
/// `SegmentBoundary.failed` by text alone. Requiring the trailing `(` for `failed` specifically
/// closes exactly that collision — `SegmentBoundary.failed` is never referenced anywhere under
/// `Sources/Headless`/`Sources/Render` today, so the real check (this REDACTED field is never
/// read there) is unchanged; only the false alarm from an unrelated SDK enum case is. Applies to
/// this one entry, not to every REDACT row, because it is the one row this reasoning is actually
/// true for.
let redactedCaseFields: Set<String> = ["failed"]

/// **Gate 2 — consumption.** The render path never reads a `REDACT`-marked
/// field. Scanned through `codeLinesNaming` over `Sources/Headless` and
/// `Sources/Render`, so a mention in a doc comment does not count and a real
/// read does.
@Test func theRenderPathNeverReadsARedactedField() throws {
    let redactedFields = adjudicatedStringFields
        .filter { $0.value.hasPrefix("REDACT") }
        .map { String($0.key.split(separator: ".").last!) }
    let renderFiles = try swiftFiles(under: "Sources/Headless") + swiftFiles(under: "Sources/Render")

    for field in redactedFields {
        // See `redactedCaseFields`'s own doc comment: an associated-value ENUM CASE is never
        // validly referenced without a trailing `(`, so requiring one here for exactly that kind
        // of entry closes a real false-positive collision without narrowing what this gate
        // actually checks for a plain stored property.
        let needle = redactedCaseFields.contains(field) ? ".\(field)(" : ".\(field)"
        let readers = try codeLinesNaming(needle, in: renderFiles)
        #expect(readers.isEmpty, """
            the render path reads `\(field)`, a field the fixture redacts:
            \(readers.map { "  \($0.location): \($0.text)" }.joined(separator: "\n"))
            If the render path needs this value, the fixture cannot be redacted of it and the \
            adjudication changes — not this gate.
            """)
    }
}
