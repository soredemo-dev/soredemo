import CoreGraphics
import Foundation
import ImageIO
import AppKit
import CoreText
import Overlays
import Timeline
import Render
import Project
import Surface
import Testing
@testable import Soredemo

// The project's library in the app: adding files, the list on disk, and the agent's search over
// the recording and the items (`docs/design/2026-11-13-the-library.md`).

@MainActor private func package() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "library-\(ProcessInfo.processInfo.globallyUniqueString).soredemo")
    try FileManager.default.createDirectory(at: url.appending(path: "media"), withIntermediateDirectories: true)
    return url
}

/// A picture with words drawn on it, so the text read off it is something this test knows.
private func picture(saying words: String, at url: URL) throws {
    let width = 900, height = 200
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let attributed = NSAttributedString(string: words, attributes: [.font: NSFont.systemFont(ofSize: 72),
                                                                    .foregroundColor: NSColor.black])
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: 30, y: 70)
    CTLineDraw(line, context)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
}

@Test @MainActor func aFileAddedIsCopiedMeasuredReadAndKeptInTheList() async throws {
    let package = try package()
    defer { try? FileManager.default.removeItem(at: package) }
    let source = FileManager.default.temporaryDirectory.appending(path: "Export Settings \(ProcessInfo.processInfo.globallyUniqueString.prefix(6)).png")
    try picture(saying: "Export Settings", at: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let library = LibraryModel()
    library.load(packageURL: package)
    let added = await library.importFiles([source])
    let item = try #require(added.first)
    #expect(item.kind == .image && item.width == 900 && item.height == 200)
    #expect(item.pictureText?.localizedCaseInsensitiveContains("export") == true, "read off the picture: \(item.pictureText ?? "nothing")")
    #expect(FileManager.default.fileExists(atPath: package.appending(path: "library/\(item.filename)").path(percentEncoded: false)))
    #expect(!item.filename.contains(" "), "a name made safe")
    let reopened = LibraryModel()
    reopened.load(packageURL: package)
    #expect(reopened.library == library.library, "the list is on disk")
    // The same file twice is two items, the second not replacing the first.
    let again = await library.importFiles([source])
    let second = try #require(again.first, "the second copy was added, not refused for its name")
    #expect(second.filename != item.filename)
    #expect(library.library.items.count == 2)
    for name in [item.filename, second.filename] {
        #expect(FileManager.default.fileExists(atPath: package.appending(path: "library/\(name)").path(percentEncoded: false)))
    }
}

/// A list that does not decode is reported and left on disk as it was — never overwritten by a guess.
@Test @MainActor func aListThatCannotBeReadIsLeftAsItWas() throws {
    let package = try package()
    defer { try? FileManager.default.removeItem(at: package) }
    let folder = package.appending(path: "library")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let bad = Data(#"{"version":1,"nextID":1,"items":[{"id":0,"kind":"image","filename":"../escape.png","name":"x","origin":{"recorded":{}}}]}"#.utf8)
    try bad.write(to: folder.appending(path: "library.json"))
    let library = LibraryModel()
    library.load(packageURL: package)
    #expect(library.library.items.isEmpty)
    #expect(library.problem != nil)
    #expect(try Data(contentsOf: folder.appending(path: "library.json")) == bad)
}

/// The agent's search reaches the recording's steps with their spans, its captions, and the items.
@Test @MainActor func theAgentSearchesTheRecordingAndTheLibraryWithEvidence() async throws {
    let package = try package()
    defer { try? FileManager.default.removeItem(at: package) }
    let editor = EditorViewModel()
    editor.timeline.load(duration: 20)
    editor.mediaURL = package.appending(path: "media/master-00.mov")
    editor.library.load(packageURL: package)
    let source = FileManager.default.temporaryDirectory.appending(path: "dialog-\(ProcessInfo.processInfo.globallyUniqueString.prefix(6)).png")
    try picture(saying: "Export Dialog", at: source)
    defer { try? FileManager.default.removeItem(at: source) }
    _ = await editor.library.importFiles([source])
    editor.captions.restore(track: CaptionTrack(cues: [CaptionCue(text: "now we export it", start: Nanoseconds(3_000_000_000),
                                                                  end: Nanoseconds(5_000_000_000))]),
                            style: .default, burnsIn: false)
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    guard case .success(let json) = bridge.perform(.searchLibrary("export")) else { Issue.record("no answer"); return }
    #expect(json.contains(#""field":"spoken""#) && json.contains(#""startNanos":3000000000"#), "\(json)")
    #expect(json.contains(#""field":"textOnPicture""#), "\(json)")
    guard case .success(let listed) = bridge.perform(.library) else { Issue.record("no list"); return }
    #expect(listed.contains(#""kind":"recording""#) && listed.contains(#""kind":"image""#), "\(listed)")
}

/// A picture in the library is a background and a picture to place, by its library name — what a
/// demo prepared with a library needs from one sentence.
@Test @MainActor func aLibraryPictureIsABackgroundAndAPictureToPlace() async throws {
    let package = try package()
    defer { try? FileManager.default.removeItem(at: package) }
    let editor = EditorViewModel()
    editor.timeline.load(duration: 20)
    editor.mediaURL = package.appending(path: "media/master-00.mov")
    editor.library.load(packageURL: package)
    let source = FileManager.default.temporaryDirectory.appending(path: "NTHU emblem \(ProcessInfo.processInfo.globallyUniqueString.prefix(6)).png")
    try picture(saying: "NTHU", at: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let item = try #require(await editor.library.importFiles([source]).first)
    let bridge = AgentEditorBridge(editor: editor, agentName: "Claude Code")
    guard case .success(let look) = bridge.perform(.look) else { Issue.record("no look"); return }
    #expect(look.contains(item.filename), "the library's picture is offered as a background: \(look)")
    guard case .success = bridge.perform(.setLook(.init(backgroundImage: item.filename), reason: "The emblem")) else {
        Issue.record("refused the library's picture as the background"); return
    }
    #expect(editor.stageStyle.style.background == .image(filename: item.filename))
    guard case .success = bridge.perform(.overlay(.addMark(.init(shape: "image", fromX: 0.8, fromY: 0.05, toX: 0.95, toY: 0.2,
                                                                    startNanos: 0, seconds: 20, picture: item.filename)), reason: "The logo")) else {
        Issue.record("could not place the library's picture"); return
    }
    #expect(editor.annotations.track.items.first?.imageName == item.filename)
    #expect(FileManager.default.fileExists(atPath: package.appending(path: "pictures/\(item.filename)").path(percentEncoded: false)),
            "copied where the compositor reads pictures from")
}
