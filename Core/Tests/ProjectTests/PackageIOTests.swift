import Testing
import Foundation
@testable import Project
import Geometry
import Timeline

// MARK: - JSONLReader
//
// A well-terminated file (0-byte tail) is the identity of "drop the trailing
// partial line", so the fixtures below must include unterminated ones.

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

/// 11, not 12: the tail after the final `\n` is `{"partial":`, which is
/// 11 bytes.
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

private func snapshot(mediaFilenames: [String] = ["clip-01.mov"], segments: SegmentTable = .empty) -> ProjectSnapshot {
    ProjectSnapshot(
        schemaVersion: ProjectSnapshot.currentSchemaVersion,
        geometries: registry(),
        mediaFilenames: mediaFilenames,
        segments: segments
    )
}

private let segmentEpoch = BootEpoch(id: UUID(uuidString: "3F2A9E10-8B1D-4C3E-9A5F-2D6E7B8C9D0E")!)

/// Non-empty, per the fixture rule — `.empty` is `segments`' default and
/// therefore its identity value for every other fixture in this file.
private func nonEmptySegments() throws -> SegmentTable {
    try SegmentTable(segments: [
        MasterSegment(index: 0, mediaFilename: "clip-01.mov",
                      hostRange: HostRange(epoch: segmentEpoch, start: Nanoseconds(0), duration: Nanoseconds(2_000)),
                      revision: GeometryRevision(id: 0x0A0A_0000_0000_0001), endedBy: .stopped)
    ])
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

/// `segments` defaults to `.empty` in every other fixture in this file —
/// the identity value for that field — so this is the one place proving a
/// real segment table survives an ACTUAL file write, `replaceItemAt`, and
/// read (`ProjectUpgrade.load` → `SegmentTable.init(from:)`, its own
/// validating decode path), not just an in-memory encoder/decoder pair.
@Test func saveThenLoadRoundTripsTheSnapshot() throws {
    let url = freshPackageDirectory("save-load-roundtrip")
    defer { try? FileManager.default.removeItem(at: url) }

    let original = snapshot(segments: try nonEmptySegments())
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

/// THE test for the atomic-replace mechanism itself (review Important 1).
/// `saveLeavesNoTempFileBehindOnSuccess` and
/// `aSecondSaveReplacesTheFirstManifestContent` both read as coverage of
/// `replaceItemAt`, but both pass identically under a `save` that calls
/// plain `data.write(to: manifestURL(...))` instead — no temp file to leave
/// behind, and the second save's content still lands on disk either way.
/// D-P3's actual guarantee — a reader never sees a torn manifest, because
/// `rename(2)` swaps the whole file rather than truncating and rewriting an
/// open one in place — needs an assertion that distinguishes "replaced the
/// file" from "rewrote the file's contents." A rename produces a NEW inode
/// at the same path; an in-place truncate-and-rewrite keeps the same one.
///
/// **This was verified to discriminate, and the first attempt did not.**
/// The first version of this test read `.fileResourceIdentifierKey` via
/// `URL.resourceValues(forKeys:)` on a `manifestURL` binding queried twice
/// — and failed with identical bytes both times, on a `save` that WAS using
/// `replaceItemAt` correctly. That is `NSURL`'s documented per-instance
/// resource-value cache: the second `resourceValues(forKeys:)` call on the
/// same `URL` value returned the first call's cached answer instead of
/// re-reading the filesystem. Reproduced standalone, outside Swift Testing
/// entirely (`/tmp/inode-probe/probe3.swift`), confirming it was the cache
/// and not a real non-discrimination: two `save()` calls in a row produced
/// `first = <4d4bc607…> second = <4d4bc607…> isEqual: true` via
/// `resourceValues`, while `FileManager.attributesOfItem(atPath:)[.systemFileNumber]`
/// on the exact same two states — a fresh `stat()` per call, no caching —
/// reported `130435918` then `130435919`: genuinely different inodes.
/// `attributesOfItem` is what this test uses below, for that reason.
///
/// With that fixed, the assertion was re-verified to discriminate both
/// ways: `replaceItemAt: differ=true`, and separately, a throwaway `save`
/// calling plain `data.write(to: manifestURL)` instead of the temp-file
/// dance: `differ=false` — the same content lands, the inode does not
/// change, which is exactly what the mutation check below confirms against
/// the real `ProjectPackageIO.save`.
@Test func savingTwiceChangesTheManifestsFileNumberProvingAnAtomicReplaceNotAnInPlaceRewrite() throws {
    let url = freshPackageDirectory("save-atomic-replace-changes-identity")
    defer { try? FileManager.default.removeItem(at: url) }

    func fileNumber() throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.appending(path: "project.json").path)
        return try #require(attrs[.systemFileNumber] as? NSNumber).uint64Value
    }

    try ProjectPackageIO.save(snapshot(mediaFilenames: ["a.mov"]), to: url)
    let first = try fileNumber()

    try ProjectPackageIO.save(snapshot(mediaFilenames: ["b.mov"]), to: url)
    let second = try fileNumber()

    #expect(first != second)
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

/// Review Important 3: `name` must be a single path component. Without the
/// guard, `"../escaped.mov"` writes into the package root, one level above
/// `media/` — the exact directory `unreferencedSidecars` scans — so an
/// escaped file could never be found or compacted: a permanent orphan by
/// construction. Asserts both the specific error case AND that nothing
/// landed outside `media/`, not merely that the call threw.
@Test func writeSidecarRejectsATraversalNameAndWritesNothingOutsideMedia() throws {
    let url = freshPackageDirectory("sidecar-rejects-traversal")
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(throws: ProjectFormatError.invalidSidecarName("../escaped.mov")) {
        try ProjectPackageIO.writeSidecar(Data("evil".utf8), named: "../escaped.mov", into: url)
    }

    let escapedLocation = url.deletingLastPathComponent().appending(path: "escaped.mov")
    #expect(!FileManager.default.fileExists(atPath: escapedLocation.path))
    let insidePackageRoot = url.appending(path: "escaped.mov")
    #expect(!FileManager.default.fileExists(atPath: insidePackageRoot.path))
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

/// Review Important 2. `unreferencedSidecars` exists specifically to make
/// sure `compact` never deletes something it shouldn't — and `removeItem`
/// on a directory is recursive, so reporting a subdirectory as "orphaned"
/// would let `compact` delete an entire tree an app later created under
/// `media/`. A dotfile (`.DS_Store`, standing in for anything Finder or the
/// OS drops in the directory) must be excluded the same way: it is not a
/// sidecar, minted or otherwise. Neither may appear in `unreferencedSidecars`,
/// and — the load-bearing half of this test — `compact` must leave both
/// completely untouched, subdirectory contents included.
@Test func unreferencedSidecarsExcludesSubdirectoriesAndDotfilesAndCompactLeavesThemUntouched() throws {
    let url = freshPackageDirectory("unreferenced-skips-dirs-and-dotfiles")
    defer { try? FileManager.default.removeItem(at: url) }

    let referenced = snapshot(mediaFilenames: ["kept.mov"])
    try ProjectPackageIO.save(referenced, to: url)
    try ProjectPackageIO.writeSidecar(Data("kept".utf8), named: "kept.mov", into: url)

    let mediaDir = url.appending(path: "media")
    let subdirectory = mediaDir.appending(path: "thumbnails", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
    let fileInsideSubdirectory = subdirectory.appending(path: "keep-me.jpg")
    try Data("thumbnail".utf8).write(to: fileInsideSubdirectory)

    let dotfile = mediaDir.appending(path: ".DS_Store")
    try Data("finder metadata".utf8).write(to: dotfile)

    let orphans = try ProjectPackageIO.unreferencedSidecars(in: url, snapshot: referenced)
    #expect(orphans == [])

    let deleted = try ProjectPackageIO.compact(url, snapshot: referenced)
    #expect(deleted == [])

    #expect(FileManager.default.fileExists(atPath: fileInsideSubdirectory.path))
    #expect(FileManager.default.fileExists(atPath: dotfile.path))
    #expect(FileManager.default.fileExists(atPath: mediaDir.appending(path: "kept.mov").path))
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

// MARK: - a shared package naming files outside itself

/// **A `.soredemo` package is a document people send each other**, so every name in it is
/// untrusted. A manifest naming `../../somebody's-private.mov` used to be opened as the
/// recording — any file this unsandboxed app can read, played in the editor and carried into the
/// next project saved from it. Refused where the name enters: the decoder.
@Test(arguments: ["../outside.mov", "../../Users/someone/Movies/private.mov", "sub/clip.mov",
                  "..\\outside.mov", ".hidden.mov", "..", ".", ""])
func aManifestNamingAFileOutsideItsMediaIsRefused(_ name: String) throws {
    let good = try JSONEncoder().encode(snapshot(mediaFilenames: ["clip-01.mov"]))
    var object = try #require(try JSONSerialization.jsonObject(with: good) as? [String: Any])
    object["mediaFilenames"] = ["clip-01.mov", name]
    let bad = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(ProjectSnapshot.self, from: bad) }
    // Positive control: the same document with only the good name decodes.
    #expect(try JSONDecoder().decode(ProjectSnapshot.self, from: good).mediaFilenames == ["clip-01.mov"])
}

/// **A safe name can still point outside**: `media/clip.mov` as a symbolic link to a file
/// elsewhere. The file that is opened must be the package's own.
@Test func aMediaFileThatIsALinkToElsewhereIsRefused() throws {
    let package = freshPackageDirectory("media-link")
    defer { try? FileManager.default.removeItem(at: package) }
    let media = package.appending(path: "media", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    let outside = FileManager.default.temporaryDirectory
        .appending(path: "soredemo-t17-outside-\(ProcessInfo.processInfo.globallyUniqueString).mov")
    try Data("not yours".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: media.appending(path: "linked.mov"),
                                               withDestinationURL: outside)
    try Data("ours".utf8).write(to: media.appending(path: "own.mov"))

    #expect(throws: ProjectFormatError.mediaIsNotAFile("linked.mov")) {
        try ProjectPackageIO.mediaFile(named: "linked.mov", in: package)
    }
    #expect(throws: ProjectFormatError.invalidSidecarName("../own.mov")) {
        try ProjectPackageIO.mediaFile(named: "../own.mov", in: package)
    }
    // Positive control: the package's own file is handed back.
    #expect(try ProjectPackageIO.mediaFile(named: "own.mov", in: package).lastPathComponent == "own.mov")
}

/// **The folder can be the link.** `media` itself pointing at somebody's Movies folder makes every
/// file under it look like an ordinary file in the package.
@Test func aMediaFolderThatIsALinkToElsewhereIsRefused() throws {
    let package = freshPackageDirectory("media-folder-link")
    defer { try? FileManager.default.removeItem(at: package) }
    let elsewhere = FileManager.default.temporaryDirectory
        .appending(path: "soredemo-t17-elsewhere-\(ProcessInfo.processInfo.globallyUniqueString)",
                   directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    try Data("not yours".utf8).write(to: elsewhere.appending(path: "private.mov"))
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: package.appending(path: "media"),
                                               withDestinationURL: elsewhere)

    #expect(throws: ProjectFormatError.mediaIsNotAFile("private.mov")) {
        try ProjectPackageIO.mediaFile(named: "private.mov", in: package)
    }
}

// MARK: - files too large to be what they claim

/// **A shared package's files are read whole, so their size is bounded first.** A crafted
/// multi-gigabyte log would otherwise be read into memory before anything checked it. The limits
/// are from measurement (`BoundedRead`'s header): about 80 MB of log per hour of take, so 1 GiB is
/// twelve hours of one segment.
@Suite struct BoundedReadTests {
    /// A sparse file: it reports the size and occupies almost nothing on disk.
    private func sparse(_ name: String, bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "soredemo-t17-\(name)-\(ProcessInfo.processInfo.globallyUniqueString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return url
    }

    @Test func aLogLargerThanAnyTakeWritesIsRefusedBeforeItIsRead() throws {
        let url = try sparse("huge-log", bytes: BoundedRead.observationLogLimit + 1)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: BoundedRead.TooLarge(bytes: BoundedRead.observationLogLimit + 1,
                                             limit: BoundedRead.observationLogLimit)) {
            _ = try JSONLReader.linesOfFile(at: url)
        }
    }

    @Test func aManifestLargerThanAnyEditIsRefusedBeforeItIsRead() throws {
        let package = freshPackageDirectory("huge-manifest")
        defer { try? FileManager.default.removeItem(at: package) }
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest = package.appending(path: "project.json")
        FileManager.default.createFile(atPath: manifest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: manifest)
        try handle.truncate(atOffset: UInt64(BoundedRead.manifestLimit + 1))
        try handle.close()
        #expect(throws: BoundedRead.TooLarge(bytes: BoundedRead.manifestLimit + 1,
                                             limit: BoundedRead.manifestLimit)) {
            _ = try ProjectPackageIO.load(from: package)
        }
    }

    /// Positive control: at the limit is not over it.
    @Test func aFileAtTheLimitIsRead() throws {
        let url = try sparse("at-limit", bytes: 64)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try BoundedRead.data(at: url, limit: 64).count == 64)
    }
}
