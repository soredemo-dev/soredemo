import Foundation

/// Reads a document's schema version without decoding the document, by decoding a
/// struct carrying `schemaVersion` alone. Required because a document from a
/// future build fails to decode as `ProjectSnapshot` entirely, and must still be
/// routed to `ProjectFormatError.tooNew` rather than an opaque decode failure.
public enum SchemaProbe {
    private struct VersionOnly: Decodable {
        let schemaVersion: Int
    }

    public static func version(of data: Data) throws -> Int {
        do {
            return try JSONDecoder().decode(VersionOnly.self, from: data).schemaVersion
        } catch {
            throw ProjectFormatError.malformed(String(describing: error))
        }
    }
}
