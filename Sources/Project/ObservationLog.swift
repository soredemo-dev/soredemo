import Foundation

/// The on-disk observation log: JSONL, append-only, one file per master segment.
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

    public static func encode(_ value: some Encodable) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]   // measured: without it, key order is per-process random — see ObservationLogTests.encodedKeysAreInSortedOrderNotJustRoundTrippable
        return try e.encode(value)
    }

    public static func decode<T: Decodable>(_ line: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: line)
    }
}
