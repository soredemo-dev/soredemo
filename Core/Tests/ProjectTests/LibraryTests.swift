import Foundation
import Testing
@testable import Project

// The project's library (`docs/design/2026-11-13-the-library.md`): what it holds, how its list is
// read from an untrusted package, and how it is searched.

@Suite struct LibraryTests {
    @Test func anItemIsAddedWithTheNextIdAndASafeName() throws {
        var library = Library()
        let first = try library.adding(kind: .image, filename: "NTHU-Logo.png", name: "NTHU emblem",
                                       origin: .web(host: "www.nthu.edu.tw"), width: 512, height: 512)
        let second = try library.adding(kind: .video, filename: "take-2.mov", name: "Take 2", origin: .imported(originalName: "take 2.mov"),
                                        durationNanos: 12_000_000_000)
        #expect(first.id == 0 && second.id == 1)
        #expect(library.items.map(\.id) == [0, 1])
        #expect(throws: Library.Refusal.unsafeName("../x.png")) {
            try library.adding(kind: .image, filename: "../x.png", name: "x", origin: .recorded)
        }
    }

    /// The list arrives inside a shareable package: a name that climbs out, a negative length or
    /// an id the counter has not reached is refused, not drawn.
    @Test func aListThatCouldNotHaveBeenWrittenIsRefused() {
        func decode(_ json: String) -> Library? { try? JSONDecoder().decode(Library.self, from: Data(json.utf8)) }
        #expect(decode(#"{"version":1,"nextID":1,"items":[{"id":0,"kind":"image","filename":"a.png","name":"A","origin":{"recorded":{}}}]}"#) != nil)
        #expect(decode(#"{"version":1,"nextID":1,"items":[{"id":0,"kind":"image","filename":"../a.png","name":"A","origin":{"recorded":{}}}]}"#) == nil)
        #expect(decode(#"{"version":1,"nextID":1,"items":[{"id":0,"kind":"video","filename":"a.mov","name":"A","durationNanos":-1,"origin":{"recorded":{}}}]}"#) == nil)
        #expect(decode(#"{"version":1,"nextID":0,"items":[{"id":0,"kind":"image","filename":"a.png","name":"A","origin":{"recorded":{}}}]}"#) == nil)
        #expect(decode(#"{"version":2,"nextID":0,"items":[]}"#) == nil, "a version this does not know is not guessed at")
    }

    /// A hit carries its evidence; a label outranks spoken words, which outrank an item's name; all
    /// the words must be there; case and accents do not matter.
    @Test func aSearchFindsWhatWasObservedWithItsEvidence() {
        let index: [LibraryIndexEntry] = [
            .init(itemID: 0, field: .spoken, text: "and now we export the video", startNanos: 30_000_000_000, endNanos: 33_000_000_000),
            .init(itemID: 0, field: .stepLabel(step: 7), text: "Export…", startNanos: 41_200_000_000, endNanos: 44_900_000_000),
            .init(itemID: 1, field: .name, text: "Export settings screenshot"),
            .init(itemID: 1, field: .pictureText, text: "Résolution 1080p Exporter"),
            .init(itemID: 2, field: .name, text: "Logo"),
        ]
        let hits = LibrarySearch.search("EXPORT", in: index)
        #expect(hits.map(\.field) == [.stepLabel(step: 7), .spoken, .pictureText, .name], "Exporter on the screenshot holds export too")
        #expect(hits.first?.startNanos == 41_200_000_000)
        #expect(LibrarySearch.search("resolution 1080p", in: index).map(\.itemID) == [1], "accents fold, every word must match")
        #expect(LibrarySearch.search("export logo", in: index).isEmpty, "no single entry holds both")
        #expect(LibrarySearch.search("   ", in: index).isEmpty)
    }

    /// A sharing copy keeps every file and drops what was read off a screenshot and the names a
    /// person's files had — the two library fields judged REDACT. The web host stays: it is a
    /// public site's name, and where a picture came from is worth being able to check.
    @Test func aSharingCopyDropsTheTextOnPicturesAndTheOriginalNames() throws {
        var library = Library()
        try library.adding(kind: .image, filename: "invoice.png", name: "invoice", origin: .imported(originalName: "Jane Doe invoice.png"),
                           pictureText: "jane@example.com  Total 1200", textRevision: 3)
        try library.adding(kind: .image, filename: "logo.png", name: "logo", origin: .web(host: "www.nthu.edu.tw"))
        let shared = library.withoutScreenText()
        #expect(shared.items.map(\.filename) == ["invoice.png", "logo.png"], "every file is still listed")
        #expect(shared.items[0].pictureText == nil && shared.items[0].textRevision == nil)
        #expect(shared.items[0].origin == .imported(originalName: ""))
        #expect(shared.items[1].origin == .web(host: "www.nthu.edu.tw"))
        #expect(shared.nextID == library.nextID)
    }

    @Test func aPackagesLibraryIsRedactedInPlace() throws {
        let package = FileManager.default.temporaryDirectory.appending(path: "redact-\(ProcessInfo.processInfo.globallyUniqueString)")
        defer { try? FileManager.default.removeItem(at: package) }
        try FileManager.default.createDirectory(at: package.appending(path: Library.directory), withIntermediateDirectories: true)
        var library = Library()
        try library.adding(kind: .image, filename: "a.png", name: "a", origin: .imported(originalName: "secret.png"), pictureText: "secret")
        try JSONEncoder().encode(library).write(to: package.appending(path: "library/library.json"))
        #expect(try EvidenceRedaction.redactLibrary(in: package))
        let written = try JSONDecoder().decode(Library.self, from: Data(contentsOf: package.appending(path: "library/library.json")))
        #expect(written == library.withoutScreenText())
        let none = FileManager.default.temporaryDirectory.appending(path: "nolib-\(ProcessInfo.processInfo.globallyUniqueString)")
        #expect(try EvidenceRedaction.redactLibrary(in: none) == false, "no library is nothing to redact, said as such")
    }
}
