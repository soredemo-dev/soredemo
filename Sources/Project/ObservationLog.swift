import Foundation
import Geometry
import Timeline

/// The on-disk observation log: JSONL, append-only, one file per master segment.
///
/// # What a record may contain
///
/// **This is part of the format, not a note to the writer.** A `.soredemo`
/// package lands on a user's disk in a local-by-default product; this file is
/// the thing they are trusting. The rule is stated here, in the schema, because
/// here is where someone adding a field reads it — a comment in
/// `ObservationWriter` is read by someone changing the writer, which is not the
/// same person.
///
/// A record **may** contain:
///
///   * **instants and intervals** on the host clock, epoch-stamped;
///   * **coordinates**, normalised, carrying the `GeometryRevision` they were
///     normalised against;
///   * **AX roles and frames** — structural facts about the interface;
///   * **AX titles**. UI text, recorded on purpose: it is what makes "the Save
///     button" identifiable in derivation, and it is already legible in the
///     video this log accompanies. `AXObserver.title(of:)` carries the same
///     argument at the point of the read.
///   * **counts and spans** of things that were refused, dropped or not
///     observed, including the shortcut *identifier* a key filter matched.
///
/// A record **may not** contain, ever:
///
///   * **what a person typed.** Not the characters, not a redacted form of
///     them, not a length. `InputObserver` records the identifier of an
///     approved shortcut and a count of the key downs it refused — counts,
///     never content — because a value that existed can be logged, and there
///     is then something to redact later.
///   * **the contents of a control.** `kAXValueAttribute`,
///     `kAXSelectedTextAttribute` and their neighbours are the text *inside* a
///     field, as distinct from the label *on* it. A password field's
///     surroundings are exactly where an AX walk lands, and secure input is
///     not a defence against a walk this process performs itself.
///   * **the pasteboard**, in any form.
///   * **an enumeration of other applications' windows.** `kCGWindowName` over
///     `CGWindowListCopyWindowInfo` is a list of every document open on the
///     machine, including the ones not being recorded. **An earlier spike
///     wrote window titles into a capture log — 444 KB of them, deleted
///     since.** That was a spike; this is the format, and this paragraph is
///     the difference.
///
/// The distinction the two lists turn on is **on-screen and in-frame** versus
/// **ambient**: an AX title belongs to something the recording already shows,
/// while a keystroke, a field's contents and another app's window list are
/// none of the three. `Tests/AppSourceTests.noAppSourceReadsUserContent`
/// enforces the second list over the whole app target by scanning for the APIs
/// that would read those things — the same mechanism that already enforces the
/// keystroke half, and for the same reason: a producer cannot write what it
/// cannot read.
public enum ObservationLog {
    /// A version line of its own. It does not move with
    /// `ProjectSnapshot.currentSchemaVersion` or `CanonicalEncoding.version`;
    /// the table in the Phase 2 design doc (D2-12 Q4) is where that is stated.
    ///
    /// **2 since the Task 11 review, and the bump is the correction.** Two
    /// incompatible wire layouts both stamped themselves `1`:
    ///
    /// | | v1 (commit `89db282`) | v2 (this build) |
    /// | --- | --- | --- |
    /// | header's clock | `"epoch"`, a `BootEpoch` | `"anchor"`, an `EpochAnchor` |
    /// | `GapSite` | five cases, including `jsonlTruncatedTail` | four; that site moved to `ObservationLogReadReport` |
    ///
    /// A v1 log opened by a build that read `schemaVersion` and did nothing
    /// with it passed both guards — `kind` is `logHeader`, the version matches
    /// — and then died inside the decode on `keyNotFound(.anchor)`, a generic
    /// `DecodingError` indistinguishable from arbitrary corruption and from an
    /// anchor that is genuinely absent. Its trailer failed separately on the
    /// unknown raw value `jsonlTruncatedTail`, and
    /// `ProjectPackageIO.danglingObservationLogs` then reported it as dangling
    /// because its header "does not decode". **The guard built to make "a
    /// document from another build" loud was what certified two builds as the
    /// same one.**
    ///
    /// What a v1 log does now, on read: `ObservationLogHeader.init(from:)`
    /// throws `ProjectFormatError.unsupportedLegacyVersion(1)` — named, before
    /// a single other field is touched. There is no migration and there will
    /// not be one for a format that has never shipped; the point of the bump is
    /// that the refusal says *which* build wrote the file instead of the reader
    /// guessing at a missing key.
    ///
    /// The rule for the next person: **bump this whenever an existing key's
    /// name, type or meaning changes, or a case is removed from an enum that
    /// appears on the wire.** Adding a new optional key is additive; renaming
    /// `epoch` to `anchor` is not, and neither is deleting a `GapSite`.
    public static let schemaVersion: Int = 2

    private struct KindOnly: Decodable { let kind: String }

    /// Reads a record's kind **without decoding the record**, so a build that
    /// does not know a record type can skip it rather than fail the file. Same
    /// reasoning as `SchemaProbe.version(of:)` one layer up.
    public static func kind(of line: Data) throws -> String {
        do { return try JSONDecoder().decode(KindOnly.self, from: line).kind }
        catch { throw ProjectFormatError.malformed(String(describing: error)) }
    }

    /// Measured, not assumed: without `.sortedKeys`, key order is per-process
    /// random (Foundation's `JSONEncoder` keyed container is hash-seeded on
    /// Darwin regardless of whether the encoded type contains a
    /// `Dictionary`/`Set` — see `ObservationLogTests`'s six-process probe).
    /// Exposed as a constant, not inlined into `encode`, so a test can
    /// assert the flag directly instead of only inferring it from sampled
    /// output — see `ObservationLogTests.sortedKeysIsSetOnTheEncoder`, which
    /// reddens deterministically under this constant being changed, unlike
    /// `encodedKeysAreInSortedOrderNotJustRoundTrippable`'s byte-order check,
    /// which samples a per-process hash seed and so cannot.
    public static let outputFormatting: JSONEncoder.OutputFormatting = [.sortedKeys]

    public static func encode(_ value: some Encodable) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = outputFormatting
        return try e.encode(value)
    }

    public static func decode<T: Decodable>(_ line: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: line)
    }
}

// MARK: - The log's own clock

public enum ObservationLogError: Error, Equatable {
    /// A record carrying an instant from a boot session other than the log's.
    case foreignEpoch(kind: String, expected: UUID, found: UUID)
    /// A record that answered `epochs` with nothing at all. Not a tolerable
    /// absence: a record with no instant cannot be placed on the log's clock,
    /// and accepting it would make the guard below vacuous for exactly the
    /// record type that broke it.
    case noEpoch(kind: String)
    /// `append` or `close` after `close`.
    case logIsClosed
}

extension ObservationLog {
    /// **The log carries one `BootEpoch` and every record must match it.**
    ///
    /// This is the decision Addition B forced, and the alternative — per-record
    /// epochs with a reader-side rule against comparing across them — was
    /// rejected for a reason that is about reading, not writing. `HostInstant`
    /// does already carry `epoch`, so the epoch *is* in the schema; what is not
    /// is any statement of which epoch **the recording** is on. Without one, a
    /// reader handed a log with two epochs in it has no way to decide which of
    /// them is the run and which is the corruption, and `SegmentTable` one
    /// layer up cannot represent the answer either way: `SegmentTableError
    /// .mixedEpochs` refuses such a table outright. A log that can express what
    /// the table it joins against cannot hold is a log whose extra expressive
    /// power is only ever used by a bug.
    ///
    /// A recording spans a pause; a pause can span a reboot; so this is not
    /// hypothetical. The guard runs at `append`, which is the last moment the
    /// producer that made the mistake is still on the stack.
    ///
    /// Every epoch the record carries is checked, not just the first — see
    /// `AXChainRecord.epochs` for the record type where that matters.
    public static func checkEpoch(of record: some ObservationRecord,
                                  against epoch: BootEpoch) throws {
        let epochs = record.epochs
        guard !epochs.isEmpty else { throw ObservationLogError.noEpoch(kind: record.kind) }
        for found in epochs where found != epoch {
            throw ObservationLogError.foreignEpoch(kind: record.kind,
                                                   expected: epoch.id, found: found.id)
        }
    }
}

// MARK: - The gap register, as a schema rule

/// One row of `docs/ARCHITECTURE.md` D6a **that a producer can honestly fill at
/// segment close**.
///
/// A `String` raw value, and `CaseIterable`, because
/// `ObservationLogTrailer.init(from:)` requires **every** case to be present in
/// a decoded trailer. Adding a case for a new PRODUCER-MEASURABLE D6a row
/// therefore fails to decode logs this build wrote, which is the loud
/// direction: a site that a version knew about and did not report is the exact
/// ambiguity this whole type exists to remove.
///
/// # This enum has four cases. D6a's table does not have four rows — it has grown past that,
/// # and this enum was never meant to track its row count
///
/// **Corrected here (Phase 2B Task 8, code review, finding 7) after drifting once already**: an
/// earlier version of this comment said "D6a has five rows and this enum has four" and named the
/// JSONL reader's row as the one exception. That was true when D6a's gap-register table had five
/// rows. It has eight now — Task 8 added three (the drawn pointer's shape/hidden-state
/// substitution, the `StageCompositor` preview frame-drop counter, and the persisted-but-unread
/// `StageStyle` shadow fields) — and NONE of the three needed a case here, for a reason the
/// original comment's framing did not anticipate: they are not things a producer measures at
/// segment close, but they are also not the JSONL-truncation shape (a reader-side fact about THIS
/// log format). They are facts about the compositor and about the persisted render style,
/// entirely outside the observation log's own domain. **So the right invariant is not "D6a has N
/// rows and this enum has N-1" — that framing breaks every time D6a grows for a reason unrelated
/// to segment-close accounting, which is most of the time.** The right invariant, restated so it
/// does not drift again: this enum carries exactly the D6a rows a producer can honestly fill at
/// segment close, today four, and nothing about D6a's own row count bounds that number in either
/// direction.
///
/// The trailer is written by the **producer**, at segment close. This enum's four cases name
/// something the producer measured while recording: how many times it polled the tap, how many
/// times it asked whether secure input was on, how many frame callbacks arrived, how many ancestor
/// walks it performed. **One other D6a row** — the JSONL reader's truncated tail — names bytes
/// lost from a **truncated or corrupt record**, which is a property of *reading the file back* and
/// is discovered after the writer is gone. `JSONLReader.Result.bytesScanned` measures what a
/// reader examined, and a writer has no reader.
///
/// So a producer asked for that row has nothing to put in it and will put
/// something there anyway. This was not hypothetical: the first version of this
/// enum carried the case, and the only assembler of gap watches in the tree — a
/// probe fixture — wrote `looks: 1` for it over a recording in which not one
/// byte had been scanned, and a check three subsections later then asserted that
/// fabricated row *was* a measurement. Once the format ships, every log carries
/// a number for that site that means nothing and that a reader in six weeks
/// cannot tell from a real one. That is Addition A's ambiguity, reintroduced at
/// one site by the shape of the API.
///
/// **Where the JSONL-reader row lives instead: `ObservationLogReadReport`.** It is produced
/// by the code that actually reads a log, carries `droppedBytes` beside
/// `bytesScanned` — the same pair, with the same rule — and reports this enum's four
/// producer rows from the trailer alongside its own, so a reader sees all five OF THE
/// OBSERVATION LOG'S OWN ROWS in one place. What has been removed is the ability of a producer to
/// claim the reader-only one. The other three D6a rows (Task 8) are not observation-log rows at
/// all and are not claimed here or in `ObservationLogReadReport` — they live only in
/// `docs/ARCHITECTURE.md` D6a itself.
public enum GapSite: String, Codable, Sendable, CaseIterable {
    /// `AXObserver`'s ancestor walk — levels beyond the depth cap or budget.
    case axAncestorWalk
    /// `CaptureSession` video — frames the display did not produce.
    case videoFramesNotProduced
    /// `InputObserver` — every event while another app holds a password field.
    case secureInput
    /// `InputObserver` — every event between a tap disable and the re-arm.
    case tapDisabled

    /// **The unit this site's loss is measured in, fixed by the site.**
    ///
    /// Not a per-`GapWatch` choice, which is what it was until review: with the
    /// unit unpinned, one producer could write `.nanoseconds` for
    /// `videoFramesNotProduced` where another wrote `.frames`, both would
    /// decode, and a reader aggregating "how much of this recording is
    /// unobserved" would sum frames and nanoseconds. `GapUnit`'s own reason for
    /// existing is that a bare `Int64` with no unit invites exactly that sum;
    /// leaving the unit free left the invitation standing one field over.
    ///
    /// `GapWatch.init` derives the unit from here rather than taking it, so a
    /// producer cannot get it wrong, and `GapWatch.init(from:)` refuses bytes
    /// off disk that disagree.
    public var lostUnit: GapUnit {
        switch self {
        case .axAncestorWalk: .levels
        case .videoFramesNotProduced: .frames
        case .secureInput, .tapDisabled: .nanoseconds
        }
    }
}

/// The unit the loss at a site is measured in. Named rather than assumed,
/// because D6a's whole argument is that a gap must be quantified **in the unit
/// that was lost** — bytes for bytes, nanoseconds for time — and a bare `Int64`
/// with no unit invites the next reader to sum two of them.
///
/// `bytes` has no `GapSite`: it is D6a row 1's unit, and that row is
/// `ObservationLogReadReport`'s, not a producer's. Kept in the enum because the
/// read report reports in it.
public enum GapUnit: String, Codable, Sendable {
    case bytes
    case nanoseconds
    case frames
    case levels
}

/// **A gap, and the evidence that something was looking for it.**
///
/// This type is Addition A made structural. D6a's closing rule —
///
/// > An empty gap record and an absent gap detector produce the same bytes.
///
/// — was true of four of D6a's five rows when this format was designed. Only
/// the tap row paired its gaps with a poll count over a span. The other four
/// wrote a zero that a stranger reading the log in six weeks could not tell
/// from a version that never looked.
///
/// Three states, and they are distinguishable on disk:
///
/// | on disk | reading |
/// | --- | --- |
/// | the site is absent from `ObservationLogTrailer.gapWatches` | **impossible in a v1 log** — the trailer refuses to decode, so it can only mean a log from a version that did not know this site |
/// | present, `looks == 0` | nothing looked. `gapsFound == 0` here is **not** a measurement, and `isAMeasurement` says so |
/// | present, `looks > 0`, `gapsFound == 0` | something looked, `looks` times over `watchedSpanNanos`, and found none |
///
/// The middle row is the one that could not be written before. It is not
/// hypothetical: `InputObserver`'s tap poll is a `DispatchSourceTimer`, and a
/// timer that fails to arm produces `looks == 0` with every other number in the
/// log unchanged.
public struct GapWatch: Hashable, Codable, Sendable {
    public let site: GapSite
    /// How many times the detector actually ran — polls, frames examined,
    /// bytes-scanning passes, secure-input checks. **Zero means nothing
    /// looked**, and every other field here is then about nothing.
    public let looks: Int
    /// The span the looks cover, first to last, in nanoseconds. A count with
    /// no span cannot distinguish 1247 polls over two minutes from 1247 polls
    /// in the first second before the timer died — D6a says so about the tap
    /// row, and it is true of every row.
    public let watchedSpanNanos: Int64
    /// How many gaps were found. Distinct from `looks`, and both are needed:
    /// `gapsFound == 0` is a measurement only when `looks > 0`.
    public let gapsFound: Int
    /// How much was lost, in `lostUnit`. An over-estimate wherever the
    /// underlying interval is an enclosing bound (`TapDisabledInterval`); the
    /// safe direction for "how much of this recording is unobserved" is up.
    public let lost: Int64
    /// Fixed by `site` — see `GapSite.lostUnit`. Stored and encoded so the
    /// document is self-describing, derived rather than taken so a producer
    /// cannot write a unit that disagrees with its own site.
    public let lostUnit: GapUnit

    /// `precondition`, not `throw`: a producer assembling this from its own
    /// diagnostics cannot legitimately produce a negative count or claim gaps
    /// it never looked for. Untrusted input arrives through `init(from:)`
    /// below, which throws.
    ///
    /// **There is no `lostUnit` parameter**, deliberately — it comes from
    /// `site`. See `GapSite.lostUnit` for the aggregation this closes.
    ///
    /// Prefer the four named constructors below to this one. They exist because
    /// the only assembler of gap watches in the tree at review time was a
    /// fixture that passed a proxy — `looks: pointerSamples` for
    /// `.videoFramesNotProduced` — and nothing in the type or at the call site
    /// pushed it towards the honest number. Each named constructor's parameter
    /// labels are its producer's own counter names, so passing something else
    /// costs a visible rename at the call site.
    public init(site: GapSite, looks: Int, watchedSpanNanos: Int64,
                gapsFound: Int, lost: Int64) {
        precondition(looks >= 0 && watchedSpanNanos >= 0 && gapsFound >= 0 && lost >= 0,
                     "GapWatch(\(site)) has a negative count: looks \(looks), "
                     + "span \(watchedSpanNanos), gaps \(gapsFound), lost \(lost)")
        precondition(!(looks == 0 && gapsFound > 0),
                     "GapWatch(\(site)) reports \(gapsFound) gaps found by 0 looks — "
                     + "a gap nothing looked for was not found")
        self.site = site
        self.looks = looks
        self.watchedSpanNanos = watchedSpanNanos
        self.gapsFound = gapsFound
        self.lost = lost
        self.lostUnit = site.lostUnit
    }

    /// Whether `gapsFound` is a statement about the world. `false` means
    /// nothing was looking, and the row says nothing about whether gaps
    /// happened.
    public var isAMeasurement: Bool { looks > 0 }

    /// The two numbers that only mean something together, in the shape
    /// `InputObserver.Diagnostics.tapAccounting` already prints.
    public var accounting: String {
        let seconds = Double(watchedSpanNanos) / 1e9
        // `String(format:_:)` is flagged because its underlying C varargs machinery is
        // unauditable in general — but this call passes exactly one `Double` matched to
        // exactly one `%.3f`, both fixed at the call site, so there is nothing a caller
        // could vary to make it unsafe in practice. `unsafe` cannot appear to the right of
        // `+`, hence the local rather than an inline call.
        let secondsFormatted = unsafe String(format: "%.3f", seconds)
        var line = "\(site.rawValue): \(gapsFound) gap(s), \(lost) \(lostUnit.rawValue) lost"
            + "  ←  \(looks) look(s) over " + secondsFormatted + " s"
        if !isAMeasurement { line += "   ← NOTHING WAS LOOKING; the count left of the arrow is not a measurement" }
        return line
    }
}

extension GapWatch {
    private enum CodingKeys: String, CodingKey {
        case site, looks, watchedSpanNanos, gapsFound, lost, lostUnit
    }

    /// Untrusted input, validated — the memberwise initialiser above
    /// `precondition`s and a synthesised `Decodable` would assign the stored
    /// properties directly, bypassing it. That is the same hole
    /// `AXElementRecord.init(from:)` and `SegmentTable.init(from:)` close, and
    /// here it is sharper than a merely odd value: `looks == 0, gapsFound == 3`
    /// off disk is a row that claims to be evidence against itself, and
    /// `isAMeasurement` would answer `false` for a row reporting three gaps.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let site = try container.decode(GapSite.self, forKey: .site)
        let looks = try container.decode(Int.self, forKey: .looks)
        let span = try container.decode(Int64.self, forKey: .watchedSpanNanos)
        let gapsFound = try container.decode(Int.self, forKey: .gapsFound)
        let lost = try container.decode(Int64.self, forKey: .lost)
        let lostUnit = try container.decode(GapUnit.self, forKey: .lostUnit)

        guard looks >= 0, span >= 0, gapsFound >= 0, lost >= 0 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: """
                    GapWatch(\(site.rawValue)) has a negative count: looks \(looks), \
                    span \(span), gaps \(gapsFound), lost \(lost)
                    """))
        }
        guard !(looks == 0 && gapsFound > 0) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: """
                    GapWatch(\(site.rawValue)) reports \(gapsFound) gap(s) found by 0 looks. \
                    isAMeasurement would answer false for a row reporting gaps, which is the \
                    one reading this type exists to make impossible.
                    """))
        }
        guard lostUnit == site.lostUnit else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: """
                    GapWatch(\(site.rawValue)) reports its loss in \(lostUnit.rawValue), and that \
                    site is measured in \(site.lostUnit.rawValue). A reader aggregating \
                    'how much of this recording is unobserved' would sum two units.
                    """))
        }
        self.init(site: site, looks: looks, watchedSpanNanos: span,
                  gapsFound: gapsFound, lost: lost)
    }
}

// MARK: - the honest path, one constructor per producer

extension GapWatch {
    /// D6a's tap row, from `InputObserver.Diagnostics`.
    ///
    /// The labels are that type's own field names. `tapEnabledPolls` over
    /// `tapPollingSpanNanos` is the pair D6a names as the one that made
    /// `tapDisabledIntervals: []` a measurement.
    public static func tapDisabled(tapEnabledPolls: Int, tapPollingSpanNanos: Int64,
                                   tapDisabledIntervals: Int, tapBlindNanos: Int64) -> GapWatch {
        GapWatch(site: .tapDisabled, looks: tapEnabledPolls,
                 watchedSpanNanos: tapPollingSpanNanos,
                 gapsFound: tapDisabledIntervals, lost: tapBlindNanos)
    }

    /// D6a's secure-input row, from `InputObserver.Diagnostics`. The predicate
    /// is consulted per event, so `secureInputChecks` is the number of asks —
    /// counted at the ask, not at the answer.
    public static func secureInput(secureInputChecks: Int, secureInputCheckSpanNanos: Int64,
                                   secureInputIntervals: Int, suppressedNanos: Int64) -> GapWatch {
        GapWatch(site: .secureInput, looks: secureInputChecks,
                 watchedSpanNanos: secureInputCheckSpanNanos,
                 gapsFound: secureInputIntervals, lost: suppressedNanos)
    }

    /// D6a's video row, from `CaptureSession.Diagnostics`.
    ///
    /// `frameCallbacksObserved` is every callback the stream delivered — the
    /// sum of `frameStatusCounts.values`, **not** `completeFrameCount`, which
    /// is already post-filter and cannot say whether the stream was running.
    /// `idleFrames` is `frameStatusCounts[SCFrameStatus.idle.rawValue]`.
    public static func videoFramesNotProduced(frameCallbacksObserved: Int,
                                              observationSpanNanos: Int64,
                                              idleFrames: Int) -> GapWatch {
        GapWatch(site: .videoFramesNotProduced, looks: frameCallbacksObserved,
                 watchedSpanNanos: observationSpanNanos,
                 gapsFound: idleFrames, lost: Int64(idleFrames))
    }

    /// D6a's AX row, from `AXObserver.Diagnostics`.
    ///
    /// `chainsRecorded` is how many walks were performed — a run with no clicks
    /// has nothing looking, and that is the state this row could not previously
    /// express. `levelsLost` is genuinely unknowable per walk (nothing counts
    /// the ancestors that were never asked for), so it is reported as the
    /// number of walks that stopped early, in `levels`, and is a **lower bound
    /// of one level each**; the record's own `truncation` is where the detail is.
    public static func axAncestorWalk(chainsRecorded: Int, observationSpanNanos: Int64,
                                      truncatedWalks: Int) -> GapWatch {
        GapWatch(site: .axAncestorWalk, looks: chainsRecorded,
                 watchedSpanNanos: observationSpanNanos,
                 gapsFound: truncatedWalks, lost: Int64(truncatedWalks))
    }
}

// MARK: - The two records that bracket a log

/// Why observation was degraded for a whole segment, as opposed to for a
/// moment inside it.
///
/// **`CaptureError.inputMonitoringUnavailable` maps to
/// `CapturePermissions`' `.observationBlind` and, until this type, nothing
/// wrote it anywhere.** A recording made without Input Monitoring produces no
/// pointer samples, no clicks and no shortcuts — which is byte-identical to a
/// recording of somebody not touching the mouse. This is the field that tells
/// them apart, and it is on the header rather than inferred from an empty log
/// because the inference is exactly the one that cannot be made.
public enum ObservationBlindness: String, Codable, Sendable, CaseIterable {
    /// `CGEvent.tapCreate` returned `nil` — read as "Input Monitoring is not
    /// granted". No pointer track, no clicks, no shortcuts, for the whole
    /// segment.
    case inputMonitoringUnavailable
    /// The grant is held and this process's own run-loop plumbing failed.
    /// Same observable consequence, different thing to go and look at — the
    /// distinction `CaptureError` already draws and this must not collapse.
    case eventTapRunLoopSourceUnavailable
    /// Accessibility is not granted, so every hit-test answers with nothing.
    /// Clicks are still recorded; their object half is not.
    case accessibilityUnavailable
}

/// The first line of every observation log.
///
/// One file per segment (D2-12 Q3), so this is also the join to the segment
/// table: `segmentIndex` and `mediaFilename` are copied from the `MasterSegment`
/// this log accompanies, so a log found on its own still says what it is a log
/// **of**.
public struct ObservationLogHeader: Hashable, Codable, Sendable {
    public let kind: String
    public let schemaVersion: Int
    /// **The log's clock, tied to a wall-clock reading.**
    ///
    /// `anchor.epoch` is the epoch every record in this log must carry — see
    /// `ObservationLog.checkEpoch(of:against:)` for why that lives at the log
    /// level and is not left to the per-record epochs `HostInstant` already
    /// holds.
    ///
    /// **`EpochAnchor` rather than a bare `BootEpoch`, and this is the field
    /// that dates a recording.** Nothing else in the format did. `HostInstant`
    /// is monotonic-clock nanoseconds since a boot whose identity is a UUID;
    /// `MasterSegment`, `SegmentTable` and `ProjectSnapshot` carry no wall
    /// clock at all. So a `.soredemo` package said nowhere when it was made,
    /// and two logs from two boot epochs could not be placed relative to each
    /// other even roughly — which is precisely what `EpochAnchor` documents
    /// itself as being for, and it had zero references in the repository until
    /// this field. Filesystem mtime is not part of the format and is destroyed
    /// by any copy.
    ///
    /// It is on the **header** rather than the manifest because a log is the
    /// thing that has one epoch. A package holds several recordings by Phase 4,
    /// each its own boot session, and one anchor on the manifest would have to
    /// pick one of them.
    ///
    /// The wall clock is still not an ordering key — `EpochAnchor` says so at
    /// length and `SegmentTable` is the order. This dates the recording; it
    /// does not sequence it.
    public let anchor: EpochAnchor
    /// The boot epoch every record in this log must be stamped with.
    public var epoch: BootEpoch { anchor.epoch }
    public let segmentIndex: Int
    /// Relative, never absolute — the same rule `MasterSegment.mediaFilename`
    /// and `ProjectSnapshot.mediaFilenames` keep.
    public let mediaFilename: String
    public let revision: GeometryRevision
    /// What could not be observed for this whole segment.
    ///
    /// **Mandatory and non-optional, so `[]` is a statement.** An empty array
    /// means the permissions were checked and none of them was missing. A log
    /// with no `blindness` key at all fails to decode — which is the third
    /// state, and it can only be reached by a version that did not have this
    /// field. Same argument as `GapWatch`, one record up.
    public let blindness: [ObservationBlindness]

    public init(anchor: EpochAnchor, segmentIndex: Int, mediaFilename: String,
                revision: GeometryRevision, blindness: [ObservationBlindness]) {
        self.kind = "logHeader"
        self.schemaVersion = ObservationLog.schemaVersion
        self.anchor = anchor
        self.segmentIndex = segmentIndex
        self.mediaFilename = mediaFilename
        self.revision = revision
        self.blindness = blindness
    }
}

extension ObservationLogHeader {
    private enum CodingKeys: String, CodingKey {
        case kind, schemaVersion, anchor, segmentIndex, mediaFilename, revision, blindness
    }

    /// **Untrusted input, validated — and the field this exists for is
    /// `schemaVersion`.**
    ///
    /// `kind` and `schemaVersion` are literals assigned inside the memberwise
    /// initialiser: they are invariants of a header this build wrote, not
    /// values a caller supplies. A synthesised `Decodable` assigns both from
    /// the bytes, so a package carrying `"schemaVersion": 9` decoded cleanly
    /// into a v1 reader, which then read v9 meanings as v1 — the version line
    /// the format exists to carry was inert on the one path that carries a
    /// document written by somebody else.
    ///
    /// The stance is `SchemaProbe`'s and `ProjectUpgrade`'s, one layer down:
    /// refuse to read a single other field rather than partially interpret a
    /// document from a future build. A version *lower* than this build's is
    /// refused too, because there is no migration chain for observation logs
    /// yet — when there is, this is where it hooks in, and an unsupported-low
    /// error is a better place to start than a silent reinterpretation.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard kind == "logHeader" else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "expected kind 'logHeader', found '\(kind)'"))
        }
        // The two directions are different errors, because they send the
        // reader to different places: `tooNew` means "get a newer build",
        // `unsupportedLegacyVersion` means "this file predates the format this
        // build reads, and there is no upgrade path". `ProjectUpgrade` already
        // draws that line for the manifest; throwing `tooNew` for both was a
        // reader being told a v1 log was from the future.
        if schemaVersion > ObservationLog.schemaVersion {
            throw ProjectFormatError.tooNew(found: schemaVersion,
                                            supported: ObservationLog.schemaVersion)
        }
        if schemaVersion < ObservationLog.schemaVersion {
            throw ProjectFormatError.unsupportedLegacyVersion(schemaVersion)
        }
        self.init(anchor: try container.decode(EpochAnchor.self, forKey: .anchor),
                  segmentIndex: try container.decode(Int.self, forKey: .segmentIndex),
                  mediaFilename: try container.decode(String.self, forKey: .mediaFilename),
                  revision: try container.decode(GeometryRevision.self, forKey: .revision),
                  blindness: try container.decode([ObservationBlindness].self, forKey: .blindness))
    }

    /// Matches the synthesised shape exactly, so this hand-written conformance
    /// changes validation and not the wire form.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(anchor, forKey: .anchor)
        try container.encode(segmentIndex, forKey: .segmentIndex)
        try container.encode(mediaFilename, forKey: .mediaFilename)
        try container.encode(revision, forKey: .revision)
        try container.encode(blindness, forKey: .blindness)
    }
}

/// The last line of every observation log — written on `close`, which is the
/// first moment the segment's own `HostRange` and its boundary reason are
/// known.
///
/// **A log with no trailer is a crashed log**, and that is deliberate rather
/// than a gap: `JSONLReader`'s truncated-tail rule already tells a reader that
/// the last line was cut off, and a missing trailer tells it that the process
/// died before the segment closed. Both are recoverable and both are visible;
/// neither is silent.
public struct ObservationLogTrailer: Hashable, Codable, Sendable {
    public let kind: String
    public let segmentIndex: Int
    /// The segment's host range, copied from the `MasterSegment` — so "every
    /// record's instant lies inside its segment's range" is checkable from the
    /// log alone, without the manifest.
    public let hostRange: HostRange
    public let endedBy: SegmentBoundary
    /// How many records of each `kind` this writer appended, keyed by the
    /// `kind` string.
    ///
    /// **A key present with a zero value and a key absent are different
    /// facts**, and that is why this is a dictionary rather than a set of
    /// named counters. `"pointer": 0` says this writer emits pointer samples
    /// and none occurred; no `"pointer"` key at all says this producer does
    /// not emit them. The same three-state rule as `GapWatch`, applied to the
    /// record streams themselves rather than to the gaps between them.
    public let recordCounts: [String: Int]
    /// One row per `GapSite`, all of them, every time. See `GapWatch`.
    public let gapWatches: [GapWatch]

    public init(segmentIndex: Int, hostRange: HostRange, endedBy: SegmentBoundary,
                recordCounts: [String: Int], gapWatches: [GapWatch]) {
        let missing = Set(GapSite.allCases).subtracting(gapWatches.map(\.site))
        precondition(missing.isEmpty,
                     "ObservationLogTrailer needs one GapWatch per D6a site; missing "
                     + missing.map(\.rawValue).sorted().joined(separator: ", "))
        self.kind = "logTrailer"
        self.segmentIndex = segmentIndex
        self.hostRange = hostRange
        self.endedBy = endedBy
        self.recordCounts = recordCounts
        self.gapWatches = gapWatches
    }

    /// Whether every gap row in this trailer is backed by something that
    /// looked. `false` names the rows that are not — the summary a reader
    /// needs before quoting any zero out of this log.
    public var sitesNothingWasWatching: [GapSite] {
        gapWatches.filter { !$0.isAMeasurement }.map(\.site).sorted { $0.rawValue < $1.rawValue }
    }

    public var accounting: String {
        gapWatches.sorted { $0.site.rawValue < $1.site.rawValue }.map(\.accounting)
            .joined(separator: "\n")
    }
}

extension ObservationLogTrailer {
    private enum CodingKeys: String, CodingKey {
        case kind, segmentIndex, hostRange, endedBy, recordCounts, gapWatches
    }

    /// Untrusted input, validated, for the reason the memberwise
    /// `precondition` above exists: **a trailer missing a site is the exact
    /// ambiguity Addition A removes**, and a synthesised `Decodable` would
    /// accept one silently. A reader would then see four rows, have no reason
    /// to count them, and read the absent fifth as "no gaps at that site" —
    /// which is the pre-Addition-A behaviour reintroduced by the one path
    /// carrying data written by somebody else.
    ///
    /// Throwing rather than trapping: a `.soredemo` package's bytes are
    /// attacker-influenced by `agentic-threat-model`'s assumption.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let segmentIndex = try container.decode(Int.self, forKey: .segmentIndex)
        let hostRange = try container.decode(HostRange.self, forKey: .hostRange)
        let endedBy = try container.decode(SegmentBoundary.self, forKey: .endedBy)
        let recordCounts = try container.decode([String: Int].self, forKey: .recordCounts)
        let gapWatches = try container.decode([GapWatch].self, forKey: .gapWatches)

        guard kind == "logTrailer" else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "expected kind 'logTrailer', found '\(kind)'"))
        }
        let sites = gapWatches.map(\.site)
        let missing = Set(GapSite.allCases).subtracting(sites)
        guard missing.isEmpty else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: """
                    ObservationLogTrailer is missing a GapWatch for \
                    \(missing.map(\.rawValue).sorted().joined(separator: ", ")). \
                    An absent site reads as 'no gaps there' and is indistinguishable from \
                    'this version did not look' — ARCHITECTURE.md D6a.
                    """))
        }
        guard Set(sites).count == sites.count else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: """
                    ObservationLogTrailer has two GapWatch rows for one site: \
                    \(sites.map(\.rawValue).sorted()). Which one a reader believes is undefined.
                    """))
        }
        guard recordCounts.values.allSatisfy({ $0 >= 0 }) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "ObservationLogTrailer.recordCounts has a negative count: \(recordCounts)"))
        }
        self.init(segmentIndex: segmentIndex, hostRange: hostRange, endedBy: endedBy,
                  recordCounts: recordCounts, gapWatches: gapWatches)
    }
}

// MARK: - D6a row 1, on the side that can measure it

/// **What reading one observation log back actually found.**
///
/// This is where `docs/ARCHITECTURE.md` D6a's first row lives — bytes lost to a
/// truncated or corrupt record — and it is a separate type from
/// `ObservationLogTrailer` for the reason `GapSite` sets out at length: that
/// row is a property of *reading* a file, and the trailer is written by a
/// producer that has no reader. Asked for it, a producer fabricates one.
///
/// So the five rows of D6a are reported from two places, and this type is the
/// one that puts them back together: `gapWatches` is the trailer's four, and
/// `droppedBytes` over `bytesScanned` is the fifth, measured here, by the code
/// that scanned the bytes.
///
/// **Three states again, and the same rule.** `droppedBytes == 0` over
/// `bytesScanned == 0` is *no file* — not a clean one. `closedCleanly` is
/// `false` for a log whose producer died before the segment closed, which is a
/// different fault from a truncated tail and must not be read as an empty
/// recording.
public struct ObservationLogReadReport: Hashable, Sendable {
    /// `nil` only for a file whose very first line is damaged — the header is
    /// written at `open`, before any record.
    public let header: ObservationLogHeader?
    /// `nil` means the producer died before the segment closed. See
    /// `ObservationLogTrailer`.
    public let trailer: ObservationLogTrailer?
    /// Complete lines that were neither the header nor the trailer.
    public let recordLines: Int
    /// **How many `logTrailer` lines the file holds**, and whether the last
    /// complete line is one.
    ///
    /// Both, because `closedCleanly` used to be `trailer != nil` and that
    /// verified neither clause of what it claimed. A reader keeps the last
    /// trailer it sees, so two concurrent `close`s writing two trailers — the
    /// state a missing `guard` in `ObservationWriter.close` produces — gave a
    /// non-nil trailer, identical counts, and a green check. "A missing trailer
    /// is the crash signal" rests on there being exactly one and it being last;
    /// nothing in the tree asserted either.
    public let trailerCount: Int
    /// Whether the last **complete** line is the trailer. A partial tail
    /// appended after it does not make this `false` — that is
    /// `droppedBytes`'s job, and they are different faults.
    public let trailerIsLastCompleteLine: Bool
    /// D6a row 1: bytes in a truncated or corrupt final record.
    public let droppedBytes: Int
    /// D6a row 1's companion, without which the line above has two readings.
    public let bytesScanned: Int

    public init(header: ObservationLogHeader?, trailer: ObservationLogTrailer?,
                recordLines: Int, trailerCount: Int, trailerIsLastCompleteLine: Bool,
                droppedBytes: Int, bytesScanned: Int) {
        precondition(recordLines >= 0 && droppedBytes >= 0 && bytesScanned >= 0
                     && trailerCount >= 0,
                     "ObservationLogReadReport has a negative count")
        precondition((trailer != nil) == (trailerCount > 0),
                     "ObservationLogReadReport was handed a trailer and a count of "
                     + "\(trailerCount), or neither and a positive count")
        self.trailerCount = trailerCount
        self.trailerIsLastCompleteLine = trailerIsLastCompleteLine
        precondition(droppedBytes <= bytesScanned,
                     "ObservationLogReadReport dropped \(droppedBytes) of \(bytesScanned) "
                     + "scanned — a reader cannot lose more than it examined")
        self.header = header
        self.trailer = trailer
        self.recordLines = recordLines
        self.droppedBytes = droppedBytes
        self.bytesScanned = bytesScanned
    }

    /// Reads one log file and reports it. The one filesystem call is
    /// `JSONLReader.linesOfFile(at:)`'s.
    public static func read(logAt url: URL) throws -> ObservationLogReadReport {
        let result = try JSONLReader.linesOfFile(at: url)
        var header: ObservationLogHeader?
        var trailer: ObservationLogTrailer?
        var records = 0
        var trailerCount = 0
        var lastCompleteLineWasATrailer = false
        for line in result.lines {
            let kind = try ObservationLog.kind(of: line)
            lastCompleteLineWasATrailer = kind == "logTrailer"
            switch kind {
            case "logHeader": header = try ObservationLog.decode(line)
            case "logTrailer":
                trailer = try ObservationLog.decode(line)
                trailerCount += 1
            default: records += 1
            }
        }
        return ObservationLogReadReport(header: header, trailer: trailer,
                                        recordLines: records,
                                        trailerCount: trailerCount,
                                        trailerIsLastCompleteLine: lastCompleteLineWasATrailer,
                                        droppedBytes: result.droppedBytes,
                                        bytesScanned: result.bytesScanned)
    }

    /// Whether the segment this log belongs to closed **once, at the end**.
    ///
    /// `false` is a crash, and it is a different fault from a truncated tail: a
    /// log can have a clean tail and no trailer (the process was killed between
    /// records), or a trailer and a damaged tail (something appended
    /// afterwards).
    ///
    /// All three clauses, not just the first. `trailer != nil` was what this
    /// used to be, and it is satisfied by two trailers — a reader keeps the
    /// last one it sees — and by a trailer with records after it. Both are
    /// states a writer can reach, and both make "a missing trailer is the crash
    /// signal" mean nothing.
    public var closedCleanly: Bool {
        trailerCount == 1 && trailerIsLastCompleteLine
    }

    /// Why `closedCleanly` is `false`, for a reader that needs to act on it.
    /// `nil` when it is `true`.
    public var closeFault: String? {
        switch trailerCount {
        case 1 where trailerIsLastCompleteLine: nil
        case 0: "no trailer: the producer died before this segment closed"
        case 1: "the trailer is not the last line: something appended after the segment closed"
        default: "\(trailerCount) trailers: this segment was closed more than once"
        }
    }

    /// Whether anything was read at all. `droppedBytes == 0` means nothing
    /// only when this is `true`.
    public var isAMeasurement: Bool { bytesScanned > 0 }

    /// All five D6a rows: the producer's four, plus this read's own.
    ///
    /// The fifth is deliberately **not** a `GapWatch` — see `GapSite`. It is
    /// returned as the pair it is, so a caller cannot append it to the other
    /// four and lose which side measured it.
    public var producerGapWatches: [GapWatch] { trailer?.gapWatches ?? [] }

    /// The read side's own row, in the shape D6a asks for: the loss, and the
    /// evidence something looked.
    public var truncatedTailAccounting: String {
        var line = "jsonlTruncatedTail: \(droppedBytes) byte(s) lost"
            + "  ←  \(bytesScanned) byte(s) scanned across \(recordLines) record line(s)"
        if !isAMeasurement { line += "   ← NOTHING WAS READ; 0 dropped is not a measurement" }
        return line
    }

    /// Every D6a row for this log in one block, from both sides, each labelled
    /// with which side measured it.
    public var accounting: String {
        var lines = ["producer (trailer):"]
        if let trailer {
            lines.append(contentsOf: trailer.accounting.split(separator: "\n").map { "  " + $0 })
        } else {
            lines.append("  NO TRAILER — the producer died before this segment closed, so none of "
                         + "D6a's four producer rows was written for it")
        }
        lines.append("reader (this read):")
        lines.append("  " + truncatedTailAccounting)
        return lines.joined(separator: "\n")
    }
}
