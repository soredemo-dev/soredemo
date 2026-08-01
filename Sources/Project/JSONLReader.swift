import Foundation

/// Reads an append-only observation log, applying the truncated-tail rule
/// (D-P3, Controller addendum ruling 3).
///
/// A crash mid-write leaves a partial final line on disk. Silently dropping
/// it would turn a crash into a quietly shortened observation log — a log
/// short by one record is a derivation that is wrong with no diagnostic.
/// So the reader drops the partial tail (there is no way to make a partial
/// JSON record usable) but REPORTS how many bytes it dropped, which is the
/// whole point of this type existing rather than `data.split(separator:)`.
///
/// Takes `Data`, not a URL: the reader stays a pure function of its input,
/// which is what lets it be tested exhaustively without a filesystem. A
/// one-line helper (`linesOfFile(at:)` below) does the one `Data(contentsOf:)`
/// call needed to use this against a real file.
public enum JSONLReader {
    public struct Result: Sendable, Equatable {
        public let lines: [Data]
        public let droppedBytes: Int
    }

    /// A line is terminated by `\n` (0x0A). Any bytes after the final `\n`
    /// are an incomplete record and are dropped; their count is
    /// `droppedBytes`.
    ///
    /// Decision, stated per Controller addendum ruling 3: an empty line
    /// (two adjacent `\n`s, or a leading `\n`) is a complete, zero-length
    /// record — preserved as an empty `Data` in `lines`, not dropped and not
    /// collapsed into the next line. This falls directly out of taking "a
    /// line is terminated by `\n`" literally: nothing here special-cases a
    /// zero-length line, so it gets exactly the same treatment as any other
    /// terminated line. The alternative (silently skipping empty lines)
    /// would be defensible too, but would need its own justification for
    /// why an empty line is not itself a valid append the way every other
    /// terminated line is.
    public static func lines(from data: Data) -> Result {
        var lines: [Data] = []
        var recordStart = data.startIndex
        var index = data.startIndex
        let newline: UInt8 = 0x0A

        while index < data.endIndex {
            if data[index] == newline {
                lines.append(data[recordStart..<index])
                index = data.index(after: index)
                recordStart = index
            } else {
                index = data.index(after: index)
            }
        }

        let droppedBytes = data.distance(from: recordStart, to: data.endIndex)
        return Result(lines: lines, droppedBytes: droppedBytes)
    }

    /// The one-line filesystem helper the doc comment above promises.
    /// Everything about the truncated-tail rule itself lives in `lines(from:)`,
    /// which never touches a URL.
    public static func linesOfFile(at url: URL) throws -> Result {
        lines(from: try Data(contentsOf: url))
    }
}
