import Foundation
import Project
import Timeline

/// **One observation log per master segment, written as it happens.**
///
/// D2-12 Q3: one JSONL file per segment, append-only, under `observations/`. A
/// crash then damages only the current segment's log, and `JSONLReader`'s
/// truncated-tail rule has exactly one file it can apply to — rather than one
/// file whose damaged tail is the whole recording's.
///
/// **Nothing is buffered across a segment, and that is the point of
/// append-only rather than an implementation detail.** Each `append` is one
/// `FileHandle.write(contentsOf:)` of the record's bytes plus `\n`, straight to
/// the file descriptor. `FileHandle` is not a `FILE*` — there is no userspace
/// buffer between this and the kernel — so what a crash costs is the tail the
/// page cache had not flushed, not the segment. Collecting records in an array
/// and writing them at `close` would be faster and would lose everything on the
/// one path this design exists for.
///
/// (Durability is a separate question and is answered the same way
/// `ProjectPackageIO` answers it: no `F_FULLFSYNC`, deliberately. A power cut
/// can still cost whatever the page cache held. What is bought here is that a
/// *process* crash — the case this app can actually cause — costs a tail whose
/// size `JSONLReader.droppedBytes` reports.)
///
/// **What this type refuses.** Two things, both at `append`, which is the last
/// moment the producer that made the mistake is still on the stack:
///
///   * a record stamped with a boot epoch other than the log's
///     (`ObservationLog.checkEpoch(of:against:)` — see there for why the log
///     carries an epoch of its own at all);
///   * a record whose encoded bytes contain a literal newline, which would
///     split one record into two lines and be reported by `JSONLReader` as two
///     clean records with **zero dropped bytes**. Foundation's `JSONEncoder`
///     escapes newlines inside strings, so this cannot fire today; it is here
///     because its failure mode is silent and looks like success, which is the
///     shape this project keeps paying for.
///
/// **The straddling-observation rule (D2-12).** An observation whose AX chain
/// extends past a segment boundary belongs to the segment **its click happened
/// in** — the click is the anchor, the chain is its attribute. Nothing here
/// splits a chain: `append` is called with the whole `AXChainRecord` on
/// whichever writer was open when the button event was stamped. Because each
/// chain element carries its own `readInterval`, a chain reaching past the
/// boundary is *detectable* after the fact by comparing against the trailer's
/// `hostRange`, which is one more real input for `framing-gates`'
/// `observation stale`. That detectability is the reason the rule is anchoring
/// rather than clipping.
///
/// **`.window` sources: a pointer sample's revision can never equal the
/// segment's.** A window `CaptureSource` mints its own `GeometryRevision`
/// (`CaptureSource.geometry`), while `InputObserver` normalises against the
/// display the pointer routed to. Nothing here compares the two, and nothing
/// downstream should read the header's `revision` as one a record's revision
/// must match. Whether that divergence is intended is a `camera-motion`
/// question; the log is built so that it is not an error here.
final class ObservationWriter: @unchecked Sendable {

    // **`nonisolated` on every member below, deliberately — not left to
    // `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.** This type's whole purpose
    // is to be called from the threads the observations arrive on:
    // `InputObserver`'s tap callback (a `nonisolated` synchronous CoreGraphics
    // callback), `AXObserver`'s own queue, and `CaptureSession`'s sample queue.
    // Unannotated, each method here is implicitly main-actor, and calling one
    // from any of those **traps at runtime rather than failing to compile** —
    // `_swift_task_checkIsolatedSwift` → `dispatch_assert_queue_fail`, inside
    // `withLock`'s closure, with no diagnostic anywhere before it runs.
    //
    // That is not hypothetical and it is not a precaution: it is what this
    // file did until § 9.9 of the cross-boundary probe was written. Eight
    // concurrent `append`s crashed the probe, and the crash report named the
    // isolation check. The same reasoning, and the same discovery, as
    // `CaptureSession`'s own header — recorded here rather than referenced,
    // because the next person to add a method to this class needs it at the
    // point of the edit.


    enum WriterError: Error, Equatable {
        /// A log already exists for this segment. Append-only means the file
        /// is opened once; a second open would interleave two segments'
        /// records into one file, and the interleaving would be invisible
        /// afterwards because every record carries its own instant and would
        /// look sorted.
        case logAlreadyExists(String)
        /// `append` or `close` after `close`.
        case logIsClosed
        /// A record encoded to bytes containing a literal `\n`. See the type
        /// documentation.
        case recordSpansTwoLines(kind: String)
    }

    /// `observations/segment-NN.jsonl`, matching `master-NN.mov`'s two-digit
    /// form so the pair is obvious in a directory listing and sorts the same
    /// way. `CaptureSession.beginSegment` mints the media name with the
    /// identical `%02d`.
    nonisolated static func logFilename(forSegment index: Int) -> String {
        "segment-\(String(format: "%02d", index)).jsonl"
    }

    nonisolated static func logURL(forSegment index: Int, in packageURL: URL) -> URL {
        packageURL
            .appending(path: "observations", directoryHint: .isDirectory)
            .appending(path: logFilename(forSegment: index), directoryHint: .notDirectory)
    }

    /// The reverse of the pairing `logFilename(forSegment:)`'s own doc comment states: given a
    /// media file's URL, the observation log this app expects to find BESIDE it, if that media
    /// URL has the exact shape `beginSegment` produces — `<package>/media/master-NN.mov` — and
    /// `nil` otherwise.
    ///
    /// **A candidate URL, not a promise the file exists.** The caller (`StageWindow.load()`) still
    /// has to check the filesystem: a capture that ran without Input Monitoring produces media
    /// with no observation log beside it at all (`ObservationBlindness
    /// .inputMonitoringUnavailable`), and this function cannot tell that apart from "nothing has
    /// looked here yet" — nor should it try to; that is exactly the ambiguity
    /// `ObservationLogReadReport`'s own header refuses to collapse. Returning a URL here is a
    /// STATEMENT ABOUT NAMING ONLY: "if a log for this media exists, this is where it would be."
    ///
    /// `nil` when `mediaURL`'s parent directory is not literally named `media`, or its filename
    /// does not match `master-NN.mov` for some non-negative integer `NN`. Before Task 5.5,
    /// `ContentView`'s scratch `TemporaryFileMediaSink` wrote flatly into a temporary directory with
    /// no `media/` parent and no `ObservationWriter` behind it at all, so this function correctly
    /// answered `nil` for every recording that sink produced. Task 5.5 gave that sink a `media/`
    /// subdirectory and `CaptureSession` an `ObservationWriter` writing `observations/` beside it —
    /// the same convention this function already derives — so a recording made through it now has a
    /// log here whenever observation was not blind for the whole segment.
    nonisolated static func expectedLogURL(forMediaURL mediaURL: URL) -> URL? {
        guard mediaURL.pathExtension == "mov",
              mediaURL.deletingLastPathComponent().lastPathComponent == "media" else { return nil }
        let name = mediaURL.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("master-") else { return nil }
        let digits = name.dropFirst("master-".count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let index = Int(digits) else { return nil }
        let packageURL = mediaURL.deletingLastPathComponent().deletingLastPathComponent()
        return logURL(forSegment: index, in: packageURL)
    }

    nonisolated let url: URL
    private nonisolated let header: ObservationLogHeader
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var handle: FileHandle?
    /// One count per `kind` appended. A key present with a zero value and a
    /// key absent are different facts on disk — see
    /// `ObservationLogTrailer.recordCounts` — so this starts empty and gains a
    /// key the first time a kind is written. A producer that wants to say "I
    /// emit this kind and saw none" declares it with `declareRecordKind(_:)`.
    private nonisolated(unsafe) var recordCounts: [String: Int] = [:]

    private nonisolated init(url: URL, header: ObservationLogHeader, handle: FileHandle) {
        self.url = url
        self.header = header
        self.handle = handle
    }

    /// Opens the log for one segment and writes its header line immediately.
    ///
    /// The header goes down before any record, so a log truncated to its first
    /// line still says which segment, which media file and which boot epoch it
    /// belongs to. A header written at `close` alongside the trailer would be
    /// absent from exactly the logs that need identifying.
    nonisolated static func open(segment header: ObservationLogHeader,
                                 in packageURL: URL) throws -> ObservationWriter {
        let fm = FileManager.default
        let directory = packageURL.appending(path: "observations", directoryHint: .isDirectory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = logURL(forSegment: header.segmentIndex, in: packageURL)
        guard !fm.fileExists(atPath: url.path) else {
            throw WriterError.logAlreadyExists(logFilename(forSegment: header.segmentIndex))
        }
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw WriterError.logAlreadyExists(logFilename(forSegment: header.segmentIndex))
        }
        let handle = try FileHandle(forWritingTo: url)
        let writer = ObservationWriter(url: url, header: header, handle: handle)
        try writer.writeLine(try ObservationLog.encode(header), kind: header.kind, counted: false)
        return writer
    }

    /// Records that this writer emits `kind` even if it never sees one, so the
    /// trailer's `recordCounts` carries `kind: 0` rather than no key at all.
    ///
    /// The two are different facts (`ObservationLogTrailer.recordCounts`), and
    /// only the producer knows which applies: a run with Input Monitoring
    /// denied emits no `pointer` records and **does not** emit them, while a
    /// run with the grant held and a still mouse emits none and does.
    nonisolated func declareRecordKind(_ kind: String) {
        lock.withLock { if recordCounts[kind] == nil { recordCounts[kind] = 0 } }
    }

    /// Appends one record as one line. Not buffered — see the type
    /// documentation.
    nonisolated func append(_ record: some ObservationRecord) throws {
        try ObservationLog.checkEpoch(of: record, against: header.epoch)
        try writeLine(try ObservationLog.encode(record), kind: record.kind, counted: true)
    }

    private nonisolated func writeLine(_ bytes: Data, kind: String, counted: Bool) throws {
        try lock.withLock { try writeLineLocked(bytes, kind: kind, counted: counted) }
    }

    /// The lock is **not** taken here. `NSLock` is not reentrant, and `close`
    /// has to hold it across snapshot → build → encode → write → close; see
    /// there for why that whole sequence is one critical section.
    private nonisolated func writeLineLocked(_ bytes: Data, kind: String, counted: Bool) throws {
        guard !bytes.contains(UInt8(ascii: "\n")) else {
            throw WriterError.recordSpansTwoLines(kind: kind)
        }
        var line = bytes
        line.append(UInt8(ascii: "\n"))
        guard let handle else { throw WriterError.logIsClosed }
        try handle.write(contentsOf: line)
        if counted { recordCounts[kind, default: 0] += 1 }
    }

    /// Writes the trailer and closes the file.
    ///
    /// **Three parameters where the plan wrote one.** `endedBy` alone cannot
    /// produce a trailer: `hostRange` is the segment's own span, which is not
    /// known until it closes and is what makes "every record's instant lies
    /// inside its segment" checkable from the log without the manifest; and
    /// `gapWatches` is Addition A — one row per `GapSite`, mandatory, refused
    /// by `ObservationLogTrailer`'s initialiser if a site is missing. A
    /// defaulted argument for either would be a value nothing measured
    /// sitting in the field a reader trusts.
    /// **One critical section, from the count snapshot to the file being
    /// closed**, and that is a correction rather than caution.
    ///
    /// This used to snapshot `recordCounts` under the lock, release it, encode
    /// the trailer, then take the lock again to write. The intended load is
    /// exactly concurrent — the tap callback thread and the AX queue both call
    /// `append` — and three things fell through the gap:
    ///
    ///   * an `append` between the snapshot and the write lands **before** the
    ///     trailer and is **missing from its counts**. The trailer then says
    ///     1199 where 1200 record lines are on disk, and a reader using
    ///     `recordCounts` to detect loss concludes truncation where there was
    ///     none — a fabricated fault, in the field a reader trusts to find
    ///     real ones;
    ///   * an `append` **after** the trailer write breaks "the trailer is the
    ///     last line", which is the premise of "a missing trailer is the crash
    ///     signal";
    ///   * two concurrent `close`s write two trailers.
    ///
    /// Holding the lock across `ObservationLog.encode` is deliberate. The
    /// trailer is a few hundred bytes and encoding it is bounded; the
    /// alternative is the gap above.
    @discardableResult
    nonisolated func close(endedBy boundary: SegmentBoundary,
                       hostRange: HostRange,
                       gapWatches: [GapWatch]) throws -> URL {
        try lock.withLock {
            guard handle != nil else { throw WriterError.logIsClosed }
            let trailer = ObservationLogTrailer(segmentIndex: header.segmentIndex,
                                                hostRange: hostRange,
                                                endedBy: boundary,
                                                recordCounts: recordCounts,
                                                gapWatches: gapWatches)
            try writeLineLocked(try ObservationLog.encode(trailer),
                                kind: trailer.kind, counted: false)
            try handle?.close()
            handle = nil
        }
        return url
    }

    /// What has been written so far, for a caller assembling the trailer.
    nonisolated var countsSoFar: [String: Int] { lock.withLock { recordCounts } }
}

// MARK: - the blindness a whole segment inherits

extension CaptureError {
    /// The header field this error becomes.
    ///
    /// `CaptureError.inputMonitoringUnavailable` maps to
    /// `CapturePermissions`' `.observationBlind`, and **nothing wrote it
    /// anywhere until `ObservationLogHeader.blindness`**. This is that
    /// mapping, in one place, so a caller catching a `CaptureError` at
    /// observation start-up puts it in the log rather than deciding
    /// per-call-site what it means.
    ///
    /// `.alreadyObserving` returns `nil` on purpose: it is a programming
    /// error in this app's own state machine, not a statement about what the
    /// recording could see. Recording it as blindness would put a bug in the
    /// field a reader uses to decide whether a user's permissions were the
    /// problem.
    var blindness: ObservationBlindness? {
        switch self {
        case .inputMonitoringUnavailable: .inputMonitoringUnavailable
        case .eventTapRunLoopSourceUnavailable: .eventTapRunLoopSourceUnavailable
        case .alreadyObserving: nil
        }
    }
}
