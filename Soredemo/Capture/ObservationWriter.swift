import Foundation
import Project
import Timeline

/// One append-only JSONL observation log per master segment, under `observations/`.
///
/// Each `append` is one unbuffered `FileHandle.write(contentsOf:)` of the record's bytes plus a
/// newline, so a process crash costs only the tail the page cache had not flushed. No
/// `F_FULLFSYNC`: a power cut can still cost whatever the page cache held.
///
/// `append` refuses a record stamped with a boot epoch other than the log's, and a record whose
/// encoded bytes contain a literal newline (`JSONLReader` would read that as two clean records
/// with zero dropped bytes).
///
/// An observation whose AX chain extends past a segment boundary belongs to the segment its
/// click happened in; chains are never split.
final class ObservationWriter: @unchecked Sendable {

    // `nonisolated` on every member below: the target builds with
    // `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and observations arrive on
    // `InputObserver`'s tap callback, `AXObserver`'s queue and `CaptureSession`'s sample queue.
    // An unannotated member is implicitly main-actor and traps at runtime — not at compile
    // time — when called from any of them.


    enum WriterError: Error, Equatable {
        /// A log already exists for this segment; append-only means the file is opened once.
        case logAlreadyExists(String)
        /// `append` or `close` after `close`.
        case logIsClosed
        /// A record encoded to bytes containing a literal `\n`.
        case recordSpansTwoLines(kind: String)
    }

    /// `observations/segment-NN.jsonl`, matching the `%02d` form of `master-NN.mov`.
    nonisolated static func logFilename(forSegment index: Int) -> String {
        "segment-\(String(format: "%02d", index)).jsonl"
    }

    nonisolated static func logURL(forSegment index: Int, in packageURL: URL) -> URL {
        packageURL
            .appending(path: "observations", directoryHint: .isDirectory)
            .appending(path: logFilename(forSegment: index), directoryHint: .notDirectory)
    }

    /// Where the observation log for `mediaURL` would live, given media of the exact shape
    /// `<package>/media/master-NN.mov`; `nil` for any other shape.
    ///
    /// A statement about naming only — the caller must still check the filesystem, since a
    /// capture that ran without Input Monitoring produces media with no log beside it.
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
    /// One count per `kind` appended. A key present with a zero value and a key absent are
    /// different facts on disk; a producer declares a kind it saw none of with
    /// `declareRecordKind(_:)`.
    private nonisolated(unsafe) var recordCounts: [String: Int] = [:]

    private nonisolated init(url: URL, header: ObservationLogHeader, handle: FileHandle) {
        self.url = url
        self.header = header
        self.handle = handle
    }

    /// Opens the log for one segment and writes its header line immediately, so a log truncated
    /// to its first line still names its segment, media file and boot epoch.
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

    /// Records that this writer emits `kind` even if it never sees one, so the trailer's
    /// `recordCounts` carries `kind: 0` rather than no key at all.
    nonisolated func declareRecordKind(_ kind: String) {
        lock.withLock { if recordCounts[kind] == nil { recordCounts[kind] = 0 } }
    }

    /// Appends one record as one line, unbuffered.
    nonisolated func append(_ record: some ObservationRecord) throws {
        try ObservationLog.checkEpoch(of: record, against: header.epoch)
        try writeLine(try ObservationLog.encode(record), kind: record.kind, counted: true)
    }

    private nonisolated func writeLine(_ bytes: Data, kind: String, counted: Bool) throws {
        try lock.withLock { try writeLineLocked(bytes, kind: kind, counted: counted) }
    }

    /// The lock is not taken here: `NSLock` is not reentrant and `close` holds it across the
    /// whole snapshot → encode → write → close sequence.
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
    /// `hostRange` and `gapWatches` are required rather than defaulted: neither is known before
    /// the segment closes, and `ObservationLogTrailer` refuses a `gapWatches` missing a `GapSite`.
    ///
    /// The whole body is one critical section, from the count snapshot to the file being closed,
    /// including the encode. Releasing the lock to encode lets an `append` land before the
    /// trailer but outside its counts, or after the trailer write, and lets two concurrent
    /// `close`s write two trailers.
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
}

// MARK: - the blindness a whole segment inherits

extension CaptureError {
    /// The `ObservationLogHeader.blindness` field this error becomes, mapped in one place.
    ///
    /// `.alreadyObserving` returns `nil`: it is a programming error in this app's own state
    /// machine, not a statement about what the recording could see.
    var blindness: ObservationBlindness? {
        switch self {
        case .inputMonitoringUnavailable: .inputMonitoringUnavailable
        case .eventTapRunLoopSourceUnavailable: .eventTapRunLoopSourceUnavailable
        case .alreadyObserving: nil
        }
    }
}
