import AVFoundation
import Foundation
import Framing
import Timeline
import ImageIO
import Observation
import Overlays
import Project
import Vision

/// The project's library: what is in it, adding to it, and the index the agent searches
/// (`docs/design/2026-11-13-the-library.md`). The list lives in the package; this keeps it in
/// memory, writes it back on every change, and reads it when a project opens.
@Observable
@MainActor
final class LibraryModel {
    private(set) var library = Library()
    /// Why the last import or read did not work, said rather than swallowed.
    private(set) var problem: String?
    /// The package this library belongs to, set when the recording loads.
    private(set) var packageURL: URL?

    /// The index's id for the project's own recording, which is the package's media rather than a
    /// library file. Never issued by `Library`, whose ids start at 0.
    static let recordingID = -1

    var folder: URL? { packageURL?.appending(path: Library.directory, directoryHint: .isDirectory) }

    /// Reads the package's list, or starts an empty one. A list that does not decode is reported
    /// and left on disk untouched, so nothing a person added is overwritten by a guess.
    func load(packageURL: URL) {
        self.packageURL = packageURL
        guard let folder, let data = try? Data(contentsOf: folder.appending(path: Library.listFilename)) else {
            library = Library()
            return
        }
        do { library = try JSONDecoder().decode(Library.self, from: data) } catch {
            library = Library()
            problem = String(localized: "The project's library list could not be read, so it is shown empty and left as it was: \(String(describing: error))")
        }
    }

    private func save() throws {
        guard let folder else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(library).write(to: folder.appending(path: Library.listFilename), options: .atomic)
    }

    /// Adds files a person chose, each copied into the library. Returns the items added.
    @discardableResult
    func importFiles(_ urls: [URL]) async -> [Library.Item] {
        var added: [Library.Item] = []
        for url in urls {
            switch await add(url, origin: .imported(originalName: url.lastPathComponent)) {
            case .success(let item): added.append(item)
            case .failure(let refusal): problem = refusal.message
            }
        }
        return added
    }

    /// Adds one file: its kind and measurements, the text on it when it is a picture, a copy in
    /// the library under a name made safe and unused.
    func add(_ source: URL, origin: Library.Origin) async -> Result<Library.Item, LibraryProblem> {
        guard let folder else { return .failure(LibraryProblem(String(localized: "Save the project first; its library lives in it."))) }
        guard let kind = Self.kind(of: source) else {
            return .failure(LibraryProblem(String(localized: "\(source.lastPathComponent) is not a video, a picture or a sound this can use.")))
        }
        let measured = await Self.measure(source, kind: kind)
        let name = uniqueFilename(LibraryModel.safeName(source.lastPathComponent))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: folder.appending(path: name))
            let item = try library.adding(kind: kind, filename: name, name: source.deletingPathExtension().lastPathComponent,
                                          origin: origin, durationNanos: measured.duration, width: measured.width,
                                          height: measured.height, pictureText: measured.text,
                                          textRevision: measured.text == nil ? nil : Self.textRevision)
            try save()
            problem = nil
            return .success(item)
        } catch {
            return .failure(LibraryProblem(String(localized: "Could not add \(source.lastPathComponent): \(String(describing: error))")))
        }
    }

    func remove(_ id: Int) {
        guard let item = library.items.first(where: { $0.id == id }), let folder else { return }
        try? FileManager.default.removeItem(at: folder.appending(path: item.filename))
        library.removing(id)
        try? save()
    }

    /// The library's files by id, videos and pictures apart — what the composition and the
    /// compositor read a library clip from.
    func files() -> (videos: [Int: URL], pictures: [Int: URL]) {
        guard let folder else { return ([:], [:]) }
        var videos: [Int: URL] = [:], pictures: [Int: URL] = [:]
        for item in library.items {
            switch item.kind {
            case .video, .recording: videos[item.id] = folder.appending(path: item.filename)
            case .image: pictures[item.id] = folder.appending(path: item.filename)
            case .audio: break
            }
        }
        return (videos, pictures)
    }

    /// What inserting `item` puts in the edit: a picture held for `pictureSeconds`, a video for its
    /// length. `nil` for what cannot be a clip — sound, or a video whose length is not known.
    static let pictureSeconds: Int64 = 3
    static func clip(for item: Library.Item, seconds: Double? = nil) -> (source: ClipSource, duration: Nanoseconds)? {
        switch item.kind {
        case .image:
            let held = seconds.map { Int64($0 * 1e9) } ?? pictureSeconds * 1_000_000_000
            return held > 0 ? (.picture(item: item.id), Nanoseconds(held)) : nil
        case .video, .recording:
            guard let length = item.durationNanos, length > 0 else { return nil }
            let wanted = seconds.map { min(Int64($0 * 1e9), length) } ?? length
            return wanted > 0 ? (.video(item: item.id), Nanoseconds(wanted)) : nil
        case .audio:
            return nil
        }
    }

    // MARK: - the index

    /// Everything the agent can search: the recording's steps and words, and every item's name and
    /// the text read off it. Built when asked, from what is current — never cached, so a step
    /// renamed or a caption fixed a moment ago is what is found.
    func index(steps: [RecordedStep], anchorHostNanos: Int64?, captions: CaptionTrack) -> [LibraryIndexEntry] {
        var entries: [LibraryIndexEntry] = []
        if let anchor = anchorHostNanos {
            for step in steps {
                let start = step.origin.hostTime.rawValue - anchor, end = step.end.hostTime.rawValue - anchor
                entries.append(.init(itemID: Self.recordingID, field: .stepLabel(step: step.number), text: step.label,
                                     startNanos: start, endNanos: end))
                if let application = step.application {
                    entries.append(.init(itemID: Self.recordingID, field: .application(step: step.number), text: application,
                                         startNanos: start, endNanos: end))
                }
            }
        }
        for cue in captions.cues {
            entries.append(.init(itemID: Self.recordingID, field: .spoken, text: cue.text,
                                 startNanos: cue.start.rawValue, endNanos: cue.end.rawValue))
        }
        for item in library.items {
            entries.append(.init(itemID: item.id, field: .name, text: item.name))
            if let text = item.pictureText { entries.append(.init(itemID: item.id, field: .pictureText, text: text)) }
        }
        return entries
    }

    // MARK: - reading a file

    static let textRevision = 3

    static func kind(of url: URL) -> Library.Kind? {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "m4v": .video
        case "png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp": .image
        case "m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "flac": .audio
        default: nil
        }
    }

    /// A name made of letters, digits, `-`, `_` and one extension — what the library folder holds.
    static func safeName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let stem = (name as NSString).deletingPathExtension
        var safe = ""
        for character in stem {
            if character.isLetter || character.isNumber || character == "_" { safe.append(character) }
            else if safe.last != "-" { safe.append("-") }
        }
        let trimmed = safe.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (trimmed.isEmpty ? "item" : String(trimmed.prefix(60))) + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// `name`, or `name-2`, `name-3`… — never replacing a file already in the library.
    private func uniqueFilename(_ name: String) -> String {
        let taken = Set(library.items.map(\.filename))
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        var n = 2
        while taken.contains("\(stem)-\(n).\(ext)") { n += 1 }
        return "\(stem)-\(n).\(ext)"
    }

    nonisolated static func measure(_ url: URL, kind: Library.Kind) async
        -> (duration: Int64?, width: Int?, height: Int?, text: String?) {
        switch kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                return (nil, nil, nil, nil)
            }
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            let text = (try? await request.perform(on: url))?
                .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            return (nil, properties[kCGImagePropertyPixelWidth] as? Int, properties[kCGImagePropertyPixelHeight] as? Int,
                    text.flatMap { $0.isEmpty ? nil : $0 })
        case .video, .recording, .audio:
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration)).map { Int64($0.seconds * 1e9) }
            let track = try? await asset.loadTracks(withMediaType: .video).first
            let size = try? await track?.load(.naturalSize)
            return (duration, size.map { Int(abs($0.width)) }, size.map { Int(abs($0.height)) }, nil)
        }
    }
}

struct LibraryProblem: Error, Equatable { let message: String; init(_ message: String) { self.message = message } }
