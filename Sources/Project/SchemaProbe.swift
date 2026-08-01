import Foundation

/// Reads a document's schema version WITHOUT decoding the document.
///
/// That is this type's entire reason to exist (Controller addendum ruling
/// 2): a build cannot know how to decode a document until it knows the
/// document's version, so decoding into `ProjectSnapshot` first and reading
/// `.schemaVersion` off it defeats the purpose — a v2 document written by a
/// future build would fail to decode as `ProjectSnapshot` at all, and a v1
/// build must still be able to probe its version to route it to
/// `ProjectFormatError.tooNew` rather than an opaque decode failure.
///
/// The probe decodes a minimal private struct carrying `schemaVersion`
/// alone. `Decodable` synthesis ignores any key it does not declare, so
/// every other field in the document — known, unknown, or absent — is
/// simply never looked at.
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
