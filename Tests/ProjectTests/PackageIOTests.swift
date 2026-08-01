import Testing
import Foundation
@testable import Project
import Geometry

// MARK: - JSONLReader
//
// Controller addendum ruling 3, and the identity rule from AGENTS.md: a
// fixture set that only contains well-terminated files tests nothing,
// because a well-terminated file (0-byte tail) is the identity of "drop the
// trailing partial line". Every row below is drawn from the addendum's
// fixture table, EXCEPT one — see the comment on
// `dropsAPartialJSONObjectTailAfterTwoFullLines` below.

@Test func jsonlReaderKeepsAllThreeLinesOfAWellTerminatedFile() {
    let result = JSONLReader.lines(from: Data("a\nb\nc\n".utf8))
    #expect(result.lines == [Data("a".utf8), Data("b".utf8), Data("c".utf8)])
    #expect(result.droppedBytes == 0)
}

@Test func dropsATrailingLineWithNoFinalNewline() {
    let result = JSONLReader.lines(from: Data("a\nb\nc".utf8))
    #expect(result.lines == [Data("a".utf8), Data("b".utf8)])
    #expect(result.droppedBytes == 1)
}

/// The addendum's fixture table gives this row as `droppedBytes == 12`. It
/// is wrong: the tail after the final `\n` is `{"partial":`, which is 11
/// bytes — verified independently with `printf '{"partial":' | wc -c` and
/// with `len('{"partial":')` in Python, both giving 11, and by hand-count
/// (`{`,`"`,`p`,`a`,`r`,`t`,`i`,`a`,`l`,`"`,`:` = 11 characters). AGENTS.md:
/// "When a document is wrong, say so" — this test asserts the value the
/// bytes actually produce, not the table's arithmetic.
@Test func dropsAPartialJSONObjectTailAfterTwoFullLines() {
    let result = JSONLReader.lines(from: Data("a\nb\n{\"partial\":".utf8))
    #expect(result.lines == [Data("a".utf8), Data("b".utf8)])
    #expect(result.droppedBytes == 11)
}

@Test func emptyDataYieldsNoLinesAndNoDroppedBytes() {
    let result = JSONLReader.lines(from: Data())
    #expect(result.lines == [])
    #expect(result.droppedBytes == 0)
}

@Test func aFileThatIsEntirelyAnUnterminatedPartialRecordDropsEverything() {
    let result = JSONLReader.lines(from: Data("{\"only\":\"partial\"".utf8))
    #expect(result.lines == [])
    #expect(result.droppedBytes == 17)
}

/// Decision (Controller addendum ruling 3): an empty line between two `\n`s
/// is a complete, zero-length record — preserved as an empty `Data`, not
/// dropped. `"\n"` is one complete line (empty) with nothing left over, so
/// `droppedBytes` is 0. This is what falls out of "a line is terminated by
/// `\n`" taken literally: the reader does not special-case zero-length
/// lines, so an empty line has exactly the same status as any other
/// terminated line.
@Test func aLoneNewlineIsOneEmptyLineNotADroppedByte() {
    let result = JSONLReader.lines(from: Data("\n".utf8))
    #expect(result.lines == [Data()])
    #expect(result.droppedBytes == 0)
}

// MARK: - ProjectPackageIO fixtures
//
// AGENTS.md: every fixture set needs a non-identity value for every
// transform applied to it, and a shared fixed directory name under parallel
// Swift Testing execution is a bug generator (Controller addendum ruling
// 5) — so every test below gets its own hard-coded, literal directory name,
// removed at both the start and the end of the test.

private func packageURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "soredemo-t17-\(name)", directoryHint: .isDirectory)
}

private func freshPackageDirectory(_ name: String) -> URL {
    let url = packageURL(name)
    try? FileManager.default.removeItem(at: url)
    return url
}

private let displayA = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
private let displayB = UUID(uuidString: "F47AC10B-58CC-4372-A567-0E02B2C3D479")!

private func registry() -> GeometryRegistry {
    var registry = GeometryRegistry()
    registry.insert(DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2), observedAt: 100)
    registry.insert(DisplayGeometry(displayUUID: displayB, pixelWidth: 2560, pixelHeight: 1440, scale: 1), observedAt: 200)
    return registry
}

private func snapshot(mediaFilenames: [String] = ["clip-01.mov"]) -> ProjectSnapshot {
    ProjectSnapshot(
        schemaVersion: ProjectSnapshot.currentSchemaVersion,
        geometries: registry(),
        mediaFilenames: mediaFilenames
    )
}

// MARK: - save

@Test func saveCreatesThePackageDirectoryAndItsMediaAndObservationsSubdirectories() throws {
    let url = freshPackageDirectory("save-creates-layout")
    defer { try? FileManager.default.removeItem(at: url) }

    try ProjectPackageIO.save(snapshot(), to: url)

    let media = try url.appending(path: "media").resourceValues(forKeys: [.isDirectoryKey])
    #expect(media.isDirectory == true)
    let observations = try url.appending(path: "observations").resourceValues(forKeys: [.isDirectoryKey])
    #expect(observations.isDirectory == true)
    #expect(FileManager.default.fileExists(atPath: url.appending(path: "project.json").path))
}

@Test func saveThenLoadRoundTripsTheSnapshot() throws {
    let url = freshPackageDirectory("save-load-roundtrip")
    defer { try? FileManager.default.removeItem(at: url) }

    let original = snapshot()
    try ProjectPackageIO.save(original, to: url)
    let loaded = try ProjectPackageIO.load(from: url)

    #expect(loaded == original)
}

/// The atomic replace must leave no trace of its fixed sibling temp name
/// (Controller addendum ruling 1) once `save` returns successfully —
/// `replaceItemAt` removes `project.json.new` on success.
@Test func saveLeavesNoTempFileBehindOnSuccess() throws {
    let url = freshPackageDirectory("save-no-temp-leftover")
    defer { try? FileManager.default.removeItem(at: url) }

    try ProjectPackageIO.save(snapshot(), to: url)

    #expect(!FileManager.default.fileExists(atPath: url.appending(path: "project.json.new").path))
}

/// A second save must replace the manifest, not merely coexist with the
/// first — this is what makes `replaceItemAt` (not a first-write-only path)
/// the mechanism under test.
@Test func aSecondSaveReplacesTheFirstManifestContent() throws {
    let url = freshPackageDirectory("save-second-replaces-first")
    defer { try? FileManager.default.removeItem(at: url) }

    try ProjectPackageIO.save(snapshot(mediaFilenames: ["a.mov"]), to: url)
    try ProjectPackageIO.save(snapshot(mediaFilenames: ["b.mov", "c.mov"]), to: url)

    let loaded = try ProjectPackageIO.load(from: url)
    #expect(loaded.mediaFilenames == ["b.mov", "c.mov"])
}

// MARK: - writeSidecar: write-once, mechanically enforced

@Test func writeSidecarWritesTheBytesUnderMediaWithTheGivenName() throws {
    let url = freshPackageDirectory("sidecar-writes-bytes")
    defer { try? FileManager.default.removeItem(at: url) }

    let payload = Data("hello sidecar".utf8)
    try ProjectPackageIO.writeSidecar(payload, named: "clip-01.mov", into: url)

    let onDisk = try Data(contentsOf: url.appending(path: "media/clip-01.mov"))
    #expect(onDisk == payload)
}

/// The load-bearing write-once test (Controller addendum ruling 1): a
/// second write with the SAME name must throw, AND the original bytes must
/// be unchanged on disk — not merely that the call threw. Asserting only
/// the throw would also pass an implementation that overwrote and then
/// somehow reported failure, which is not the invariant this row exists
/// for.
@Test func aSecondWriteSidecarWithTheSameNameThrowsAndLeavesTheOriginalBytesUnchanged() throws {
    let url = freshPackageDirectory("sidecar-write-once")
    defer { try? FileManager.default.removeItem(at: url) }

    let original = Data("original bytes".utf8)
    try ProjectPackageIO.writeSidecar(original, named: "clip-01.mov", into: url)

    let attempted = Data("different bytes".utf8)
    #expect(throws: ProjectFormatError.sidecarAlreadyExists("clip-01.mov")) {
        try ProjectPackageIO.writeSidecar(attempted, named: "clip-01.mov", into: url)
    }

    let onDisk = try Data(contentsOf: url.appending(path: "media/clip-01.mov"))
    #expect(onDisk == original)
}

// MARK: - unreferencedSidecars / compact / the load-bearing save-must-not-delete test

@Test func unreferencedSidecarsReturnsNamesOnDiskNotInTheSnapshotSortedByName() throws {
    let url = freshPackageDirectory("unreferenced-sorted")
    defer { try? FileManager.default.removeItem(at: url) }

    try ProjectPackageIO.save(snapshot(mediaFilenames: ["kept.mov"]), to: url)
    try ProjectPackageIO.writeSidecar(Data("z".utf8), named: "zzz-orphan.mov", into: url)
    try ProjectPackageIO.writeSidecar(Data("a".utf8), named: "aaa-orphan.mov", into: url)
    try ProjectPackageIO.writeSidecar(Data("k".utf8), named: "kept.mov", into: url)

    let orphans = try ProjectPackageIO.unreferencedSidecars(in: url, snapshot: snapshot(mediaFilenames: ["kept.mov"]))
    #expect(orphans == ["aaa-orphan.mov", "zzz-orphan.mov"])
}

@Test func unreferencedSidecarsIsEmptyWhenNoMediaDirectoryExistsYet() throws {
    let url = freshPackageDirectory("unreferenced-no-media-dir")
    defer { try? FileManager.default.removeItem(at: url) }

    let orphans = try ProjectPackageIO.unreferencedSidecars(in: url, snapshot: snapshot(mediaFilenames: []))
    #expect(orphans == [])
}

/// THE LOAD-BEARING TEST for this whole row (Controller addendum ruling 2,
/// stated as the row's own completion criterion): put more media on disk
/// than the snapshot references, save, and assert EVERY sidecar — including
/// the unreferenced ones — is still present by NAME, not by count (a count
/// is equal when one file is deleted and another created). Only after an
/// explicit `compact` may the unreferenced ones go. If a future refactor
/// makes `save` sweep unreferenced media, this test is what stops it
/// reaching a user's recording.
@Test func saveNeverDeletesUnreferencedMediaOnlyCompactDoes() throws {
    let url = freshPackageDirectory("save-never-deletes-media")
    defer { try? FileManager.default.removeItem(at: url) }

    let referenced = snapshot(mediaFilenames: ["kept.mov"])
    try ProjectPackageIO.save(referenced, to: url)
    try ProjectPackageIO.writeSidecar(Data("kept".utf8), named: "kept.mov", into: url)
    try ProjectPackageIO.writeSidecar(Data("orphan-1".utf8), named: "orphan-1.mov", into: url)
    try ProjectPackageIO.writeSidecar(Data("orphan-2".utf8), named: "orphan-2.mov", into: url)

    // save again — must not touch media at all
    try ProjectPackageIO.save(referenced, to: url)

    let mediaDir = url.appending(path: "media")
    let onDiskAfterSave = Set(try FileManager.default.contentsOfDirectory(atPath: mediaDir.path))
    #expect(onDiskAfterSave.contains("kept.mov"))
    #expect(onDiskAfterSave.contains("orphan-1.mov"))
    #expect(onDiskAfterSave.contains("orphan-2.mov"))

    let deleted = try ProjectPackageIO.compact(url, snapshot: referenced)
    #expect(deleted == ["orphan-1.mov", "orphan-2.mov"])

    let onDiskAfterCompact = Set(try FileManager.default.contentsOfDirectory(atPath: mediaDir.path))
    #expect(onDiskAfterCompact == ["kept.mov"])
}
