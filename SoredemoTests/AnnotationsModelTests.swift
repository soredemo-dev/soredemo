import Compositing
import Foundation
import Overlays
import Render
import Testing
import Timeline
@testable import Soredemo

private func ns(_ seconds: Int64) -> Nanoseconds { Nanoseconds(seconds * 1_000_000_000) }

/// A package directory nobody else uses. Not `soredemo-preview-`, which the preview's own
/// clean-up deletes at launch.
private func scratchPackage() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "soredemo-annotations-\(UUID().uuidString).soredemo", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func chosenFile(named name: String, contents: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appending(path: "soredemo-chosen-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: name)
    try Data(contents.utf8).write(to: url)
    return url
}

@MainActor @Suite(.serialized) struct AnnotationsModelTests {
    /// An annotation at 2 s lasting 3 s — neither at zero nor at the default length's identity
    /// with the playhead, so a "start here" that reset the length or measured from zero shows.
    private func modelWithOne() throws -> (AnnotationsModel, AnnotationItem) {
        let model = AnnotationsModel()
        model.add(at: ns(2))
        let item = try #require(model.selected)
        model.endHere(item, at: ns(6))
        return (model, try #require(model.selected))
    }

    @Test func startHereKeepsTheLength() throws {
        let (model, item) = try modelWithOne()
        #expect(item.duration == ns(4))
        model.startHere(item, at: ns(9))
        #expect(model.selected?.start == ns(9))
        #expect(model.selected?.end == ns(13), "four seconds, as it was")
    }

    @Test func endHereAtOrBeforeTheStartChangesNothing() throws {
        let (model, item) = try modelWithOne()
        #expect(!model.endHere(item, at: ns(2)), "at the start")
        #expect(!model.endHere(item, at: ns(1)), "before it")
        #expect(model.selected == item)
        #expect(model.endHere(item, at: ns(5)))
        #expect(model.selected?.end == ns(5))
    }

    @Test func aPictureIsCopiedIntoThePackageAndTheRendererIsTold() throws {
        let model = AnnotationsModel()
        let package = try scratchPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let before = CoreImageFrameRenderer.packageImagesForgotten

        let name = model.adoptPicture(try chosenFile(named: "logo.png", contents: "first"),
                                      packageURL: package)
        #expect(name == "logo.png")
        let kept = package.appending(path: "\(AnnotationOverlay.imageDirectory)/logo.png")
        #expect(try String(contentsOf: kept, encoding: .utf8) == "first")

        // The same name again: the file is replaced, and the renderer is told so it does not
        // go on drawing the first one.
        #expect(model.adoptPicture(try chosenFile(named: "logo.png", contents: "second"),
                                   packageURL: package) == "logo.png")
        #expect(try String(contentsOf: kept, encoding: .utf8) == "second")
        #expect(CoreImageFrameRenderer.packageImagesForgotten >= before + 2)
        #expect(model.pictureFailure == nil)
    }

    @Test func aHiddenFileIsRefusedWithTheReason() throws {
        let model = AnnotationsModel()
        let package = try scratchPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        #expect(model.adoptPicture(try chosenFile(named: ".logo.png", contents: "x"),
                                   packageURL: package) == nil)
        #expect(model.pictureFailure?.contains(".logo.png") == true)
    }

    /// The background adopter shares the copy and the forget.
    @Test func aBackgroundReplacedUnderItsOwnNameTellsTheRenderer() throws {
        let style = StageStyleModel()
        let package = try scratchPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let before = CoreImageFrameRenderer.packageImagesForgotten
        #expect(style.useImageBackground(try chosenFile(named: "wall.png", contents: "a"),
                                         inPackageAt: package) == nil)
        #expect(style.useImageBackground(try chosenFile(named: "wall.png", contents: "b"),
                                         inPackageAt: package) == nil)
        let kept = package.appending(path: "\(StageBackground.imageDirectory)/wall.png")
        #expect(try String(contentsOf: kept, encoding: .utf8) == "b")
        #expect(CoreImageFrameRenderer.packageImagesForgotten >= before + 2)
        #expect(style.imageBackgroundName == "wall.png")
    }
}
