import Foundation
import Geometry
import Timeline

/// The on-disk observation log: JSONL, append-only, one file per master segment. A
/// record may never carry typed text, control contents (`kAXValueAttribute` and
/// neighbours), the pasteboard, or other applications' windows.
public enum ObservationLog {
    /// This log's own version; v1 logs are refused outright, with no migration. Bump
    /// when a key's name, type or meaning changes, or a case leaves an enum.
    public static let schemaVersion: Int = 2

    private struct KindOnly: Decodable { let kind: String }

    /// Reads a record's kind without decoding it, so an unknown type can be skipped.
    public static func kind(of line: Data) throws -> String {
        do { return try JSONDecoder().decode(KindOnly.self, from: line).kind }
        catch { throw ProjectFormatError.malformed(String(describing: error)) }
    }

    /// `.sortedKeys` is required: Darwin's key order is otherwise per-process random.
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
    /// An instant from a boot session other than the log's.
    case foreignEpoch(kind: String, expected: UUID, found: UUID)
    /// An empty `epochs`: the record cannot be placed on the log's clock.
    case noEpoch(kind: String)
    /// `append` or `close` after `close`.
    case logIsClosed
}

extension ObservationLog {
    /// Throws unless every epoch the record carries — not just the first — equals
    /// the log's single `BootEpoch`; `SegmentTable` cannot represent more than one.
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

// MARK: - The gap register

/// A gap site a producer fills at segment close. A trailer must carry every case, so
/// adding one fails to decode logs this build wrote.
public enum GapSite: String, Codable, Sendable, CaseIterable {
    /// `AXObserver`'s ancestor walk — levels beyond the depth cap or budget.
    case axAncestorWalk
    /// `CaptureSession` video — frames the display did not produce.
    case videoFramesNotProduced
    /// `InputObserver` — events while another app holds a password field.
    case secureInput
    /// `InputObserver` — events between a tap disable and the re-arm.
    case tapDisabled

    /// The unit this site's loss is measured in; disagreeing bytes fail to decode.
    public var lostUnit: GapUnit {
        switch self {
        case .axAncestorWalk: .levels
        case .videoFramesNotProduced: .frames
        case .secureInput, .tapDisabled: .nanoseconds
        }
    }
}

/// The unit a loss is measured in; `bytes` has no `GapSite` and belongs to
/// `ObservationLogReadReport`.
public enum GapUnit: String, Codable, Sendable {
    case bytes
    case nanoseconds
    case frames
    case levels
}

/// A gap, and the evidence that something was looking for it. `looks == 0` means
/// nothing looked, so every other field is then vacuous — `gapsFound == 0` is not a
/// measurement.
public struct GapWatch: Hashable, Codable, Sendable {
    public let site: GapSite
    public let looks: Int
    /// The span the looks cover, first to last, in nanoseconds.
    public let watchedSpanNanos: Int64
    public let gapsFound: Int
    /// How much was lost, in `lostUnit`. An over-estimate wherever the underlying
    /// interval is an enclosing bound (`TapDisabledInterval`).
    public let lost: Int64
    /// Fixed by `site`; encoded so the document is self-describing.
    public let lostUnit: GapUnit

    /// Traps on a negative count or gaps found by zero looks; untrusted input goes
    /// through `init(from:)` instead. `lostUnit` comes from `site`.
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

    public var isAMeasurement: Bool { looks > 0 }

    /// The loss and the evidence something looked, which only mean anything together.
    public var accounting: String {
        let seconds = Double(watchedSpanNanos) / 1e9
        // A local because `unsafe` cannot appear to the right of `+`.
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

    /// Hand-written: a synthesised `Decodable` would bypass the memberwise
    /// `precondition`s, letting `looks == 0, gapsFound == 3` decode off disk.
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

// MARK: - One constructor per producer

extension GapWatch {
    /// The tap row, from `InputObserver.Diagnostics`.
    public static func tapDisabled(tapEnabledPolls: Int, tapPollingSpanNanos: Int64,
                                   tapDisabledIntervals: Int, tapBlindNanos: Int64) -> GapWatch {
        GapWatch(site: .tapDisabled, looks: tapEnabledPolls,
                 watchedSpanNanos: tapPollingSpanNanos,
                 gapsFound: tapDisabledIntervals, lost: tapBlindNanos)
    }

    /// The secure-input row; `secureInputChecks` counts asks, not answers.
    public static func secureInput(secureInputChecks: Int, secureInputCheckSpanNanos: Int64,
                                   secureInputIntervals: Int, suppressedNanos: Int64) -> GapWatch {
        GapWatch(site: .secureInput, looks: secureInputChecks,
                 watchedSpanNanos: secureInputCheckSpanNanos,
                 gapsFound: secureInputIntervals, lost: suppressedNanos)
    }

    /// The video row, from `CaptureSession.Diagnostics`. `frameCallbacksObserved` is
    /// the sum of `frameStatusCounts.values`, not the post-filter `completeFrameCount`.
    public static func videoFramesNotProduced(frameCallbacksObserved: Int,
                                              observationSpanNanos: Int64,
                                              idleFrames: Int) -> GapWatch {
        GapWatch(site: .videoFramesNotProduced, looks: frameCallbacksObserved,
                 watchedSpanNanos: observationSpanNanos,
                 gapsFound: idleFrames, lost: Int64(idleFrames))
    }

    /// The AX row, from `AXObserver.Diagnostics`. Levels lost is unknowable per walk,
    /// so `lost` counts walks that stopped early — a lower bound of one level each.
    public static func axAncestorWalk(chainsRecorded: Int, observationSpanNanos: Int64,
                                      truncatedWalks: Int) -> GapWatch {
        GapWatch(site: .axAncestorWalk, looks: chainsRecorded,
                 watchedSpanNanos: observationSpanNanos,
                 gapsFound: truncatedWalks, lost: Int64(truncatedWalks))
    }
}

// MARK: - The two records that bracket a log

/// Why observation was degraded for a whole segment. Stated, never inferred: a
/// recording made without Input Monitoring is byte-identical to one of nobody
/// touching the mouse.
public enum ObservationBlindness: String, Codable, Sendable, CaseIterable {
    /// `CGEvent.tapCreate` returned `nil` — Input Monitoring not granted; no
    /// pointer track, clicks or shortcuts for the whole segment.
    case inputMonitoringUnavailable
    /// The grant is held and run-loop plumbing failed; same consequence, other cause.
    case eventTapRunLoopSourceUnavailable
    /// Accessibility not granted: clicks are recorded, their object half is not.
    case accessibilityUnavailable
}

/// The first line of every log, and the join to the segment table: `segmentIndex`
/// and `mediaFilename` are copied from the accompanying `MasterSegment`.
public struct ObservationLogHeader: Hashable, Codable, Sendable {
    public let kind: String
    public let schemaVersion: Int
    /// The log's clock and the only field that dates a recording; not an ordering key.
    /// `anchor.epoch` is the epoch every record in this log must carry.
    public let anchor: EpochAnchor
    public var epoch: BootEpoch { anchor.epoch }
    public let segmentIndex: Int
    /// Relative, never absolute — the rule `MasterSegment.mediaFilename` keeps.
    public let mediaFilename: String
    public let revision: GeometryRevision
    /// What could not be observed for this whole segment. Non-optional, so `[]`
    /// asserts the permissions were checked; a log without the key fails to decode.
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

    /// Hand-written to validate `kind` and `schemaVersion`, which a synthesised
    /// `Decodable` would assign from the bytes; any other version is refused first.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard kind == "logHeader" else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "expected kind 'logHeader', found '\(kind)'"))
        }
        // Distinct errors: newer builds can read this file, older formats cannot be read.
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

    /// Matches the synthesised wire shape exactly; only validation is hand-written.
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

/// The last line of every log, written on `close` — the first moment the segment's
/// `HostRange` and boundary reason are known. A log with no trailer crashed.
public struct ObservationLogTrailer: Hashable, Codable, Sendable {
    public let kind: String
    public let segmentIndex: Int
    /// Copied from the `MasterSegment`, so record instants can be checked without it.
    public let hostRange: HostRange
    public let endedBy: SegmentBoundary
    /// Records appended per `kind`. `"pointer": 0` means none occurred; an absent
    /// key means this producer does not emit them.
    public let recordCounts: [String: Int]
    /// One row per `GapSite`, all of them, every time.
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

    /// The gap rows nothing was watching; check before quoting any zero from this log.
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

    /// Hand-written: a trailer missing a site reads as "no gaps there", which a
    /// synthesised `Decodable` would accept. Throws rather than traps — untrusted bytes.
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

// MARK: - The reader-side gap row

/// What reading one log back found: bytes lost to a truncated record, which only a
/// reader can measure. `droppedBytes == 0` over `bytesScanned == 0` is no file.
public struct ObservationLogReadReport: Hashable, Sendable {
    /// `nil` only for a file whose first line is damaged; the header precedes records.
    public let header: ObservationLogHeader?
    /// `nil` means the producer died before the segment closed.
    public let trailer: ObservationLogTrailer?
    /// Complete lines that were neither header nor trailer.
    public let recordLines: Int
    /// How many `logTrailer` lines the file holds; a clean close needs exactly one.
    public let trailerCount: Int
    /// Whether the last complete line is the trailer; a partial tail after it does not
    /// make this `false`.
    public let trailerIsLastCompleteLine: Bool
    /// Bytes in a truncated or corrupt final record; read with `bytesScanned`.
    public let droppedBytes: Int
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

    /// Reads one log file and reports it; the sole filesystem call is `JSONLReader`'s.
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

    /// Whether the segment closed once, at the end; `trailer != nil` alone would
    /// accept two trailers, or records after one.
    public var closedCleanly: Bool {
        trailerCount == 1 && trailerIsLastCompleteLine
    }

    /// Why `closedCleanly` is `false`; `nil` when it is `true`.
    public var closeFault: String? {
        switch trailerCount {
        case 1 where trailerIsLastCompleteLine: nil
        case 0: "no trailer: the producer died before this segment closed"
        case 1: "the trailer is not the last line: something appended after the segment closed"
        default: "\(trailerCount) trailers: this segment was closed more than once"
        }
    }

    /// Whether anything was read; `droppedBytes == 0` means something only if `true`.
    public var isAMeasurement: Bool { bytesScanned > 0 }

    /// The producer's rows. The read side's row is deliberately not a `GapWatch`, so
    /// it cannot be appended and lose which side measured it.
    public var producerGapWatches: [GapWatch] { trailer?.gapWatches ?? [] }

    /// The read side's own row: the loss, and the evidence something looked.
    public var truncatedTailAccounting: String {
        var line = "jsonlTruncatedTail: \(droppedBytes) byte(s) lost"
            + "  ←  \(bytesScanned) byte(s) scanned across \(recordLines) record line(s)"
        if !isAMeasurement { line += "   ← NOTHING WAS READ; 0 dropped is not a measurement" }
        return line
    }

    /// Every gap row for this log, each labelled with the side that measured it.
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
