import Foundation

/// Reads a whole file, but only after its size says it can be what it claims to be.
///
/// **A `.soredemo` package is a document people send each other**, and its log and manifest were
/// read whole into memory before anything looked at them: a crafted multi-gigabyte log was a way
/// to exhaust memory the moment a project opened. The size is asked of the file system first.
///
/// **The limits are from measurement, not from taste** (`HeadlessFixtures/segment-00-redacted
/// .jsonl`, 2026-10-22): a pointer line is about 225 bytes at 60 a second, and an accessibility
/// chain up to about 3.4 KB a click — roughly 80 MB of log per hour of take. 1 GiB is about twelve
/// hours of one segment, more than any take this app writes. A manifest is the edit, captions
/// included; a multi-hour transcript is a few megabytes, so 64 MiB is generous.
public enum BoundedRead {
    public static let observationLogLimit = 1 << 30
    public static let manifestLimit = 64 << 20

    /// The refusal names both numbers, so a person can tell a damaged file from a real one.
    public struct TooLarge: Error, Equatable, CustomStringConvertible {
        public let bytes: Int
        public let limit: Int
        public var description: String {
            "the file is \(bytes) bytes, larger than the \(limit) any recording or edit of this app produces"
        }
    }

    public static func data(at url: URL, limit: Int) throws -> Data {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        if let size, size > limit { throw TooLarge(bytes: size, limit: limit) }
        return try Data(contentsOf: url)
    }
}
