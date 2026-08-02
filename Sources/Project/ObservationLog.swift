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
    public static let schemaVersion: Int = 1

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

/// One row of `docs/ARCHITECTURE.md` D6a — every place this app can fail to
/// observe.
///
/// A `String` raw value, and `CaseIterable`, because
/// `ObservationLogTrailer.init(from:)` requires **every** case to be present in
/// a decoded trailer. Adding a sixth row to D6a therefore fails to decode logs
/// this build wrote, which is the loud direction: a site that a version knew
/// about and did not report is the exact ambiguity this whole type exists to
/// remove.
public enum GapSite: String, Codable, Sendable, CaseIterable {
    /// `JSONLReader` — bytes in a truncated or corrupt record.
    case jsonlTruncatedTail
    /// `AXObserver`'s ancestor walk — levels beyond the depth cap or budget.
    case axAncestorWalk
    /// `CaptureSession` video — frames the display did not produce.
    case videoFramesNotProduced
    /// `InputObserver` — every event while another app holds a password field.
    case secureInput
    /// `InputObserver` — every event between a tap disable and the re-arm.
    case tapDisabled
}

/// The unit the loss at a site is measured in. Named rather than assumed,
/// because D6a's whole argument is that a gap must be quantified **in the unit
/// that was lost** — bytes for bytes, nanoseconds for time — and a bare `Int64`
/// with no unit invites the next reader to sum two of them.
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
    public let lostUnit: GapUnit

    /// `precondition`, not `throw`: a producer assembling this from its own
    /// diagnostics cannot legitimately produce a negative count or claim gaps
    /// it never looked for. Untrusted input arrives through `init(from:)`
    /// below, which throws.
    public init(site: GapSite, looks: Int, watchedSpanNanos: Int64,
                gapsFound: Int, lost: Int64, lostUnit: GapUnit) {
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
        self.lostUnit = lostUnit
    }

    /// Whether `gapsFound` is a statement about the world. `false` means
    /// nothing was looking, and the row says nothing about whether gaps
    /// happened.
    public var isAMeasurement: Bool { looks > 0 }

    /// The two numbers that only mean something together, in the shape
    /// `InputObserver.Diagnostics.tapAccounting` already prints.
    public var accounting: String {
        let seconds = Double(watchedSpanNanos) / 1e9
        var line = "\(site.rawValue): \(gapsFound) gap(s), \(lost) \(lostUnit.rawValue) lost"
            + "  ←  \(looks) look(s) over " + String(format: "%.3f", seconds) + " s"
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
        self.init(site: site, looks: looks, watchedSpanNanos: span,
                  gapsFound: gapsFound, lost: lost, lostUnit: lostUnit)
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
    /// **The log's clock.** See `ObservationLog.checkEpoch(of:against:)` for
    /// why this is at the log level and not left to the per-record epochs
    /// `HostInstant` already carries.
    public let epoch: BootEpoch
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

    public init(epoch: BootEpoch, segmentIndex: Int, mediaFilename: String,
                revision: GeometryRevision, blindness: [ObservationBlindness]) {
        self.kind = "logHeader"
        self.schemaVersion = ObservationLog.schemaVersion
        self.epoch = epoch
        self.segmentIndex = segmentIndex
        self.mediaFilename = mediaFilename
        self.revision = revision
        self.blindness = blindness
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
