import Foundation
import Overlays
import Render
import Surface
import Timeline

/// Titles, chapters, marks, hidden regions and the camera, read and changed by the agent.
///
/// **Positions cross one conversion, here.** The tools speak x from the left and y from the top
/// (`AgentOverlayTools`); a title, a mark and the camera store y up from the BOTTOM, and a hidden
/// region stores it down from the top. Each is flipped exactly once, on the way in and the way out.
extension AgentEditorBridge {
    static func up(_ downFromTop: Double) -> Double { 1 - downFromTop }

    func overlaysReport() -> MCPToolResult {
        let ns = { (n: Nanoseconds) in n.rawValue }
        return json([
            "titles": editor.texts.track.items.map { item in
                ["id": item.id, "text": item.text, "startNanos": ns(item.start), "endNanos": ns(item.end),
                 "x": tidy(item.style.x), "y": tidy(Self.up(item.style.y)), "size": tidy(item.style.heightFraction),
                 "bold": item.style.isBold,
                 "color": EditorLook.hex(item.style.red, item.style.green, item.style.blue)] as [String: Any]
            },
            "chapters": editor.chapters.track.chapters.map { ["id": $0.id, "title": $0.title, "startNanos": ns($0.start)] as [String: Any] },
            "marks": editor.annotations.track.items.map { item in
                ["id": item.id, "shape": item.shape.rawValue, "fromX": tidy(item.startX), "fromY": tidy(Self.up(item.startY)),
                 "toX": tidy(item.endX), "toY": tidy(Self.up(item.endY)), "startNanos": ns(item.start), "endNanos": ns(item.end),
                 "text": item.text] as [String: Any]
            },
            "hiddenRegions": editor.redactions.track.items.map { item in
                ["id": item.id, "startNanos": ns(item.start), "endNanos": ns(item.end), "x": tidy(item.region.x),
                 "y": tidy(item.region.y), "width": tidy(item.region.width), "height": tidy(item.region.height),
                 "oval": item.region.isOval] as [String: Any]
            },
            "camera": !hasCamera ? NSNull() : [
                "shape": editor.cameraStyle.shape.rawValue, "size": tidy(editor.cameraStyle.widthFraction),
                "x": tidy(editor.cameraStyle.x), "y": tidy(Self.up(editor.cameraStyle.y)),
                "hidden": editor.cameraStyle.isHidden, "mirrored": editor.cameraStyle.isMirrored,
            ] as Any,
        ])
    }

    private var hasCamera: Bool { editor.hasCamera }

    func performOverlay(_ edit: OverlayEdit, reason: String) -> MCPToolResult {
        recordLook(reason: reason) {
            switch edit {
            case .addTitle(let fields):
                let start = Nanoseconds(fields.startNanos ?? editor.timeline.playhead.rawValue)
                let added = editor.texts.track.adding(
                    text: fields.text ?? "", start: start,
                    end: Nanoseconds(start.rawValue + Int64((fields.seconds ?? 3) * 1e9)))
                guard let item = added.items.first(where: { $0.id == editor.texts.track.nextID }) else { return "The title could not be added." }
                editor.texts.restore(added.replacing(applying(fields, to: item)))
            case .editTitle(let id, let fields):
                guard let item = editor.texts.track.items.first(where: { $0.id == id }) else {
                    return "No title has the id \(id). Read overlays for the titles."
                }
                editor.texts.update(applying(fields, to: item))
            case .removeTitle(let id):
                guard editor.texts.track.items.contains(where: { $0.id == id }) else { return "No title has the id \(id)." }
                editor.texts.remove(id)
            case .addChapter(let at, let title):
                editor.chapters.replaceTrack(editor.chapters.track.adding(title: title, start: Nanoseconds(at)))
            case .renameChapter(let id, let title):
                guard editor.chapters.track.chapters.contains(where: { $0.id == id }) else { return "No chapter has the id \(id)." }
                editor.chapters.retitle(id, to: title)
            case .removeChapter(let id):
                guard editor.chapters.track.chapters.contains(where: { $0.id == id }) else { return "No chapter has the id \(id)." }
                editor.chapters.remove(id)
            case .addMark(let mark):
                guard let shape = AnnotationShape(rawValue: mark.shape) else { return "There is no mark shape \(mark.shape)." }
                if let picture = mark.picture {
                    let file = editor.mediaURL.map(ProjectStore.packageURL(forMediaAt:))?
                        .appending(path: AnnotationOverlay.imageDirectory).appending(path: picture)
                    guard let file, FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
                        return "This project has no picture \(picture). Bring one in with import_image."
                    }
                }
                var track = editor.annotations.track.adding(
                    shape: shape, startX: mark.fromX, startY: Self.up(mark.fromY), endX: mark.toX, endY: Self.up(mark.toY),
                    start: Nanoseconds(mark.startNanos),
                    end: Nanoseconds(mark.startNanos + Int64(mark.seconds * 1e9)),
                    imageName: mark.picture ?? "")
                if let text = mark.text, var item = track.items.first(where: { $0.id == editor.annotations.track.nextID }) {
                    item.text = text
                    track = track.replacing(item)
                }
                editor.annotations.restore(track)
            case .removeMark(let id):
                guard editor.annotations.track.items.contains(where: { $0.id == id }) else { return "No mark has the id \(id)." }
                editor.annotations.remove(id)
            case .hideRegion(let region):
                var track = editor.redactions.track.adding(
                    x: region.x, y: region.y, width: region.width, height: region.height,
                    start: Nanoseconds(region.startNanos), end: Nanoseconds(region.endNanos))
                if region.oval, var item = track.items.first(where: { $0.id == editor.redactions.track.nextID }) {
                    item.region.isOval = true
                    track = track.replacing(item)
                }
                editor.redactions.restore(track)
            case .removeHiddenRegion(let id):
                guard editor.redactions.track.items.contains(where: { $0.id == id }) else { return "No hidden region has the id \(id)." }
                editor.redactions.remove(id)
            case .setCamera(let fields):
                guard hasCamera else { return "This recording has no camera to place." }
                editor.cameraStyle = editor.cameraStyle.changing(
                    widthFraction: fields.size, x: fields.x, y: fields.y.map(Self.up),
                    isHidden: fields.hidden, shape: fields.shape.flatMap(CameraOverlayStyle.Shape.init(rawValue:)),
                    isMirrored: fields.mirrored)
            }
            return nil
        }
    }

    /// A title with the given fields applied and the others left.
    private func applying(_ fields: TitleFields, to item: TextItem) -> TextItem {
        var item = item
        if let text = fields.text { item.text = text }
        if let start = fields.startNanos {
            let length = item.end.rawValue - item.start.rawValue
            item.start = Nanoseconds(start)
            item.end = Nanoseconds(start + length)
        }
        if let seconds = fields.seconds { item.end = Nanoseconds(item.start.rawValue + Int64(seconds * 1e9)) }
        let rgb = fields.color.flatMap(EditorLook.components)
        item.style = item.style.changing(heightFraction: fields.size, x: fields.x, y: fields.y.map(Self.up),
                                         isBold: fields.bold, red: rgb?.red, green: rgb?.green, blue: rgb?.blue)
        return item
    }
}
