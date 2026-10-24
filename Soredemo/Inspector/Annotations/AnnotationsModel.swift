import Compositing
import Foundation
import Observation
import Overlays
import Render
import Timeline

/// The arrows, lines, boxes and ellipses drawn over a recording.
///
/// **Published to the compositor on every change**, like every other model here. An annotation
/// is placed by looking at it — a person drags a slider and checks the arrow is on the button —
/// so a change that reached the preview only on the next play would be a change they could not
/// judge.
@Observable
final class AnnotationsModel {
    private(set) var track = AnnotationTrack()
    var selection: Int?
    /// The shape the next annotation gets. Held on the model rather than passed in, so a person
    /// drawing three arrows in a row picks "arrow" once.
    var nextShape: AnnotationShape = .arrow
    /// Why a chosen picture did not take, said where it was chosen. `nil` once one does.
    private(set) var pictureFailure: String?

    /// Three seconds. Long enough to read an arrow and notice what it points at, short enough
    /// that leaving one on by accident is obvious — `TextPanel` uses the same reasoning for its
    /// own default and this deliberately matches it, so a title and an arrow added at the same
    /// playhead leave together.
    static let defaultDuration = Nanoseconds(3_000_000_000)

    init() { publish() }

    var selected: AnnotationItem? {
        selection.flatMap { id in track.items.first { $0.id == id } }
    }

    /// A new annotation across the middle of the frame, big enough to see and to grab.
    ///
    /// **Not a zero-length one waiting to be dragged.** There is no draw-on-the-preview surface
    /// yet, and an annotation with no length draws nothing at all — so offering one would be
    /// offering a row in a list and an empty picture, which reads as the feature being broken.
    /// The numbers put it clear of the frame's edges in the recording's own coordinates, where
    /// `y` runs from the bottom.
    func add(at playhead: Nanoseconds, imageName: String = "") {
        track = track.adding(shape: nextShape,
                             startX: 0.3, startY: 0.35, endX: 0.62, endY: 0.6,
                             start: playhead,
                             end: Nanoseconds(playhead.rawValue + Self.defaultDuration.rawValue),
                             imageName: imageName)
        selection = track.items.map(\.id).max()
        publish()
    }

    func update(_ item: AnnotationItem) {
        track = track.replacing(item)
        publish()
    }

    func remove(_ id: Int) {
        track = track.removing(id)
        if selection == id { selection = nil }
        publish()
    }

    func restore(_ saved: AnnotationTrack) {
        track = saved
        selection = nil
        publish()
    }

    /// Moves the annotation to start at the playhead, **keeping its length** — "start here" is
    /// about when it appears, and an arrow that also changed how long it stays would be two
    /// edits for one press.
    func startHere(_ item: AnnotationItem, at playhead: Nanoseconds) {
        var changed = item
        changed.start = playhead
        changed.end = Nanoseconds(playhead.rawValue + item.duration.rawValue)
        update(changed)
    }

    /// Ends the annotation at the playhead. Returns whether it did.
    ///
    /// **Refused rather than silently reordered**: an end at or before its start is a
    /// zero-length annotation that draws nothing, and a button that quietly did something else
    /// would be worse than one that does nothing. The panel disables the button on the same
    /// test, from `canEndHere`.
    @discardableResult
    func endHere(_ item: AnnotationItem, at playhead: Nanoseconds) -> Bool {
        guard Self.canEndHere(item, at: playhead) else { return false }
        var changed = item
        changed.end = playhead
        update(changed)
        return true
    }

    static func canEndHere(_ item: AnnotationItem, at playhead: Nanoseconds) -> Bool {
        playhead.rawValue > item.start.rawValue
    }

    /// Copies a picture a person chose into the project, returning the name it is kept under,
    /// or `nil` with `pictureFailure` saying why.
    ///
    /// **Copied, not referenced.** A project is a package that travels, and a logo read from
    /// somebody's Downloads folder would be missing from every copy of it. The name is the file's
    /// own, checked by `StageBackground.isSafeImageFilename` — the same rule image backgrounds
    /// use, because the compositor joins it onto a path. **A same-named picture replaces the old
    /// one, and the renderer is told** (`forgetPackageImages`), or it goes on drawing the one
    /// replaced — `docs/design/2026-10-24-a-replaced-picture-is-drawn.md`.
    func adoptPicture(_ source: URL, packageURL: URL) -> String? {
        let name = source.lastPathComponent
        guard StageBackground.isSafeImageFilename(name) else {
            pictureFailure = String(localized: "\(name) is not a name this can use.")
            return nil
        }
        do {
            try ProjectStore.copyIntoPackage(source, directory: AnnotationOverlay.imageDirectory,
                                             packageURL: packageURL)
        } catch {
            pictureFailure = String(localized: "Could not copy \(name) into the project: \(String(describing: error))")
            return nil
        }
        CoreImageFrameRenderer.forgetPackageImages()
        pictureFailure = nil
        return name
    }

    private func publish() {
        StageCompositor.annotations = track
    }
}
