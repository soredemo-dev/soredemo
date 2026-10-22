import Foundation

/// Reads an append-only observation log, applying the truncated-tail rule: a
/// crash mid-write leaves a partial final line, which is dropped but whose byte
/// count is reported. That report is why this exists rather than `split`.
///
/// Takes `Data`, not a URL, so it stays a pure function; `linesOfFile(at:)` is the
/// filesystem helper.
public enum JSONLReader {
    public struct Result: Sendable, Equatable {
        public let lines: [Data]
        public let droppedBytes: Int
        /// How many bytes this reader examined; `droppedBytes`'s companion. Read
        /// them together: `droppedBytes 0 of bytesScanned 0` is not a clean file,
        /// it is no file.
        public let bytesScanned: Int

        /// The two numbers above, which only mean something together.
        public var accounting: String {
            var line = "dropped \(droppedBytes) byte(s) of \(bytesScanned) scanned"
                + " across \(lines.count) complete line(s)"
            if bytesScanned == 0 { line += "   ← NOTHING WAS READ; 0 dropped is not a measurement" }
            return line
        }
    }

    /// A line is terminated by `\n` (0x0A); bytes after the final `\n` are dropped
    /// and counted in `droppedBytes`. An empty line is a complete zero-length
    /// record, preserved as empty `Data` rather than skipped.
    public static func lines(from data: Data) -> Result {
        var lines: [Data] = []
        var recordStart = data.startIndex
        var index = data.startIndex
        let newline: UInt8 = 0x0A

        while index < data.endIndex {
            if data[index] == newline {
                // `Data(...)`, not the bare slice: a slice keeps the parent's
                // indices, so `line[0]` traps on every line after the first.
                lines.append(Data(data[recordStart..<index]))
                index = data.index(after: index)
                recordStart = index
            } else {
                index = data.index(after: index)
            }
        }

        let droppedBytes = data.distance(from: recordStart, to: data.endIndex)
        return Result(lines: lines, droppedBytes: droppedBytes,
                      bytesScanned: data.distance(from: data.startIndex, to: data.endIndex))
    }

    /// The filesystem helper; the truncated-tail rule itself lives in `lines(from:)`.
    public static func linesOfFile(at url: URL) throws -> Result {
        lines(from: try BoundedRead.data(at: url, limit: BoundedRead.observationLogLimit))
    }
}
