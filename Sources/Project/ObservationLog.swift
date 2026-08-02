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
